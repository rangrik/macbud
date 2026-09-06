import SwiftUI

/// Colour and type tokens for the island. Everything sits on pure black so the island fuses with the notch.
enum Theme {
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.38)
    static let separator = Color.white.opacity(0.08)
    static let rowSelection = Color.white.opacity(0.11)
    static let rowHover = Color.white.opacity(0.05)
    static let chipFill = Color.white.opacity(0.07)
    static let accent = Color.accentColor
    static let warning = Color.orange

    static let rowTitle = Font.system(size: 13, weight: .regular)
    static let rowSubtitle = Font.system(size: 11)
    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let body = Font.system(size: 13)
    static let search = Font.system(size: 15)
    static let caption = Font.system(size: 11, weight: .medium)
}

extension Date {
    /// "just now", "4m ago", "Yesterday 14:02"…
    var relativeDescription: String {
        let interval = Date.now.timeIntervalSince(self)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if Calendar.current.isDateInToday(self) { return "Today " + formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(self) { return "Yesterday " + formatted(date: .omitted, time: .shortened) }
        return formatted(date: .abbreviated, time: .shortened)
    }
}

extension Int {
    var byteCountDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}

/// A keyboard hint like "⌘↩ Paste".
struct KeyHint: View {
    let keys: String
    let label: String
    var emphasized = false
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if !keys.isEmpty {
                Text(keys)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(emphasized ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 4))
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(emphasized ? Theme.textSecondary : Theme.textTertiary)
        }
    }
}

/// Loads an image from disk off the main thread and caches it.
struct DiskImage<Placeholder: View>: View {
    let url: URL?
    let maxPixelSize: Int
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await DiskImageLoader.shared.load(url, maxPixelSize: maxPixelSize)
        }
    }
}

final class DiskImageLoader {
    static let shared = DiskImageLoader()
    private let cache = NSCache<NSString, NSImage>()

    func load(_ url: URL, maxPixelSize: Int) async -> NSImage? {
        let key = "\(url.path)|\(maxPixelSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// True while a view tree is being rendered for an automation snapshot; AppKit-backed fields render as text.
extension EnvironmentValues {
    @Entry var snapshotMode: Bool = false
}
