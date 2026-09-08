import Foundation

/// One thing you can land on: an app to launch, or a specific open window to jump to. Keyed by
/// bundle id for apps so the running copy and the installed copy are one tile. Deliberately plain
/// data — the accessibility handle a window needs stays with the controller that raises it.
nonisolated struct AppEntry: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let url: URL
    var isRunning = false
    /// When you last used the app and how many times, as macOS itself records it.
    var lastUsed: Date?
    var useCount = 0
    /// Set when this tile is one window rather than the whole app.
    var windowID: String?
    /// Shown instead of the app name — the window title, but only when its app has more than one
    /// window open, so a single-window app reads exactly as it did before windows appeared here.
    var label: String?

    var id: String { windowID ?? bundleID }
    var displayName: String { label ?? name }
    /// Both the app name and the window title match, so "chrome" and "inbox" each find the window.
    var searchText: String { label.map { "\(name) \($0)" } ?? name }

    static func == (lhs: AppEntry, rhs: AppEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Two labelled groups drawn as one grid. Selection is a flat index; `rows` is what makes ↑/↓
/// jump a whole row instead of one tile, and what keeps a group from sharing a row with the next.
nonisolated struct AppGrid: Sendable {
    struct Group: Sendable {
        let title: String
        let items: [AppEntry]
        /// Recent narrows to make room for the preview pane; All always has the full width.
        let columns: Int
    }

    let groups: [Group]

    init(groups: [Group]) {
        self.groups = groups.filter { !$0.items.isEmpty }.map {
            Group(title: $0.title, items: $0.items, columns: max(1, $0.columns))
        }
    }

    /// Flat display order across every group — the order arrow keys and the selection index use.
    var items: [AppEntry] { groups.flatMap(\.items) }

    var isEmpty: Bool { groups.isEmpty }

    /// Flat indices split into visual rows. Every group starts a fresh row.
    var rows: [[Int]] {
        var result: [[Int]] = []
        var offset = 0
        for group in groups {
            for start in stride(from: 0, to: group.items.count, by: group.columns) {
                let end = min(start + group.columns, group.items.count)
                result.append(Array((offset + start)..<(offset + end)))
            }
            offset += group.items.count
        }
        return result
    }

    func position(of index: Int) -> (row: Int, column: Int)? {
        for (row, indices) in rows.enumerated() {
            if let column = indices.firstIndex(of: index) { return (row, column) }
        }
        return nil
    }

    /// Arrow-key movement. Horizontal walks the flat order so it crosses group edges; vertical
    /// keeps the column and clamps to however wide the target row actually is.
    func index(from index: Int, rows dRow: Int = 0, columns dColumn: Int = 0) -> Int {
        let count = items.count
        guard count > 0 else { return 0 }
        let current = min(max(index, 0), count - 1)
        if dColumn != 0 { return min(max(current + dColumn, 0), count - 1) }
        guard dRow != 0, let position = position(of: current) else { return current }
        let all = rows
        let target = position.row + dRow
        guard all.indices.contains(target) else { return current }
        let row = all[target]
        return row[min(position.column, row.count - 1)]
    }

    func firstIndex(of entry: AppEntry) -> Int? { items.firstIndex(where: { $0.id == entry.id }) }

    /// Which group a flat selection index sits in, or nil when the grid is empty.
    func groupIndex(of index: Int) -> Int? {
        var offset = 0
        for (position, group) in groups.enumerated() {
            if index < offset + group.items.count { return position }
            offset += group.items.count
        }
        return nil
    }

    /// Flat index where each group starts.
    var offsets: [Int] {
        groups.dropLast().reduce(into: [0]) { result, group in result.append(result.last! + group.items.count) }
    }
}
