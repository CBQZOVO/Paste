import Foundation
import PasteCore

/// Navigation state for the panel. Deliberately a plain value type with no
/// SwiftUI import, so every keyboard rule can be unit tested.
public struct PanelState: Equatable, Sendable {
    public var clips: [Clip]
    public var selection: Int
    public var detailClipId: Int64?
    public var sidebarOpen: Bool
    public var kindFilter: ClipKind?
    public var query: String

    public init(
        clips: [Clip] = [],
        selection: Int = 0,
        detailClipId: Int64? = nil,
        sidebarOpen: Bool = false,
        kindFilter: ClipKind? = nil,
        query: String = ""
    ) {
        self.clips = clips
        self.selection = selection
        self.detailClipId = detailClipId
        self.sidebarOpen = sidebarOpen
        self.kindFilter = kindFilter
        self.query = query
    }
}

public enum PanelLogic {
    /// Left/right browsing: clamped, never wraps. With the detail overlay
    /// open it follows the card the selection lands on.
    public static func move(_ state: inout PanelState, delta: Int) {
        guard !state.clips.isEmpty else {
            state.selection = 0
            return
        }
        state.selection = min(max(state.selection + delta, 0), state.clips.count - 1)
        if state.detailClipId != nil {
            state.detailClipId = selectedClip(state)?.id
        }
    }

    /// Replacing the clip list (search, filter, background insert) keeps the
    /// user's place: follow the previously selected clip id when it survives,
    /// otherwise clamp the old index. A detail overlay whose clip disappeared
    /// is closed; one that survived stays open.
    public static func replaceClips(_ state: inout PanelState, _ clips: [Clip]) {
        let previousId = state.clips.indices.contains(state.selection)
            ? state.clips[state.selection].id : nil
        state.clips = clips
        if let previousId, let index = clips.firstIndex(where: { $0.id == previousId }) {
            state.selection = index
        } else {
            state.selection = min(max(state.selection, 0), max(0, clips.count - 1))
        }
        if let id = state.detailClipId, !clips.contains(where: { $0.id == id }) {
            state.detailClipId = nil
        }
    }

    public static func clamp(_ state: inout PanelState) {
        if state.clips.isEmpty {
            state.selection = 0
            state.detailClipId = nil
        } else {
            state.selection = min(max(state.selection, 0), state.clips.count - 1)
            if let id = state.detailClipId,
               !state.clips.contains(where: { $0.id == id }) {
                state.detailClipId = nil
            }
        }
    }

    public static func selectedClip(_ state: PanelState) -> Clip? {
        guard state.clips.indices.contains(state.selection) else { return nil }
        return state.clips[state.selection]
    }

    public static func toggleDetail(_ state: inout PanelState) {
        if state.detailClipId != nil {
            state.detailClipId = nil
        } else {
            state.detailClipId = selectedClip(state)?.id
        }
    }
}
