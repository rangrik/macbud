import AppKit

/// Apps section: a grid of what is open now, then what you reach for most. Typing collapses both
/// groups into one ranked result set, because two groups only mean anything with an empty query.
@Observable
final class AppsSectionController {
    let index: AppIndex
    let usage: AppUsageStore
    let context: ActionContext
    var selectedIndex = 0

    static let columns = 6
    static let recentLimit = 10
    static let openLimit = 12

    init(index: AppIndex, usage: AppUsageStore, context: ActionContext) {
        self.index = index
        self.usage = usage
        self.context = context
    }

    var query: String { context.state.query }

    var grid: AppGrid {
        guard query.isEmpty else {
            return AppGrid(groups: [.init(title: "Results", items: searchResults)], columns: Self.columns)
        }
        let open = Array(index.running.prefix(Self.openLimit))
        let recent = usage.ranked(index.installed, excluding: Set(open.map(\.bundleID)), limit: Self.recentLimit)
        return AppGrid(groups: [.init(title: "Open now", items: open), .init(title: "Recent", items: recent)],
                       columns: Self.columns)
    }

    /// Name match decides who is in; running and often-used apps decide who is first, so typing
    /// "sl" reaches the Slack you use all day rather than an installer you have never opened.
    private var searchResults: [AppEntry] {
        let runningIDs = Set(index.running.map(\.bundleID))
        var pool = index.installed
        for entry in index.running where !pool.contains(where: { $0.bundleID == entry.bundleID }) { pool.append(entry) }
        let ranked = SearchMatcher.rank(pool, query: query, text: \.name)
        return ranked
            .map { result -> (entry: AppEntry, score: Int) in
                var entry = result.item
                entry.isRunning = runningIDs.contains(entry.bundleID)
                entry.lastUsed = usage.lastUsed(for: entry.bundleID)
                let bonus = (entry.isRunning ? 60 : 0) + min(usage.score(for: entry.bundleID) / 20, 40)
                return (entry, result.match.score + bonus)
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
        // Index 0 is the app you just came from, so start one past it: ⌥⇧A + ↩ jumps back, like ⌘⇥.
        selectedIndex = index.running.count > 1 ? 1 : 0
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
        usage.record(entry.bundleID)
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
