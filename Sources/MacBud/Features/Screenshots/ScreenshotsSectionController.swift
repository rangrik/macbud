import AppKit

@Observable
final class ScreenshotsSectionController {
    let library: ScreenshotLibrary
    let context: ActionContext
    var selectedIndex = 0

    init(library: ScreenshotLibrary, context: ActionContext) {
        self.library = library
        self.context = context
    }

    var results: [(item: MediaItem, match: SearchMatch)] { library.results(for: context.state.query) }

    var selected: MediaItem? {
        let r = results
        return r.indices.contains(selectedIndex) ? r[selectedIndex].item : nil
    }

    func didShow() {
        selectedIndex = 0
        library.requestRescan(delay: .zero)
    }

    func queryChanged() { selectedIndex = 0 }

    func handle(_ command: PanelCommand) -> Bool {
        let count = results.count
        switch command {
        case .moveUp, .moveLeft: move(by: -1, count: count)
        case .moveDown, .moveRight: move(by: 1, count: count)
        case .pageUp: move(by: -5, count: count)
        case .pageDown: move(by: 5, count: count)
        case .moveToStart: selectedIndex = 0
        case .moveToEnd: selectedIndex = max(0, count - 1)
        case .primaryAction, .secondaryAction:
            guard let item = selected else { return true }
            activate(item, paste: context.wantsPaste(for: command))
        case .delete:
            guard let item = selected else { return true }
            do {
                try library.trash(item)
                selectedIndex = min(selectedIndex, max(0, results.count - 1))
                context.showHint("Moved “\(item.filename)” to Trash")
            } catch {
                context.showHint("Couldn't trash \(item.filename): \(error.localizedDescription)")
            }
        case .revealInFinder:
            guard let item = selected else { return true }
            context.revealInFinder([item.url])
        case .quickLook:
            guard let item = selected else { return true }
            context.quickLook([item.url])
        default:
            return false
        }
        return true
    }

    func select(_ item: MediaItem) {
        if let index = results.firstIndex(where: { $0.item.url == item.url }) { selectedIndex = index }
    }

    func activate(_ item: MediaItem, paste: Bool) {
        let paster = context.paster
        context.perform(paste: paste, description: item.filename) {
            paster.write(mediaFile: item.url, kind: item.kind)
        }
    }

    private func move(by delta: Int, count: Int) {
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }
}
