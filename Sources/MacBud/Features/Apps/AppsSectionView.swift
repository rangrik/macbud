import AppKit
import SwiftUI

/// One grid, two labelled groups. Arrow keys walk it: ←/→ inside a row, ↑/↓ a whole row at a time,
/// straight across the group divider.
struct AppsSectionView: View {
    @Bindable var controller: AppsSectionController

    var body: some View {
        let grid = controller.grid
        let query = controller.context.state.query
        if grid.isEmpty {
            if query.isEmpty {
                EmptyState(symbol: "square.grid.2x2", title: controller.index.isScanning ? "Finding your apps…" : "No apps found",
                           detail: "MacBud looks in Applications, System Applications and your home Applications folder.")
            } else {
                EmptyState(symbol: "magnifyingglass", title: "No matches", detail: "Search matches app names.")
            }
        } else {
            AppGridView(grid: grid, query: query, selectedIndex: controller.selectedIndex,
                        onSelect: { controller.selectedIndex = $0 },
                        onActivate: { controller.activate(grid.items[$0]) })
        }
    }
}

struct AppGridView: View {
    let grid: AppGrid
    let query: String
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(zip(grid.groups.indices, offsets)), id: \.0) { position, offset in
                        let group = grid.groups[position]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .kerning(0.6)
                                .padding(.leading, 6)
                            // Explicit rows rather than a lazy grid: the whole section is at most a
                            // couple of dozen tiles, and lazy containers render blank off-screen.
                            ForEach(Array(stride(from: 0, to: group.items.count, by: grid.columns)), id: \.self) { start in
                                let end = min(start + grid.columns, group.items.count)
                                HStack(spacing: 6) {
                                    ForEach(start..<end, id: \.self) { item in
                                        let index = offset + item
                                        AppTile(entry: group.items[item], query: query, isSelected: index == selectedIndex)
                                            .onTapGesture(count: 2) { onActivate(index) }
                                            .onTapGesture { onSelect(index) }
                                            .id(group.items[item].id)
                                    }
                                    // Keep the last row's tiles on their columns instead of stretching them.
                                    ForEach(0..<(grid.columns - (end - start)), id: \.self) { _ in
                                        Color.clear.frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onChange(of: selectedIndex, initial: true) { _, index in
                guard grid.items.indices.contains(index) else { return }
                proxy.scrollTo(grid.items[index].id, anchor: nil)
            }
        }
    }

    /// Where each group starts in the flat selection order.
    private var offsets: [Int] {
        grid.groups.dropLast().reduce(into: [0]) { result, group in result.append(result.last! + group.items.count) }
    }
}

struct AppTile: View {
    let entry: AppEntry
    let query: String
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: AppIconCache.icon(for: entry.url))
                .resizable().interpolation(.high)
                .frame(width: 40, height: 40)
            HighlightedText(text: entry.name, query: query, font: .system(size: 11), color: Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Theme.rowSelection : hovering ? Theme.rowHover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(entry.name)
    }
}

/// App icons at grid size, kept around because `NSWorkspace.icon` re-reads the bundle every call.
enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        if let cached = icons[url.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        icons[url.path] = icon
        return icon
    }
}
