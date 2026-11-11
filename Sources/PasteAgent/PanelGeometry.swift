import CoreGraphics
import Foundation

/// Geometry for the floating panel, in logical points (origin bottom-left
/// for screen coordinates). `NSScreen.visibleFrame` already excludes the
/// menu bar and the Dock, so a panel placed against its edges never sits
/// underneath either of them.
public enum PanelGeometry {
    /// Size of the full-content overlay, clamped to the panel's own size.
    /// A fixed 640x360 box is taller than the 300pt panel and would cut off
    /// the overlay header, its close button and the end of long text.
    public static func detailSize(
        available: CGSize,
        preferred: CGSize = CGSize(width: 640, height: 360),
        margin: CGFloat = 20
    ) -> CGSize {
        CGSize(
            width: max(1, min(preferred.width, available.width - 2 * margin)),
            height: max(1, min(preferred.height, available.height - 2 * margin))
        )
    }

    public static func frame(
        visible: CGRect,
        panelHeight: CGFloat,
        position: String,
        margin: CGFloat = 12
    ) -> CGRect {
        let usable = max(1, visible.height - 2 * margin)
        let height = min(max(1, panelHeight), usable)
        let y: CGFloat
        switch position {
        case "top":
            y = visible.maxY - margin - height
        case "bottom":
            y = visible.minY + margin
        default:
            y = visible.midY - height / 2
        }
        // Never let a tall panel or an odd screen arrangement push it out of
        // the usable area. When margins plus height exceed the visible frame
        // the clamp interval inverts — center whatever fits instead.
        let lower = visible.minY + margin
        let upper = visible.maxY - margin - height
        let clamped = upper >= lower
            ? min(max(y, lower), upper)
            : visible.midY - height / 2
        return CGRect(
            x: visible.minX,
            y: clamped,
            width: max(1, visible.width),
            height: height
        )
    }
}
