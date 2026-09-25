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

/// What can be done to a snippet, and the editor for new and changed ones. The shelf decides which snippet.
@Observable
final class SnippetsSectionController {
    enum Mode: Equatable { case list, editing }

    let store: SnippetStore
    let clipboard: ClipboardStore
    let context: ActionContext

    var mode: Mode = .list
    let draft = SnippetDraft()

    init(store: SnippetStore, clipboard: ClipboardStore, context: ActionContext) {
        self.store = store
        self.clipboard = clipboard
        self.context = context
    }

    var isEditing: Bool { mode == .editing }

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
    func saveDraft() -> Snippet? {
        guard draft.isValid else { context.showHint("A snippet needs a name and some content"); return nil }
        let existing = draft.id.flatMap(store.snippet(id:))
        var snippet = existing ?? Snippet(name: "", keyword: "", content: "")
        snippet.name = draft.name.trimmingCharacters(in: .whitespaces)
        snippet.keyword = draft.keyword.trimmingCharacters(in: .whitespaces).lowercased()
        snippet.content = draft.content
        store.upsert(snippet)
        endEditing()
        context.showHint(existing == nil ? "Snippet saved" : "Snippet updated")
        return store.snippet(id: snippet.id)
    }

    func cancelEditing() { endEditing() }

    private func endEditing() {
        mode = .list
        context.state.wantsSearchFocus = true
    }

    // MARK: Commands

    /// While editing, the editor's fields keep every key except close and save.
    func handleEditing(_ command: PanelCommand) -> Bool {
        switch command {
        case .close: cancelEditing(); return true
        case .secondaryAction, .saveAsSnippet: saveDraft(); return true
        default: return false
        }
    }

    func handle(_ command: PanelCommand, on snippet: Snippet) -> Bool {
        switch command {
        case .primaryAction, .secondaryAction:
            activate(snippet, paste: context.wantsPaste(for: command))
        case .delete:
            store.remove(snippet.id)
            context.showHint("Deleted “\(snippet.name)”")
        case .editItem:
            beginEdit(snippet)
        default:
            return false
        }
        return true
    }

    func activate(_ snippet: Snippet, paste: Bool) {
        context.onUse?(paste ? "paste" : "copy", Outcome(kind: .snippet))
        let expansion = expand(snippet)
        let paster = context.paster
        store.recordUse(snippet.id)
        context.perform(paste: paste, description: snippet.name,
                        charactersAfterCursor: paste ? expansion.charactersAfterCursor : nil) {
            paster.write(text: expansion.text)
        }
    }

    func expand(_ snippet: Snippet) -> SnippetExpander.Expansion {
        let current = NSPasteboard.general.string(forType: .string)
        let latest = clipboard.items.filter { $0.kind == .text || $0.kind == .link }.max { $0.copiedAt < $1.copiedAt }?.text
        return SnippetExpander.expand(snippet.content, context: SnippetExpander.Context(clipboard: current ?? latest))
    }
}
