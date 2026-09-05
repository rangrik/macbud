import AVFoundation
import SwiftUI

struct ScreenshotsSectionView: View {
    @Bindable var controller: ScreenshotsSectionController

    var body: some View {
        let results = controller.results.map { Ranked(item: $0.item, match: $0.match) }
        let query = controller.context.state.query
        HStack(spacing: 0) {
            Group {
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
                    ThumbnailGrid(items: results, selectedIndex: controller.selectedIndex,
                                  onSelect: { controller.selectedIndex = $0 },
                                  onActivate: { controller.activate(results[$0].item, paste: controller.context.settings.enterAction == .paste) })
                }
            }
            .frame(width: 300)
            Rectangle().fill(Theme.separator).frame(width: 1)
            MediaPreview(item: controller.selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ThumbnailGrid: View {
    let items: [Ranked<MediaItem>]
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: ScreenshotsSectionController.columns), spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, ranked in
                        ThumbnailCell(item: ranked.item, isSelected: index == selectedIndex)
                            .onTapGesture(count: 2) { onActivate(index) }
                            .onTapGesture { onSelect(index) }
                            .id(ranked.id)
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.never)
            .onChange(of: selectedIndex, initial: true) { _, index in
                guard items.indices.contains(index) else { return }
                proxy.scrollTo(items[index].id, anchor: nil)
            }
        }
    }
}

struct ThumbnailCell: View {
    let item: MediaItem
    let isSelected: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
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
        .frame(height: 84)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : .white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: isSelected ? Theme.accent.opacity(0.35) : .clear, radius: 8)
        .task(id: item.url) {
            if let hit = ThumbnailCache.shared.cached(item.url, size: Self.size) {
                image = hit
            } else {
                image = await ThumbnailCache.shared.thumbnail(for: item.url, size: Self.size)
            }
        }
    }

    static let size = CGSize(width: 280, height: 168)
}

struct MediaPreview: View {
    let item: MediaItem?
    @State private var image: NSImage?
    @State private var details = ""

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                .padding(16)
                Rectangle().fill(Theme.separator).frame(height: 1)
                HStack(spacing: 6) {
                    Text(item.filename).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Text("·")
                    Text(details).lineLimit(1)
                    Spacer()
                    Text(item.folderName)
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 16)
                .frame(height: 30)
            }
            .task(id: item.url) {
                image = nil
                details = MediaInfo.quickDescription(for: item)
                image = await ThumbnailCache.shared.thumbnail(for: item.url, size: CGSize(width: 880, height: 600))
                details = await MediaInfo.description(for: item)
            }
        } else {
            EmptyState(symbol: "photo.on.rectangle.angled", title: "Select a screenshot", detail: "Arrow keys move through the grid; ↩ copies the file.")
        }
    }
}

/// Dimensions, duration, size and date for the preview footer.
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
