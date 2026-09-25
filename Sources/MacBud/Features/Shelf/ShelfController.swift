import AppKit

/// What the shelf and the island's list show, which item is selected, and what keys do to it.
@Observable
final class ShelfController {
    let state: NotchState
    let settings: AppSettings
    let clipboard: ClipboardSectionController
    let screenshots: ScreenshotsSectionController
    let dictations: DictationHistorySectionController
    let snippets: SnippetsSectionController
    let apps: AppsSectionController
    /// The app or window a prediction put first on the shelf, until the next open.
    var suggested: AppEntry?
    /// By item id, so a list that changes underneath keeps the selection.
    var selectedID: String?
    @ObservationIgnored private var merged: (key: Inputs, items: [ShelfItem])?
    @ObservationIgnored private var laidOut: (key: LayoutKey, cards: [ShelfItem], rows: [ShelfItem])?

    init(state: NotchState, settings: AppSettings, clipboard: ClipboardSectionController, screenshots: ScreenshotsSectionController,
         dictations: DictationHistorySectionController, snippets: SnippetsSectionController, apps: AppsSectionController) {
        self.state = state
        self.settings = settings
        self.clipboard = clipboard
        self.screenshots = screenshots
        self.dictations = dictations
        self.snippets = snippets
        self.apps = apps
    }

    // MARK: What is shown

    /// Arrays compare by storage first, so an unchanged store costs nothing to check.
    private struct Inputs: Equatable {
        var clips: [ClipboardItem], media: [MediaItem], dictations: [DictationHistoryItem], snippets: [Snippet], kinds: [IntentKind]
    }

    private struct LayoutKey: Equatable {
        var items: [ShelfItem], apps: [AppEntry], lead: AppEntry?, chip: Chip, query: String
    }

    /// Every visible item, newest first. Rebuilt only when a store or a feature toggle changes.
    var items: [ShelfItem] {
        let inputs = Inputs(clips: clipboard.store.items, media: screenshots.library.items, dictations: dictations.store.items,
                            snippets: snippets.store.snippets, kinds: settings.visibleKinds)
        if let merged, merged.key == inputs { return merged.items }
        let items = Shelf.merge(clips: inputs.clips, media: inputs.media, dictations: inputs.dictations,
                                snippets: inputs.snippets, kinds: inputs.kinds)
        merged = (inputs, items)
        return items
    }

    var recents: [ShelfItem] { Shelf.recents(items, lead: suggested) }

    /// The island's Recent row and list for the current chip and query.
    var layout: (cards: [ShelfItem], rows: [ShelfItem]) {
        // Windows and apps only join a search, so the list is not built for every open.
        let pool = state.query.isEmpty || !settings.visibleKinds.contains(.app) ? [] : apps.pool(titled: true)
        let key = LayoutKey(items: items, apps: pool, lead: suggested, chip: state.chip, query: state.query)
        if let laidOut, laidOut.key == key { return (laidOut.cards, laidOut.rows) }
        let layout = Shelf.layout(key.items, apps: key.apps, lead: key.lead, chip: key.chip, query: key.query)
        laidOut = (key, layout.cards, layout.rows)
        return layout
    }

    /// What the arrows move through: the cards, then in the island the list.
    private var reachable: [ShelfItem] {
        if state.isShelf { return recents }
        let layout = layout
        return layout.cards + layout.rows
    }

    var selected: ShelfItem? {
        if state.isShelf {
            let recents = recents
            return recents.first { $0.id == selectedID } ?? recents.first
        }
        let (cards, rows) = layout
        return cards.first { $0.id == selectedID } ?? rows.first { $0.id == selectedID } ?? cards.first ?? rows.first
    }

    func select(_ id: String?) { selectedID = id ?? reachable.first?.id }

    /// ↓ from the shelf, a chip change and a new query all start on the list.
    func selectFirstRow() {
        let layout = layout
        selectedID = (layout.rows.first ?? layout.cards.first)?.id
    }

    // MARK: Keys

    /// Moves, uses and per-item actions. Chips, closing and expanding belong to the coordinator.
    func handle(_ command: PanelCommand) -> Bool {
        if snippets.isEditing { return snippets.handleEditing(command) }
        switch command {
        case .moveLeft, .moveRight:
            // With a query the caret needs these keys; the Recent row is hidden then anyway.
            guard state.query.isEmpty else { return false }
            moveAlongCards(by: command == .moveLeft ? -1 : 1)
        case .moveUp, .moveDown, .pageUp, .pageDown, .moveToStart, .moveToEnd:
            guard state.isExpanded else { return true }
            moveInList(command)
        case .clearAll:
            guard settings.isEnabled(.clipboard) else { return false }
            clipboard.clearAll()
        case .newItem:
            guard settings.isEnabled(.snippets) else { return false }
            state.chip = .snippets
            snippets.beginNew()
        case .close:
            return false
        default:
            guard let item = selected else {
                // "No matches — ↩ creates a new snippet."
                if command == .primaryAction, state.chip == .snippets, settings.isEnabled(.snippets) { snippets.beginNew() }
                return true
            }
            return perform(command, on: item)
        }
        return true
    }

    /// A click on a card, or a double click on a row: the Return action.
    func use(_ item: ShelfItem) {
        selectedID = item.id
        _ = perform(.primaryAction, on: item)
    }

    private func perform(_ command: PanelCommand, on item: ShelfItem) -> Bool {
        if command == .saveAsSnippet, !settings.isEnabled(.snippets) { return false }
        // A deleted item hands the selection to its neighbour, the way lists usually do.
        let neighbour = command == .delete ? neighbour(of: item) : nil
        let handled = switch item {
        case .clip(let clip): clipboard.handle(command, on: clip)
        case .media(let media): screenshots.handle(command, on: media)
        case .dictation(let dictation): dictations.handle(command, on: dictation)
        case .snippet(let snippet): snippets.handle(command, on: snippet)
        case .app(let entry): apps.handle(command, on: entry)
        }
        if handled, command == .delete { selectedID = neighbour?.id }
        return handled
    }

    private func neighbour(of item: ShelfItem) -> ShelfItem? {
        let reachable = reachable
        guard let index = reachable.firstIndex(of: item) else { return nil }
        return reachable.indices.contains(index + 1) ? reachable[index + 1] : index > 0 ? reachable[index - 1] : nil
    }

    private func moveAlongCards(by delta: Int) {
        let cards = state.isShelf ? recents : layout.cards
        guard !cards.isEmpty else { return }
        let index = cards.firstIndex { $0.id == selected?.id } ?? (delta > 0 ? -1 : cards.count)
        selectedID = cards[min(max(index + delta, 0), cards.count - 1)].id
    }

    private func moveInList(_ command: PanelCommand) {
        let (cards, rows) = layout
        if cards.contains(where: { $0.id == selected?.id }) {
            // The cards are one row: going down drops into the list, going up stays.
            if command == .moveDown || command == .pageDown, let first = rows.first { selectedID = first.id }
            return
        }
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selected?.id } ?? 0
        let target = switch command {
        case .moveUp: index - 1
        case .moveDown: index + 1
        case .pageUp: index - 8
        case .pageDown: index + 8
        case .moveToStart: 0
        default: rows.count - 1
        }
        if target < 0, command == .moveUp, let card = cards.first { selectedID = card.id; return }
        selectedID = rows[min(max(target, 0), rows.count - 1)].id
    }

    // MARK: Prediction

    /// The selected item in prediction terms.
    var selectedOutcome: Outcome? {
        switch selected {
        case .clip(let clip): .clip(clip, among: clipboard.store.items)
        case .media(let media): .screenshot(media, among: screenshots.library.items)
        case .dictation(let dictation): .dictation(dictation, among: dictations.store.items)
        case .snippet: Outcome(kind: .snippet)
        // A switch reports itself, and nothing else acts on an app.
        case .app, nil: nil
        }
    }
}
