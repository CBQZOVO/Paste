import ApplicationServices
import CoreGraphics
import Foundation

/// Accessibility permission and the synthesized Cmd+V chord.
enum PasteKeys {
    // kVK_Command / kVK_ANSI_V
    private static let commandKey: CGKeyCode = 55
    private static let vKey: CGKeyCode = 9

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// kAXTrustedCheckOptionPrompt is exposed as a global mutable CFString,
    /// which Swift 6 forbids reading from a concurrency-safe context. Its
    /// value is a stable documented string, so use it directly.
    private static let promptKey = "AXTrustedCheckOptionPrompt"

    /// Shows the system Accessibility prompt and adds the app to the list.
    /// Safe to call repeatedly; the system only prompts while untrusted.
    static func requestPrompt() -> Bool {
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// A bare Command keydown followed by a bare V does not work: CGEvent
    /// builds events with zero modifier flags. Every event must be tagged
    /// with maskCommand explicitly, with small gaps so apps that track
    /// modifier transitions see a real chord.
    static func sendCmdV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        func chord(_ key: CGKeyCode, down: Bool) -> Bool {
            guard let event = CGEvent(
                keyboardEventSource: source, virtualKey: key, keyDown: down
            ) else { return false }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
            return true
        }

        var ok = chord(commandKey, down: true)
        Thread.sleep(forTimeInterval: 0.03)
        ok = chord(vKey, down: true) && ok
        Thread.sleep(forTimeInterval: 0.03)
        ok = chord(vKey, down: false) && ok
        Thread.sleep(forTimeInterval: 0.03)
        ok = chord(commandKey, down: false) && ok
        return ok
    }
}
