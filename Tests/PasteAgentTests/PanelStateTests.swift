import Foundation
import XCTest
import PasteCore
@testable import PasteAgent

final class PanelStateTests: XCTestCase {
    private func clips(_ count: Int) -> [Clip] {
        (0..<count).map { index in
            Clip(id: Int64(index + 1), kind: .text, text: "clip \(index)", createdAt: Int64(100 - index))
        }
    }

    func testMoveIsClampedAndNeverWraps() {
        var state = PanelState(clips: clips(3))
        PanelLogic.move(&state, delta: 1)
        XCTAssertEqual(state.selection, 1)
        PanelLogic.move(&state, delta: 10)
        XCTAssertEqual(state.selection, 2)
        PanelLogic.move(&state, delta: -10)
        XCTAssertEqual(state.selection, 0)
    }

    func testEmptyListKeepsSelectionAtZero() {
        var state = PanelState(clips: [], selection: 5)
        PanelLogic.move(&state, delta: 1)
        XCTAssertEqual(state.selection, 0)
        XCTAssertNil(PanelLogic.selectedClip(state))
    }

    func testReplaceClipsFollowsSurvivingSelection() {
        var state = PanelState(clips: clips(3), selection: 2)
        state.clips[2].id = 42
        var refreshed = clips(3)
        refreshed[0].id = 42
        PanelLogic.replaceClips(&state, refreshed)
        XCTAssertEqual(state.selection, 0)
    }

    func testReplaceClipsClampsWhenSelectionDisappears() {
        var state = PanelState(clips: clips(3), selection: 2, detailClipId: 3)
        PanelLogic.replaceClips(&state, clips(1))
        XCTAssertEqual(state.selection, 0)
        XCTAssertNil(state.detailClipId)
    }

    func testMoveKeepsDetailOnTheCardItLandsOn() {
        var state = PanelState(clips: clips(3), selection: 1)
        state.detailClipId = state.clips[1].id
        PanelLogic.move(&state, delta: 1)
        XCTAssertEqual(state.selection, 2)
        XCTAssertEqual(state.detailClipId, state.clips[2].id)
    }

    func testClampAfterDeletion() {
        var state = PanelState(clips: clips(3), selection: 2, detailClipId: 7)
        state.clips = clips(1)
        PanelLogic.clamp(&state)
        XCTAssertEqual(state.selection, 0)
        XCTAssertNil(state.detailClipId)
    }

    func testToggleDetailUsesSelectedClip() {
        var state = PanelState(clips: clips(2), selection: 1)
        state.clips[0].id = 10
        state.clips[1].id = 20
        PanelLogic.toggleDetail(&state)
        XCTAssertEqual(state.detailClipId, 20)
        PanelLogic.toggleDetail(&state)
        XCTAssertNil(state.detailClipId)
    }
}
