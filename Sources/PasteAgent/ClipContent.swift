import Foundation

/// The app that owned the foreground when the copy happened.
public struct SourceApplication: Equatable, Sendable {
    public var name: String
    /// Lowercased executable/bundle name, used for the exclusion list.
    public var executableName: String
    public var path: String
    public var iconPath: String
    public var color: String

    public init(
        name: String = "",
        executableName: String = "",
        path: String = "",
        iconPath: String = "",
        color: String = ""
    ) {
        self.name = name
        self.executableName = executableName
        self.path = path
        self.iconPath = iconPath
        self.color = color
    }

    public static let unknown = SourceApplication()
}

/// A raw read of NSPasteboard, already reduced to plain data. Contains no
/// AppKit types so the whole capture pipeline can be unit tested.
public struct ClipboardSnapshot: Equatable, Sendable {
    public var text: String?
    public var html: String?
    public var imagePNG: Data?
    public var filePaths: [String]
    public var changeCount: Int
    public var source: SourceApplication

    public init(
        text: String? = nil,
        html: String? = nil,
        imagePNG: Data? = nil,
        filePaths: [String] = [],
        changeCount: Int = 0,
        source: SourceApplication = .unknown
    ) {
        self.text = text
        self.html = html
        self.imagePNG = imagePNG
        self.filePaths = filePaths
        self.changeCount = changeCount
        self.source = source
    }
}

public enum ClipContent: Equatable, Sendable {
    case text(String, html: String?)
    case link(String, html: String?)
    case color(String)
    case image(Data)
    case files([String])
}

/// Classification priority is files > image > text, because Finder copies
/// carry a text flavor too.
public enum ClipClassifier {
    public static func classify(_ snapshot: ClipboardSnapshot) -> ClipContent? {
        if !snapshot.filePaths.isEmpty {
            return .files(snapshot.filePaths)
        }
        if let png = snapshot.imagePNG, !png.isEmpty {
            return .image(png)
        }
        guard let text = snapshot.text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return classify(text: trimmed, html: snapshot.html)
    }

    public static func classify(text: String, html: String? = nil) -> ClipContent {
        if isURL(text) {
            return .link(text, html: html)
        }
        if normalizedColor(text) != nil {
            return .color(text)
        }
        return .text(text, html: html)
    }

    /// A conservative URL test: no whitespace, 4...2048 bytes, and one of
    /// four literal prefixes. `www.` counts even without a scheme.
    public static func isURL(_ string: String) -> Bool {
        let bytes = string.utf8.count
        guard bytes >= 4, bytes <= 2048,
              !string.contains("\n"), !string.contains(" ") else { return false }
        let lower = string.lowercased()
        return lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("www.")
            || lower.hasPrefix("ftp://")
    }

    /// Returns a canonical `#rrggbb`, or nil for anything that is not a hex
    /// color. Walks UTF-8 bytes, so multi-byte input (`#中文`) can never trap.
    /// Supports #rgb, #rrggbb, #rrggbbaa and 0x/0X prefixes. `rgb(r,g,b)`
    /// is intentionally not supported.
    public static func normalizedColor(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(trimmed.utf8)
        var start = 0
        if bytes.first == UInt8(ascii: "#") {
            start = 1
        } else if bytes.count >= 2,
                  bytes[0] == UInt8(ascii: "0"),
                  bytes[1] == UInt8(ascii: "x") || bytes[1] == UInt8(ascii: "X") {
            start = 2
        } else {
            return nil
        }
        let digits = Array(bytes[start...])
        let count = digits.count
        guard count == 3 || count == 6 || count == 8 else { return nil }

        func value(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var components: [UInt8] = []
        if count == 3 {
            for digit in digits {
                guard let v = value(digit) else { return nil }
                components.append(v * 16 + v)
            }
        } else {
            for pair in stride(from: 0, to: 6, by: 2) {
                guard let high = value(digits[pair]), let low = value(digits[pair + 1]) else {
                    return nil
                }
                components.append(high * 16 + low)
            }
        }
        return String(format: "#%02x%02x%02x", components[0], components[1], components[2])
    }
}
