import Foundation
import XCTest
@testable import PasteAgent

final class ClipMediaTests: XCTestCase {
    func testImageExtensionWhitelistIsCaseInsensitive() {
        XCTAssertTrue(ClipMedia.isImagePath("/tmp/shot.PNG"))
        XCTAssertTrue(ClipMedia.isImagePath("/tmp/中文截图.jpeg"))
        XCTAssertTrue(ClipMedia.isImagePath("/tmp/a.HEIC"))
        XCTAssertTrue(ClipMedia.isImagePath("/tmp/a.tiff"))
    }

    func testNonImagesAndMissingExtensionsAreRejected() {
        XCTAssertFalse(ClipMedia.isImagePath("/tmp/notes.txt"))
        XCTAssertFalse(ClipMedia.isImagePath("/tmp/noextension"))
        XCTAssertFalse(ClipMedia.isImagePath(""))
        XCTAssertFalse(ClipMedia.isImagePath("/tmp/a.png.txt"))
    }

    func testParsesStoredFilesJSON() {
        XCTAssertEqual(
            ClipMedia.paths(from: "[\"/tmp/a.txt\",\"/tmp/b.png\"]"),
            ["/tmp/a.txt", "/tmp/b.png"]
        )
        XCTAssertEqual(ClipMedia.paths(from: "[\"\",\"/tmp/ok\"]"), ["/tmp/ok"])
        XCTAssertEqual(ClipMedia.paths(from: nil), [])
        XCTAssertEqual(ClipMedia.paths(from: "not json"), [])
    }

    func testImagePathsKeepsOrderAndRespectsLimit() {
        let paths = ["/a.png", "/b.txt", "/c.JPG", "/d.gif"]
        XCTAssertEqual(ClipMedia.imagePaths(in: paths), ["/a.png", "/c.JPG"])
        XCTAssertEqual(ClipMedia.imagePaths(in: paths, limit: 1), ["/a.png"])
        XCTAssertEqual(ClipMedia.imagePaths(in: ["/a.txt"]), [])
    }
}
