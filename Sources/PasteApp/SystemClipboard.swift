import AppKit
import Foundation
import PasteAgent
import PasteCore

/// NSPasteboard read/write. All access stays on the main thread.
@MainActor
final class SystemClipboard {
    private let pasteboard = NSPasteboard.general
    private let htmlType = NSPasteboard.PasteboardType("public.html")

    var changeCount: Int { pasteboard.changeCount }

    func read(source: SourceApplication) -> ClipboardSnapshot {
        var snapshot = ClipboardSnapshot(changeCount: pasteboard.changeCount, source: source)

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] {
            snapshot.filePaths = urls.compactMap(\.path).filter { !$0.isEmpty }
        }
        // A Finder copy exposes file URLs AND image data. Classification
        // prefers files, so skip the potentially large image read entirely.
        if snapshot.filePaths.isEmpty,
           let png = pasteboard.data(forType: .png) ?? tiffAsPNG(), !png.isEmpty {
            snapshot.imagePNG = png
        }
        snapshot.text = pasteboard.string(forType: .string)
        if let htmlData = pasteboard.data(forType: htmlType) {
            snapshot.html = String(data: htmlData, encoding: .utf8)
                ?? String(data: htmlData, encoding: .utf16)
        }
        return snapshot
    }

    /// Write a stored clip back. Returns false when the content is missing —
    /// the caller must NOT post Cmd+V in that case, or it would paste stale
    /// clipboard contents. Every flavor is built and validated BEFORE
    /// clearContents(), so a missing file or empty payload never touches the
    /// user's current clipboard. `writeObjects` only fails if the pasteboard
    /// server rejects an already-built item; that rare case is logged.
    @discardableResult
    func write(_ clip: Clip) -> Bool {
        let items: [NSPasteboardWriting]
        switch clip.kind {
        case .text, .link, .color:
            guard let text = clip.text else { return false }
            let item = NSPasteboardItem()
            guard item.setString(text, forType: .string), !item.types.isEmpty else {
                return false
            }
            if let html = clip.html {
                _ = item.setString(html, forType: htmlType)
            }
            items = [item]
        case .image:
            guard let path = clip.imagePath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  !data.isEmpty else { return false }
            let item = NSPasteboardItem()
            guard item.setData(data, forType: .png), !item.types.isEmpty else {
                return false
            }
            items = [item]
        case .file:
            guard let raw = clip.files,
                  let data = raw.data(using: .utf8),
                  let paths = try? JSONDecoder().decode([String].self, from: data),
                  !paths.isEmpty,
                  paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
                return false
            }
            items = paths.map { NSURL(fileURLWithPath: $0) }
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else {
            NSLog("[paste] pasteboard.writeObjects failed; clipboard was cleared")
            return false
        }
        return true
    }

    private func tiffAsPNG() -> Data? {
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
