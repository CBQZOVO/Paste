import Foundation

/// Which clips to list: unpinned history, one pinboard, or everything.
public enum PinboardFilter: Sendable {
    case all
    case history
    case board(Int64)
}

public struct DeletedClip: Equatable, Sendable {
    public let id: Int64
    public let imagePath: String?
}

/// All reads and writes against paste.db. Queries bind every value through
/// anonymous placeholders, and the schema is created on open if missing.
public final class ClipStore {
    private let db: SQLite
    /// A read-only open may see an older schema where some columns do not
    /// exist yet; those are selected as constants so diagnostics still work.
    private let clipColumns: String

    private static let allColumns = """
        id, kind, text, html, image_path, files, source_name, source_path,
        source_color, source_icon, pinboard_id, created_at, paste_count
        """

    /// `readOnly` is for diagnostics: it never runs PRAGMAs or DDL, so it can
    /// safely inspect the database of a running app.
    public init(path: String, readOnly: Bool = false) throws {
        db = try SQLite(path: path, readOnly: readOnly)
        if readOnly {
            let hasIcon = ((try? db.rows(
                "SELECT COUNT(*) FROM pragma_table_info('clips') WHERE name = 'source_icon'"
            ) { $0.int(0) })?.first ?? 0) > 0
            clipColumns = hasIcon
                ? Self.allColumns
                : Self.allColumns.replacingOccurrences(
                    of: "source_icon", with: "'' AS source_icon")
        } else {
            try db.configure()
            clipColumns = Self.allColumns
        }
    }

    /// Opens the app's own database. Creating the data directory belongs to
    /// the app entry point, not to an arbitrary (possibly test) path.
    public convenience init(readOnly: Bool = false) throws {
        if !readOnly { try PastePaths.ensureDataDirectory() }
        try self.init(path: PastePaths.database().path, readOnly: readOnly)
    }

    // MARK: - Clips

    public func listClips(
        filter: PinboardFilter = .history,
        search: String = "",
        searchMode: String = "plain",
        kind: ClipKind? = nil,
        limit: Int64 = 100,
        offset: Int64 = 0
    ) throws -> [Clip] {
        var sql = "SELECT \(clipColumns) FROM clips WHERE 1=1"
        // Every placeholder is anonymous "?" and bound left to right. Mixing
        // numbered and anonymous params breaks board + wildcard/regex
        // searches.
        var args: [SQLValue] = []
        switch filter {
        case .all:
            break
        case .history:
            sql += " AND pinboard_id IS NULL"
        case .board(let id):
            sql += " AND pinboard_id = ?"
            args.append(.int(id))
        }
        if !search.isEmpty {
            switch searchMode {
            case "wildcard":
                // GLOB gives real glob semantics: `*` = any run, `?` =
                // exactly one character, `%`/`_` are literal. Full-string
                // match; use `*x*` for a substring search.
                sql += " AND text GLOB ?"
                args.append(.text(search))
            case "regex":
                sql += " AND text REGEXP ?"
                args.append(.text(search))
            default:
                sql += " AND text LIKE '%' || ? || '%' ESCAPE '\\'"
                args.append(.text(Self.escapeLike(search)))
            }
        }
        if let kind {
            sql += " AND kind = ?"
            args.append(.text(kind.rawValue))
        }
        sql += " ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?"
        args.append(.int(limit))
        args.append(.int(offset))

        return try db.rows(sql, args, self.clip(from:))
    }

    public func countClips() throws -> Int {
        let rows = try db.rows("SELECT COUNT(*) FROM clips") { $0.int(0) }
        return rows.first.map(Int.init) ?? 0
    }

    public func getClip(id: Int64) throws -> Clip? {
        let sql = "SELECT \(clipColumns) FROM clips WHERE id = ?"
        return try db.rows(sql, [.int(id)], self.clip(from:)).first
    }

    @discardableResult
    public func insertClip(_ clip: Clip, contentHash: String? = nil) throws -> Int64 {
        try db.execute(
            """
            INSERT INTO clips (kind, text, html, image_path, files, source_name,
                               source_path, source_color, source_icon,
                               pinboard_id, created_at, paste_count, content_hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(clip.kind.rawValue),
                Self.optionalText(clip.text),
                Self.optionalText(clip.html),
                Self.optionalText(clip.imagePath),
                Self.optionalText(clip.files),
                .text(clip.sourceName),
                .text(clip.sourcePath),
                .text(clip.sourceColor),
                .text(clip.sourceIcon),
                Self.optionalInt(clip.pinboardId),
                .int(clip.createdAt),
                .int(clip.pasteCount),
                Self.optionalText(contentHash),
            ]
        )
        return db.lastInsertRowID
    }

    @discardableResult
    public func deleteClip(id: Int64) throws -> Int {
        try db.execute("DELETE FROM clips WHERE id = ?", [.int(id)])
        return db.changes
    }

    @discardableResult
    public func setPinboard(id: Int64, pinboardId: Int64?) throws -> Int {
        try db.execute(
            "UPDATE clips SET pinboard_id = ? WHERE id = ?",
            [Self.optionalInt(pinboardId), .int(id)]
        )
        return db.changes
    }

    @discardableResult
    public func setPinboardForBoard(_ pinboardId: Int64) throws -> Int {
        try db.execute(
            "UPDATE clips SET pinboard_id = NULL WHERE pinboard_id = ?",
            [.int(pinboardId)]
        )
        return db.changes
    }

    @discardableResult
    public func incrementPasteCount(id: Int64) throws -> Int {
        try db.execute(
            "UPDATE clips SET paste_count = paste_count + 1 WHERE id = ?",
            [.int(id)]
        )
        return db.changes
    }

    @discardableResult
    public func touchClip(id: Int64, nowMs: Int64) throws -> Int {
        try db.execute(
            "UPDATE clips SET created_at = ? WHERE id = ?",
            [.int(nowMs), .int(id)]
        )
        return db.changes
    }

    /// Dedupe only considers history rows. A pinned copy belongs to its
    /// board: touching it would silently swallow the newly copied content.
    public func findTextClip(_ text: String) throws -> Clip? {
        let sql = """
            SELECT \(clipColumns) FROM clips
            WHERE kind IN ('text','link','color') AND text = ?
              AND pinboard_id IS NULL
            ORDER BY created_at DESC, id DESC LIMIT 1
            """
        return try db.rows(sql, [.text(text)], self.clip(from:)).first
    }

    /// Image and file dedupe key: identical content anywhere in history,
    /// not just the newest row.
    public func findClipByHash(_ hash: String) throws -> Clip? {
        let sql = """
            SELECT \(clipColumns) FROM clips
            WHERE content_hash = ? AND pinboard_id IS NULL
            ORDER BY created_at DESC, id DESC LIMIT 1
            """
        return try db.rows(sql, [.text(hash)], self.clip(from:)).first
    }

    /// Delete all unpinned clips; returns their image paths so the caller can
    /// remove the orphan PNGs too.
    public func clearHistory() throws -> [String?] {
        try db.transaction {
            let paths = try db.rows(
                "SELECT image_path FROM clips WHERE pinboard_id IS NULL"
            ) { $0.string(0) }
            try db.execute("DELETE FROM clips WHERE pinboard_id IS NULL")
            return paths
        }
    }

    public func pruneExpired(cutoffMs: Int64) throws -> [DeletedClip] {
        try db.transaction {
            let victims = try db.rows(
                """
                SELECT id, image_path FROM clips
                WHERE pinboard_id IS NULL AND created_at < ?
                """,
                [.int(cutoffMs)]
            ) { DeletedClip(id: $0.int(0), imagePath: $0.string(1)) }
            if !victims.isEmpty {
                try db.execute(
                    "DELETE FROM clips WHERE pinboard_id IS NULL AND created_at < ?",
                    [.int(cutoffMs)]
                )
            }
            return victims
        }
    }

    /// Keep the newest `max` unpinned clips and delete the rest in the same
    /// transaction, returning the rows whose image files the caller must
    /// remove.
    public func enforceLimit(max: Int64) throws -> [DeletedClip] {
        if max <= 0 { return [] }
        return try db.transaction {
            let victims = try db.rows(
                """
                SELECT id, image_path FROM clips WHERE pinboard_id IS NULL
                ORDER BY created_at DESC, id DESC LIMIT -1 OFFSET ?
                """,
                [.int(max)]
            ) { DeletedClip(id: $0.int(0), imagePath: $0.string(1)) }
            if !victims.isEmpty {
                // One statement instead of concatenating every victim id into
                // the SQL text; same transaction, same end state.
                try db.execute(
                    """
                    DELETE FROM clips WHERE pinboard_id IS NULL AND id NOT IN (
                        SELECT id FROM clips WHERE pinboard_id IS NULL
                        ORDER BY created_at DESC, id DESC LIMIT ?
                    )
                    """,
                    [.int(max)]
                )
            }
            return victims
        }
    }

    public func distinctSources() throws -> [Source] {
        try db.rows(
            """
            SELECT source_name, source_path, source_color FROM clips
            WHERE source_name != '' GROUP BY source_path
            ORDER BY MAX(created_at) DESC LIMIT 50
            """
        ) {
            Source(
                name: $0.requiredString(0),
                path: $0.requiredString(1),
                color: $0.requiredString(2)
            )
        }
    }

    // MARK: - Pinboards

    public func listPinboards() throws -> [Pinboard] {
        try db.rows(
            "SELECT id, name, position, created_at FROM pinboards ORDER BY position, id"
        ) {
            Pinboard(
                id: $0.int(0),
                name: $0.requiredString(1),
                position: $0.int(2),
                createdAt: $0.int(3)
            )
        }
    }

    public func insertPinboard(name: String) throws -> Pinboard {
        let rows = try db.rows(
            "SELECT COALESCE(MAX(position), 0) + 1 FROM pinboards"
        ) { $0.int(0) }
        let position = rows.first ?? 1
        let now = Int64(Date().timeIntervalSince1970) // pinboards.created_at uses seconds
        try db.execute(
            "INSERT INTO pinboards (name, position, created_at) VALUES (?, ?, ?)",
            [.text(name), .int(position), .int(now)]
        )
        return Pinboard(id: db.lastInsertRowID, name: name, position: position, createdAt: now)
    }

    @discardableResult
    public func renamePinboard(id: Int64, name: String) throws -> Int {
        try db.execute(
            "UPDATE pinboards SET name = ? WHERE id = ?",
            [.text(name), .int(id)]
        )
        return db.changes
    }

    @discardableResult
    public func deletePinboard(id: Int64) throws -> Int {
        // Unpin the board's clips in the same transaction: a bare DELETE
        // would leave orphaned pinboard_id values that history never shows
        // and the cleanup queries never collect.
        try db.transaction {
            try db.execute(
                "UPDATE clips SET pinboard_id = NULL WHERE pinboard_id = ?",
                [.int(id)]
            )
            try db.execute("DELETE FROM pinboards WHERE id = ?", [.int(id)])
            return db.changes
        }
    }

    // MARK: - Settings

    public func getSetting(_ key: String) throws -> String? {
        let values: [String?] = try db.rows(
            "SELECT value FROM settings WHERE key = ?", [.text(key)]
        ) { $0.string(0) }
        return values.first.flatMap { $0 }
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try db.execute(
            """
            INSERT INTO settings(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [.text(key), .text(value)]
        )
    }

    /// A missing or unparsable blob yields the defaults; a partial blob keeps
    /// every field that did decode, so one corrupt value can never reset the
    /// whole configuration.
    public func loadSettings() throws -> AppSettings {
        guard let json = try getSetting("settings"),
              let data = json.data(using: .utf8) else {
            return AppSettings()
        }
        guard let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            NSLog("[paste] settings blob is unreadable; using defaults")
            return AppSettings()
        }
        return decoded
    }

    public func saveSettings(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try setSetting("settings", json)
    }

    // MARK: - Helpers

    private func clip(from row: SQLRow) -> Clip {
        Clip(
            id: row.int(0),
            kind: ClipKind(dbValue: row.requiredString(1)),
            text: row.string(2),
            html: row.string(3),
            imagePath: row.string(4),
            files: row.string(5),
            sourceName: row.requiredString(6),
            sourcePath: row.requiredString(7),
            sourceColor: row.requiredString(8),
            sourceIcon: row.requiredString(9),
            pinboardId: row.optionalInt(10),
            createdAt: row.int(11),
            pasteCount: row.int(12)
        )
    }

    private static func optionalText(_ value: String?) -> SQLValue {
        value.map(SQLValue.text) ?? .null
    }

    private static func optionalInt(_ value: Int64?) -> SQLValue {
        value.map(SQLValue.int) ?? .null
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
