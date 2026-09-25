import AVFoundation
import SwiftUI

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
                    Label(item.folderName, systemImage: "folder")
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 16)
                .frame(height: 26)
            }
            .task(id: item.url) {
                // Show the strip's small thumbnail at once (videos take a moment at full size), then upgrade.
                image = ThumbnailCache.shared.cached(item.url, size: MediaThumbnail.pixels)
                details = MediaInfo.quickDescription(for: item)
                if let large = await ThumbnailCache.shared.thumbnail(for: item.url, size: CGSize(width: 1460, height: 900)) { image = large }
                details = await MediaInfo.description(for: item)
            }
        } else {
            EmptyState(symbol: "photo.on.rectangle.angled", title: "Select a screenshot")
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
