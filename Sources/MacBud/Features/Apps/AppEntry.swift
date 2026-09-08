import Foundation

/// One launchable app. Keyed by bundle id so the running copy and the installed copy are one row.
nonisolated struct AppEntry: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let url: URL
    var isRunning = false
    var lastUsed: Date?

    var id: String { bundleID }
}

/// Two labelled groups drawn as one grid. Selection is a flat index; `rows` is what makes ↑/↓
/// jump a whole row instead of one tile, and what keeps a group from sharing a row with the next.
nonisolated struct AppGrid: Sendable {
    struct Group: Sendable {
        let title: String
        let items: [AppEntry]
    }

    let groups: [Group]
    let columns: Int

    init(groups: [Group], columns: Int) {
        self.groups = groups.filter { !$0.items.isEmpty }
        self.columns = max(1, columns)
    }

    /// Flat display order across every group — the order arrow keys and the selection index use.
    var items: [AppEntry] { groups.flatMap(\.items) }

    var isEmpty: Bool { groups.isEmpty }

    /// Flat indices split into visual rows. Every group starts a fresh row.
    var rows: [[Int]] {
        var result: [[Int]] = []
        var offset = 0
        for group in groups {
            for start in stride(from: 0, to: group.items.count, by: columns) {
                let end = min(start + columns, group.items.count)
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
}
