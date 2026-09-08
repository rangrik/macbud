import AppKit
import ScreenCaptureKit

/// Pictures of what is actually on each window. Captured one at a time, for the window you have
/// selected — capturing every visible window on open would burn battery for images you never look at.
@Observable
final class WindowPreviewCache {
    enum Access: Equatable { case unknown, granted, denied }

    private(set) var access: Access = .unknown
    /// Observed, so a capture landing redraws the pane on its own.
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var inflight: Set<String> = []
    @ObservationIgnored private var order: [String] = []

    /// Roughly two screenfuls of previews. Beyond that the oldest go, so a long session does not
    /// hold on to pictures of windows you have stopped looking at.
    private let limit = 24
    /// Captured at twice the pane's width so it stays sharp on a Retina display.
    private let targetWidth = 600

    func image(for entry: WindowEntry) -> NSImage? { images[entry.id] }

    /// Asks once, on the first preview anyone actually wants. Returns false when the answer is no,
    /// which leaves the pane showing the app icon rather than an error.
    @discardableResult
    func ensureAccess() -> Bool {
        if access == .unknown {
            access = CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
        guard access == .denied else { return true }
        // Prompts the first time only; afterwards it just reports the current answer, which is why
        // the pane offers a way into System Settings rather than asking again and again.
        if CGRequestScreenCaptureAccess() { access = .granted }
        return access == .granted
    }

    /// Opens the Screen Recording list, since a second prompt never comes.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func capture(_ entry: WindowEntry) {
        guard images[entry.id] == nil, !failed.contains(entry.id), !inflight.contains(entry.id) else { return }
        guard ensureAccess() else { return }
        inflight.insert(entry.id)
        Task { [weak self] in
            let image = await Self.screenshot(pid: entry.pid, frame: entry.frame, width: self?.targetWidth ?? 600)
            guard let self else { return }
            inflight.remove(entry.id)
            if let image { store(image, for: entry.id) } else { failed.insert(entry.id) }
        }
    }

    /// Window contents move on, so every panel open starts from a clean slate.
    func clear() {
        images.removeAll()
        failed.removeAll()
        order.removeAll()
    }

    private func store(_ image: NSImage, for id: String) {
        if images[id] == nil { order.append(id) }
        images[id] = image
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }

    /// Matches the accessibility window to its ScreenCaptureKit twin by owner and rect — the two
    /// APIs share no identifier, and the on-screen rect is the one thing both agree on.
    private nonisolated static func screenshot(pid: pid_t, frame: CGRect, width: Int) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let candidates = content.windows.filter { $0.owningApplication?.processID == pid }
            guard let window = candidates.first(where: { matches($0.frame, frame) }) ?? candidates.first else { return nil }
            let configuration = SCStreamConfiguration()
            let scale = min(1, Double(width) / max(window.frame.width, 1))
            configuration.width = Int((window.frame.width * scale).rounded())
            configuration.height = Int((window.frame.height * scale).rounded())
            configuration.showsCursor = false
            guard configuration.width > 0, configuration.height > 0 else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            Log.app.debug("window preview failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// A couple of points of slack: the two APIs round window rects differently.
    private nonisolated static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.width - rhs.width) < 3 && abs(lhs.height - rhs.height) < 3
            && abs(lhs.minX - rhs.minX) < 3 && abs(lhs.minY - rhs.minY) < 3
    }
}
