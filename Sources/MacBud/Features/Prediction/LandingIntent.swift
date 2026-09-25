import Foundation

/// What the owner wants to reach, in words that outlive today's tabs.
nonisolated enum IntentKind: String, Codable, CaseIterable, Sendable {
    case text, link, image, screenshot, dictation, snippet, app

    /// The chip that holds items of this kind. `Shelf.landing` decides where an open lands.
    var chip: Chip {
        switch self {
        case .text: .text
        case .link: .links
        case .image: .images
        case .screenshot: .screenshots
        case .dictation: .dictations
        case .snippet: .snippets
        case .app: .apps
        }
    }

    static func available(in chips: [Chip]) -> [IntentKind] { allCases.filter { chips.contains($0.chip) } }

    /// MacBud's own copies are dictation output. Files count as text until there is a file kind.
    init(clip kind: ClipboardItem.Kind, source: String?) {
        if source == Bundle.main.bundleIdentifier { self = .dictation; return }
        self = switch kind {
        case .link: .link
        case .image: .image
        case .text, .file: .text
        }
    }
}

nonisolated enum ItemHint: String, Codable, CaseIterable, Sendable {
    /// The most recent item of the kind; for apps, the window of the app the owner just left.
    case newest
    case older
    case any
}

nonisolated struct LandingIntent: Codable, Equatable, Sendable {
    var kind: IntentKind
    var hint: ItemHint = .any
    var confidence: Double = 1
    /// For `app`, one app to switch to by bundle id. It beats the hint.
    var app: String?

    /// A miss is a different kind, another app than the one named, or a wrong newest-or-older guess when we know which it was.
    func matches(_ outcome: Outcome) -> Bool {
        guard outcome.kind == kind else { return false }
        if let app { return outcome.app == app }
        guard let newest = outcome.newest, hint != .any else { return true }
        return newest == (hint == .newest)
    }
}

/// What the owner used: its kind, and whether it was the newest of that kind (nil when that means nothing).
nonisolated struct Outcome: Codable, Equatable, Sendable {
    var kind: IntentKind
    var newest: Bool?
    /// The bundle id, when an app was switched to.
    var app: String?

    static func clip(_ item: ClipboardItem, among items: [ClipboardItem]) -> Outcome {
        let kind = IntentKind(clip: item.kind, source: item.sourceBundleID)
        let newest = items.filter { IntentKind(clip: $0.kind, source: $0.sourceBundleID) == kind }.max { $0.copiedAt < $1.copiedAt }
        return Outcome(kind: kind, newest: newest?.id == item.id)
    }

    static func screenshot(_ item: MediaItem, among items: [MediaItem]) -> Outcome {
        Outcome(kind: .screenshot, newest: item == items.max { $0.createdAt < $1.createdAt })
    }

    static func dictation(_ item: DictationHistoryItem, among items: [DictationHistoryItem]) -> Outcome {
        Outcome(kind: .dictation, newest: item.id == items.max { $0.createdAt < $1.createdAt }?.id)
    }

    static func app(_ entry: AppEntry, switchTarget: AppEntry?) -> Outcome {
        Outcome(kind: .app, newest: entry.id == switchTarget?.id, app: entry.bundleID)
    }
}
