import Darwin
import Foundation
import PasteCore
import SQLite3

/// `paste-dbcheck`: read-only inspection of the app's database. It never
/// runs PRAGMAs or DDL, so it is safe to point at a running app's file.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("[paste-dbcheck] " + message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
var path = (try? PastePaths.database().path) ?? ""
if let index = arguments.firstIndex(of: "--db"), index + 1 < arguments.count {
    path = arguments[index + 1]
}
guard !path.isEmpty else { fail("cannot resolve the default database path") }
guard FileManager.default.fileExists(atPath: path) else {
    fail("database not found: \(path) (pass --db <path>)")
}

do {
    let store = try ClipStore(path: path, readOnly: true)
    let clips = try store.listClips(filter: .all, limit: 3)
    let boards = try store.listPinboards()
    let settings = try store.loadSettings()

    print("sqlite      \(String(cString: sqlite3_libversion()))")
    print("database    \(path)")
    print("clips       \(try store.countClips())")
    print("pinboards   \(boards.count)")
    print("hotkey      \(settings.hotkey)")
    print("position    \(settings.panelPosition)")
    print("wheel       \(settings.wheelDirection)")
    print("searchMode  \(settings.searchMode)")
    print("retention   \(settings.retentionDays) days, maxClips \(settings.maxClips)")
    print("quickPaste  \(settings.quickPaste), paused \(settings.paused)")
    print("autostart   \(settings.autostart), plainText \(settings.alwaysPlainText)")
    print("excluded    \(settings.excludedApps.count) apps")
    print("newest      \(clips.prefix(3).map { "\($0.id)/\($0.kind.rawValue)/\($0.createdAt)" }.joined(separator: " "))")
    print("OK: read-only compatibility check passed")
} catch {
    fail("\(error)")
}
