import AppKit
import QuickLookThumbnailing

/// QuickLook-generated thumbnails, cached in memory and de-duplicated while in flight.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        cache.countLimit = 600
    }

    func cached(_ url: URL, size: CGSize) -> NSImage? { cache.object(forKey: key(url, size) as NSString) }

    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let k = key(url, size)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        if let task = inflight[k] { return await task.value }
        let task = Task<NSImage?, Never> {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
            do {
                return try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            } catch {
                Log.screenshots.debug("thumbnail failed for \(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }
        inflight[k] = task
        let image = await task.value
        inflight[k] = nil
        if let image { cache.setObject(image, forKey: k as NSString) }
        return image
    }

    private func key(_ url: URL, _ size: CGSize) -> String { "\(url.path)|\(Int(size.width))x\(Int(size.height))" }
}
