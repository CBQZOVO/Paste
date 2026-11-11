import Foundation

/// All app data lives in Application Support under this bundle-id directory.
/// Keep the identifier stable: changing it would orphan an existing user's
/// history, images and settings.
public enum PastePaths {
    public static func dataDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return base.appendingPathComponent("com.pasteclone.app", isDirectory: true)
    }

    public static func database() throws -> URL {
        try dataDirectory().appendingPathComponent("paste.db", isDirectory: false)
    }

    /// Called only when opening for writing; read-only diagnostics must not
    /// create directories or touch the database.
    public static func ensureDataDirectory() throws {
        let dir = try dataDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for sub in ["images", "icons"] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
}
