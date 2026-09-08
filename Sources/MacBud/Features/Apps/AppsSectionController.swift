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
    /// Read once when the panel opens; enumerating every app's windows is too slow to redo per
    /// keystroke. Keyed so a tile can name its window without carrying the accessibility handle.
    private(set) var windows: [WindowEntry] = []
    private var windowsByID: [String: WindowEntry] = [:]

    /// Recent narrows to four while the preview pane is up, and matches All at six when it is not.
    static let previewColumns = 4
    static let columns = 6
    static let recentLimit = 10
    static let openLimit = 12

    let previews: WindowPreviewCache

    init(index: AppIndex, context: ActionContext, previews: WindowPreviewCache) {
        self.index = index
        self.context = context
        self.previews = previews
    }

    var query: String { context.state.query }

    var grid: AppGrid { grid(showingPreview: showsPreview) }

    /// The pane is up whenever the selection is in Recent, so Recent has to be laid out narrower —
    /// which is itself decided by where the selection is. Resolved by laying the grid out at the
    /// full width first and asking that copy which group the selection landed in.
    var showsPreview: Bool {
        guard query.isEmpty else { return false }
        return grid(showingPreview: false).groupIndex(of: selectedIndex) == 0
    }

    private func grid(showingPreview: Bool) -> AppGrid {
        guard query.isEmpty else {
            return AppGrid(groups: [.init(title: "Results", items: searchResults, columns: Self.columns)])
        }
        let open = Array(openWindows.prefix(Self.openLimit))
        let recent = Self.recentApps(index.installed, excluding: Set(open.map(\.bundleID)), limit: Self.recentLimit)
        return AppGrid(groups: [
            .init(title: "Recent", items: open, columns: showingPreview ? Self.previewColumns : Self.columns),
            .init(title: "All", items: recent, columns: Self.columns),
        ])
    }

    /// The window the preview pane is showing, if the selection is one.
    var selectedWindow: WindowEntry? {
        selected?.windowID.flatMap { windowsByID[$0] }
    }

    /// The line under the preview: which app, and which of its windows this is. Never repeats the
    /// title above it — a single-window app already says its name there.
    var previewSubtitle: String {
        guard let entry = selected else { return "" }
        guard let window = selectedWindow else { return entry.isRunning ? "Open" : "Not open · Return launches it" }
        let siblings = windows.filter { $0.bundleID == window.bundleID }
        guard siblings.count > 1, let position = siblings.firstIndex(of: window) else {
            return entry.displayName == entry.name ? "Open" : entry.name
        }
        return "\(entry.name) · window \(position + 1) of \(siblings.count)"
    }

    /// One tile per open window, so two Chrome windows are two things you can land on. Apps come in
    /// the order you last visited them, each app's windows in its own front-to-back order.
    var openWindows: [AppEntry] {
        Self.expand(Self.byLastVisit(index.running), windows: windows)
    }

    /// An app that exposes no windows still gets its single app tile — Chromium apps hide their
    /// window list, and vanishing from the switcher would be far worse than showing one entry.
    static func expand(_ running: [AppEntry], windows: [WindowEntry]) -> [AppEntry] {
        let byApp = Dictionary(grouping: windows, by: \.bundleID)
        return running.flatMap { app -> [AppEntry] in
            guard let open = byApp[app.bundleID], !open.isEmpty else { return [app] }
            return open.map { window in
                var entry = app
                entry.windowID = window.id
                // Only name the window when there is a choice to make between windows.
                entry.label = open.count > 1 ? window.shortTitle : nil
                return entry
            }
        }
    }

    /// Window stacking is a decent guess at "last visited", but an app whose windows are all
    /// minimised or parked on another Space falls out of it and lands in launch order instead.
    /// A recorded visit beats the guess wherever we have one.
    static func byLastVisit(_ entries: [AppEntry]) -> [AppEntry] {
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

    /// Apps you have actually used, most recent first, minus the ones already shown in the top group.
    static func recentApps(_ installed: [AppEntry], excluding excluded: Set<String>, limit: Int) -> [AppEntry] {
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

    /// Open windows first-class in search too, so typing "chrome" offers both Chrome windows and
    /// typing part of a window title goes straight to that window.
    private var searchResults: [AppEntry] {
        let open = openWindows
        let openApps = Set(open.map(\.bundleID))
        let pool = open + index.installed.filter { !openApps.contains($0.bundleID) }
        return SearchMatcher.rank(pool, query: query, text: \.searchText)
            .map { result -> (entry: AppEntry, score: Int) in
                var entry = result.item
                entry.isRunning = openApps.contains(entry.bundleID)
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
        windows = WindowIndex.windows()
        previews.clear()
        windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

    /// Jump to the exact window when the tile is one, otherwise focus a running app rather than
    /// relaunching it; `openApplication` covers the rest and also catches the case where the
    /// running copy refuses to come forward.
    func activate(_ entry: AppEntry) {
        // Switch first, close second. Closing the panel hands focus back to whatever app you came
        // from, and that lands after our activation if we close first — leaving the right window
        // raised inside an app that never came forward.
        defer { context.notch.close() }
        if let window = entry.windowID.flatMap({ windowsByID[$0] }), WindowIndex.raise(window) {
            Log.app.info("apps: raised \(window.appName) · \(window.displayTitle)")
            return
        }
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
