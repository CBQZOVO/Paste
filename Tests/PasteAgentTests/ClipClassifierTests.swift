import Foundation
import XCTest
@testable import PasteAgent

final class ClipClassifierTests: XCTestCase {
    func testPriorityIsFilesThenImageThenText() {
        let full = ClipboardSnapshot(
            text: "hello", html: "<b>hello</b>",
            imagePNG: Data([1, 2, 3]),
            filePaths: ["/tmp/a.txt"]
        )
        XCTAssertEqual(ClipClassifier.classify(full), .files(["/tmp/a.txt"]))

        let withImage = ClipboardSnapshot(text: "hello", imagePNG: Data([1, 2, 3]))
        XCTAssertEqual(ClipClassifier.classify(withImage), .image(Data([1, 2, 3])))

        let textOnly = ClipboardSnapshot(text: "  hello  ", html: "<b>hello</b>")
        XCTAssertEqual(
            ClipClassifier.classify(textOnly),
            .text("hello", html: "<b>hello</b>")
        )
    }

    func testEmptyClipboardIsSkipped() {
        XCTAssertNil(ClipClassifier.classify(ClipboardSnapshot()))
        XCTAssertNil(ClipClassifier.classify(ClipboardSnapshot(text: "   \n  ")))
        XCTAssertNil(ClipClassifier.classify(ClipboardSnapshot(imagePNG: Data())))
    }

    func testClassifiesLinksColorsAndPlainText() {
        XCTAssertEqual(ClipClassifier.classify(text: "https://example.com/a"), .link("https://example.com/a", html: nil))
        XCTAssertEqual(ClipClassifier.classify(text: "WWW.Example.com"), .link("WWW.Example.com", html: nil))
        XCTAssertEqual(ClipClassifier.classify(text: "#abc"), .color("#abc"))
        XCTAssertEqual(ClipClassifier.classify(text: "0X22c55e"), .color("0X22c55e"))
        XCTAssertEqual(ClipClassifier.classify(text: "plain note"), .text("plain note", html: nil))
    }

    func testIsURLBoundaries() {
        XCTAssertFalse(ClipClassifier.isURL("abc"))
        XCTAssertFalse(ClipClassifier.isURL("https://exa mple.com"))
        XCTAssertFalse(ClipClassifier.isURL("https://example.com\nother"))
        XCTAssertFalse(ClipClassifier.isURL("example.com"))
        XCTAssertFalse(ClipClassifier.isURL(String(repeating: "a", count: 2049)))
        XCTAssertTrue(ClipClassifier.isURL("ftp://host/file"))
    }

    func testColorParsingNeverTrapsAndIsCanonical() {
        XCTAssertEqual(ClipClassifier.normalizedColor("#abc"), "#aabbcc")
        XCTAssertEqual(ClipClassifier.normalizedColor("  #22C55E  "), "#22c55e")
        XCTAssertEqual(ClipClassifier.normalizedColor("0x7c5cf6"), "#7c5cf6")
        XCTAssertEqual(ClipClassifier.normalizedColor("#7c5cf6ff"), "#7c5cf6")

        // Multi-byte input must return nil rather than trap on byte slicing.
        XCTAssertNil(ClipClassifier.normalizedColor("#中文"))
        XCTAssertNil(ClipClassifier.normalizedColor("#😀😀😀"))
        XCTAssertNil(ClipClassifier.normalizedColor("#zzz"))
        XCTAssertNil(ClipClassifier.normalizedColor("#12345"))
        XCTAssertNil(ClipClassifier.normalizedColor("#"))
        XCTAssertNil(ClipClassifier.normalizedColor("rgb(1, 2, 3)"))
        XCTAssertNil(ClipClassifier.normalizedColor(""))
    }
}
