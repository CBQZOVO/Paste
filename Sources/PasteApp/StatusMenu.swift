import AppKit
import Foundation

/// Menu-bar presence: the fallback entry point when the global shortcut is
/// taken by another app.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let infoItem = NSMenuItem(title: "Paste", action: nil, keyEquivalent: "")
    private let openPanelItem = NSMenuItem(title: "打开面板", action: #selector(openPanelClicked), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "设置…", action: #selector(settingsClicked), keyEquivalent: ",")
    private let pauseItem = NSMenuItem(title: "暂停采集", action: #selector(pauseClicked), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "", action: #selector(accessibilityClicked), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "退出", action: #selector(quitClicked), keyEquivalent: "q")

    var onOpenPanel: (@MainActor () -> Void)?
    var onOpenSettings: (@MainActor () -> Void)?
    var onTogglePause: (@MainActor () -> Void)?
    var onRequestAccessibility: (@MainActor () -> Void)?
    var onQuit: (@MainActor () -> Void)?
    var onMenuWillOpen: (@MainActor () -> Void)?

    override init() {
        super.init()
        if let button = statusItem.button {
            if let logo = Self.appIcon() {
                button.image = logo
            } else {
                // Running straight from SwiftPM: no bundle resources.
                button.image = NSImage(
                    systemSymbolName: "doc.on.clipboard",
                    accessibilityDescription: "Paste"
                )
                button.image?.isTemplate = true
            }
        }
        infoItem.isEnabled = false
        let menu = NSMenu()
        for item in [
            infoItem, openPanelItem, settingsItem, pauseItem, accessibilityItem,
            NSMenuItem.separator(), quitItem,
        ] {
            item.target = self
            menu.addItem(item)
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The bundled logo is used both as the Finder app icon and in the menu
    /// bar. NSImage reads .icns directly; scale it to menu-bar size and keep
    /// it colored — a template image would flatten the orange square and the
    /// white "P" into one opaque black block.
    private static func appIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    func update(clipCount: Int, paused: Bool, axTrusted: Bool) {
        infoItem.title = "Paste — \(clipCount) 条历史"
        pauseItem.title = paused ? "恢复采集" : "暂停采集"
        accessibilityItem.title = axTrusted
            ? "辅助功能：已授权"
            : "辅助功能：未授权（点击申请）"
    }

    @objc private func openPanelClicked() { onOpenPanel?() }
    @objc private func settingsClicked() { onOpenSettings?() }
    @objc private func pauseClicked() { onTogglePause?() }
    @objc private func accessibilityClicked() { onRequestAccessibility?() }
    @objc private func quitClicked() { onQuit?() }

    /// The AX line is only refreshed elsewhere on state changes; re-evaluate
    /// it every time the menu opens so a fresh approval shows up immediately.
    func menuWillOpen(_ menu: NSMenu) {
        onMenuWillOpen?()
    }
}
