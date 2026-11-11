import CoreGraphics
import Foundation
import XCTest
@testable import PasteAgent

final class PanelGeometryTests: XCTestCase {
    // A 1080pt-tall screen with a 24pt menu bar and a 24pt Dock leaves a
    // visible frame of 1032pt starting at y=24 (Dock is NOT part of it).
    private let workArea = CGRect(x: 0, y: 24, width: 1920, height: 1032)

    func testBottomPanelSitsAboveTheDock() {
        let frame = PanelGeometry.frame(visible: workArea, panelHeight: 440, position: "bottom")
        XCTAssertEqual(frame.minY, 36)                 // 24 + 12 margin
        XCTAssertEqual(frame.maxY, 476)
        XCTAssertLessThan(frame.maxY, workArea.maxY)   // never off-screen
        XCTAssertEqual(frame.width, 1920)
        XCTAssertEqual(frame.height, 440)
    }

    func testTopAndCenterStayInsideVisibleFrame() {
        let top = PanelGeometry.frame(visible: workArea, panelHeight: 440, position: "top")
        XCTAssertEqual(top.maxY, workArea.maxY - 12)
        let center = PanelGeometry.frame(visible: workArea, panelHeight: 440, position: "center")
        XCTAssertEqual(center.midY, workArea.midY, accuracy: 0.5)
        for frame in [top, center] {
            XCTAssertGreaterThanOrEqual(frame.minY, workArea.minY + 12)
            XCTAssertLessThanOrEqual(frame.maxY, workArea.maxY - 12)
        }
    }

    func testUnknownPositionFallsBackToCenter() {
        let explicit = PanelGeometry.frame(visible: workArea, panelHeight: 440, position: "center")
        let empty = PanelGeometry.frame(visible: workArea, panelHeight: 440, position: "")
        XCTAssertEqual(explicit, empty)
    }

    func testShortWorkAreaClampsPanelHeight() {
        let short = CGRect(x: 0, y: 0, width: 1280, height: 300)
        let frame = PanelGeometry.frame(visible: short, panelHeight: 440, position: "bottom")
        XCTAssertEqual(frame.minY, 12)
        XCTAssertEqual(frame.maxY, 288)
        XCTAssertEqual(frame.height, 276)
    }

    func testSecondaryMonitorWithNegativeOrigin() {
        let secondary = CGRect(x: -1860, y: -200, width: 1860, height: 1040)
        for position in ["top", "bottom", "center"] {
            let frame = PanelGeometry.frame(visible: secondary, panelHeight: 440, position: position)
            XCTAssertEqual(frame.minX, -1860)
            XCTAssertEqual(frame.width, 1860)
            XCTAssertGreaterThanOrEqual(frame.minY, -188)
            XCTAssertLessThanOrEqual(frame.maxY, 828)
        }
    }

    func testDetailOverlayFitsInsideThePanel() {
        let panel = CGSize(width: 1200, height: 300)
        let size = PanelGeometry.detailSize(available: panel)
        XCTAssertEqual(size.width, 640)
        XCTAssertEqual(size.height, 260) // 300 - 2 * 20 margin
        XCTAssertLessThanOrEqual(size.height, panel.height)
    }

    func testDetailOverlayKeepsPreferredSizeOnLargePanels() {
        let size = PanelGeometry.detailSize(available: CGSize(width: 1600, height: 900))
        XCTAssertEqual(size, CGSize(width: 640, height: 360))
    }

    func testDetailOverlayShrinksOnNarrowPanelsAndNeverInverts() {
        let narrow = PanelGeometry.detailSize(available: CGSize(width: 300, height: 200))
        XCTAssertEqual(narrow, CGSize(width: 260, height: 160))
        let tiny = PanelGeometry.detailSize(available: CGSize(width: 10, height: 10))
        XCTAssertGreaterThan(tiny.width, 0)
        XCTAssertGreaterThan(tiny.height, 0)
        XCTAssertLessThanOrEqual(tiny.width, 10)
        XCTAssertLessThanOrEqual(tiny.height, 10)
    }

    func testTinyWorkAreaDoesNotInvertClamp() {
        // Margins (600pt) plus any panel height exceed this 20pt work area;
        // the clamp interval inverts, so the panel must center what fits.
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 20)
        for position in ["top", "bottom", "center"] {
            let frame = PanelGeometry.frame(
                visible: tiny, panelHeight: 440, position: position, margin: 600
            )
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxY, tiny.maxY)
        }
    }
}
