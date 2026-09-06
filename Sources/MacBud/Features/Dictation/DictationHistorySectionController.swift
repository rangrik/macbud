import Foundation

@Observable
final class DictationHistorySectionController {
    let store: DictationHistoryStore
    let context: ActionContext
    let snippets: SnippetsSectionController
    var selectedIndex = 0

    init(store: DictationHistoryStore, context: ActionContext, snippets: SnippetsSectionController) {
        self.store = store
        self.context = context
        self.snippets = snippets
    }

    var results: [DictationHistoryItem] { store.results(for: context.state.query) }
    var selected: DictationHistoryItem? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    func didShow() { selectedIndex = 0 }
    func queryChanged() { selectedIndex = 0 }

    func use(_ item: DictationHistoryItem, insert: Bool) {
        // History is a key panel: restore its captured target before the same focused-input validation.
        let target = context.frontmost.previousApp
        context.notch.close()
        Task {
            if insert, let target, !target.isTerminated {
                target.activate()
                for _ in 0..<10 where !target.isActive {
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
            context.deliverDictation(item.text, insert: insert)
        }
    }

    func saveAsSnippet(_ item: DictationHistoryItem) {
        guard context.settings.isEnabled(.snippets) else { return }
        context.state.section = .snippets
        context.settings.lastSection = .snippets
        context.state.query = ""
        snippets.beginNew(content: item.text)
        snippets.draft.name = String((item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Dictation").prefix(60))
    }

    func handle(_ command: PanelCommand) -> Bool {
        switch command {
        case .moveUp: selectedIndex = max(0, selectedIndex - 1)
        case .moveDown: selectedIndex = min(max(0, results.count - 1), selectedIndex + 1)
        case .pageUp: selectedIndex = max(0, selectedIndex - 8)
        case .pageDown: selectedIndex = min(max(0, results.count - 1), selectedIndex + 8)
        case .moveToStart: selectedIndex = 0
        case .moveToEnd: selectedIndex = max(0, results.count - 1)
        case .primaryAction, .secondaryAction:
            if let selected { use(selected, insert: context.wantsPaste(for: command)) }
        case .saveAsSnippet:
            if let selected { saveAsSnippet(selected) }
        case .delete:
            if let selected { store.remove(selected.id) }
            selectedIndex = min(selectedIndex, max(0, results.count - 1))
        default: return false
        }
        return true
    }
}
