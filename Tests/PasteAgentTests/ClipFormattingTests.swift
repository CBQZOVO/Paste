import Foundation
import XCTest
import PasteCore
@testable import PasteAgent

final class ClipFormattingTests: XCTestCase {
    func testRelativeTimeBoundaries() {
        let now: Int64 = 1_700_000_000_000
        XCTAssertEqual(ClipFormatting.relativeTime(nowMs: now, createdAtMs: now - 5_000), "刚刚")
        XCTAssertEqual(ClipFormatting.relativeTime(nowMs: now, createdAtMs: now - 60_000), "1分钟前")
        XCTAssertEqual(ClipFormatting.relativeTime(nowMs: now, createdAtMs: now - 59 * 60_000), "59分钟前")
        XCTAssertEqual(ClipFormatting.relativeTime(nowMs: now, createdAtMs: now - 60 * 60_000), "1小时前")
        XCTAssertEqual(ClipFormatting.relativeTime(nowMs: now, createdAtMs: now - 24 * 3_600_000), "1天前")
        XCTAssertEqual(ClipFormatting.relativeTime(nowMs: now, createdAtMs: now - 40 * 86_400_000), "1个月前")
        // A clock in the future must not produce a negative age.
        XCTAssertEqual(ClipFormatting.relativeTime(nowMs: now, createdAtMs: now + 10_000), "刚刚")
    }

    private func clip(_ kind: ClipKind, text: String? = nil, files: String? = nil) -> Clip {
        Clip(kind: kind, text: text, files: files, createdAt: 0)
    }

    func testTitles() {
        XCTAssertEqual(ClipFormatting.title(for: clip(.text)), "文本")
        XCTAssertEqual(ClipFormatting.title(for: clip(.image)), "图片")
        XCTAssertEqual(ClipFormatting.title(for: clip(.link)), "链接")
        XCTAssertEqual(ClipFormatting.title(for: clip(.color)), "颜色")
        XCTAssertEqual(
            ClipFormatting.title(for: clip(.file, files: "[\"/a.png\"]")),
            "1个文件"
        )
        XCTAssertEqual(
            ClipFormatting.title(for: clip(.file, files: "[\"/a.png\",\"/b.txt\"]")),
            "2个文件"
        )
    }

    func testCaptions() {
        XCTAssertEqual(ClipFormatting.caption(for: clip(.text, text: "abcdef")), "6 个字符")
        XCTAssertEqual(ClipFormatting.caption(for: clip(.image)), "图片")
        XCTAssertEqual(
            ClipFormatting.caption(for: clip(.file, files: "[\"/tmp/截图.png\"]")),
            "截图.png"
        )
        XCTAssertEqual(ClipFormatting.caption(for: clip(.file, files: "not json")), "文件")
    }

    func testDetailTextExpandsFileLists() {
        XCTAssertEqual(
            ClipFormatting.detailText(for: clip(.text, text: "line1\nline2")),
            "line1\nline2"
        )
        XCTAssertEqual(
            ClipFormatting.detailText(for: clip(.file, files: "[\"/tmp/a.png\",\"/tmp/b.txt\"]")),
            "/tmp/a.png\n/tmp/b.txt"
        )
        // A damaged value is still shown verbatim instead of disappearing.
        XCTAssertEqual(ClipFormatting.detailText(for: clip(.file, files: "broken")), "broken")
    }

    func testDetailTextTruncatesHugePayloads() {
        let text = ClipFormatting.detailText(
            for: clip(.text, text: String(repeating: "a", count: 12)), limit: 5
        )
        XCTAssertTrue(text.hasPrefix("aaaaa"))
        XCTAssertTrue(text.contains("共 12 个"))
    }

    func testDetailTextHandlesMissingContent() {
        XCTAssertEqual(ClipFormatting.detailText(for: clip(.text)), "（无文本内容）")
        XCTAssertEqual(
            ClipFormatting.detailText(for: Clip(kind: .image, createdAt: 0)),
            "（图片文件已丢失）"
        )
    }
}
