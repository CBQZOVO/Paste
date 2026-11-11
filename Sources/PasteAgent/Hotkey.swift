import Foundation

/// A parsed global shortcut in Carbon terms. Carbon constants stay out of
/// this module so hotkey parsing remains unit-testable without AppKit.
public struct Hotkey: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum HotkeyParser {
    /// Parses strings in the settings format, e.g. "CmdOrCtrl+Shift+V".
    /// `CmdOrCtrl` resolves to Command on macOS (the only platform here).
    public static func parse(_ string: String) -> Hotkey? {
        // Keep empty segments: "Cmd++V" must be rejected, not silently
        // collapsed into "Cmd+V".
        let parts = string.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        let key = parts[parts.count - 1]
        guard let keyCode = keyCodes[key] else { return nil }

        var modifiers: Hotkey.Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "super", "cmdorctrl": modifiers.insert(.command)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        guard !modifiers.isEmpty else { return nil }
        return Hotkey(keyCode: keyCode, modifiers: modifiers)
    }

    /// Cmd+1...Cmd+9 for quick pasting.
    public static func quickPaste(_ index: Int) -> Hotkey? {
        guard (1...9).contains(index), let keyCode = keyCodes[String(index)] else { return nil }
        return Hotkey(keyCode: keyCode, modifiers: .command)
    }

    /// macOS virtual key codes (Carbon HIToolbox). Only the keys the settings
    /// UI can produce are included; an unknown key is rejected, never
    /// guessed — a wrong global hotkey is worse than no hotkey.
    static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "space": 49, "return": 36, "tab": 48, "delete": 51, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "up": 126, "down": 125, "left": 123, "right": 124,
    ]
}
