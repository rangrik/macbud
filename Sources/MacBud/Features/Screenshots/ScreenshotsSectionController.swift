import AppKit

/// What can be done to a screenshot or recording. The shelf decides which one.
@Observable
final class ScreenshotsSectionController {
    let library: ScreenshotLibrary
    let context: ActionContext

    init(library: ScreenshotLibrary, context: ActionContext) {
        self.library = library
        self.context = context
    }

    func handle(_ command: PanelCommand, on item: MediaItem) -> Bool {
        switch command {
        case .primaryAction, .secondaryAction:
            activate(item, paste: context.wantsPaste(for: command))
        case .delete:
            do {
                try library.trash(item)
                context.showHint("Moved “\(item.filename)” to Trash")
            } catch {
                context.showHint("Couldn't trash \(item.filename): \(error.localizedDescription)")
            }
        case .revealInFinder:
            context.revealInFinder([item.url])
        case .quickLook:
            context.quickLook([item.url])
        default:
            return false
        }
        return true
    }

    func activate(_ item: MediaItem, paste: Bool) {
        context.onUse?(paste ? "paste" : "copy", .screenshot(item, among: library.items))
        let paster = context.paster
        context.perform(paste: paste, description: item.filename) {
            paster.write(mediaFile: item.url, kind: item.kind)
        }
    }
}
