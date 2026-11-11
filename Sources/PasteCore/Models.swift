import Foundation

/// Values stored in `clips.kind`.
public enum ClipKind: String, Codable, Sendable {
    case text, link, image, file, color

    /// Unknown values from an older database fall back to text.
    public init(dbValue: String) {
        self = ClipKind(rawValue: dbValue) ?? .text
    }
}

/// One row of `clips`. Property names use Swift conventions; the SQL
/// columns stay snake_case and are mapped in `ClipStore`.
public struct Clip: Codable, Equatable, Sendable {
    public var id: Int64
    public var kind: ClipKind
    public var text: String?
    public var html: String?
    public var imagePath: String?
    /// JSON array of file paths, kept as the raw database string.
    public var files: String?
    public var sourceName: String
    /// Absolute path of the source app, kept for diagnostics.
    public var sourcePath: String
    /// Kept for compatibility with older databases: the UI uses a fixed
    /// per-clip palette instead of sampling app icons for a brand color.
    public var sourceColor: String
    public var sourceIcon: String
    public var pinboardId: Int64?
    /// Unix epoch MILLISECONDS (not seconds): sorting, retention and the
    /// relative-time labels all depend on this unit.
    public var createdAt: Int64
    /// Incremented on every paste; not shown in the panel today.
    public var pasteCount: Int64

    public init(
        id: Int64 = 0,
        kind: ClipKind,
        text: String? = nil,
        html: String? = nil,
        imagePath: String? = nil,
        files: String? = nil,
        sourceName: String = "",
        sourcePath: String = "",
        sourceColor: String = "",
        sourceIcon: String = "",
        pinboardId: Int64? = nil,
        createdAt: Int64,
        pasteCount: Int64 = 0
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.html = html
        self.imagePath = imagePath
        self.files = files
        self.sourceName = sourceName
        self.sourcePath = sourcePath
        self.sourceColor = sourceColor
        self.sourceIcon = sourceIcon
        self.pinboardId = pinboardId
        self.createdAt = createdAt
        self.pasteCount = pasteCount
    }
}

public struct Pinboard: Codable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var position: Int64
    /// Unix epoch SECONDS (deliberately different from clips.createdAt).
    public var createdAt: Int64
}

public struct Source: Equatable, Sendable {
    public var name: String
    public var path: String
    public var color: String
}

/// Settings live in a single JSON blob under key "settings". Decoding is
/// tolerant per field, so a blob written by an older version — or one with
/// a single corrupt value — never resets the user's configuration.
public struct AppSettings: Codable, Equatable, Sendable {
    public var hotkey: String
    public var quickPaste: Bool
    public var maxClips: Int64
    public var retentionDays: Int64
    public var searchMode: String
    public var alwaysPlainText: Bool
    public var excludedApps: [String]
    public var paused: Bool
    public var autostart: Bool
    public var panelPosition: String
    public var wheelDirection: String

    /// Used only when the settings row does not exist at all.
    public init() {
        hotkey = "CmdOrCtrl+Shift+V"
        quickPaste = true
        maxClips = 0
        retentionDays = 0
        searchMode = "plain"
        alwaysPlainText = false
        excludedApps = AppSettings.defaultExcludedApps
        paused = false
        autostart = false
        panelPosition = "bottom"
        wheelDirection = "default"
    }

    private enum CodingKeys: String, CodingKey {
        case hotkey, quickPaste, maxClips, retentionDays, searchMode
        case alwaysPlainText, excludedApps, paused, autostart
        case panelPosition, wheelDirection
    }

    /// Absent or mistyped keys fall back per field. Empty strings are mapped
    /// to the real defaults (an empty panelPosition would leave the Picker
    /// unselected), and negative counters are clamped to zero. Unknown keys
    /// from older versions are simply ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        func string(_ key: CodingKeys, _ fallback: String) -> String {
            let value = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil
            return (value?.isEmpty == false) ? value! : fallback
        }
        func bool(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            ((try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? fallback
        }
        func count(_ key: CodingKeys, _ fallback: Int64) -> Int64 {
            let value = (try? c.decodeIfPresent(Int64.self, forKey: key)) ?? nil
            return value.map { max(0, $0) } ?? fallback
        }
        func strings(_ key: CodingKeys, _ fallback: [String]) -> [String] {
            ((try? c.decodeIfPresent([String].self, forKey: key)) ?? nil) ?? fallback
        }

        hotkey = string(.hotkey, "CmdOrCtrl+Shift+V")
        quickPaste = bool(.quickPaste, true)
        maxClips = count(.maxClips, 0)
        retentionDays = count(.retentionDays, 0)
        searchMode = string(.searchMode, "plain")
        alwaysPlainText = bool(.alwaysPlainText, false)
        excludedApps = strings(.excludedApps, AppSettings.defaultExcludedApps)
        paused = bool(.paused, false)
        autostart = bool(.autostart, false)
        panelPosition = string(.panelPosition, "bottom")
        wheelDirection = string(.wheelDirection, "default")
    }

    /// Common password managers, matched by lowercased executable name.
    /// Their clipboard contents are never written to the database.
    public static let defaultExcludedApps: [String] = [
        "1password.exe", "bitwarden.exe", "keepass.exe", "keepassxc.exe",
        "dashlane.exe", "lastpass.exe", "enpass.exe", "protonpass.exe",
        "robat.exe", "1password", "bitwarden", "keepassxc", "dashlane",
        "lastpass", "enpass", "protonpass",
    ]
}
