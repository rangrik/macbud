import Foundation

/// What can be done to a saved dictation. The shelf decides which one.
@Observable
final class DictationHistorySectionController {
    let store: DictationHistoryStore
    let context: ActionContext
    let snippets: SnippetsSectionController

    init(store: DictationHistoryStore, context: ActionContext, snippets: SnippetsSectionController) {
        self.store = store
        self.context = context
        self.snippets = snippets
    }

    func use(_ item: DictationHistoryItem, insert: Bool) {
        // History is a key panel: restore its captured target before the same focused-input validation.
        context.onUse?(insert ? "insert" : "copy", .dictation(item, among: store.items))
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
        context.state.chip = .snippets
        context.state.query = ""
        snippets.beginNew(content: item.text)
        snippets.draft.name = String((item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Dictation").prefix(60))
    }

    func handle(_ command: PanelCommand, on item: DictationHistoryItem) -> Bool {
        switch command {
        case .primaryAction, .secondaryAction: use(item, insert: context.wantsPaste(for: command))
        case .saveAsSnippet: saveAsSnippet(item)
        case .delete: store.remove(item.id)
        default: return false
        }
        return true
    }
}
