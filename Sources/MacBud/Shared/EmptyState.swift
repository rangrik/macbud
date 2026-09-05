import AppKit
import SwiftUI

/// Compact empty state for a list column or preview pane.
struct EmptyState: View {
    let symbol: String
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A search result paired with its match, usable in `ForEach`.
nonisolated struct Ranked<T: Identifiable>: Identifiable {
    let item: T
    let match: SearchMatch
    var id: T.ID { item.id }
}

/// Icon and display name for a source application, cached.
enum AppInfo {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func name(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let cached = names[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        names[bundleID] = name
        return name
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        icons[bundleID] = icon
        return icon
    }
}

/// Title text with matched characters highlighted in the accent colour.
struct HighlightedText: View {
    let text: String
    let query: String
    var font: Font = Theme.rowTitle
    var color: Color = Theme.textPrimary

    var body: some View {
        let ranges = query.isEmpty ? [] : (SearchMatcher.match(query: query, in: text)?.ranges ?? [])
        Text(AttributedString.highlighting(text, ranges: ranges) { container in
            container.foregroundColor = Theme.accent
            container.font = font.weight(.semibold)
        })
        .font(font)
        .foregroundStyle(color)
    }
}
