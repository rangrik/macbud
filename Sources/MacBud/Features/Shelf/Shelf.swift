import Foundation

/// One thing the shelf can show, from whichever store holds it.
nonisolated enum ShelfItem: Identifiable, Equatable, Sendable {
    case clip(ClipboardItem)
    case media(MediaItem)
    case dictation(DictationHistoryItem)
    case snippet(Snippet)
    /// A window or app: in All's search, or first on the shelf when a prediction names it.
    case app(AppEntry)

    var id: String {
        switch self {
        case .clip(let clip): "clip:\(clip.id)"
        case .media(let media): "media:\(media.url.path)"
        case .dictation(let dictation): "dictation:\(dictation.id)"
        case .snippet(let snippet): "snippet:\(snippet.id)"
        case .app(let entry): "app:\(entry.id)"
        }
    }

    var date: Date {
        switch self {
        case .clip(let clip): clip.copiedAt
        case .media(let media): media.createdAt
        case .dictation(let dictation): dictation.createdAt
        case .snippet(let snippet): snippet.updatedAt
        case .app(let entry): entry.lastUsed ?? .distantPast
        }
    }

    var kind: IntentKind {
        switch self {
        case .clip(let clip): IntentKind(clip: clip.kind, source: clip.sourceBundleID)
        case .media: .screenshot
        case .dictation: .dictation
        case .snippet: .snippet
        case .app: .app
        }
    }

    var title: String {
        switch self {
        case .clip(let clip): clip.title
        case .media(let media): media.filename
        case .dictation(let dictation): dictation.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        case .snippet(let snippet): snippet.name
        case .app(let entry): entry.displayName
        }
    }

    var searchText: String {
        switch self {
        case .clip(let clip): clip.searchText
        case .media(let media): media.filename
        case .dictation(let dictation): dictation.text
        case .snippet(let snippet): snippet.searchText
        case .app(let entry): entry.searchText
        }
    }

    var isPinned: Bool { if case .clip(let clip) = self { clip.isPinned } else { false } }
}

/// Where an open lands: the chip, the card with the ring, and whether to skip the shelf.
nonisolated struct Landing: Equatable, Sendable {
    var chip: Chip = .all
    var card: String?
    var expanded = false

    /// How the prediction log names this landing.
    var place: String { expanded ? chip.rawValue : "shelf" }
}

nonisolated enum Shelf {
    static let recentCount = 6

    /// Every item of a visible kind, newest first. A dictation MacBud also copied shows once, from History.
    static func merge(clips: [ClipboardItem], media: [MediaItem], dictations: [DictationHistoryItem],
                      snippets: [Snippet], kinds: [IntentKind]) -> [ShelfItem] {
        let dictated = Set(dictations.map(\.text))
        let copies = clips.map(ShelfItem.clip).filter { item in
            guard item.kind == .dictation, case .clip(let clip) = item else { return true }
            return !dictated.contains((clip.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let all = copies + media.map(ShelfItem.media) + dictations.map(ShelfItem.dictation) + snippets.map(ShelfItem.snippet)
        return all.filter { kinds.contains($0.kind) }.sorted { $0.date > $1.date }
    }

    /// The newest things made or copied, after the app a prediction names. Snippets are kept, not recent, so they wait in the list.
    static func recents(_ items: [ShelfItem], lead: AppEntry? = nil) -> [ShelfItem] {
        let lead = lead.map { [ShelfItem.app($0)] } ?? []
        return lead + items.lazy.filter { $0.kind != .snippet }.prefix(recentCount - lead.count)
    }

    /// The Recent row and the list under it for a chip. A query searches everything the chip allows, best first;
    /// under All that includes `apps`, scored as the Apps chip scores them.
    static func layout(_ items: [ShelfItem], apps: [AppEntry] = [], lead: AppEntry? = nil, chip: Chip,
                       query: String) -> (cards: [ShelfItem], rows: [ShelfItem]) {
        let scoped = chip == .all ? items : items.filter { $0.kind.chip == chip }
        let query = query.trimmingCharacters(in: .whitespaces)
        guard query.isEmpty else {
            let found = SearchMatcher.rank(scoped, query: query, text: \.searchText).map { ($0.item, $0.match.score) }
            let windows: [(ShelfItem, Int)] = chip == .all ? AppsSectionController.rank(apps, query: query).map { (.app($0.entry), $0.score) } : []
            return ([], (found + windows).sorted { $0.1 > $1.1 }.map(\.0))
        }
        let recent = recents(items, lead: lead).filter { chip == .all || $0.kind.chip == chip }
        let ids = Set(recent.map(\.id))
        let rest = scoped.filter { !ids.contains($0.id) }
        return (recent, rest.filter(\.isPinned) + rest.filter { !$0.isPinned })
    }

    /// The one place an intent meets the UI: the ring goes on the first card of its kind (`older`: the second).
    /// An app is on the shelf only when the prediction named one; otherwise it opens the island on Apps.
    static func landing(for intent: LandingIntent?, recents: [ShelfItem]) -> Landing {
        guard let intent else { return Landing(card: recents.first?.id) }
        let ofKind = recents.filter { $0.kind == intent.kind }
        if intent.kind == .app, ofKind.isEmpty { return Landing(chip: .apps, expanded: true) }
        let pick = intent.hint == .older && ofKind.count > 1 ? ofKind[1] : ofKind.first
        return Landing(card: (pick ?? recents.first)?.id)
    }
}

/// Hover opens the shelf only once the pointer rests on the tab, and only from a quiet, closed notch.
nonisolated enum HoverDwell {
    static let delay: Duration = .milliseconds(150)
    /// How long the pointer may stay off an open shelf before it closes.
    static let leaveDelay: Duration = .milliseconds(400)

    static func opens(enabled: Bool, phase: NotchPhase, toasting: Bool, hoveredFor: Duration) -> Bool {
        enabled && phase == .collapsed && !toasting && hoveredFor >= delay
    }
}
