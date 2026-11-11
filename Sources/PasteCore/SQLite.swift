import Foundation
import SQLite3

public enum PasteError: Error, CustomStringConvertible {
    case open(String)
    case sql(String, String)

    public var description: String {
        switch self {
        case .open(let message): return "cannot open database: \(message)"
        case .sql(let sql, let message): return "SQLite error: \(message) | \(sql)"
        }
    }
}

enum SQLValue {
    case null
    case int(Int64)
    case text(String)
}

/// Read-only view of one result row. Text is decoded lossily so a damaged
/// row can never crash the app with an invalid UTF-8 trap.
struct SQLRow {
    private let stmt: OpaquePointer

    init(_ stmt: OpaquePointer) {
        self.stmt = stmt
    }

    func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(stmt, column)
    }

    func optionalInt(_ column: Int32) -> Int64? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : int(column)
    }

    func string(_ column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
              let bytes = sqlite3_column_text(stmt, column) else { return nil }
        let buffer = UnsafeBufferPointer(
            start: bytes,
            count: Int(sqlite3_column_bytes(stmt, column))
        )
        return String(decoding: buffer, as: UTF8.self)
    }

    func requiredString(_ column: Int32) -> String {
        string(column) ?? ""
    }
}

/// Compiled patterns for the REGEXP function, cached so a regex search does
/// not recompile the expression for every row. NSCache is thread-safe but not
/// marked Sendable, so it rides in an unchecked wrapper.
private final class RegexpCache: @unchecked Sendable {
    static let shared = RegexpCache()
    let cache = NSCache<NSString, NSRegularExpression>()

    private init() {
        // Search queries are user input; without a bound, typing a new
        // pattern on every keystroke grows this cache forever.
        cache.countLimit = 64
    }
}

/// The REGEXP function used by regex search mode. Matching is
/// case-insensitive; an invalid pattern matches nothing instead of failing
/// the query.
private let regexpFunction: @convention(c) (
    OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?
) -> Void = { ctx, argc, argv in
    guard let ctx else { return }
    guard argc == 2, let argv,
          let patternBytes = sqlite3_value_text(argv[0]),
          let textBytes = sqlite3_value_text(argv[1]) else {
        sqlite3_result_int(ctx, 0)
        return
    }
    let pattern = sqliteCString(patternBytes, sqlite3_value_bytes(argv[0]))
    let text = sqliteCString(textBytes, sqlite3_value_bytes(argv[1]))
    let key = pattern as NSString
    let regex: NSRegularExpression
    if let cached = RegexpCache.shared.cache.object(forKey: key) {
        regex = cached
    } else {
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            sqlite3_result_int(ctx, 0)
            return
        }
        RegexpCache.shared.cache.setObject(compiled, forKey: key)
        regex = compiled
    }
    let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    sqlite3_result_int(ctx, found ? 1 : 0)
}

private func sqliteCString(_ bytes: UnsafePointer<UInt8>, _ count: Int32) -> String {
    String(decoding: UnsafeBufferPointer(start: bytes, count: Int(count)), as: UTF8.self)
}

/// Thin wrapper over the system libsqlite3 C API. Single connection, no
/// concurrency abstraction — the app owns it from one serial context.
final class SQLite {
    let handle: OpaquePointer

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, readOnly: Bool) throws {
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE)
            | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 returned \(rc)"
            if let db { sqlite3_close(db) }
            throw PasteError.open(message)
        }
        handle = opened
        sqlite3_busy_timeout(handle, 5_000)
        if sqlite3_create_function_v2(
            handle, "REGEXP", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            nil, regexpFunction, nil, nil, nil
        ) != SQLITE_OK {
            NSLog("[paste] REGEXP function unavailable: %@", errorMessage)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }
    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// For PRAGMAs and multi-statement DDL, where step() returns a row.
    func execRaw(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        defer { if let error { sqlite3_free(error) } }
        guard rc == SQLITE_OK else {
            throw PasteError.sql(sql, error.map { String(cString: $0) } ?? errorMessage)
        }
    }

    func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw PasteError.sql(sql, errorMessage)
        }
    }

    func rows<T>(
        _ sql: String,
        _ params: [SQLValue] = [],
        _ map: (SQLRow) throws -> T
    ) throws -> [T] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var result: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw PasteError.sql(sql, errorMessage) }
            try result.append(map(SQLRow(stmt)))
        }
        return result
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execRaw("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execRaw("COMMIT")
            return value
        } catch {
            try? execRaw("ROLLBACK")
            throw error
        }
    }

    /// Columns added after the initial schema. Every writable open backfills
    /// whichever are missing, so an older database can never reach the read
    /// path with an absent column.
    private static let migratedColumns: [(name: String, ddl: String)] = [
        ("source_icon", "TEXT NOT NULL DEFAULT ''"),
        ("content_hash", "TEXT"),
    ]

    /// Only for writable databases; a read-only diagnostic must never run DDL.
    func configure() throws {
        try execRaw("PRAGMA journal_mode = WAL")
        try execRaw("PRAGMA synchronous = NORMAL")
        // Tables first, then backfill missing columns, THEN the indexes —
        // idx_clips_text/idx_clips_hash reference columns an older table may
        // not have until the ALTERs below run.
        try execRaw(Self.schemaSQL)
        for column in Self.migratedColumns {
            let present = try rows(
                "SELECT COUNT(*) FROM pragma_table_info('clips') WHERE name = ?",
                [.text(column.name)]
            ) { $0.int(0) }.first ?? 0
            if present == 0 {
                try execRaw("ALTER TABLE clips ADD COLUMN \(column.name) \(column.ddl);")
            }
        }
        try execRaw(Self.indexSQL)
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw PasteError.sql(sql, errorMessage)
        }
        do {
            for (offset, value) in params.enumerated() {
                let index = Int32(offset + 1)
                let rc: Int32
                switch value {
                case .null:
                    rc = sqlite3_bind_null(stmt, index)
                case .int(let number):
                    rc = sqlite3_bind_int64(stmt, index, number)
                case .text(let string):
                    rc = sqlite3_bind_text(stmt, index, string, -1, SQLite.transient)
                }
                guard rc == SQLITE_OK else {
                    throw PasteError.sql("bind #\(index) of \(sql)", errorMessage)
                }
            }
        } catch {
            sqlite3_finalize(stmt)
            throw error
        }
        return stmt
    }

    /// Table definitions. `configure()` also backfills the columns added
    /// after the initial schema, so older databases remain readable.
    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS clips (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            kind          TEXT NOT NULL,
            text          TEXT,
            html          TEXT,
            image_path    TEXT,
            files         TEXT,
            source_name   TEXT NOT NULL DEFAULT '',
            source_path   TEXT NOT NULL DEFAULT '',
            source_color  TEXT NOT NULL DEFAULT '',
            source_icon   TEXT NOT NULL DEFAULT '',
            pinboard_id   INTEGER,
            created_at    INTEGER NOT NULL,
            paste_count   INTEGER NOT NULL DEFAULT 0,
            content_hash  TEXT
        );

        CREATE TABLE IF NOT EXISTS pinboards (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT NOT NULL,
            position   INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """

    /// Kept separate from `schemaSQL`: these must run AFTER the migrated
    /// columns are backfilled, or an older clips table breaks their creation.
    private static let indexSQL = """
        CREATE INDEX IF NOT EXISTS idx_clips_created ON clips(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_clips_pinboard ON clips(pinboard_id);
        CREATE INDEX IF NOT EXISTS idx_clips_text ON clips(text);
        CREATE INDEX IF NOT EXISTS idx_clips_hash ON clips(content_hash);
        """
}
