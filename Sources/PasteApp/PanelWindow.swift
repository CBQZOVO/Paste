import AppKit
import PasteAgent
import PasteCore
import SwiftUI

/// Plain value extracted from NSEvent. A global monitor must hop onto the
/// main queue, and NSEvent is not Sendable under Swift 6 — carrying only
/// these values keeps the keyboard rules identical for both event paths.
private struct KeyEventInfo: Sendable {
    let keyCode: UInt16
    let command: Bool
    let control: Bool
    let characters: String

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        command = flags.contains(.command)
        control = flags.contains(.control)
        characters = event.charactersIgnoringModifiers ?? ""
    }
}

/// Same idea for scroll wheels: deltas plus the pointer position at the
/// moment of the event, so the global fallback can tell whether the cursor
/// was actually over the panel.
private struct WheelEventInfo: Sendable {
    let deltaX: Double
    let deltaY: Double
    let mouseX: Double
    let mouseY: Double

    init(_ event: NSEvent) {
        deltaX = Double(event.deltaX)
        deltaY = Double(event.deltaY)
        let point = NSEvent.mouseLocation
        mouseX = Double(point.x)
        mouseY = Double(point.y)
    }
}

/// Preferred path: the window receives its own keyDown events and can
/// consume them before they reach the first responder.
@MainActor
private final class KeyPanel: NSPanel {
    var keyHandler: ((KeyEventInfo) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(KeyEventInfo(event)) == true { return }
        super.sendEvent(event)
    }
}

/// Hosts the SwiftUI panel in a borderless NSPanel. Placement uses
/// NSScreen.visibleFrame, which already excludes the Dock and menu bar.
@MainActor
final class PanelWindow {
    /// Toolbar + card row fit comfortably in 300pt.
    private static let panelHeight: CGFloat = 300

    private let panel: KeyPanel
    private let viewModel: PanelViewModel
    private var globalClickMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalWheelMonitor: Any?
    private var localWheelMonitor: Any?
    private var shownAt = Date.distantPast
    private var wheelAccumulator: CGFloat = 0
    private var lastWheelStep = Date.distantPast

    init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
        let frame = NSRect(x: 0, y: 0, width: 1200, height: PanelWindow.panelHeight)
        let panel = KeyPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // NSPanel defaults to becomesKeyOnlyIfNeeded = true, which stops it
        // from ever taking key status on its own.
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: PanelRootView(vm: viewModel))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        self.panel = panel

        panel.keyHandler = { [weak self] info in
            self?.handleKey(info) ?? false
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        guard let screen = Self.screenWithCursor() ?? NSScreen.main else { return }
        let rect = PanelGeometry.frame(
            visible: screen.visibleFrame,
            panelHeight: Self.panelHeight,
            position: viewModel.settings.panelPosition
        )
        // Activate BEFORE asking the panel to become key: an inactive app
        // cannot own a key window. Activation is asynchronous, so makeKey is
        // also repeated on the next run-loop turn.
        shownAt = Date()
        wheelAccumulator = 0
        lastWheelStep = .distantPast
        NSApplication.shared.activate()
        NSRunningApplication.current.activate(options: [])
        panel.setFrame(rect.insetBy(dx: 8, dy: 0), display: true)
        viewModel.refetch()
        panel.makeKeyAndOrderFront(nil)
        panel.makeKey()
        // Clear any leftover field editor from a previous search.
        _ = panel.makeFirstResponder(nil)
        NSLog("[paste] panel shown; keyWindow=%d", panel.isKeyWindow ? 1 : 0)
        installFocusWatch()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.panel.makeKey()
        }
    }

    func hide() {
        removeFocusWatch()
        panel.orderOut(nil)
        // Clear search, focus and the detail overlay so a stale state cannot
        // change what Esc or a letter key does on the next open.
        viewModel.resetForHide()
    }

    /// Auto-hide triggers plus keyboard/wheel monitors. Global monitors see
    /// events belonging to OTHER apps, local ones see this app's events. A
    /// key the rules pass through travels on to sendEvent, which re-runs the
    /// same side-effect-free checks before handing it to the field editor.
    private func installFocusWatch() {
        removeFocusWatch()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isVisible else { return }
                    // show() insets the window frame by 8pt; expand it back
                    // so clicks on the visual edge do not count as "outside".
                    if !self.panel.frame.insetBy(dx: -8, dy: 0).contains(NSEvent.mouseLocation) {
                        self.hide()
                    }
                }
            }
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let info = KeyEventInfo(event)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isVisible else { return }
                    _ = self.handleKey(info)
                }
            }
        }
        globalWheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let info = WheelEventInfo(event)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isVisible else { return }
                    _ = self.handleWheel(info)
                }
            }
        }
        // Events belonging to THIS app, even when the panel is not the key
        // window. Returning nil consumes the event, so the app behind the
        // panel never sees arrows/Enter while it is open.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            // Do not steal keys from another window of this app (the settings
            // window). A nil keyWindow means nobody else owns the event.
            if let keyWindow = NSApplication.shared.keyWindow,
               keyWindow !== self.panel { return event }
            let info = KeyEventInfo(event)
            return self.handleKey(info) ? nil : event
        }
        localWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isVisible else { return event }
            // Consume the wheel event so the horizontal ScrollView does not
            // scroll on its own; selection is the only thing that moves.
            return self.handleWheel(WheelEventInfo(event)) ? nil : event
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func removeFocusWatch() {
        for monitor in [globalClickMonitor, globalKeyMonitor, globalWheelMonitor,
                        localKeyMonitor, localWheelMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalClickMonitor = nil
        globalKeyMonitor = nil
        globalWheelMonitor = nil
        localKeyMonitor = nil
        localWheelMonitor = nil
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appActivated(_ note: Notification) {
        // Activating ourselves can produce an activation notification for
        // the previously frontmost app; ignore that short window so the
        // panel is not hidden the moment it appears.
        guard isVisible,
              Date().timeIntervalSince(shownAt) > 0.5,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                  as? NSRunningApplication else { return }
        if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            hide()
        }
    }

    /// The screen under the cursor, falling back to the main screen.
    private static func screenWithCursor() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    // MARK: - Wheel

    /// One wheel "step" moves the selection exactly like Left/Right.
    /// Trackpad events arrive as many tiny deltas, so accumulate to a
    /// threshold and rate-limit to one step per 80ms; otherwise inertia
    /// would skip half the history in a single swipe.
    private func handleWheel(_ info: WheelEventInfo) -> Bool {
        guard panel.frame.contains(NSPoint(x: info.mouseX, y: info.mouseY)) else {
            return false
        }
        let primary = abs(info.deltaX) > abs(info.deltaY) ? info.deltaX : info.deltaY
        guard abs(primary) > 0.001 else { return false }

        wheelAccumulator += CGFloat(primary)
        let now = Date()
        guard now.timeIntervalSince(lastWheelStep) >= 0.08,
              abs(wheelAccumulator) >= 0.5 else { return true }

        var direction = wheelAccumulator > 0 ? -1 : 1
        if viewModel.settings.wheelDirection == "natural" { direction = -direction }
        viewModel.move(direction)
        wheelAccumulator = 0
        lastWheelStep = now
        return true
    }

    // MARK: - Keyboard

    private func handleKey(_ info: KeyEventInfo) -> Bool {
        let cmd = info.command
        let ctrl = info.control
        let chars = info.characters
        // SwiftUI's TextField uses an NSTextView field editor. While one is
        // editing (search box, new-board name), only Escape is ours — every
        // other key must reach the field editor, or Return could never commit
        // the board name and Cmd+C would clobber text selections.
        let editing = panel.firstResponder is NSTextView
        if editing && info.keyCode != 53 { return false }
        let inSearch = viewModel.searchFocused || editing

        switch info.keyCode {
        case 53: // Escape
            if inSearch && !viewModel.state.query.isEmpty {
                viewModel.setQuery("")
            } else if viewModel.state.detailClipId != nil {
                viewModel.closeDetail()
            } else {
                hide()
            }
            return true
        case 36: // Return
            viewModel.pasteSelected(plain: cmd || ctrl)
            return true
        case 49: // Space — full-content preview
            if inSearch && !viewModel.state.query.isEmpty { return false }
            viewModel.toggleDetail()
            return true
        case 123, 124: // Left / Right
            // Only yield to caret movement when the search box actually has
            // text; a stale focus flag must not block card navigation.
            if inSearch && !viewModel.state.query.isEmpty { return false }
            viewModel.move(info.keyCode == 123 ? -1 : 1)
            return true
        case 48: // Tab — cycle kind filter
            viewModel.cycleKind()
            return true
        case 51, 117: // Delete / Forward Delete
            if inSearch && !viewModel.state.query.isEmpty { return false }
            viewModel.deleteSelected()
            return true
        default:
            break
        }

        let lower = chars.lowercased()
        if cmd && lower == "p" { viewModel.pinSelected(); return true }
        if cmd && lower == "b" { viewModel.toggleSidebar(); return true }
        if cmd && lower == "c" { viewModel.copySelected(); return true }

        // Typing anywhere jumps into search. Feed the character directly so
        // the first keystroke is never lost; "/" just expands the field.
        if !cmd && !ctrl, let character = chars.first,
           character.isLetter || character.isNumber || character == "/" {
            if !inSearch {
                if character == "/" {
                    viewModel.beginSearch()
                } else {
                    viewModel.appendToQuery(String(character))
                }
                return true
            }
        }
        return false
    }
}
