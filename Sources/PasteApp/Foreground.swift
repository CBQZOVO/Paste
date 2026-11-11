import AppKit
import Foundation
import PasteAgent

/// Frontmost app metadata, app icon caching and focus restore.
@MainActor
enum Foreground {
    static var frontmostPID: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Cheap frontmost-app lookup for the exclusion check. `current(_:)`
    /// additionally writes an icon file, which is wasted work for a
    /// clipboard change we are going to discard anyway.
    static func executableName() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let path = app.executableURL?.path else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent.lowercased()
    }

    static func current(iconsDirectory: URL) -> SourceApplication {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        let name = app.localizedName ?? ""
        let path = app.executableURL?.path ?? ""
        let executable = URL(fileURLWithPath: path).lastPathComponent.lowercased()

        var iconPath = ""
        if let bundleID = app.bundleIdentifier, !path.isEmpty {
            let file = iconsDirectory.appendingPathComponent("\(bundleID).png")
            var iconExists = FileManager.default.fileExists(atPath: file.path)
            if !iconExists {
                try? FileManager.default.createDirectory(
                    at: iconsDirectory, withIntermediateDirectories: true
                )
                let icon = app.icon ?? NSWorkspace.shared.icon(forFile: path)
                if let tiff = icon.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: file)
                    iconExists = FileManager.default.fileExists(atPath: file.path)
                }
            }
            if iconExists { iconPath = file.path }
        }
        return SourceApplication(
            name: name, executableName: executable, path: path,
            iconPath: iconPath, color: ""
        )
    }

    /// App activation is asynchronous; the paste keystroke must wait for it.
    static func restore(pid: pid_t) {
        // activateIgnoringOtherApps was deprecated in macOS 14 and is a
        // no-op on 26; a plain activation is the supported equivalent.
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }
}
