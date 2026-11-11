import Foundation

/// Small, testable helpers for the media paths stored in `clips.files`.
/// Previews and the storage layer share these rules so they always agree
/// on what counts as an image.
public enum ClipMedia {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp",
    ]

    /// Case-insensitive extension check. Never reads the file itself.
    public static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// `clips.files` is a JSON array of absolute paths. A missing or damaged
    /// value yields an empty list instead of crashing.
    public static func paths(from json: String?) -> [String] {
        guard let json,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return decoded.filter { !$0.isEmpty }
    }

    /// The first few image paths worth rendering as thumbnails. A negative
    /// limit is treated as zero instead of trapping inside `prefix`.
    public static func imagePaths(in paths: [String], limit: Int = 2) -> [String] {
        Array(paths.filter(isImagePath).prefix(max(0, limit)))
    }
}
