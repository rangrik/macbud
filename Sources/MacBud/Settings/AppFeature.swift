import Foundation

nonisolated enum AppFeature: String, CaseIterable, Sendable {
    case clipboard, snippets, screenshots, dictationHistory, dictation, keepAwake, apps

    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .snippets: "Snippets"
        case .screenshots: "Screenshots"
        case .dictationHistory: "History"
        case .dictation: "Dictation"
        case .keepAwake: "Keep Alive"
        case .apps: "Apps"
        }
    }
}

extension Section {
    var feature: AppFeature {
        switch self {
        case .clipboard: .clipboard
        case .snippets: .snippets
        case .screenshots: .screenshots
        case .dictationHistory: .dictationHistory
        case .apps: .apps
        }
    }
}
