import CryptoKit
import Foundation
import PasteCore

public enum CaptureOutcome: Equatable, Sendable {
    case inserted(Clip)
    case touched(Clip)
    case skipped
}

/// Owns dedupe, image persistence and cleanup for a plain
/// `ClipboardSnapshot`. Everything here runs in tests without a real
/// clipboard or foreground app.
public final class CapturePipeline {
    private let store: ClipStore
    private let imagesDirectory: URL

    /// Reports image files removed by cleanup so the UI can drop their
    /// cached thumbnails. PasteAgent stays free of AppKit types.
    public var onImagesRemoved: (([String]) -> Void)?

    public init(store: ClipStore, dataDirectory: URL) {
        self.store = store
        self.imagesDirectory = dataDirectory.appendingPathComponent("images", isDirectory: true)
    }

    public struct Columns: Equatable, Sendable {
        public var kind: ClipKind = .text
        public var text: String?
        public var html: String?
        public var files: String?
        public var imagePNG: Data?
    }

    public static func columns(for content: ClipContent) -> Columns {
        switch content {
        case .text(let text, let html):
            return Columns(kind: .text, text: text, html: html)
        case .link(let text, let html):
            return Columns(kind: .link, text: text, html: html)
        case .color(let text):
            return Columns(kind: .color, text: text)
        case .image(let png):
            return Columns(kind: .image, imagePNG: png)
        case .files(let paths):
            // Do not escape "/": the files string is part of the dedupe
            // comparison, so a different escaping would make every Finder
            // copy a new clip.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let json = (try? encoder.encode(paths)).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? "[]"
            return Columns(kind: .file, files: json)
        }
    }

    public func process(
        snapshot: ClipboardSnapshot,
        nowMs: Int64,
        settings: AppSettings
    ) throws -> CaptureOutcome {
        guard let content = ClipClassifier.classify(snapshot) else { return .skipped }
        let columns = Self.columns(for: content)
        let source = snapshot.source
        let contentHash = Self.contentHash(for: columns)

        // 1. Identical text anywhere in history moves that row to the front.
        //    Kind is deliberately ignored: the same string classified as a
        //    color on a later copy must not become a second entry.
        if let text = columns.text, let existing = try store.findTextClip(text) {
            return try touch(existing, nowMs: nowMs, settings: settings)
        }

        // 2. Identical image/file content anywhere in history moves that row
        //    to the front. The content hash covers A,B,A sequences instead of
        //    only comparing against the newest row.
        if let contentHash,
           let existing = try store.findClipByHash(contentHash) {
            return try touch(existing, nowMs: nowMs, settings: settings)
        }

        // 3. Persist image bytes before inserting the row. If the write
        //    fails, keep the clip with a NULL image_path instead of losing
        //    the history entry.
        var imagePath: String?
        if let png = columns.imagePNG {
            let target = imagesDirectory.appendingPathComponent("\(Self.sha256(png))-\(nowMs).png")
            try? FileManager.default.createDirectory(
                at: imagesDirectory, withIntermediateDirectories: true
            )
            if (try? png.write(to: target)) != nil {
                imagePath = target.path
            }
        }

        let clip = Clip(
            kind: columns.kind,
            text: columns.text,
            html: columns.html,
            imagePath: imagePath,
            files: columns.files,
            sourceName: source.name,
            sourcePath: source.path,
            sourceColor: source.color,
            sourceIcon: source.iconPath,
            createdAt: nowMs
        )
        // If the PNG did not land, storing the hash would make every later
        // copy of the same image "touch" a row that can never be pasted.
        let storedHash = (columns.kind == .image && imagePath == nil) ? nil : contentHash
        let id: Int64
        do {
            id = try store.insertClip(clip, contentHash: storedHash)
        } catch {
            // The row did not land; do not leave the PNG behind as an orphan.
            removeImage(imagePath)
            throw error
        }
        var inserted = clip
        inserted.id = id

        try cleanup(nowMs: nowMs, settings: settings)
        return .inserted(inserted)
    }

    /// Enforce the limit / retention policy. Called after every accepted clip
    /// (insert OR touch) and when those settings change, so a policy change
    /// takes effect even if the next copies are all duplicates.
    @discardableResult
    public func cleanup(nowMs: Int64, settings: AppSettings) throws -> [String] {
        var removed: [String] = []
        if settings.maxClips > 0 {
            for victim in try store.enforceLimit(max: settings.maxClips) {
                if let path = victim.imagePath {
                    removeImage(path)
                    removed.append(path)
                }
            }
        }
        if let cutoff = CapturePolicy.retentionCutoff(nowMs: nowMs, days: settings.retentionDays) {
            for victim in try store.pruneExpired(cutoffMs: cutoff) {
                if let path = victim.imagePath {
                    removeImage(path)
                    removed.append(path)
                }
            }
        }
        if !removed.isEmpty { onImagesRemoved?(removed) }
        return removed
    }

    /// Content-level dedupe key for the kinds whose text is NULL. Text kinds
    /// dedupe through `findTextClip` instead.
    private static func contentHash(for columns: Columns) -> String? {
        switch columns.kind {
        case .image:
            return columns.imagePNG.map(sha256)
        case .file:
            return columns.files.map { sha256(Data($0.utf8)) }
        case .text, .link, .color:
            return nil
        }
    }

    private func touch(_ clip: Clip, nowMs: Int64, settings: AppSettings) throws -> CaptureOutcome {
        _ = try store.touchClip(id: clip.id, nowMs: nowMs)
        try cleanup(nowMs: nowMs, settings: settings)
        var moved = clip
        moved.createdAt = nowMs
        return .touched(moved)
    }

    private func removeImage(_ path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
