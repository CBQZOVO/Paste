import Foundation
import PasteAgent
import PasteCore
import SwiftUI

/// Single source of truth for the panel. There is one process and one store,
/// so every write (clear history, delete, pin) refreshes this object and all
/// views update together. `AppSettings` lives only here; the controller and
/// the settings window read it through this object.
@MainActor
final class PanelViewModel: ObservableObject {
    @Published private(set) var state = PanelState()
    @Published var pinboards: [Pinboard] = []
    @Published var settings: AppSettings
    @Published var paused: Bool
    @Published var toast: String?
    @Published var currentBoard: Int64?
    @Published var focusSearchTick = 0
    @Published var searchFocused = false
    @Published var searchExpanded = false

    let store: ClipStore

    var onPaste: ((Clip, Bool) -> Void)?
    var onCopy: ((Clip) -> Void)?
    var onTogglePause: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onSettingsChanged: ((AppSettings) -> Void)?
    /// Returns false when the system refused the change, so the settings UI
    /// can keep the old value instead of persisting a dead toggle.
    var onAutostartChanged: ((Bool) -> Bool)?

    private var toastWork: DispatchWorkItem?
    private var queryWork: DispatchWorkItem?

    private static let filterOrder: [ClipKind?] = [nil, .text, .link, .image, .file, .color]
    /// Cards shown in the strip. History beyond this is still stored and
    /// searchable, just not paginated in the panel yet.
    private static let panelLimit: Int64 = 500

    init(store: ClipStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.paused = settings.paused
    }

    var selected: Clip? { PanelLogic.selectedClip(state) }

    var detailClip: Clip? {
        guard let id = state.detailClipId else { return nil }
        return state.clips.first { $0.id == id }
    }

    // MARK: - Queries

    func refetch() {
        do {
            let filter: PinboardFilter = currentBoard.map { .board($0) } ?? .history
            let clips = try store.listClips(
                filter: filter,
                search: state.query,
                searchMode: settings.searchMode,
                kind: state.kindFilter,
                limit: Self.panelLimit
            )
            var next = state
            PanelLogic.replaceClips(&next, clips)
            state = next
            pinboards = (try? store.listPinboards()) ?? []
        } catch {
            showToast("读取历史失败")
        }
    }

    func setQuery(_ query: String) {
        var next = state
        next.query = query
        state = next
        // Coalesce keystrokes so the full-text scan does not run mid-word.
        queryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refetch() }
        queryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func appendToQuery(_ character: String) {
        setQuery(state.query + character)
        focusSearchTick += 1
    }

    func beginSearch() {
        searchExpanded = true
        focusSearchTick += 1
    }

    /// Reset the search state machine; called when the panel hides so a stale
    /// query or focus flag cannot change what Esc or a letter key does on the
    /// next open.
    /// Reset the transient panel state when it hides: the next show() starts
    /// with a clean search and a closed detail overlay. The selected board
    /// and filter are deliberate user choices and survive.
    func resetForHide() {
        // No delayed refetch after hiding: show() refetches with the cleared
        // query when the panel opens again.
        queryWork?.cancel()
        queryWork = nil
        searchExpanded = false
        searchFocused = false
        var next = state
        next.query = ""
        next.detailClipId = nil
        state = next
    }

    func setKind(_ kind: ClipKind?) {
        var next = state
        next.kindFilter = kind
        state = next
        refetch()
    }

    func cycleKind() {
        let current = Self.filterOrder.firstIndex { $0 == state.kindFilter } ?? 0
        setKind(Self.filterOrder[(current + 1) % Self.filterOrder.count])
    }

    func setBoard(_ id: Int64?) {
        currentBoard = id
        refetch()
    }

    // MARK: - Navigation / actions

    func select(index: Int) {
        var next = state
        next.selection = min(max(index, 0), max(0, state.clips.count - 1))
        state = next
    }

    func move(_ delta: Int) {
        var next = state
        PanelLogic.move(&next, delta: delta)
        state = next
    }

    func toggleDetail() {
        var next = state
        PanelLogic.toggleDetail(&next)
        state = next
    }

    func closeDetail() {
        var next = state
        next.detailClipId = nil
        state = next
    }

    func toggleSidebar() {
        var next = state
        next.sidebarOpen.toggle()
        state = next
    }

    func pasteSelected(plain: Bool = false) {
        guard let clip = selected else { return }
        onPaste?(clip, plain || settings.alwaysPlainText)
    }

    func copySelected() {
        guard let clip = selected else { return }
        onCopy?(clip)
    }

    func deleteSelected() {
        guard let clip = selected else { return }
        // Only delete the PNG once the row is really gone; deleting it on a
        // failed write would leave a dangling image_path behind.
        guard ((try? store.deleteClip(id: clip.id)) ?? 0) > 0 else { return }
        if let path = clip.imagePath {
            ThumbnailCache.shared.invalidate(path: path)
            try? FileManager.default.removeItem(atPath: path)
        }
        refetch()
    }

    func clearHistory() {
        do {
            let paths = try store.clearHistory()
            for path in paths.compactMap({ $0 }) {
                try? FileManager.default.removeItem(atPath: path)
            }
            ThumbnailCache.shared.removeAll()
            refetch()
            showToast("历史已清空")
        } catch {
            NSLog("[paste] clear history failed: %@", String(describing: error))
            showToast("清空历史失败")
        }
    }

    func pinSelected() {
        guard let clip = selected else { return }
        // When browsing a board, pin there; in history, use the first board.
        let board = currentBoard.flatMap { id in pinboards.first { $0.id == id } }
            ?? pinboards.first
        guard let board else {
            showToast("先在侧栏创建一个收藏板")
            return
        }
        let target = clip.pinboardId == board.id ? nil : board.id
        _ = try? store.setPinboard(id: clip.id, pinboardId: target)
        refetch()
    }

    func createPinboard(name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        _ = try? store.insertPinboard(name: name)
        refetch()
    }

    func deletePinboard(_ id: Int64) {
        // deletePinboard is transactional on the store side: it unpins its
        // clips in the same commit, so no clip can be orphaned.
        _ = try? store.deletePinboard(id: id)
        if currentBoard == id { currentBoard = nil }
        refetch()
    }

    func applySettings(_ next: AppSettings) {
        settings = next
        try? store.saveSettings(next)
        onSettingsChanged?(next)
        refetch()
    }

    func showToast(_ message: String) {
        toast = message
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}
