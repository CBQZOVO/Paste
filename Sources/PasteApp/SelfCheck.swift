import AppKit
import Foundation
import PasteAgent
import PasteCore

/// Non-resident smoke test for the system-integration layer. Verifies that
/// AppKit/Carbon/ApplicationServices link correctly and the real database is
/// readable, without starting an event loop or posting keystrokes.
enum SelfCheck {
    static func run() -> Never {
        var failures = 0

        func check(_ label: String, _ condition: @autoclosure () -> Bool, _ detail: String = "") {
            let ok = condition()
            print("\(ok ? "OK  " : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        do {
            let directory = try PastePaths.dataDirectory()
            let path = try PastePaths.database().path
            check("data directory exists", FileManager.default.fileExists(atPath: directory.path), directory.path)

            if FileManager.default.fileExists(atPath: path) {
                let store = try ClipStore(path: path, readOnly: true)
                let count = try store.countClips()
                check("database readable", true, "\(count) clips")

                // Decode the raw blob ourselves: loadSettings() silently
                // falls back to defaults, so it cannot report corruption.
                if let json = try store.getSetting("settings") {
                    let decodes = (try? JSONDecoder().decode(
                        AppSettings.self, from: Data(json.utf8)
                    )) != nil
                    check("settings JSON decodes", decodes)
                } else {
                    print("OK   settings JSON decodes — no settings row yet (defaults)")
                }

                let settings = try store.loadSettings()
                let hotkey = HotkeyParser.parse(settings.hotkey)
                check("main hotkey parses", hotkey != nil, hotkey.map { "keyCode=\($0.keyCode)" } ?? "")
                check("quick-paste hotkeys parse", (1...9).allSatisfy { HotkeyParser.quickPaste($0) != nil })
            } else {
                print("SKIP database — not initialized yet at \(path)")
            }
        } catch {
            print("FAIL database — \(error)")
            failures += 1
        }

        // Only meaningful inside a real .app bundle; `swift run` has no
        // Resources directory and legitimately falls back to a system symbol.
        if Bundle.main.bundleURL.pathExtension == "app" {
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            check("app icon resource", iconURL != nil, iconURL?.lastPathComponent ?? "")
            if let iconURL {
                check("app icon loads as NSImage", NSImage(contentsOf: iconURL) != nil)
            }
        }

        // Informational: an untrusted machine is a valid state, not a failure.
        print("INFO Accessibility API \(PasteKeys.isTrusted ? "trusted" : "NOT trusted (paste needs approval)")")
        print(failures == 0 ? "SELF-CHECK PASSED" : "SELF-CHECK FAILED: \(failures) issue(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
