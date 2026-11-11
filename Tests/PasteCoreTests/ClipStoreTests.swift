import Foundation
import XCTest
@testable import PasteCore

/// Storage tests: search modes, pinboard filters, cleanup policies and
/// settings persistence.
final class ClipStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: ClipStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteStoreTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try! ClipStore(path: tempDir.appendingPathComponent("paste.db").path)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    @discardableResult
    private func add(
        _ text: String?,
        kind: ClipKind = .text,
        at: Int64,
        imagePath: String? = nil,
        board: Int64? = nil,
        source: String = "Notes",
        sourcePath: String = "/Applications/Notes.app"
    ) throws -> Int64 {
        try store.insertClip(Clip(
            kind: kind,
            text: text,
            imagePath: imagePath,
            sourceName: source,
            sourcePath: sourcePath,
            sourceColor: "#4f8ef7",
            sourceIcon: "",
            pinboardId: board,
            createdAt: at,
            pasteCount: 0
        ))
    }

    private func texts(_ filter: PinboardFilter = .all) throws -> [String] {
        try store.listClips(filter: filter, limit: 1_000).compactMap(\.text)
    }

    func testPlainSearchEscapesLikeWildcards() throws {
        try add("100% off", at: 1)
        try add("1000 off", at: 2)
        try add("a_b", at: 3)
        try add("axb", at: 4)

        XCTAssertEqual(try store.listClips(search: "100%", limit: 100).compactMap(\.text), ["100% off"])
        XCTAssertEqual(try store.listClips(search: "a_b", limit: 100).compactMap(\.text), ["a_b"])
    }

    func testWildcardSearchMatchesGlobSemantics() throws {
        try add("alpha note", at: 1)
        try add("alpha", at: 2)
        try add("alpha1", at: 3)
        try add("50% off", at: 4)
        try add("投机非日内开仓", at: 5)
        try add("投机日记", at: 6)

        XCTAssertEqual(try store.listClips(search: "*note", searchMode: "wildcard", limit: 100).count, 1)
        // Wildcard mode is a real GLOB: `?` matches exactly one character on
        // a full-string match, so "alpha?" cannot reach "alpha note".
        XCTAssertEqual(
            try store.listClips(search: "alpha?", searchMode: "wildcard", limit: 100).compactMap(\.text),
            ["alpha1"]
        )
        // % is literal in wildcard mode, not an SQL wildcard.
        XCTAssertEqual(try store.listClips(search: "50%*", searchMode: "wildcard", limit: 100).compactMap(\.text), ["50% off"])
        XCTAssertEqual(try store.listClips(search: "投*仓", searchMode: "wildcard", limit: 100).compactMap(\.text), ["投机非日内开仓"])
    }

    func testRegexSearchIsCaseInsensitiveAndInvalidPatternIsSafe() throws {
        try add("Hello World", at: 1)
        try add("goodbye", at: 2)

        XCTAssertEqual(try store.listClips(search: "^hello", searchMode: "regex", limit: 100).count, 1)
        XCTAssertEqual(try store.listClips(search: "[", searchMode: "regex", limit: 100).count, 0)
    }

    /// Regression guard: mixing numbered and anonymous SQL placeholders
    /// once made a board + wildcard/regex search silently return [].
    func testBoardCombinedWithWildcardAndRegex() throws {
        let board = try store.insertPinboard(name: "Work")
        try add("alpha note", at: 1, board: board.id)
        try add("beta note", at: 2, board: board.id)
        try add("alpha other", at: 3)

        XCTAssertEqual(
            try store.listClips(filter: .board(board.id), search: "alpha*", searchMode: "wildcard", limit: 100).count,
            1
        )
        XCTAssertEqual(
            try store.listClips(filter: .board(board.id), search: "^ALPHA", searchMode: "regex", kind: .text, limit: 100).count,
            1
        )
        XCTAssertEqual(try store.listClips(filter: .board(board.id), limit: 100).count, 2)
    }

    func testClearHistoryKeepsPinnedAndReportsImages() throws {
        let board = try store.insertPinboard(name: "b")
        let unpinned = try add(nil, kind: .image, at: 1, imagePath: "/tmp/a.png")
        let pinned = try add("kept", at: 2)
        try store.setPinboard(id: pinned, pinboardId: board.id)

        let removed = try store.clearHistory()
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.compactMap { $0 }, ["/tmp/a.png"])
        let rest = try store.listClips(filter: .all, limit: 100)
        XCTAssertEqual(rest.map(\.id), [pinned])
        XCTAssertNil(try store.getClip(id: unpinned))
    }

    func testPruneExpiredKeepsPinnedAndRecent() throws {
        let board = try store.insertPinboard(name: "b")
        try add("old", at: 100)
        let oldPinned = try add("old pinned", at: 100)
        try store.setPinboard(id: oldPinned, pinboardId: board.id)
        try add("recent", at: 900)

        let victims = try store.pruneExpired(cutoffMs: 500)
        XCTAssertEqual(victims.count, 1)
        XCTAssertEqual(try texts(), ["recent", "old pinned"])
    }

    func testEnforceLimitDropsOldest() throws {
        let board = try store.insertPinboard(name: "b")
        try add("oldest", at: 100)
        try add("middle", at: 200)
        try add("newest", at: 300)
        let pinned = try add("pinned", at: 50)
        try store.setPinboard(id: pinned, pinboardId: board.id)

        let victims = try store.enforceLimit(max: 2)
        XCTAssertEqual(victims.count, 1)
        XCTAssertEqual(try texts(), ["newest", "middle", "pinned"])
        XCTAssertEqual(try store.listClips(filter: .history, limit: 100).count, 2)
    }

    func testPinboardCRUDAndUnpin() throws {
        let first = try store.insertPinboard(name: "First")
        let second = try store.insertPinboard(name: "Second")
        XCTAssertEqual(first.position, 1)
        XCTAssertEqual(second.position, 2)
        XCTAssertLessThanOrEqual(abs(second.createdAt - Int64(Date().timeIntervalSince1970)), 2)

        try store.renamePinboard(id: first.id, name: "Renamed")
        XCTAssertEqual(try store.listPinboards().map(\.name), ["Renamed", "Second"])

        let clip = try add("x", at: 1, board: first.id)
        XCTAssertEqual(try store.listClips(filter: .board(first.id), limit: 100).count, 1)
        try store.setPinboardForBoard(first.id)
        XCTAssertEqual(try store.getClip(id: clip)?.pinboardId, nil)
        try store.deletePinboard(id: first.id)
        XCTAssertEqual(try store.listPinboards().count, 1)
    }

    func testSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.hotkey = "Alt+Space"
        settings.retentionDays = 30
        settings.wheelDirection = "natural"
        settings.excludedApps = ["1password"]
        try store.saveSettings(settings)
        XCTAssertEqual(try store.loadSettings(), settings)

        var again = try store.loadSettings()
        again.panelPosition = "top"
        try store.saveSettings(again)
        XCTAssertEqual(try store.loadSettings().panelPosition, "top") // upsert, not duplicate
    }

    func testFindTextClipTouchAndPasteCount() throws {
        let id = try add("duplicate me", at: 1)
        XCTAssertEqual(try store.findTextClip("duplicate me")?.id, id)
        XCTAssertNil(try store.findTextClip("absent"))

        try store.touchClip(id: id, nowMs: 9_999)
        XCTAssertEqual(try store.getClip(id: id)?.createdAt, 9_999)
        try store.incrementPasteCount(id: id)
        XCTAssertEqual(try store.getClip(id: id)?.pasteCount, 1)
    }

    func testDistinctSources() throws {
        try add("a", at: 1, source: "Notes", sourcePath: "/Notes.app")
        try add("b", at: 2, source: "Notes", sourcePath: "/Notes.app")
        try add("c", at: 3, source: "Safari", sourcePath: "/Safari.app")
        let sources = try store.distinctSources()
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].name, "Safari")
    }

    func testPlainSearchEscapesBackslashes() throws {
        try add("C:\\path", at: 1)
        try add("C:\\\\double", at: 2)
        XCTAssertEqual(
            try store.listClips(search: "C:\\path", limit: 100).compactMap(\.text),
            ["C:\\path"]
        )
    }

    func testInsertClipPreservesPasteCount() throws {
        let id = try store.insertClip(
            Clip(kind: .text, text: "counted", createdAt: 1, pasteCount: 7)
        )
        XCTAssertEqual(try store.getClip(id: id)?.pasteCount, 7)
    }

    func testFindClipByHashMatchesAcrossHistory() throws {
        try store.insertClip(Clip(kind: .image, imagePath: "/tmp/a.png", createdAt: 1), contentHash: "hash-a")
        try store.insertClip(Clip(kind: .image, imagePath: "/tmp/b.png", createdAt: 2), contentHash: "hash-b")
        XCTAssertEqual(try store.findClipByHash("hash-a")?.imagePath, "/tmp/a.png")
        XCTAssertNil(try store.findClipByHash("hash-x"))
    }

    func testPinnedClipsDoNotParticipateInTextDedupe() throws {
        let board = try store.insertPinboard(name: "b")
        let pinned = try add("secret", at: 1, board: board.id)
        XCTAssertNil(try store.findTextClip("secret"))

        let history = try add("secret", at: 2)
        XCTAssertEqual(try store.findTextClip("secret")?.id, history)
        XCTAssertEqual(try store.getClip(id: pinned)?.createdAt, 1)
    }

    func testPinnedClipsDoNotParticipateInHashDedupe() throws {
        let board = try store.insertPinboard(name: "b")
        try store.insertClip(
            Clip(kind: .image, imagePath: "/tmp/pinned.png", pinboardId: board.id, createdAt: 1),
            contentHash: "hash-a"
        )
        XCTAssertNil(try store.findClipByHash("hash-a"))

        let history = try store.insertClip(
            Clip(kind: .image, imagePath: "/tmp/history.png", createdAt: 2),
            contentHash: "hash-a"
        )
        XCTAssertEqual(try store.findClipByHash("hash-a")?.id, history)
    }

    func testDeletePinboardUnpinsItsClips() throws {
        let board = try store.insertPinboard(name: "b")
        let clip = try add("kept", at: 1, board: board.id)
        try store.deletePinboard(id: board.id)
        XCTAssertEqual(try store.getClip(id: clip)?.pinboardId, nil)
        XCTAssertEqual(try store.listPinboards().count, 0)
        XCTAssertEqual(try texts(), ["kept"])
    }
}
