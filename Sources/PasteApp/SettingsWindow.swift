import AppKit
import PasteAgent
import PasteCore
import SwiftUI

@MainActor
final class SettingsWindow {
    private let window: NSWindow

    init(viewModel: PanelViewModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Paste 设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(vm: viewModel))
        self.window = window
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct SettingsView: View {
    @ObservedObject var vm: PanelViewModel
    @State private var draft: AppSettings
    @State private var excludedText: String
    /// The panel toast is invisible while this separate window is key, so
    /// save results are shown inline instead.
    @State private var statusMessage: String?

    init(vm: PanelViewModel) {
        self.vm = vm
        _draft = State(initialValue: vm.settings)
        _excludedText = State(initialValue: vm.settings.excludedApps.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("全局快捷键", text: $draft.hotkey)
                Toggle("快速粘贴（⌘1…⌘9）", isOn: $draft.quickPaste)
                Picker("面板位置", selection: $draft.panelPosition) {
                    Text("顶部").tag("top")
                    Text("居中").tag("center")
                    Text("底部").tag("bottom")
                }
                Picker("搜索语法", selection: $draft.searchMode) {
                    Text("普通").tag("plain")
                    Text("通配符").tag("wildcard")
                    Text("正则").tag("regex")
                }
                Picker("滚轮方向", selection: $draft.wheelDirection) {
                    Text("默认").tag("default")
                    Text("自然").tag("natural")
                }
                TextField("历史上限（0 = 不限）", value: $draft.maxClips, format: .number)
                TextField("自动删除天数（0 = 永久）", value: $draft.retentionDays, format: .number)
                Toggle("默认粘贴纯文本", isOn: $draft.alwaysPlainText)
                Toggle("开机启动", isOn: $draft.autostart)
                    .disabled(!LaunchAtLogin.isAvailable)
                    .help(LaunchAtLogin.isAvailable
                          ? "由 macOS 登录项管理"
                          : "仅打包为 .app 后可用")
            }

            Text("排除应用（每行一个可执行名）").font(.caption)
            TextEditor(text: $excludedText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 72)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.4)))

            HStack {
                Text(statusMessage ?? "保存后热键会立即重新注册")
                    .font(.caption)
                    .foregroundStyle(statusMessage == nil ? Color.secondary : Color.orange)
                Spacer()
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 620, height: 500)
        // Only `paused` can change from outside this window (the tray menu).
        // Replacing the whole draft would discard unsaved edits.
        .onChange(of: vm.settings.paused) { _, value in draft.paused = value }
    }

    private func save() {
        var next = draft
        next.maxClips = max(0, next.maxClips)
        next.retentionDays = max(0, next.retentionDays)
        next.excludedApps = excludedText
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // A hotkey that fails to parse would unregister the working one and
        // leave the app with no global shortcut at all.
        guard HotkeyParser.parse(next.hotkey) != nil else {
            statusMessage = "快捷键格式无效，未保存"
            return
        }
        var autostartFailed = false
        if next.autostart != vm.settings.autostart,
           !(vm.onAutostartChanged?(next.autostart) ?? false) {
            // Roll back only this field; the other settings still save.
            next.autostart = vm.settings.autostart
            draft.autostart = next.autostart
            autostartFailed = true
        }
        vm.applySettings(next)
        statusMessage = autostartFailed
            ? "其它设置已保存；开机启动未生效（请检查系统登录项）"
            : "设置已保存"
    }
}
