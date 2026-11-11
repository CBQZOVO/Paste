import AppKit
import PasteAgent
import PasteCore
import SwiftUI

/// Light/dark palette for the panel: solid cards with a colored header
/// over a translucent background.
enum PanelPalette {
    static func cardSurface(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Color.white : Color.black.opacity(0.30)
    }

    static func cardStroke(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Color.black.opacity(0.12) : Color.white.opacity(0.12)
    }

    static func primary(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Color.black.opacity(0.88) : Color.white.opacity(0.94)
    }

    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Color.black.opacity(0.58) : Color.white.opacity(0.62)
    }

    static func chip(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.12)
    }
}

struct CardStripView: View {
    @ObservedObject var vm: PanelViewModel

    var body: some View {
        // A ScrollView proposes an unbounded height to its content, so
        // `.frame(maxHeight: .infinity)` on the cards collapses to their
        // intrinsic height and leaves a large empty band below. Measure the
        // available height and give every card an explicit one instead.
        GeometryReader { geometry in
            let cardHeight = max(1, geometry.size.height - 20)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(Array(vm.state.clips.enumerated()), id: \.element.id) { index, clip in
                            ClipCardView(
                                clip: clip,
                                selected: index == vm.state.selection,
                                shortcutIndex: index + 1
                            )
                            .frame(height: cardHeight)
                            .id(clip.id)
                            // A single click selects and pastes. The panel
                            // hides on the first paste, so a double click
                            // cannot paste twice.
                            .onTapGesture {
                                vm.select(index: index)
                                vm.pasteSelected()
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                // Wheel events are reinterpreted as selection changes, so
                // the strip never scrolls by itself. Only the selected id
                // and the list size are observed: typing in the search field
                // must not yank the user back to the selected card.
                .onChange(of: selectedID, initial: true) { _, _ in
                    scrollToSelection(proxy)
                }
                .onChange(of: vm.state.clips.count, initial: true) { _, _ in
                    scrollToSelection(proxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedID: Int64? { PanelLogic.selectedClip(vm.state)?.id }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let id = selectedID else { return }
        proxy.scrollTo(id, anchor: .center)
    }
}

private struct ClipCardView: View {
    let clip: Clip
    let selected: Bool
    let shortcutIndex: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            caption
        }
        .frame(width: 245)
        .frame(maxHeight: .infinity)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(PanelPalette.cardStroke(scheme), lineWidth: 1)
        )
        .overlay {
            if selected {
                // The emphasis is a BORDER, not a tinted card: a soft halo,
                // a thick accent stroke, then a thin white inner line so the
                // outline stays readable over the colored header too.
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 9)
                    .blur(radius: 5)
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 4)
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                    .padding(3)
            }
        }
        .shadow(
            color: selected ? Color.accentColor.opacity(0.35) : .clear,
            radius: selected ? 8 : 0
        )
        // Keep the halo above neighbouring cards.
        .zIndex(selected ? 1 : 0)
    }

    /// Card body stays white/dark for both states; selection is expressed
    /// only by the outline so the content does not look "filled in".
    private var surface: Color {
        PanelPalette.cardSurface(scheme)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ClipFormatting.title(for: clip))
                    .font(.system(size: 16, weight: .bold))
                Text(ClipFormatting.relativeTime(
                    nowMs: Int64(Date().timeIntervalSince1970 * 1_000),
                    createdAtMs: clip.createdAt
                ))
                .font(.system(size: 11))
                .opacity(0.85)
            }
            Spacer(minLength: 4)
            sourceBadge
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(headerColor)
    }

    /// Stable per-clip mix of blue / purple / orange. Blue dominates,
    /// orange is the accent.
    private var headerColor: Color {
        let blue = Color(red: 0.28, green: 0.62, blue: 0.96)
        let purple = Color(red: 0.47, green: 0.36, blue: 0.95)
        let orange = Color(red: 0.98, green: 0.69, blue: 0.24)
        let palette: [Color] = [blue, blue, blue, purple, blue, orange]
        let index = Int(abs(clip.id) % Int64(palette.count))
        return palette[index]
    }

    private var sourceBadge: some View {
        Group {
            if let image = ThumbnailCache.shared.appIcon(for: clip.sourceIcon) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Text(String(clip.sourceName.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 36, height: 36)
        .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Content

    private var content: some View {
        ClipPreview(clip: clip)
            .foregroundStyle(PanelPalette.primary(scheme))
            // Explicit top-leading alignment: a plain maxWidth/maxHeight
            // frame centers its content, which would make card text float in
            // the middle of the card.
            .padding(.top, 16)
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .padding(.bottom, 10)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .background {
                if clip.kind == .image {
                    Checkerboard()
                } else {
                    surface
                }
            }
    }

    // MARK: Caption

    private var caption: some View {
        HStack(spacing: 4) {
            Text(captionText)
                .font(.system(size: 11))
                .foregroundStyle(PanelPalette.secondary(scheme))
                .lineLimit(1)
            Spacer(minLength: 2)
            if (1...9).contains(shortcutIndex) {
                Text("\(shortcutIndex)")
                    .font(.system(size: 11))
                    .foregroundStyle(PanelPalette.secondary(scheme))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(surface)
    }

    private var captionText: String {
        if clip.kind == .image, let path = clip.imagePath,
           let size = ThumbnailCache.shared.pixelSize(at: path) {
            return "\(size.width) × \(size.height)"
        }
        return ClipFormatting.caption(for: clip)
    }
}

/// Transparency checkerboard behind image clips.
private struct Checkerboard: View {
    private let square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let light = Color.white
            let dark = Color(white: 0.88)
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var column = 0
                var x: CGFloat = 0
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: square, height: square)
                    context.fill(
                        Path(rect),
                        with: .color((row + column) % 2 == 0 ? light : dark)
                    )
                    x += square
                    column += 1
                }
                y += square
                row += 1
            }
        }
    }
}

private struct ClipPreview: View {
    let clip: Clip
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch clip.kind {
            case .text, .link:
                Text(clip.text ?? "")
                    .font(.system(size: 15))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .color:
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hexColor(clip.text ?? "") ?? .gray)
                        .frame(height: 70)
                    Text(clip.text ?? "").font(.system(size: 12, design: .monospaced))
                }
            case .image:
                if let path = clip.imagePath,
                   let image = ThumbnailCache.shared.thumbnail(for: path, maxPixel: 360) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("图片文件已丢失")
                        .font(.caption)
                        .foregroundStyle(PanelPalette.secondary(scheme))
                }
            case .file:
                FilePreview(files: clip.files)
            }
        }
    }
}

/// File clips show thumbnails for image paths (Finder copies / screenshots)
/// and plain file names for everything else.
private struct FilePreview: View {
    let files: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let paths = ClipMedia.paths(from: files)
        let images = ClipMedia.imagePaths(in: paths, limit: 2)
        return VStack(alignment: .leading, spacing: 5) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images, id: \.self) { path in
                        if let image = ThumbnailCache.shared.thumbnail(for: path, maxPixel: 220) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
            ForEach(Array(paths.prefix(3)), id: \.self) { path in
                Label((path as NSString).lastPathComponent, systemImage: "doc")
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            if paths.count > 3 {
                Text("还有 \(paths.count - 3) 个文件…")
                    .font(.system(size: 10))
                    .foregroundStyle(PanelPalette.secondary(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func hexColor(_ raw: String) -> Color? {
    guard let hex = ClipClassifier.normalizedColor(raw), hex.count == 7 else { return nil }
    let digits = Array(hex.dropFirst())
    func component(_ high: Character, _ low: Character) -> Double {
        Double(Int(String(high) + String(low), radix: 16) ?? 0) / 255.0
    }
    return Color(
        red: component(digits[0], digits[1]),
        green: component(digits[2], digits[3]),
        blue: component(digits[4], digits[5])
    )
}
