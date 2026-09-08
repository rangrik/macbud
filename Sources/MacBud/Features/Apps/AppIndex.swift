import AppKit
import CoreServices

/// Every app you could launch, plus who is running right now and in what order you last used them.
/// The installed scan is slow and rare; the running list is cheap and re-read every time the notch opens.
@Observable
final class AppIndex {
    private(set) var installed: [AppEntry] = []
    private(set) var running: [AppEntry] = []
    private(set) var isScanning = false
    @ObservationIgnored private var scannedAt: Date?

    nonisolated static let searchRoots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]

    /// CoreServices is hundreds of agents nobody switches to — Notification Center, UnmountAssistant,
    /// WindowManager. Finder is the one thing in there you actually want, so name it and skip the rest.
    nonisolated static let extraApps = ["/System/Library/CoreServices/Finder.app"]

    /// Re-scans installed apps at most once every few minutes; the running list is always fresh.
    func refresh(force: Bool = false) {
        refreshRunning()
        let stale = scannedAt.map { Date.now.timeIntervalSince($0) > 300 } ?? true
        guard force || stale, !isScanning else { return }
        isScanning = true
        Task {
            let found = await Self.scanInstalled()
            installed = found
            scannedAt = .now
            isScanning = false
            Log.app.info("app index: \(found.count) installed apps")
        }
    }

    /// Usage is re-read here rather than reused from the installed scan: that scan is minutes old,
    /// and "which app was I just in" has to be right to the second.
    func refreshRunning() {
        running = Self.runningInFrontToBackOrder().compactMap { app in
            guard let bundleID = app.bundleIdentifier, let url = app.bundleURL else { return nil }
            let usage = Self.usage(for: url)
            return AppEntry(bundleID: bundleID, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                            url: url, isRunning: true, lastUsed: usage.lastUsed, useCount: usage.useCount)
        }
    }

    /// Front-to-back window order is a true most-recently-used ordering. `runningApplications` is
    /// launch order, which puts whatever you opened first at the top — the opposite of useful.
    /// Window owner pids stay readable without Screen Recording; only window titles are withheld.
    static func runningInFrontToBackOrder() -> [NSRunningApplication] {
        let regular = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        let byPID = Dictionary(regular.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var ordered: [NSRunningApplication] = []
        var seen: Set<pid_t> = []
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = byPID[pid], seen.insert(pid).inserted else { continue }
            ordered.append(app)
        }
        ordered.append(contentsOf: regular.filter { !seen.contains($0.processIdentifier) })
        return ordered
    }

    private nonisolated static func scanInstalled() async -> [AppEntry] {
        await Task.detached(priority: .utility) {
            var byBundleID: [String: AppEntry] = [:]
            let roots = searchRoots.flatMap { bundles(under: URL(fileURLWithPath: $0, isDirectory: true)) }
            for url in roots + extraApps.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
                guard let entry = entry(for: url), byBundleID[entry.bundleID] == nil else { continue }
                byBundleID[entry.bundleID] = entry
            }
            return byBundleID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }

    /// Walks a few levels down so vendor folders like /Applications/Utilities are covered, but never
    /// descends into a bundle — an .app is a directory full of thousands of files we do not want.
    private nonisolated static func bundles(under root: URL, depth: Int = 3) -> [URL] {
        guard depth > 0, let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for url in contents {
            if url.pathExtension == "app" {
                found.append(url)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                found.append(contentsOf: bundles(under: url, depth: depth - 1))
            }
        }
        return found
    }

    private nonisolated static func entry(for url: URL) -> AppEntry? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return nil }
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
        // True daemons have no UI at all. Menu-bar agents (LSUIElement) stay — you still want to
        // start Rectangle or Bartender from here, even though they never take the foreground.
        if flag(info["LSBackgroundOnly"]) { return nil }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let usage = usage(for: url)
        return AppEntry(bundleID: bundleID, name: name, url: url, lastUsed: usage.lastUsed, useCount: usage.useCount)
    }

    /// When you last used an app and how often, straight from LaunchServices via Spotlight. It has
    /// been recording this since long before MacBud existed and it updates on every app switch, not
    /// just on launch — so it is both more complete and more accurate than anything we could watch
    /// ourselves. Nil date when Spotlight indexing is off, or for an app never opened.
    /// `kMDItemUseCount` has no bridged Swift constant, hence the string key.
    nonisolated static func usage(for url: URL) -> (lastUsed: Date?, useCount: Int) {
        guard let item = MDItemCreate(nil, url.path as CFString) else { return (nil, 0) }
        return (MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date,
                (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue ?? 0)
    }

    /// Info.plist booleans are written as both `<true/>` and the string "1".
    private nonisolated static func flag(_ value: Any?) -> Bool {
        (value as? Bool) ?? ((value as? String).map { $0 == "1" || $0.lowercased() == "true" } ?? false)
    }
}
