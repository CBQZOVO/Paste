import Foundation
import PasteCore

/// Labels shown on the cards and in the full-content overlay. Kept free of
/// AppKit/SwiftUI so the boundaries (time buckets, counters, captions) are
/// unit testable.
public enum ClipFormatting {
    /// `clips.created_at` is milliseconds since the unix epoch.
    public static func relativeTime(nowMs: Int64, createdAtMs: Int64) -> String {
        let seconds = max(0, (nowMs - createdAtMs) / 1_000)
        if seconds < 60 { return "刚刚" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)小时前" }
        let days = hours / 24
        if days < 30 { return "\(days)天前" }
        return "\(days / 30)个月前"
    }

    /// Colored header title, e.g. "图片" / "1个文件".
    public static func title(for clip: Clip) -> String {
        switch clip.kind {
        case .text: return "文本"
        case .link: return "链接"
        case .color: return "颜色"
        case .image: return "图片"
        case .file:
            let count = ClipMedia.paths(from: clip.files).count
            return count == 1 ? "1个文件" : "\(count)个文件"
        }
    }

    /// Small line under the preview: character count, file name, etc.
    public static func caption(for clip: Clip) -> String {
        switch clip.kind {
        case .text, .link, .color:
            return "\(clip.text?.count ?? 0) 个字符"
        case .image:
            return "图片"
        case .file:
            let paths = ClipMedia.paths(from: clip.files)
            if paths.count == 1 { return (paths[0] as NSString).lastPathComponent }
            return paths.isEmpty ? "文件" : "\(paths.count) 个文件"
        }
    }

    /// SwiftUI lays out a Text in one pass, so a multi-megabyte clipboard
    /// payload would freeze the panel. The overlay shows a bounded prefix.
    public static let detailTextLimit = 100_000

    /// Full content for the detail overlay. File lists are expanded to one
    /// path per line; a damaged JSON value falls back to the stored raw text
    /// so the user can still see and copy what was captured.
    public static func detailText(for clip: Clip, limit: Int = detailTextLimit) -> String {
        let full: String
        switch clip.kind {
        case .text, .link, .color:
            full = clip.text ?? "（无文本内容）"
        case .image:
            full = clip.imagePath ?? "（图片文件已丢失）"
        case .file:
            let paths = ClipMedia.paths(from: clip.files)
            full = paths.isEmpty ? (clip.files ?? "（无文件内容）") : paths.joined(separator: "\n")
        }
        guard limit > 0, full.count > limit else { return full }
        return "\(full.prefix(limit))\n\n… 内容过长，仅显示前 \(limit) 个字符（共 \(full.count) 个）"
    }
}
