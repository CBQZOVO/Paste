import Foundation
import XCTest
@testable import PasteCore

/// Compatibility tests: build databases with the older schema and data
/// shapes, then read them through the current store. A drifting column,
/// timestamp unit or settings default would damage an existing user's
/// history, so every field is asserted explicitly.
final class LegacyDatabaseTests: XCTestCase {
    private var tempDir: URL!
    private var dbPath: String { tempDir.appendingPathComponent("paste.db").path }

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteCompatibility-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private static let schema = """
        CREATE TABLE clips (
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
            paste_count   INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_clips_created ON clips(created_at DESC);
        CREATE INDEX idx_clips_pinboard ON clips(pinboard_id);
        CREATE TABLE pinboards (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT NOT NULL,
            position   INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        );
        CREATE TABLE settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """

    private static let fullSettingsJSON = """
        {"hotkey":"CmdOrCtrl+Shift+V","quickPaste":true,"maxClips":500,\
        "retentionDays":7,"searchMode":"regex","alwaysPlainText":false,\
        "excludedApps":["1password"],"paused":true,"autostart":false,\
        "theme":"dark","panelPosition":"bottom","wheelDirection":"natural",\
        "trayIcon":"emerald","language":"zh"}
        """

    private func makeDatabase(
        withoutSourceIcon: Bool = false,
        settingsJSON: String? = fullSettingsJSON
    ) throws {
        let db = try SQLite(path: dbPath, readOnly: false)
        let ddl = withoutSourceIcon
            ? Self.schema.split(separator: "\n")
                .filter { !$0.contains("source_icon") }
                .joined(separator: "\n")
            : Self.schema
        try db.execRaw(ddl)

        let columns = withoutSourceIcon
            ? "id, kind, text, html, image_path, files, source_name, source_path, source_color, pinboard_id, created_at, paste_count"
            : "id, kind, text, html, image_path, files, source_name, source_path, source_color, source_icon, pinboard_id, created_at, paste_count"
        let placeholders = Array(repeating: "?", count: columns.split(separator: ",").count)
            .joined(separator: ",")
        let insert = "INSERT INTO clips (\(columns)) VALUES (\(placeholders))"

        func clip(
            _ id: Int64, _ kind: String, _ text: String?, _ html: String?,
            _ image: String?, _ files: String?, _ name: String, _ path: String,
            _ color: String, _ icon: String, _ board: Int64?, _ at: Int64, _ count: Int64
        ) throws {
            var args: [SQLValue] = [
                .int(id), .text(kind), Self.text(text), Self.text(html),
                Self.text(image), Self.text(files), .text(name), .text(path), .text(color),
            ]
            if !withoutSourceIcon { args.append(.text(icon)) }
            args += [Self.integer(board), .int(at), .int(count)]
            try db.execute(insert, args)
        }

        try clip(1, "text", "中文 😀 第一行\n第二行", "<b>rich</b>", nil, nil,
                 "Notes", "/Applications/Notes.app", "#4f8ef7",
                 "/tmp/icons/notes.png", nil, 1_700_000_000_004, 3)
        try clip(2, "link", "https://example.com/a_b", nil, nil, nil,
                 "Safari", "/Applications/Safari.app", "#1e88e5",
                 "", nil, 1_700_000_000_003, 0)
        try clip(3, "image", nil, nil, "/tmp/images/a.png", nil,
                 "Preview", "/Applications/Preview.app", "#999999",
                 "", nil, 1_700_000_000_002, 1)
        try clip(4, "file", nil, nil, nil, "[\"/tmp/a.txt\"]",
                 "Finder", "/System/Library/CoreServices/Finder.app", "#3b82f6",
                 "", nil, 1_700_000_000_001, 0)
        try clip(5, "color", "#22c55e", nil, nil, nil,
                 "Picker", "", "", "", nil, 1_700_000_000_000, 0)
        try clip(6, "text", "pinned", nil, nil, nil,
                 "Notes", "", "", "", 1, 1_699_999_999_999, 0)

        try db.execute(
            "INSERT INTO pinboards (id, name, position, created_at) VALUES (?, ?, ?, ?)",
            [.int(1), .text("工作"), .int(1), .int(1_700_000_000)]
        )
        if let settingsJSON {
            try db.execute(
                "INSERT INTO settings (key, value) VALUES ('settings', ?)",
                [.text(settingsJSON)]
            )
        }
    }

    private static func text(_ value: String?) -> SQLValue {
        value.map(SQLValue.text) ?? .null
    }

    private static func integer(_ value: Int64?) -> SQLValue {
        value.map(SQLValue.int) ?? .null
    }

    func testReadsLegacyRowsFieldByField() throws {
        try makeDatabase()
        let store = try ClipStore(path: dbPath, readOnly: true)

        let all = try store.listClips(filter: .all, limit: 100)
        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(all.map(\.id), [1, 2, 3, 4, 5, 6]) // created_at DESC

        let first = all[0]
        XCTAssertEqual(first.kind, .text)
        XCTAssertEqual(first.text, "中文 😀 第一行\n第二行")
        XCTAssertEqual(first.html, "<b>rich</b>")
        XCTAssertNil(first.imagePath)
        XCTAssertEqual(first.sourceName, "Notes")
        XCTAssertEqual(first.sourceIcon, "/tmp/icons/notes.png")
        XCTAssertNil(first.pinboardId)
        XCTAssertEqual(first.createdAt, 1_700_000_000_004) // milliseconds, not seconds
        XCTAssertEqual(first.pasteCount, 3)

        XCTAssertEqual(all[2].imagePath, "/tmp/images/a.png")
        XCTAssertEqual(all[3].files, "[\"/tmp/a.txt\"]")
        XCTAssertEqual(all[4].text, "#22c55e")
        XCTAssertEqual(all[5].pinboardId, 1)

        XCTAssertEqual(try store.listClips(filter: .history, limit: 100).count, 5)
        XCTAssertEqual(try store.listClips(filter: .board(1), limit: 100).count, 1)
        XCTAssertEqual(try store.countClips(), 6)
    }

    func testReadsLegacySettingsAndPinboards() throws {
        try makeDatabase()
        let store = try ClipStore(path: dbPath, readOnly: true)

        let settings = try store.loadSettings()
        XCTAssertEqual(settings.hotkey, "CmdOrCtrl+Shift+V")
        XCTAssertEqual(settings.maxClips, 500)
        XCTAssertEqual(settings.retentionDays, 7)
        XCTAssertEqual(settings.searchMode, "regex")
        XCTAssertEqual(settings.excludedApps, ["1password"])
        XCTAssertTrue(settings.paused)
        XCTAssertEqual(settings.panelPosition, "bottom")
        XCTAssertEqual(settings.wheelDirection, "natural")
        // theme / trayIcon / language in the blob are unknown keys and must
        // be ignored rather than breaking the decode.

        let boards = try store.listPinboards()
        XCTAssertEqual(boards.count, 1)
        XCTAssertEqual(boards[0].name, "工作")
        XCTAssertEqual(boards[0].createdAt, 1_700_000_000) // seconds
    }

    func testPartialSettingsBlobUsesDefaults() throws {
        try makeDatabase(settingsJSON: "{\"hotkey\":\"Alt+Space\"}")
        let store = try ClipStore(path: dbPath, readOnly: true)
        let settings = try store.loadSettings()

        XCTAssertEqual(settings.hotkey, "Alt+Space")
        XCTAssertTrue(settings.quickPaste)
        // Empty strings in older blobs would leave a Picker unselected and
        // center the panel; they are mapped to the real defaults instead.
        XCTAssertEqual(settings.searchMode, "plain")
        XCTAssertEqual(settings.panelPosition, "bottom")
        XCTAssertEqual(settings.wheelDirection, "default")
        XCTAssertEqual(settings.excludedApps, AppSettings.defaultExcludedApps)
    }

    func testCorruptSettingsFieldDoesNotResetOthers() throws {
        try makeDatabase(
            settingsJSON: #"{"hotkey":"Alt+Space","maxClips":"oops","panelPosition":123}"#
        )
        let store = try ClipStore(path: dbPath, readOnly: true)
        let settings = try store.loadSettings()
        XCTAssertEqual(settings.hotkey, "Alt+Space")
        XCTAssertEqual(settings.maxClips, 0)
        XCTAssertEqual(settings.panelPosition, "bottom")
    }

    func testMissingSettingsRowUsesDefaults() throws {
        try makeDatabase(settingsJSON: nil)
        let store = try ClipStore(path: dbPath, readOnly: true)
        let settings = try store.loadSettings()
        XCTAssertEqual(settings.panelPosition, "bottom")
        XCTAssertEqual(settings.wheelDirection, "default")
        XCTAssertEqual(settings.searchMode, "plain")
        XCTAssertEqual(settings.hotkey, "CmdOrCtrl+Shift+V")
    }

    func testOldSchemaWithoutSourceIconIsMigrated() throws {
        try makeDatabase(withoutSourceIcon: true)
        let store = try ClipStore(path: dbPath, readOnly: false) // runs the migration
        let clips = try store.listClips(filter: .all, limit: 100)
        XCTAssertEqual(clips.count, 6)
        XCTAssertEqual(clips[0].sourceIcon, "")
        XCTAssertEqual(clips[0].text, "中文 😀 第一行\n第二行")
        XCTAssertEqual(try store.countClips(), 6)
    }

    func testReadOnlyOpenHandlesSchemaWithoutSourceIcon() throws {
        try makeDatabase(withoutSourceIcon: true)
        // paste-dbcheck opens read-only and must not fail with
        // "no such column: source_icon" on an older database.
        let store = try ClipStore(path: dbPath, readOnly: true)
        let clips = try store.listClips(filter: .all, limit: 100)
        XCTAssertEqual(clips.count, 6)
        XCTAssertEqual(clips[0].sourceIcon, "")
    }

    func testReadOnlyOpenNeverWritesTheDatabase() throws {
        try makeDatabase()
        let before = try Data(contentsOf: URL(fileURLWithPath: dbPath))
        let store = try ClipStore(path: dbPath, readOnly: true)
        XCTAssertEqual(try store.listClips(filter: .all, limit: 100).count, 6)
        _ = try store.loadSettings()
        let after = try Data(contentsOf: URL(fileURLWithPath: dbPath))
        XCTAssertEqual(before, after)
    }
}
