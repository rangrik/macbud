import AppKit
import SwiftUI

/// The shelf: the clock and logo, the six newest items as cards, and a line of hints.
struct ShelfView: View {
    let coordinator: PanelCoordinator

    var body: some View {
        let shelf = coordinator.shelf
        let cards = shelf.recents
        VStack(spacing: 0) {
            // Clicking the notch on a hover-opened shelf is asking for the keyboard, as clicking the closed tab is.
            NotchBand(coordinator: coordinator)
                .contentShape(Rectangle())
                .onTapGesture { coordinator.notch.focusShelf() }
            if cards.isEmpty {
                Text("Nothing yet. Copy something, take a screenshot or dictate.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 93)
            } else {
                CardRow(cards: cards, selectedID: shelf.selected?.id, cardWidth: 92, spacing: 8,
                        coordinator: coordinator, selectsOnHover: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            ShelfHints(coordinator: coordinator)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
    }
}

/// The clock and logo where the closed notch shows them, so opening does not move them.
struct NotchBand: View {
    let coordinator: PanelCoordinator

    var body: some View {
        let state = coordinator.state
        NotchTabContent(state: state, isOpen: true, notchWidth: state.geometry.notchRect.width,
                        wing: state.metrics.tabExtension, height: state.geometry.notchRect.height)
            .frame(maxWidth: .infinity)
            .frame(height: state.geometry.notchRect.height)
            .overlay(alignment: .trailing) {
                if coordinator.settings.isEnabled(.keepAwake) { KeepAliveSwitch(coordinator: coordinator).padding(.trailing, 18) }
            }
    }
}

/// "←→ pick · ↩ copy · ⌘↩ paste to Slack · ↓ Search everything · ⎋"
struct ShelfHints: View {
    let coordinator: PanelCoordinator

    var body: some View {
        let uses = coordinator.useHints(for: coordinator.shelf.selected)
        HStack(spacing: 5) {
            hint("←→", "pick")
            ForEach(uses) { hint($0.keys, $0.label) }
            Button { coordinator.expand() } label: { Text("↓ Search everything") }
                .buttonStyle(ChipButtonStyle(height: 18, fontSize: 10.5))
            Text("·  ⎋")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(keys).foregroundStyle(Theme.textSecondary)
            Text(label.prefix(1).lowercased() + label.dropFirst())
            Text("·")
        }
        .lineLimit(1)
    }
}

/// A row of cards. A click uses the card; on the shelf the ring also follows the pointer.
struct CardRow: View {
    let cards: [ShelfItem]
    let selectedID: String?
    let cardWidth: CGFloat
    let spacing: CGFloat
    let coordinator: PanelCoordinator
    var selectsOnHover = false

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(cards) { item in
                ShelfCard(item: item, isSelected: item.id == selectedID, width: cardWidth, clipboard: coordinator.clipboardStore)
                    .onTapGesture { coordinator.shelf.use(item) }
                    .onHover { inside in if inside, selectsOnHover { coordinator.shelf.selectedID = item.id } }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ShelfCard: View {
    let item: ShelfItem
    let isSelected: Bool
    let width: CGFloat
    let clipboard: ClipboardStore
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    KindBadge(item: item, size: 16)
                    if item.kind == .dictation { WaveBars(count: 16, height: 12) }
                }
                .frame(height: 16)
                CardBody(item: item, clipboard: clipboard)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(7)
            .frame(width: width, height: 76, alignment: .topLeading)
            .background(shape.fill(.white.opacity(isSelected ? 0.13 : hovering ? 0.1 : 0.07)))
            .overlay(shape.strokeBorder(.white.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5))
            HStack(spacing: 0) {
                Text(item.source).foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                if item.kind != .app { Text(" · \(item.date.shortAge)").layoutPriority(1) }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(isSelected ? Theme.textSecondary : Theme.textTertiary)
            .lineLimit(1)
            .padding(.leading, 2)
            .frame(width: width, alignment: .leading)
        }
        .opacity(isSelected ? 1 : 0.85)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind.rawValue): \(item.title), \(item.source)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A two-line excerpt, a link's host, or a picture cropped to fit.
private struct CardBody: View {
    let item: ShelfItem
    let clipboard: ClipboardStore

    var body: some View {
        switch item {
        case .clip(let clip):
            switch clip.kind {
            case .text: Excerpt(text: clip.text ?? "")
            case .link: LinkExcerpt(text: clip.text ?? "")
            case .image: CardPicture(load: { await DiskImageLoader.shared.load($0, maxPixelSize: 240) }, url: clipboard.previewURL(for: clip))
            case .file:
                HStack(alignment: .top, spacing: 5) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: clip.filePaths.first ?? "/")).resizable().frame(width: 16, height: 16)
                    Text(clip.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }
            }
        case .media(let media): CardPicture(load: { await MediaThumbnail.load($0) }, url: media.url)
        case .dictation(let dictation): Excerpt(text: dictation.text)
        case .snippet(let snippet): Excerpt(text: snippet.content)
        case .app(let entry): Text(entry.displayName).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
        }
    }
}

private struct Excerpt: View {
    let text: String

    var body: some View {
        let head = String(text.prefix(240))
        if ClipboardPreview.looksLikeCode(head) {
            Text(head.split(whereSeparator: \.isNewline).prefix(2).joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
        } else {
            Text(head.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
        }
    }
}

private struct LinkExcerpt: View {
    let text: String

    var body: some View {
        let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        let tail = url.map { $0.pathComponents.filter { $0 != "/" }.suffix(2).joined(separator: "/") } ?? ""
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 9, weight: .semibold))
                Text(url?.host() ?? text).lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.85))
            if !tail.isEmpty {
                Text("…/\(tail)").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
    }
}

/// Fills the card and crops, so every picture card has the same shape.
private struct CardPicture: View {
    let load: (URL) async -> NSImage?
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Color.white.opacity(0.05)
            .overlay {
                if let image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .task(id: url) {
                guard let url else { image = nil; return }
                image = await load(url)
            }
    }
}

enum MediaThumbnail {
    /// The small size, shared with the preview so it can show the card's picture while the large one loads.
    static let pixels = CGSize(width: 300, height: 190)

    static func load(_ url: URL) async -> NSImage? {
        if let hit = ThumbnailCache.shared.cached(url, size: pixels) { return hit }
        return await ThumbnailCache.shared.thumbnail(for: url, size: pixels)
    }
}

/// The feature's colour with a glyph for the kind, so a link and an image from the clipboard read as related.
struct KindBadge: View {
    let item: ShelfItem
    var size: CGFloat = 16

    var body: some View {
        let (art, symbol): (FeatureArt, String) = switch item {
        case .clip where item.kind == .dictation: (.dictation, "waveform")
        case .clip(let clip):
            switch clip.kind {
            case .text: (.clipboard, ClipboardPreview.looksLikeCode(String((clip.text ?? "").prefix(240)))
                         ? "chevron.left.forwardslash.chevron.right" : "text.alignleft")
            case .link: (.clipboard, "link")
            case .image: (.clipboard, "photo")
            case .file: (.clipboard, "doc")
            }
        case .media(let media): (.screenshots, media.kind == .video ? "video.fill" : "photo.fill")
        case .dictation: (.dictation, "waveform")
        case .snippet: (.snippets, "text.quote")
        case .app: (.apps, FeatureArt.apps.symbol)
        }
        if case .app(let entry) = item {
            // The icon says which app; the corner badge says it is one to switch to.
            Image(nsImage: AppIconCache.icon(for: entry.url)).resizable().interpolation(.high).frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) { FeatureBadge(kind: art, size: size * 0.5, symbol: symbol).offset(x: 2, y: 2) }
        } else {
            FeatureBadge(kind: art, size: size, symbol: symbol)
        }
    }
}

/// Decorative bars in the dictation colour. Fixed heights, so a card looks the same every time.
struct WaveBars: View {
    var count = 16
    var height: CGFloat = 12
    var barWidth: CGFloat = 2

    var body: some View {
        HStack(spacing: barWidth * 0.75) {
            ForEach(0..<count, id: \.self) { i in
                let level = 0.25 + 0.75 * abs(sin(Double(i) * 1.7) * cos(Double(i) * 0.45))
                Capsule().fill(Color(red: 0.76, green: 0.61, blue: 1)).frame(width: barWidth, height: height * level)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The capsule of the chip row and of the shelf's Search everything.
struct ChipButtonStyle: ButtonStyle {
    var isSelected = false
    var height: CGFloat = 22
    var fontSize: CGFloat = 11
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(isSelected || hovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, height / 2 - 1)
            .frame(height: height)
            .background(.white.opacity(isSelected ? 0.16 : hovering || configuration.isPressed ? 0.1 : 0.06), in: Capsule())
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

struct ChipRow: View {
    let coordinator: PanelCoordinator

    var body: some View {
        HStack(spacing: 6) {
            ForEach(coordinator.settings.visibleChips) { chip in
                Button(chip.title) { coordinator.select(chip) }
                    .buttonStyle(ChipButtonStyle(isSelected: chip == coordinator.state.chip))
                    .help(coordinator.chipShortcut(chip).map { "\(chip.title) (\($0))" } ?? chip.title)
                    .accessibilityAddTraits(chip == coordinator.state.chip ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
    }
}

/// Recent cards over the Earlier list, with the selection previewed on the right.
struct ItemsBody: View {
    let coordinator: PanelCoordinator

    var body: some View {
        let shelf = coordinator.shelf
        let state = coordinator.state
        let (cards, rows) = shelf.layout
        let selected = shelf.selected
        let editing = coordinator.snippets.isEditing
        if cards.isEmpty, rows.isEmpty, !editing {
            empty
        } else {
            VStack(spacing: 0) {
                if !cards.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        label("Recent")
                        CardRow(cards: cards, selectedID: selected?.id, cardWidth: 112, spacing: 10, coordinator: coordinator)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 9)
                    .frame(height: 128, alignment: .top)
                    Rectangle().fill(Theme.separator).frame(height: 1)
                }
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        label(state.query.isEmpty ? "Earlier" : "Results")
                            .padding(.leading, 18)
                            .padding(.top, 9)
                        ResultsList(items: rows, selectedIndex: rows.firstIndex { $0.id == selected?.id } ?? -1,
                                    onSelect: { shelf.selectedID = rows[$0].id },
                                    onActivate: { shelf.use(rows[$0]) }) { item, _ in
                            ItemRow(item: item, query: state.query)
                        }
                    }
                    .frame(width: 300)
                    .disabled(editing)
                    .opacity(editing ? 0.45 : 1)
                    Rectangle().fill(Theme.separator).frame(width: 1)
                    ItemPreview(item: selected, coordinator: coordinator)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
    }

    @ViewBuilder private var empty: some View {
        let settings = coordinator.settings
        if !coordinator.state.query.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches", detail: "Try fewer words, or another filter with ⇥.")
        } else {
            switch coordinator.state.chip {
            case .snippets:
                EmptyState(symbol: "text.badge.plus", title: "No snippets yet", detail: "Press ⌘N to create one, or ⌘S on a text item.")
            case .screenshots:
                EmptyState(symbol: "photo.on.rectangle.angled", title: "No screenshots found",
                           detail: "Watching \(settings.screenshotFolderURLs.map(\.lastPathComponent).joined(separator: ", ")). Add folders in Settings (⌘,).")
            case .dictations:
                EmptyState(symbol: "waveform", title: "No dictations yet", detail: "Completed dictations appear here.")
            default:
                EmptyState(symbol: "doc.on.clipboard", title: "Nothing here yet",
                           detail: settings.clipboardPaused ? "Capturing is paused. Resume it in Settings (⌘,)." : "Copy anything and it shows up here.")
            }
        }
    }
}

struct ItemRow: View {
    let item: ShelfItem
    let query: String

    var body: some View {
        HStack(spacing: 10) {
            KindBadge(item: item, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                HighlightedText(text: item.title, query: query)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.kind == .app ? item.source : "\(item.source) · \(item.date.relativeDescription)")
                    .font(Theme.rowSubtitle)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(Theme.accent)
            }
        }
    }
}

/// The selected item in full, or the snippet editor while one is open.
struct ItemPreview: View {
    let item: ShelfItem?
    let coordinator: PanelCoordinator

    var body: some View {
        if coordinator.snippets.isEditing {
            SnippetEditor(draft: coordinator.snippets.draft, controller: coordinator.snippets)
        } else {
            switch item {
            case .clip(let clip): ClipboardPreview(item: clip, store: coordinator.clipboardStore)
            case .media(let media): MediaPreview(item: media)
            case .dictation(let dictation): DictationPreview(item: dictation)
            case .snippet(let snippet): SnippetPreview(snippet: snippet, controller: coordinator.snippets)
            case .app(let entry): WindowPreviewPane(entry: entry, controller: coordinator.apps, previews: coordinator.windowPreviews)
            case nil: EmptyState(symbol: "arrow.up.and.down", title: "Select an item", detail: "Use ↑ ↓ to browse.")
            }
        }
    }
}

extension ShelfItem {
    /// Where the item came from, for captions.
    var source: String {
        switch self {
        case .clip(let clip): AppInfo.name(for: clip.sourceBundleID) ?? "Clipboard"
        case .media(let media): media.folderName
        case .dictation: "Dictation"
        case .snippet: "Snippet"
        case .app(let entry): entry.windowID != nil ? entry.name : entry.isRunning ? "Open" : "Not open"
        }
    }
}
