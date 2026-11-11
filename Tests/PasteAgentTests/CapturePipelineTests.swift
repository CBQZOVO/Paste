import Foundation
import XCTest
import PasteCore
@testable import PasteAgent

final class CapturePipelineTests: XCTestCase {
    private var tempDir: URL!
    private var store: ClipStore!
    private var pipeline: CapturePipeline!
    private var images: URL { tempDir.appendingPathComponent("images", isDirectory: true) }

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastePipelineTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try! ClipStore(path: tempDir.appendingPathComponent("paste.db").path)
        pipeline = CapturePipeline(store: store, dataDirectory: tempDir)
    }

    override func tearDown() {
        pipeline = nil
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func snapshot(text: String? = nil, png: Data? = nil, files: [String] = []) -> ClipboardSnapshot {
        ClipboardSnapshot(
            text: text, imagePNG: png, filePaths: files,
            source: SourceApplication(name: "Notes", executableName: "notes", path: "/Notes.app")
        )
    }

    private func process(
        _ snapshot: ClipboardSnapshot,
        at: Int64,
        settings: AppSettings = AppSettings()
    ) throws -> CaptureOutcome {
        try pipeline.process(snapshot: snapshot, nowMs: at, settings: settings)
    }

    private func imageFiles() throws -> [String] {
        guard FileManager.default.fileExists(atPath: images.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: images.path)
    }

    func testEmptySnapshotIsSkipped() throws {
        XCTAssertEqual(try process(snapshot(), at: 1), .skipped)
        XCTAssertEqual(try store.countClips(), 0)
    }

    func testDuplicateTextMovesExistingRowToFront() throws {
        XCTAssertEqual(try process(snapshot(text: "alpha"), at: 100).isInserted, true)
        XCTAssertEqual(try process(snapshot(text: "beta"), at: 200).isInserted, true)
        let outcome = try process(snapshot(text: "alpha"), at: 300)
        XCTAssertEqual(outcome.isInserted, false)
        XCTAssertEqual(try store.countClips(), 2)
        let all = try store.listClips(filter: .all, limit: 100)
        XCTAssertEqual(all.map(\.text), ["alpha", "beta"])
        XCTAssertEqual(all[0].createdAt, 300)
    }

    func testConsecutiveDuplicateIsTouchedNotInserted() throws {
        _ = try process(snapshot(text: "same"), at: 100)
        let second = try process(snapshot(text: "same"), at: 200)
        XCTAssertEqual(second.isInserted, false)
        XCTAssertEqual(try store.countClips(), 1)
        XCTAssertEqual(try store.listClips(filter: .all, limit: 10).first?.createdAt, 200)
    }

    func testImageIsWrittenAndDeduplicatedByHash() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
        _ = try process(snapshot(png: png), at: 100)
        XCTAssertEqual(try imageFiles().count, 1)
        let stored = try store.listClips(filter: .all, limit: 10).first
        XCTAssertEqual(stored?.kind, .image)
        XCTAssertNotNil(stored?.imagePath)

        let again = try process(snapshot(png: png), at: 200)
        XCTAssertEqual(again.isInserted, false)
        XCTAssertEqual(try store.countClips(), 1)
        XCTAssertEqual(try imageFiles().count, 1) // no orphan duplicate
    }

    func testImageDedupesAcrossInterveningClips() throws {
        // A,B,A must not insert a third copy of A — the content hash covers
        // the whole history, not just the newest row.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 9, 9])
        _ = try process(snapshot(png: png), at: 100)
        _ = try process(snapshot(text: "middle"), at: 150)
        let outcome = try process(snapshot(png: png), at: 200)
        XCTAssertEqual(outcome.isInserted, false)
        XCTAssertEqual(try store.countClips(), 2)
        XCTAssertEqual(try imageFiles().count, 1)
    }

    func testFileClipsStoreAJSONArray() throws {
        _ = try process(snapshot(files: ["/tmp/a.txt", "/tmp/b.png"]), at: 100)
        let clip = try store.listClips(filter: .all, limit: 10).first
        XCTAssertEqual(clip?.kind, .file)
        XCTAssertEqual(clip?.files, "[\"/tmp/a.txt\",\"/tmp/b.png\"]")
    }

    func testMaxClipsRemovesOrphanImageFiles() throws {
        var settings = AppSettings()
        settings.maxClips = 1
        _ = try process(snapshot(png: Data([1])), at: 100, settings: settings)
        _ = try process(snapshot(png: Data([2])), at: 200, settings: settings)
        XCTAssertEqual(try store.countClips(), 1)
        XCTAssertEqual(try imageFiles().count, 1)
    }

    func testRetentionRemovesExpiredUnpinnedClips() throws {
        var settings = AppSettings()
        settings.retentionDays = 1
        let now: Int64 = 1_700_000_000_000
        _ = try process(snapshot(text: "old"), at: now - 10 * 86_400_000, settings: settings)
        _ = try process(snapshot(text: "fresh"), at: now, settings: settings)
        XCTAssertEqual(try store.listClips(filter: .all, limit: 100).map(\.text), ["fresh"])
    }

    func testCopyingPinnedContentCreatesANewHistoryEntry() throws {
        let board = try store.insertPinboard(name: "b")
        _ = try process(snapshot(text: "kept"), at: 100)
        let pinned = try store.listClips(filter: .all, limit: 10).first!
        try store.setPinboard(id: pinned.id, pinboardId: board.id)

        let outcome = try process(snapshot(text: "kept"), at: 200)
        XCTAssertEqual(outcome.isInserted, true)
        XCTAssertEqual(try store.countClips(), 2)
        XCTAssertEqual(try store.listClips(filter: .history, limit: 10).map(\.text), ["kept"])
        // The pinned row was not silently reordered.
        XCTAssertEqual(try store.getClip(id: pinned.id)?.createdAt, 100)
    }

    func testCleanupRunsWhenADuplicateIsTouched() throws {
        _ = try process(snapshot(text: "alpha"), at: 100)
        _ = try process(snapshot(text: "beta"), at: 200)
        XCTAssertEqual(try store.countClips(), 2)

        var settings = AppSettings()
        settings.maxClips = 1
        let outcome = try process(snapshot(text: "beta"), at: 300, settings: settings)
        XCTAssertEqual(outcome.isInserted, false)
        XCTAssertEqual(try store.listClips(filter: .all, limit: 10).map(\.text), ["beta"])
    }

    func testCleanupReportsRemovedImagePaths() throws {
        var batches: [[String]] = []
        pipeline.onImagesRemoved = { batches.append($0) }
        var settings = AppSettings()
        settings.maxClips = 1
        _ = try process(snapshot(png: Data([1])), at: 100, settings: settings)
        _ = try process(snapshot(png: Data([2])), at: 200, settings: settings)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, 1)
        XCTAssertEqual(try imageFiles().count, 1)
    }

    func testHTMLIsKeptVerbatimForPasteBack() throws {
        // The UI never renders HTML, so no sanitizer runs on capture; the
        // payload is stored as-is and written back to NSPasteboard.
        let html = "<b style=\"color:red\">rich</b>"
        let snap = ClipboardSnapshot(text: "rich", html: html)
        _ = try process(snap, at: 100)
        XCTAssertEqual(try store.listClips(filter: .all, limit: 10).first?.html, html)
    }
}

private extension CaptureOutcome {
    var isInserted: Bool {
        if case .inserted = self { return true }
        return false
    }
}
