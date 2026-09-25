import Foundation

/// One thing the shelf can show, from whichever store holds it.
nonisolated enum ShelfItem: Identifiable, Equatable, Sendable {
    case clip(ClipboardItem)
    case media(MediaItem)
    case dictation(DictationHistoryItem)
    case snippet(Snippet)

    var id: String {
        switch self {
        case .clip(let clip): "clip:\(clip.id)"
        case .media(let media): "media:\(media.url.path)"
        case .dictation(let dictation): "dictation:\(dictation.id)"
        case .snippet(let snippet): "snippet:\(snippet.id)"
        }
    }

    var date: Date {
        switch self {
        case .clip(let clip): clip.copiedAt
        case .media(let media): media.createdAt
        case .dictation(let dictation): dictation.createdAt
        case .snippet(let snippet): snippet.updatedAt
        }
    }

    var kind: IntentKind {
        switch self {
        case .clip(let clip): IntentKind(clip: clip.kind, source: clip.sourceBundleID)
        case .media: .screenshot
        case .dictation: .dictation
        case .snippet: .snippet
        }
    }

    var title: String {
        switch self {
        case .clip(let clip): clip.title
        case .media(let media): media.filename
        case .dictation(let dictation): dictation.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        case .snippet(let snippet): snippet.name
        }
    }

    var searchText: String {
        switch self {
        case .clip(let clip): clip.searchText
        case .media(let media): media.filename
        case .dictation(let dictation): dictation.text
        case .snippet(let snippet): snippet.searchText
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

    /// The newest things made or copied. Snippets are kept, not recent, so they wait in the list.
    static func recents(_ items: [ShelfItem]) -> [ShelfItem] {
        Array(items.lazy.filter { $0.kind != .snippet }.prefix(recentCount))
    }

    /// The Recent row and the list under it for a chip. A query searches everything the chip allows, best first.
    static func layout(_ items: [ShelfItem], chip: Chip, query: String) -> (cards: [ShelfItem], rows: [ShelfItem]) {
        let scoped = chip == .all ? items : items.filter { $0.kind.chip == chip }
        let query = query.trimmingCharacters(in: .whitespaces)
        guard query.isEmpty else { return ([], SearchMatcher.rank(scoped, query: query, text: \.searchText).map(\.item)) }
        let recent = Set(recents(items).map(\.id))
        let rest = scoped.filter { !recent.contains($0.id) }
        return (scoped.filter { recent.contains($0.id) }, rest.filter(\.isPinned) + rest.filter { !$0.isPinned })
    }

    /// The one place an intent meets the UI. Apps are never on the shelf, so they open the island;
    /// anything else puts the ring on the first card of its kind (`older`: the second).
    static func landing(for intent: LandingIntent?, recents: [ShelfItem]) -> Landing {
        guard let intent else { return Landing(card: recents.first?.id) }
        if intent.kind == .app { return Landing(chip: .apps, expanded: true) }
        let ofKind = recents.filter { $0.kind == intent.kind }
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
