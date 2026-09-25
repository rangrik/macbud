import Foundation

nonisolated enum AppFeature: String, CaseIterable, Sendable {
    case clipboard, snippets, screenshots, dictationHistory, dictation, keepAwake, clock, apps

    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .snippets: "Snippets"
        case .screenshots: "Screenshots"
        case .dictationHistory: "History"
        case .dictation: "Dictation"
        case .keepAwake: "Keep Alive"
        case .clock: "Clock"
        case .apps: "Apps"
        }
    }
}

extension Chip {
    /// The feature that owns this chip. All has none; it shows whatever the others allow.
    var feature: AppFeature? {
        switch self {
        case .all: nil
        case .text, .links, .images: .clipboard
        case .screenshots: .screenshots
        case .dictations: .dictationHistory
        case .snippets: .snippets
        case .apps: .apps
        }
    }
}
