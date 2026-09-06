import AppKit

@Observable
final class ClipboardSectionController {
    let store: ClipboardStore
    let context: ActionContext
    /// Set by the coordinator so "save as snippet" can hand content over.
    weak var snippets: SnippetsSectionController?

    var selectedIndex = 0
    private(set) var pendingClearAll = false
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    init(store: ClipboardStore, context: ActionContext) {
        self.store = store
        self.context = context
    }

    var results: [(item: ClipboardItem, match: SearchMatch)] { store.results(for: context.state.query) }

    var selected: ClipboardItem? {
        let r = results
        return r.indices.contains(selectedIndex) ? r[selectedIndex].item : nil
    }

    func didShow() {
        selectedIndex = 0
        cancelClearAll()
    }

    func queryChanged() { selectedIndex = 0 }

    func handle(_ command: PanelCommand) -> Bool {
        let count = results.count
        switch command {
        case .moveUp: move(by: -1, count: count)
        case .moveDown: move(by: 1, count: count)
        case .pageUp: move(by: -8, count: count)
        case .pageDown: move(by: 8, count: count)
        case .moveToStart: selectedIndex = 0
        case .moveToEnd: selectedIndex = max(0, count - 1)
        case .primaryAction, .secondaryAction:
            guard let item = selected else { return true }
            activate(item, paste: context.wantsPaste(for: command))
        case .delete:
            guard let item = selected else { return true }
            store.remove(item.id)
            selectedIndex = min(selectedIndex, max(0, results.count - 1))
        case .clearAll:
            if pendingClearAll {
                store.removeAll(keepPinned: true)
                cancelClearAll()
                selectedIndex = 0
                context.showHint("History cleared")
            } else {
                pendingClearAll = true
                context.showHint("Press ⌘⇧⌫ again to clear history (pinned items stay)", for: .seconds(4))
                clearTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    self?.pendingClearAll = false
                }
            }
        case .togglePin:
            guard let item = selected else { return true }
            store.togglePin(item.id)
            if let index = results.firstIndex(where: { $0.item.id == item.id }) { selectedIndex = index }
        case .saveAsSnippet:
            guard context.settings.isEnabled(.snippets) else { return false }
            guard let item = selected, let text = item.text else { context.showHint("Only text can become a snippet"); return true }
            snippets?.beginNew(content: text)
            context.state.section = .snippets
            context.settings.lastSection = .snippets
        case .revealInFinder:
            guard let item = selected else { return true }
            context.revealInFinder(fileURLs(for: item))
        case .quickLook:
            guard let item = selected else { return true }
            let urls = fileURLs(for: item)
            if urls.isEmpty { context.showHint("Nothing to preview") } else { context.quickLook(urls) }
        default:
            return false
        }
        return true
    }

    func select(_ item: ClipboardItem) {
        if let index = results.firstIndex(where: { $0.item.id == item.id }) { selectedIndex = index }
    }

    func activate(_ item: ClipboardItem, paste: Bool) {
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

    private func move(by delta: Int, count: Int) {
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
        cancelClearAll()
    }

    private func cancelClearAll() {
        clearTask?.cancel()
        pendingClearAll = false
    }
}
