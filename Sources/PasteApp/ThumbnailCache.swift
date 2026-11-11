import AppKit
import Foundation
import ImageIO
import PasteAgent

/// Small thumbnails generated through ImageIO without decoding the full
/// image. Loading every screenshot with NSImage(contentsOfFile:) in a
/// horizontal card strip would stall the main thread on large PNGs.
///
/// Also caches app icons and pixel dimensions: both are read while building
/// a card's body, which SwiftUI re-evaluates on every selection change.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private final class PixelSize: NSObject {
        let width: Int
        let height: Int
        init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let iconCache = NSCache<NSString, NSImage>()
    private let sizeCache = NSCache<NSString, PixelSize>()
    private static let maxFileBytes: UInt64 = 20 * 1024 * 1024

    private init() {
        cache.countLimit = 200
        // Decoded bitmaps are large; bill them so memory stays bounded even
        // with fewer than countLimit entries.
        cache.totalCostLimit = 64 * 1024 * 1024
        iconCache.countLimit = 100
        sizeCache.countLimit = 500
    }

    func thumbnail(for path: String, maxPixel: Int = 480) -> NSImage? {
        let key = "\(path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) {
            // Cleanup may delete the PNG while its thumbnail is still
            // cached; never render a file that no longer exists.
            guard FileManager.default.fileExists(atPath: path) else {
                cache.removeObject(forKey: key)
                return nil
            }
            return hit
        }
        guard ClipMedia.isImagePath(path),
              Self.fileSize(at: path) <= Self.maxFileBytes,
              let source = CGImageSourceCreateWithURL(
                  URL(fileURLWithPath: path) as CFURL, nil
              ) else { return nil }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// Original pixel dimensions from image metadata — no decode, so the
    /// "1680 × 526" caption under an image card costs nothing.
    func pixelSize(at path: String) -> (width: Int, height: Int)? {
        let key = path as NSString
        if let hit = sizeCache.object(forKey: key) {
            guard FileManager.default.fileExists(atPath: path) else {
                sizeCache.removeObject(forKey: key)
                return nil
            }
            return (hit.width, hit.height)
        }
        guard ClipMedia.isImagePath(path),
              let source = CGImageSourceCreateWithURL(
                  URL(fileURLWithPath: path) as CFURL, nil
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        sizeCache.setObject(PixelSize(width: width, height: height), forKey: key)
        return (width, height)
    }

    /// Icon of the app a clip was copied from. Missing files are not cached,
    /// so a freshly written icon shows up on the next refresh.
    func appIcon(for path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        let key = path as NSString
        if let hit = iconCache.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        iconCache.setObject(image, forKey: key)
        return image
    }

    /// Drop everything cached for a deleted file so cards stop showing a
    /// stale image after the PNG is removed.
    func invalidate(path: String) {
        for pixel in [220, 360, 480] {
            cache.removeObject(forKey: "\(path)#\(pixel)" as NSString)
        }
        sizeCache.removeObject(forKey: path as NSString)
        iconCache.removeObject(forKey: path as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
        iconCache.removeAllObjects()
        sizeCache.removeAllObjects()
    }

    /// A missing file reports size 0 and is filtered out by the whitelist
    /// check above; an oversized file is skipped rather than decoded.
    private static func fileSize(at path: String) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }
}
