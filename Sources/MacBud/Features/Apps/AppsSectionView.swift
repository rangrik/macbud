import AppKit
import SwiftUI

/// Recent is a band: window tiles on the left, a preview of the selected window on the right.
/// All runs the full width beneath it, because nothing down there has a window to show.
struct AppsSectionView: View {
    @Bindable var controller: AppsSectionController
    let previews: WindowPreviewCache

    static let bandHeight: CGFloat = 232
    static let previewWidth: CGFloat = 298

    var body: some View {
        let grid = controller.grid
        let query = controller.context.state.query
        if grid.isEmpty {
            if query.isEmpty {
                EmptyState(symbol: "square.grid.2x2", title: controller.index.isScanning ? "Finding your apps…" : "No apps found",
                           detail: "MacBud looks in Applications, System Applications and your home Applications folder.")
            } else {
                EmptyState(symbol: "magnifyingglass", title: "No matches", detail: "Search matches app names and window titles.")
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(zip(grid.groups.indices, grid.offsets)), id: \.0) { position, offset in
                    let group = grid.groups[position]
                    let showsPreview = position == 0 && controller.showsPreview
                    HStack(spacing: 0) {
                        AppGroupView(group: group, offset: offset, query: query,
                                     selectedIndex: controller.selectedIndex,
                                     onSelect: { controller.selectedIndex = $0 },
                                     onActivate: { controller.activate(grid.items[$0]) })
                        if showsPreview {
                            Rectangle().fill(Theme.separator).frame(width: 1)
                            WindowPreviewPane(controller: controller, previews: previews)
                                .frame(width: Self.previewWidth)
                        }
                    }
                    .frame(height: showsPreview ? Self.bandHeight : nil, alignment: .top)
                    if position == 0, grid.groups.count > 1 {
                        Rectangle().fill(Theme.separator).frame(height: 1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct AppGroupView: View {
    let group: AppGrid.Group
    let offset: Int
    let query: String
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .kerning(0.6)
                        .padding(.leading, 6)
                    // Explicit rows rather than a lazy grid: the section is a couple of dozen tiles
                    // at most, and lazy containers render blank off-screen.
                    ForEach(Array(stride(from: 0, to: group.items.count, by: group.columns)), id: \.self) { start in
                        let end = min(start + group.columns, group.items.count)
                        HStack(spacing: 6) {
                            ForEach(start..<end, id: \.self) { item in
                                let index = offset + item
                                AppTile(entry: group.items[item], query: query, isSelected: index == selectedIndex)
                                    .onTapGesture(count: 2) { onActivate(index) }
                                    .onTapGesture { onSelect(index) }
                                    .id(group.items[item].id)
                            }
                            // Keep the last row's tiles on their columns instead of stretching them.
                            ForEach(0..<(group.columns - (end - start)), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onChange(of: selectedIndex, initial: true) { _, index in
                let item = index - offset
                guard group.items.indices.contains(item) else { return }
                proxy.scrollTo(group.items[item].id, anchor: nil)
            }
        }
    }
}

/// What is on the window you have selected. Falls back to the app's icon when the picture is not
/// there yet, was refused, or the window lives on another Space where nothing can photograph it.
struct WindowPreviewPane: View {
    let controller: AppsSectionController
    let previews: WindowPreviewCache

    var body: some View {
        let entry = controller.selected
        let window = controller.selectedWindow
        let image = window.flatMap { previews.image(for: $0) }
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill)
                if let image {
                    Image(nsImage: image)
                        .resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let entry {
                    VStack(spacing: 7) {
                        Image(nsImage: AppIconCache.icon(for: entry.url))
                            .resizable().interpolation(.high)
                            .frame(width: 44, height: 44)
                        if previews.access == .denied {
                            Button { WindowPreviewCache.openSystemSettings() } label: {
                                VStack(spacing: 3) {
                                    Text("Turn on Screen Recording for window previews")
                                    Text("Open Settings").foregroundStyle(Theme.accent)
                                }
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let entry {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(controller.previewSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .task(id: window?.id) {
            guard let window else { return }
            previews.capture(window)
        }
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
                .frame(width: 36, height: 36)
            HighlightedText(text: entry.displayName, query: query, font: .system(size: 11), color: Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .frame(height: 28, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Theme.rowSelection : hovering ? Theme.rowHover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(entry.label.map { "\(entry.name) — \($0)" } ?? entry.name)
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
