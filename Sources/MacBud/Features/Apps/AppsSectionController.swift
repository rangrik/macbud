import AppKit
import Foundation

/// Apps section: a grid of what is open now, then what you reached for most recently. Typing
/// collapses both groups into one ranked result set, because two groups only mean anything with
/// an empty query. Ordering comes from macOS's own usage record, not from anything we track.
@Observable
final class AppsSectionController {
    let index: AppIndex
    let context: ActionContext
    var selectedIndex = 0

    static let columns = 6
    static let recentLimit = 10
    static let openLimit = 12

    init(index: AppIndex, context: ActionContext) {
        self.index = index
        self.context = context
    }

    var query: String { context.state.query }

    var grid: AppGrid {
        guard query.isEmpty else {
            return AppGrid(groups: [.init(title: "Results", items: searchResults)], columns: Self.columns)
        }
        let open = Array(Self.byLastVisit(index.running).prefix(Self.openLimit))
        let recent = Self.recentApps(index.installed, excluding: Set(open.map(\.bundleID)), limit: Self.recentLimit)
        return AppGrid(groups: [.init(title: "Open now", items: open), .init(title: "Recent", items: recent)],
                       columns: Self.columns)
    }

    /// Window stacking is a decent guess at "last visited", but an app whose windows are all
    /// minimised or parked on another Space falls out of it and lands in launch order instead.
    /// A recorded visit beats the guess wherever we have one.
    nonisolated static func byLastVisit(_ entries: [AppEntry]) -> [AppEntry] {
        entries.enumerated()
            .sorted { left, right in
                switch (left.element.lastUsed, right.element.lastUsed) {
                case let (l?, r?): l == r ? left.offset < right.offset : l > r
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): left.offset < right.offset
                }
            }
            .map(\.element)
    }

    /// Apps you have actually used, most recent first, minus the ones already shown as open.
    nonisolated static func recentApps(_ installed: [AppEntry], excluding excluded: Set<String>, limit: Int) -> [AppEntry] {
        installed
            .filter { !excluded.contains($0.bundleID) && $0.lastUsed != nil }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// A name match decides who is in the list; this decides who is first. Frequency is on a log
    /// scale or Chrome's tens of thousands of launches would bury every other match.
    nonisolated static func rankingBonus(isRunning: Bool, useCount: Int) -> Int {
        let frequency = useCount > 0 ? min(Int(log2(Double(useCount)) * 4), 40) : 0
        return (isRunning ? 60 : 0) + frequency
    }

    private var searchResults: [AppEntry] {
        let running = Dictionary(index.running.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        var pool = index.installed
        for entry in index.running where !pool.contains(where: { $0.bundleID == entry.bundleID }) { pool.append(entry) }
        return SearchMatcher.rank(pool, query: query, text: \.name)
            .map { result -> (entry: AppEntry, score: Int) in
                var entry = result.item
                entry.isRunning = running[entry.bundleID] != nil
                // The running copy carries a freshly read date; the scanned one can be minutes old.
                if let live = running[entry.bundleID]?.lastUsed { entry.lastUsed = live }
                return (entry, result.match.score + Self.rankingBonus(isRunning: entry.isRunning, useCount: entry.useCount))
            }
            .sorted { $0.score > $1.score }
            .prefix(40)
            .map(\.entry)
    }

    var selected: AppEntry? {
        let items = grid.items
        return items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    func didShow() {
        index.refresh()
        // Start on the app you would switch to, not the one you are already in: ⌥⇧A + ↩ jumps back.
        let current = context.frontmost.previousApp?.bundleIdentifier
        selectedIndex = grid.items.firstIndex { $0.bundleID != current } ?? 0
    }

    func queryChanged() { selectedIndex = 0 }

    func handle(_ command: PanelCommand) -> Bool {
        let grid = grid
        switch command {
        case .moveLeft: selectedIndex = grid.index(from: selectedIndex, columns: -1)
        case .moveRight: selectedIndex = grid.index(from: selectedIndex, columns: 1)
        case .moveUp: selectedIndex = grid.index(from: selectedIndex, rows: -1)
        case .moveDown: selectedIndex = grid.index(from: selectedIndex, rows: 1)
        case .pageUp: selectedIndex = grid.index(from: selectedIndex, rows: -2)
        case .pageDown: selectedIndex = grid.index(from: selectedIndex, rows: 2)
        case .moveToStart: selectedIndex = 0
        case .moveToEnd: selectedIndex = max(0, grid.items.count - 1)
        case .primaryAction, .secondaryAction:
            guard let entry = selected else { return true }
            activate(entry)
        default:
            return false
        }
        return true
    }

    /// Focus a running app rather than relaunching it; `openApplication` covers the rest and also
    /// catches the case where the running copy refuses to come forward.
    func activate(_ entry: AppEntry) {
        context.notch.close()
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID).first,
           running.activate(options: [.activateAllWindows]) {
            Log.app.info("apps: focused \(entry.name)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration) { _, error in
            if let error { Log.app.error("apps: could not open \(entry.name): \(error.localizedDescription)") }
        }
    }
}
