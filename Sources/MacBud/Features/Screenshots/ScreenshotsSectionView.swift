import AVFoundation
import SwiftUI

/// Filmstrip layout: one large preview with its metadata on top, a horizontal strip of fixed-size
/// thumbnails below. Recency is what matters for screenshots, so the newest item is first and the
/// strip keeps the selection centred while `←/→` walk through it.
struct ScreenshotsSectionView: View {
    @Bindable var controller: ScreenshotsSectionController

    var body: some View {
        let results = controller.results.map { Ranked(item: $0.item, match: $0.match) }
        let query = controller.context.state.query
        if results.isEmpty {
            if controller.library.folders.isEmpty {
                EmptyState(symbol: "folder.badge.plus", title: "No folders configured", detail: "Add your screenshot folders in Settings (⌘,).")
            } else if query.isEmpty {
                EmptyState(symbol: "photo.on.rectangle.angled", title: controller.library.isScanning ? "Scanning…" : "No screenshots found",
                           detail: "Watching \(controller.library.folders.map(\.lastPathComponent).joined(separator: ", ")).")
            } else {
                EmptyState(symbol: "magnifyingglass", title: "No matches", detail: "Search matches file names.")
            }
        } else {
            VStack(spacing: 0) {
                MediaPreview(item: controller.selected, position: controller.selectedIndex + 1, total: results.count)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Theme.separator).frame(height: 1)
                Filmstrip(items: results, selectedIndex: controller.selectedIndex,
                          onSelect: { controller.selectedIndex = $0 },
                          onActivate: { controller.activate(results[$0].item, paste: controller.context.settings.enterAction == .paste) })
                    .frame(height: Filmstrip.height)
            }
        }
    }
}

struct Filmstrip: View {
    let items: [Ranked<MediaItem>]
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void

    static let cellSize = CGSize(width: 150, height: 94)
    static let height: CGFloat = cellSize.height + 24

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, ranked in
                        ThumbnailCell(item: ranked.item, isSelected: index == selectedIndex, size: Self.cellSize)
                            .onTapGesture(count: 2) { onActivate(index) }
                            .onTapGesture { onSelect(index) }
                            .id(ranked.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)
            .onChange(of: selectedIndex, initial: true) { _, index in
                guard items.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(items[index].id, anchor: .center) }
            }
        }
    }
}

struct ThumbnailCell: View {
    let item: MediaItem
    let isSelected: Bool
    let size: CGSize
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            shape.fill(Theme.chipFill)
            if let image {
                // Fill-and-crop inside a fixed frame; without the explicit frame + clip the image would
                // size the cell and spill across its neighbours.
                Image(nsImage: image).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Image(systemName: item.kind == .video ? "film" : "photo").foregroundStyle(Theme.textTertiary)
            }
            if item.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(6)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(isSelected ? Theme.accent : .white.opacity(hovering ? 0.3 : 0.1), lineWidth: isSelected ? 2 : 1))
        .shadow(color: isSelected ? Theme.accent.opacity(0.35) : .clear, radius: 8)
        .scaleEffect(isSelected ? 1 : hovering ? 0.99 : 0.96)
        .opacity(isSelected || hovering ? 1 : 0.82)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.filename)
        .task(id: item.url) {
            if let hit = ThumbnailCache.shared.cached(item.url, size: Self.thumbnailPixels) {
                image = hit
            } else {
                image = await ThumbnailCache.shared.thumbnail(for: item.url, size: Self.thumbnailPixels)
            }
        }
    }

    static let thumbnailPixels = CGSize(width: 300, height: 190)
}

struct MediaPreview: View {
    let item: MediaItem?
    var position: Int = 0
    var total: Int = 0
    @State private var image: NSImage?
    @State private var details = ""

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                            .overlay(alignment: .bottomTrailing) {
                                if item.kind == .video {
                                    Label("Video", systemImage: "play.fill")
                                        .font(Theme.caption).foregroundStyle(.white)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(.black.opacity(0.55), in: Capsule())
                                        .padding(10)
                                }
                            }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                HStack(spacing: 6) {
                    Text(item.filename).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                    Text("·")
                    Text(details).lineLimit(1)
                    Spacer()
                    if total > 0 { Text("\(position) of \(total)").monospacedDigit(); Text("·") }
                    Label(item.folderName, systemImage: "folder")
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 16)
                .frame(height: 26)
            }
            .task(id: item.url) {
                // Show the strip's small thumbnail at once (videos take a moment at full size), then upgrade.
                image = ThumbnailCache.shared.cached(item.url, size: ThumbnailCell.thumbnailPixels)
                details = MediaInfo.quickDescription(for: item)
                if let large = await ThumbnailCache.shared.thumbnail(for: item.url, size: CGSize(width: 1460, height: 900)) { image = large }
                details = await MediaInfo.description(for: item)
            }
        } else {
            EmptyState(symbol: "photo.on.rectangle.angled", title: "Select a screenshot", detail: "← → move through the strip; ↩ copies the file.")
        }
    }
}

enum MediaInfo {
    static func quickDescription(for item: MediaItem) -> String {
        "\(item.url.pathExtension.uppercased()) · \(item.byteCount.byteCountDescription) · \(item.createdAt.relativeDescription)"
    }

    static func description(for item: MediaItem) async -> String {
        var parts: [String] = []
        switch item.kind {
        case .image:
            if let size = await Task.detached(operation: { imageSize(item.url) }).value {
                parts.append("\(Int(size.width)) × \(Int(size.height))")
            }
        case .video:
            if let seconds = await videoDuration(item.url) {
                parts.append(Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)))
            }
        }
        parts.append(item.url.pathExtension.uppercased())
        parts.append(item.byteCount.byteCountDescription)
        parts.append(item.createdAt.relativeDescription)
        return parts.joined(separator: " · ")
    }

    nonisolated static func imageSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    nonisolated static func videoDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        return duration.seconds.isFinite ? duration.seconds : nil
    }
}
