import AppKit

/// What can be done to a clipboard item. The shelf decides which item.
@Observable
final class ClipboardSectionController {
    let store: ClipboardStore
    let context: ActionContext
    /// Set by the coordinator so "save as snippet" can hand content over.
    weak var snippets: SnippetsSectionController?

    private(set) var pendingClearAll = false
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    init(store: ClipboardStore, context: ActionContext) {
        self.store = store
        self.context = context
    }

    func handle(_ command: PanelCommand, on item: ClipboardItem) -> Bool {
        switch command {
        case .primaryAction, .secondaryAction:
            activate(item, paste: context.wantsPaste(for: command))
        case .delete:
            store.remove(item.id)
        case .togglePin:
            store.togglePin(item.id)
        case .saveAsSnippet:
            guard context.settings.isEnabled(.snippets) else { return false }
            guard let text = item.text else { context.showHint("Only text can become a snippet"); return true }
            snippets?.beginNew(content: text)
            context.state.chip = .snippets
        case .revealInFinder:
            context.revealInFinder(fileURLs(for: item))
        case .quickLook:
            let urls = fileURLs(for: item)
            if urls.isEmpty { context.showHint("Nothing to preview") } else { context.quickLook(urls) }
        default:
            return false
        }
        return true
    }

    /// Asks once, then clears on the second press within four seconds. Pinned items stay.
    func clearAll() {
        if pendingClearAll {
            store.removeAll(keepPinned: true)
            cancelClearAll()
            context.showHint("History cleared")
            return
        }
        pendingClearAll = true
        context.showHint("Press ⌘⇧⌫ again to clear clipboard history (pinned items stay)", for: .seconds(4))
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.pendingClearAll = false
        }
    }

    func cancelClearAll() {
        clearTask?.cancel()
        pendingClearAll = false
    }

    func activate(_ item: ClipboardItem, paste: Bool) {
        context.onUse?(paste ? "paste" : "copy", .clip(item, among: store.items))
        let paster = context.paster
        context.perform(paste: paste, description: item.title) {
            switch item.kind {
            case .text, .link:
                paster.write(text: item.text ?? "")
            case .image:
                if let url = store.imageURL(for: item), let data = try? Data(contentsOf: url) { paster.write(imageData: data) }
            case .file:
                paster.write(fileURLs: item.filePaths.map { URL(fileURLWithPath: $0) })
            }
        }
    }

    func fileURLs(for item: ClipboardItem) -> [URL] {
        switch item.kind {
        case .file: item.filePaths.map { URL(fileURLWithPath: $0) }
        case .image: store.imageURL(for: item).map { [$0] } ?? []
        default: []
        }
    }
}
