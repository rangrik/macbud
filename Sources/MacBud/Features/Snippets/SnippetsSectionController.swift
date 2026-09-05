import AppKit

@Observable
final class SnippetDraft {
    var id: UUID?
    var name = ""
    var keyword = ""
    var content = ""

    var isNew: Bool { id == nil }
    var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !content.isEmpty }

    func reset(with snippet: Snippet?) {
        id = snippet?.id
        name = snippet?.name ?? ""
        keyword = snippet?.keyword ?? ""
        content = snippet?.content ?? ""
    }
}

@Observable
final class SnippetsSectionController {
    enum Mode: Equatable { case list, editing }

    let store: SnippetStore
    let clipboard: ClipboardStore
    let context: ActionContext

    var mode: Mode = .list
    let draft = SnippetDraft()
    var selectedIndex = 0

    init(store: SnippetStore, clipboard: ClipboardStore, context: ActionContext) {
        self.store = store
        self.clipboard = clipboard
        self.context = context
    }

    var results: [(item: Snippet, match: SearchMatch)] { store.results(for: context.state.query) }

    var selected: Snippet? {
        let r = results
        return r.indices.contains(selectedIndex) ? r[selectedIndex].item : nil
    }

    var isEditing: Bool { mode == .editing }

    func didShow() {
        selectedIndex = 0
        if mode == .editing, !draft.isNew || !draft.content.isEmpty { return }
        mode = .list
    }

    func queryChanged() { selectedIndex = 0 }

    // MARK: Editing

    func beginNew(content: String = "") {
        draft.reset(with: nil)
        draft.content = content
        mode = .editing
        context.state.wantsSearchFocus = false
    }

    func beginEdit(_ snippet: Snippet) {
        draft.reset(with: snippet)
        mode = .editing
        context.state.wantsSearchFocus = false
    }

    @discardableResult
    func saveDraft() -> Bool {
        guard draft.isValid else { context.showHint("A snippet needs a name and some content"); return false }
        let existing = draft.id.flatMap(store.snippet(id:))
        var snippet = existing ?? Snippet(name: "", keyword: "", content: "")
        snippet.name = draft.name.trimmingCharacters(in: .whitespaces)
        snippet.keyword = draft.keyword.trimmingCharacters(in: .whitespaces).lowercased()
        snippet.content = draft.content
        store.upsert(snippet)
        endEditing()
        select(snippet)
        context.showHint(existing == nil ? "Snippet saved" : "Snippet updated")
        return true
    }

    func cancelEditing() { endEditing() }

    private func endEditing() {
        mode = .list
        context.state.wantsSearchFocus = true
    }

    // MARK: Commands

    func handle(_ command: PanelCommand) -> Bool {
        if mode == .editing {
            switch command {
            case .close: cancelEditing(); return true
            case .secondaryAction, .saveAsSnippet: saveDraft(); return true
            default: return false // let the editor's text fields have the keys
            }
        }
        let count = results.count
        switch command {
        case .moveUp: move(by: -1, count: count)
        case .moveDown: move(by: 1, count: count)
        case .pageUp: move(by: -8, count: count)
        case .pageDown: move(by: 8, count: count)
        case .moveToStart: selectedIndex = 0
        case .moveToEnd: selectedIndex = max(0, count - 1)
        case .primaryAction, .secondaryAction:
            guard let snippet = selected else { beginNew(); return true }
            activate(snippet, paste: context.wantsPaste(for: command))
        case .delete:
            guard let snippet = selected else { return true }
            store.remove(snippet.id)
            selectedIndex = min(selectedIndex, max(0, results.count - 1))
            context.showHint("Deleted “\(snippet.name)”")
        case .newItem: beginNew()
        case .editItem:
            guard let snippet = selected else { return true }
            beginEdit(snippet)
        default:
            return false
        }
        return true
    }

    func select(_ snippet: Snippet) {
        if let index = results.firstIndex(where: { $0.item.id == snippet.id }) { selectedIndex = index }
    }

    func activate(_ snippet: Snippet, paste: Bool) {
        let expansion = expand(snippet)
        let paster = context.paster
        store.recordUse(snippet.id)
        context.perform(paste: paste, description: snippet.name,
                        charactersAfterCursor: paste ? expansion.charactersAfterCursor : nil) {
            paster.write(text: expansion.text)
        }
    }

    func expand(_ snippet: Snippet) -> SnippetExpander.Expansion {
        let lastText = clipboard.items.first { $0.kind == .text || $0.kind == .link }?.text
        return SnippetExpander.expand(snippet.content, context: SnippetExpander.Context(clipboard: lastText))
    }

    private func move(by delta: Int, count: Int) {
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }
}
