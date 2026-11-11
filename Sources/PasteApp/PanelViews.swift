import AppKit
import PasteAgent
import PasteCore
import SwiftUI

struct PanelRootView: View {
    @ObservedObject var vm: PanelViewModel
    @State private var confirmClear = false
    @State private var addingBoard = false
    @State private var newBoard = ""
    @State private var moreOpen = false

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(
                vm: vm,
                addingBoard: $addingBoard,
                newBoard: $newBoard,
                moreOpen: $moreOpen
            )
            // Only one secondary bar at a time: the panel is 300pt tall and
            // stacked bars would squeeze the card previews into nothing.
            if moreOpen && !confirmClear && !addingBoard {
                MoreBar(vm: vm, confirmClear: $confirmClear)
            }
            if confirmClear {
                ConfirmBar(message: "清空全部历史？置顶项会保留", confirmLabel: "清空") {
                    vm.clearHistory()
                    confirmClear = false
                } onCancel: {
                    confirmClear = false
                }
            } else if addingBoard {
                NewBoardBar(text: $newBoard) {
                    vm.createPinboard(name: newBoard)
                    newBoard = ""
                    addingBoard = false
                } onCancel: {
                    newBoard = ""
                    addingBoard = false
                }
            }
            HStack(spacing: 0) {
                if vm.state.sidebarOpen {
                    SidebarView(vm: vm)
                }
                CardStripView(vm: vm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .overlay {
            if let clip = vm.detailClip {
                DetailOverlay(clip: clip, onClose: { vm.closeDetail() })
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = vm.toast {
                Text(toast)
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)
            }
        }
    }
}

// MARK: - Toolbar

/// Search, board tabs and the "+" button sit in the toolbar; filters and
/// secondary actions live in an expandable bar INSIDE the panel (a real
/// NSMenu would pop outside the frame and trip the click-outside auto-hide).
private struct ToolbarView: View {
    @ObservedObject var vm: PanelViewModel
    @Binding var addingBoard: Bool
    @Binding var newBoard: String
    @Binding var moreOpen: Bool

    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                Button {
                    vm.setBoard(nil)
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Color.red).frame(width: 5, height: 5)
                        Text("剪贴板")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        vm.currentBoard == nil ? PanelPalette.chip(scheme) : Color.clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    vm.currentBoard == nil
                        ? PanelPalette.primary(scheme)
                        : PanelPalette.secondary(scheme)
                )
                ForEach(vm.pinboards, id: \.id) { board in
                    Button(board.name) { vm.setBoard(board.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            vm.currentBoard == board.id
                                ? PanelPalette.primary(scheme)
                                : PanelPalette.secondary(scheme)
                        )
                }
                Button { addingBoard = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }

            HStack {
                searchArea
                Spacer()
            }

            HStack {
                Spacer()
                Button { moreOpen.toggle() } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.plain)
                .foregroundStyle(moreOpen ? Color.accentColor : PanelPalette.secondary(scheme))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(PanelPalette.primary(scheme))
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var searchArea: some View {
        if vm.searchExpanded || !vm.state.query.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(PanelPalette.secondary(scheme))
                TextField("搜索", text: Binding(
                    get: { vm.state.query },
                    set: { vm.setQuery($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onAppear { focused = true }
                .onChange(of: vm.focusSearchTick) { _, _ in focused = true }
                .onChange(of: focused) { _, value in vm.searchFocused = value }
                .onDisappear { vm.searchFocused = false }
                if !vm.state.query.isEmpty {
                    Button {
                        vm.setQuery("")
                        vm.searchExpanded = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PanelPalette.secondary(scheme))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(PanelPalette.chip(scheme), in: Capsule())
            .frame(width: 180)
        } else {
            Button { vm.searchExpanded = true } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PanelPalette.secondary(scheme))
        }
    }
}

// MARK: - Expandable options bar

private struct MoreBar: View {
    @ObservedObject var vm: PanelViewModel
    @Binding var confirmClear: Bool
    @Environment(\.colorScheme) private var scheme

    private let filters: [(String, ClipKind?)] = [
        ("全部", nil), ("文本", .text), ("链接", .link),
        ("图片", .image), ("文件", .file), ("颜色", .color),
    ]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(filters, id: \.0) { label, kind in
                Button(label) { vm.setKind(kind) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        vm.state.kindFilter == kind
                            ? Color.accentColor
                            : PanelPalette.chip(scheme),
                        in: Capsule()
                    )
                    .foregroundStyle(
                        vm.state.kindFilter == kind
                            ? Color.white
                            : PanelPalette.secondary(scheme)
                    )
            }
            Divider().frame(height: 14)
            Button(vm.paused ? "恢复采集" : "暂停采集") { vm.onTogglePause?() }
                .buttonStyle(.borderless)
            Button("设置") { vm.onOpenSettings?() }.buttonStyle(.borderless)
            Button("侧栏") { vm.toggleSidebar() }.buttonStyle(.borderless)
            Button("清空历史…") { confirmClear = true }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(PanelPalette.primary(scheme))
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(PanelPalette.chip(scheme))
    }
}

// MARK: - Inline confirmations

private struct ConfirmBar: View {
    let message: String
    let confirmLabel: String
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Text(message).font(.system(size: 12))
            Spacer()
            Button("取消", action: onCancel).buttonStyle(.borderless)
            Button(confirmLabel, action: onConfirm)
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(PanelPalette.chip(scheme))
    }
}

private struct NewBoardBar: View {
    @Binding var text: String
    let onCreate: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            TextField("收藏板名称", text: $text, onCommit: onCreate)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            Button("创建", action: onCreate).buttonStyle(.borderless)
            Button("取消", action: onCancel).buttonStyle(.borderless)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(PanelPalette.chip(scheme))
    }
}

// MARK: - Optional sidebar

private struct SidebarView: View {
    @ObservedObject var vm: PanelViewModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("历史") { vm.setBoard(nil) }.buttonStyle(.plain)
            ForEach(vm.pinboards, id: \.id) { board in
                HStack {
                    Button(board.name) { vm.setBoard(board.id) }.buttonStyle(.plain)
                    Button("×") { vm.deletePinboard(board.id) }.buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(PanelPalette.primary(scheme))
        .padding(10)
        .frame(width: 150)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Detail

private struct DetailOverlay: View {
    let clip: Clip
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = PanelGeometry.detailSize(available: geometry.size)
            ZStack {
                Color.black.opacity(0.45).onTapGesture(perform: onClose)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("完整内容").font(.headline)
                        Spacer()
                        Text(ClipFormatting.caption(for: clip))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("关闭") { onClose() }.buttonStyle(.borderless)
                    }
                    // The panel is only 300pt tall, so the box must shrink
                    // with it. fixedSize(horizontal: false) makes long lines
                    // (keys, URLs, base64) wrap at the available width
                    // instead of being clipped on the right edge.
                    ScrollView(.vertical) {
                        Text(ClipFormatting.detailText(for: clip))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .frame(width: size.width, height: size.height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
