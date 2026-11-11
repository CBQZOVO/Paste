import AppKit
import Foundation
import PasteAgent
import PasteCore

/// Wires the pieces together. Everything runs on the main thread: the 150 ms
/// clipboard poll, hotkey callbacks (dispatched to main), panel and menus.
/// The single copy of AppSettings lives in `viewModel`; this controller only
/// reads it.
@MainActor
final class AppController {
    private let store: ClipStore
    private let clipboard = SystemClipboard()
    private let pipeline: CapturePipeline
    private let hotkeys: GlobalHotkeys
    private let status = StatusMenu()
    private let dataDirectory: URL
    private let viewModel: PanelViewModel
    private let panel: PanelWindow
    private let settingsWindow: SettingsWindow
    private var baseline: Int
    private var timer: Timer?
    /// App that was frontmost BEFORE the panel opened; Cmd+V must land there.
    private var previousPID: pid_t?

    init() throws {
        try PastePaths.ensureDataDirectory()
        dataDirectory = try PastePaths.dataDirectory()
        store = try ClipStore()
        let initialSettings = try store.loadSettings()
        pipeline = CapturePipeline(store: store, dataDirectory: dataDirectory)
        baseline = clipboard.changeCount
        hotkeys = GlobalHotkeys()

        let vm = PanelViewModel(store: store, settings: initialSettings)
        viewModel = vm
        panel = PanelWindow(viewModel: vm)
        settingsWindow = SettingsWindow(viewModel: vm)

        vm.onPaste = { [weak self] clip, plain in self?.pasteFromPanel(clip, plain: plain) }
        vm.onCopy = { [weak self] clip in self?.copyToClipboard(clip) }
        vm.onTogglePause = { [weak self] in self?.togglePause() }
        vm.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        vm.onSettingsChanged = { [weak self] next in self?.applySettings(next) }
        pipeline.onImagesRemoved = { paths in
            MainActor.assumeIsolated {
                for path in paths { ThumbnailCache.shared.invalidate(path: path) }
            }
        }
        vm.onAutostartChanged = { enabled in
            let ok = LaunchAtLogin.setEnabled(enabled)
            if !ok { NSLog("[paste] login item change was rejected by macOS") }
            return ok
        }

        status.onOpenPanel = { [weak self] in self?.togglePanel() }
        status.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        status.onTogglePause = { [weak self] in self?.togglePause() }
        status.onQuit = { NSApplication.shared.terminate(nil) }
        status.onRequestAccessibility = { _ = PasteKeys.requestPrompt() }
        status.onMenuWillOpen = { [weak self] in self?.refreshStatus() }
    }

    func start() {
        registerHotkeys()
        refreshStatus()
        // A rebuilt or re-signed .app loses its login item; restore it when
        // the saved setting says it should be on. If macOS refuses, roll the
        // setting back so the toggle never claims something untrue.
        if viewModel.settings.autostart, !LaunchAtLogin.setEnabled(true) {
            var next = viewModel.settings
            next.autostart = false
            viewModel.settings = next
            try? store.saveSettings(next)
            NSLog("[paste] login item could not be restored; autostart disabled")
        }
        let pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        // .common keeps polling while menus are open or views are tracking;
        // the default mode alone silently drops ticks (and copies) there.
        RunLoop.main.add(pollTimer, forMode: .common)
        timer = pollTimer
        NSLog("[paste] agent started; AX trusted=%d, hotkey=%@",
              PasteKeys.isTrusted ? 1 : 0, viewModel.settings.hotkey)
    }

    // MARK: - Capture

    private func poll() {
        let current = clipboard.changeCount
        guard current != baseline else { return }

        // Paused: swallow the change without paying for icon extraction.
        if viewModel.paused {
            baseline = current
            return
        }

        // Check the exclusion list before doing any icon work: clipboard
        // changes from password managers must be discarded cheaply.
        guard CapturePolicy.shouldCapture(
            paused: false,
            excludedApps: viewModel.settings.excludedApps,
            executableName: Foreground.executableName()
        ) else {
            baseline = current
            return
        }
        let source = Foreground.current(
            iconsDirectory: dataDirectory.appendingPathComponent("icons", isDirectory: true)
        )

        let snapshot = clipboard.read(source: source)
        // Baseline records what we actually READ, not what we saw before
        // reading, so a copy racing in between cannot loop the same content.
        baseline = snapshot.changeCount
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            let outcome = try pipeline.process(snapshot: snapshot, nowMs: now, settings: viewModel.settings)
            switch outcome {
            case .skipped:
                break
            case .inserted, .touched:
                if panel.isVisible { viewModel.refetch() }
                refreshStatus()
            }
        } catch {
            NSLog("[paste] capture failed: %@", String(describing: error))
        }
    }

    // MARK: - Panel

    func togglePanel() {
        if panel.isVisible {
            panel.hide()
        } else {
            if let pid = Foreground.frontmostPID,
               pid != ProcessInfo.processInfo.processIdentifier {
                previousPID = pid
            }
            panel.show()
        }
    }

    // MARK: - Paste

    private func pasteFromPanel(_ clip: Clip, plain: Bool) {
        var content = clip
        // Plain-text mode only strips HTML from text-like clips; images and
        // file lists have no text variant, so ignore the flag instead of
        // failing the write below.
        if plain, content.kind == .text || content.kind == .link || content.kind == .color {
            content.html = nil
        }
        guard writeClipboard(content) else {
            viewModel.showToast("写入剪贴板失败，未粘贴")
            return
        }
        if let pid = previousPID ?? Foreground.frontmostPID,
           pid != ProcessInfo.processInfo.processIdentifier {
            Foreground.restore(pid: pid)
        }
        panel.hide()
        previousPID = nil
        sendPasteKey()
    }

    /// Cmd+1..9: with the panel open, paste the Nth visible card so the
    /// hotkey matches its badge. With the panel hidden, always use the
    /// unfiltered history — never the board or filter shown last time.
    private func pasteAt(index: Int) {
        guard (1...9).contains(index) else { return }
        let clips: [Clip]
        if panel.isVisible {
            clips = viewModel.state.clips
        } else {
            clips = (try? store.listClips(filter: .history, limit: 9)) ?? []
        }
        guard index <= clips.count else { return }
        pasteFromPanel(clips[index - 1], plain: viewModel.settings.alwaysPlainText)
    }

    private func copyToClipboard(_ clip: Clip) {
        guard writeClipboard(clip) else {
            viewModel.showToast("写入剪贴板失败，未复制")
            return
        }
        viewModel.showToast("已复制到剪贴板")
    }

    /// Writes the clip, records paste count and updates the changeCount
    /// baseline so our own write is never re-captured. Returns false when
    /// the content is unreadable — the caller must NOT post Cmd+V then.
    private func writeClipboard(_ clip: Clip) -> Bool {
        guard clipboard.write(clip) else {
            NSLog("[paste] clipboard write failed for clip %lld; paste aborted", clip.id)
            return false
        }
        // A changeCount baseline (instead of a sleep guard) means our own
        // write can never be recaptured by the 150 ms poll.
        baseline = clipboard.changeCount
        _ = try? store.incrementPasteCount(id: clip.id)
        return true
    }

    private func sendPasteKey() {
        // App activation is asynchronous; Cmd+V must land after the target
        // is key again. The chord sleeps ~90ms between events, so it runs
        // off the main thread to keep the UI and the poll responsive.
        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + .milliseconds(150)
        ) {
            guard PasteKeys.isTrusted else {
                NSLog("[paste] Accessibility not granted; Cmd+V skipped")
                return
            }
            if !PasteKeys.sendCmdV() {
                NSLog("[paste] Cmd+V could not be synthesized")
            }
        }
    }

    // MARK: - Hotkeys and state

    private func registerHotkeys() {
        if let main = HotkeyParser.parse(viewModel.settings.hotkey) {
            let ok = hotkeys.register(main, id: 1) { [weak self] in
                self?.togglePanel()
            }
            if !ok { NSLog("[paste] could not register main hotkey (taken by another app?)") }
        } else {
            NSLog("[paste] invalid hotkey in settings: %@", viewModel.settings.hotkey)
        }
        if viewModel.settings.quickPaste {
            for index in 1...9 {
                guard let hotkey = HotkeyParser.quickPaste(index) else { continue }
                let registered = hotkeys.register(hotkey, id: UInt32(10 + index)) { [weak self] in
                    self?.pasteAt(index: index)
                }
                if !registered { NSLog("[paste] could not register quick-paste %d", index) }
            }
        }
    }

    private func applySettings(_ next: AppSettings) {
        viewModel.settings = next
        viewModel.paused = next.paused
        // A changed limit / retention policy must apply immediately, not
        // only on the next new (non-duplicate) copy.
        do {
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            _ = try pipeline.cleanup(nowMs: now, settings: next)
        } catch {
            NSLog("[paste] cleanup after settings change failed: %@", String(describing: error))
        }
        hotkeys.unregisterAll()
        registerHotkeys()
        refreshStatus()
    }

    private func togglePause() {
        var next = viewModel.settings
        next.paused.toggle()
        viewModel.settings = next
        viewModel.paused = next.paused
        try? store.saveSettings(next)
        refreshStatus()
    }

    private func refreshStatus() {
        let count = (try? store.countClips()) ?? 0
        status.update(clipCount: count, paused: viewModel.paused, axTrusted: PasteKeys.isTrusted)
    }
}
