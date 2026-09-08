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
            let image = await Self.screenshot(pid: entry.pid, title: entry.title,
                                              frame: entry.frame, width: self?.targetWidth ?? 600)
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

    /// Why a given window did or did not get a picture. Written out plainly because the failure
    /// modes — no shareable window, no rect match, capture refused — look identical from the pane.
    static func diagnose(_ entries: [WindowEntry]) async -> [[String: Any]] {
        var report: [[String: Any]] = []
        let windows: [SCWindow]
        do {
            // onScreenWindowsOnly: false so off-Space windows are in the list at all — whether they
            // can then be captured is exactly what this is measuring.
            windows = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false).windows
        } catch {
            return [["error": error.localizedDescription]]
        }
        for entry in entries {
            let mine = windows.filter {
                $0.owningApplication?.processID == entry.pid && $0.frame.width > 100 && $0.frame.height > 60
            }
            let matched = bestMatch(pid: entry.pid, title: entry.title, frame: entry.frame, in: windows)
            var row: [String: Any] = [
                "app": entry.appName,
                "title": entry.shortTitle,
                "axFrame": "\(Int(entry.frame.minX)),\(Int(entry.frame.minY)) \(Int(entry.frame.width))x\(Int(entry.frame.height))",
                "scWindowsForPid": mine.count,
                "scFrames": mine.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" },
                "rectMatched": matched != nil,
                "titles": mine.map { $0.title ?? "-" },
                "onScreen": mine.map(\.isOnScreen),
            ]
            let target = matched ?? mine.first
            if let target {
                do {
                    let configuration = SCStreamConfiguration()
                    configuration.width = max(1, Int(target.frame.width / 4))
                    configuration.height = max(1, Int(target.frame.height / 4))
                    _ = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
                    row["capture"] = "ok"
                } catch {
                    row["capture"] = error.localizedDescription
                }
            } else {
                row["capture"] = "no shareable window for this pid"
            }
            report.append(row)
        }
        return report
    }

    /// Off-screen windows are included on purpose: a window parked on another Space still captures
    /// fine, and excluding them was the reason most apps showed no preview at all.
    private nonisolated static func screenshot(pid: pid_t, title: String, frame: CGRect, width: Int) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let window = bestMatch(pid: pid, title: title, frame: frame, in: content.windows) else { return nil }
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

    /// Finds a window's ScreenCaptureKit twin. The two APIs share no identifier, and matching on
    /// position alone breaks across Spaces: accessibility gives a window's place within its own
    /// Space while the window server lays Spaces out side by side, so one window reads x=0 here and
    /// x=4235 there. Title survives that, size backs it up, and x only breaks ties — which is
    /// exactly what is needed for two same-titled windows sitting on one Space.
    nonisolated static func bestMatch(pid: pid_t, title: String, frame: CGRect, in windows: [SCWindow]) -> SCWindow? {
        // Chromium apps expose a crowd of tiny untitled helper windows alongside the real one.
        let candidates = windows.filter {
            $0.owningApplication?.processID == pid && $0.frame.width > 100 && $0.frame.height > 60
        }
        guard candidates.count > 1 else { return candidates.first }
        return candidates.min { left, right in
            let leftScore = score(left, title: title, frame: frame)
            let rightScore = score(right, title: title, frame: frame)
            if leftScore != rightScore { return leftScore > rightScore }
            return abs(left.frame.minX - frame.minX) < abs(right.frame.minX - frame.minX)
        }
    }

    private nonisolated static func score(_ window: SCWindow, title: String, frame: CGRect) -> Int {
        var total = 0
        if !title.isEmpty, window.title == title { total += 4 }
        if abs(window.frame.width - frame.width) < 3, abs(window.frame.height - frame.height) < 3 { total += 2 }
        if abs(window.frame.minY - frame.minY) < 3 { total += 1 }
        return total
    }

}
