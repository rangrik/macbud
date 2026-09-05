import AppKit

/// Routes key commands to the active section and owns everything the island's views need.
@Observable
final class PanelCoordinator {
    let state: NotchState
    let notch: NotchController
    let settings: AppSettings
    let clipboardStore: ClipboardStore
    let snippetStore: SnippetStore
    let library: ScreenshotLibrary
    let frontmost = FrontmostTracker()
    let context: ActionContext
    let clipboard: ClipboardSectionController
    let snippets: SnippetsSectionController
    let screenshots: ScreenshotsSectionController
    /// Set by the app once hotkeys are bound; used by the welcome screen and footer.
    var hotKeys: HotKeyBinder?

    init(state: NotchState, notch: NotchController, settings: AppSettings,
         clipboardStore: ClipboardStore, snippetStore: SnippetStore, library: ScreenshotLibrary) {
        self.state = state
        self.notch = notch
        self.settings = settings
        self.clipboardStore = clipboardStore
        self.snippetStore = snippetStore
        self.library = library
        context = ActionContext(state: state, notch: notch, settings: settings, frontmost: frontmost)
        clipboard = ClipboardSectionController(store: clipboardStore, context: context)
        snippets = SnippetsSectionController(store: snippetStore, clipboard: clipboardStore, context: context)
        screenshots = ScreenshotsSectionController(library: library, context: context)
        clipboard.snippets = snippets
    }

    var showsWelcome: Bool { !settings.hasSeenWelcome }

    var activeResultCount: Int {
        switch state.section {
        case .clipboard: clipboard.results.count
        case .snippets: snippets.results.count
        case .screenshots: screenshots.results.count
        }
    }

    // MARK: Opening

    func open(section: Section? = nil) {
        let target = section ?? (settings.rememberLastSection ? settings.lastSection : .clipboard)
        notch.open(section: target)
    }

    func toggle() {
        if state.isExpanded { notch.close() } else { open() }
    }

    /// Called by the notch controller right before the island appears.
    func willOpen() {
        frontmost.capture()
        context.clearHint()
        activeDidShow()
    }

    func select(_ section: Section) {
        guard section != state.section else { return }
        if snippets.isEditing { snippets.cancelEditing() }
        state.section = section
        settings.lastSection = section
        state.query = ""
        state.wantsSearchFocus = true
        context.clearHint()
        activeDidShow()
    }

    func queryChanged() {
        switch state.section {
        case .clipboard: clipboard.queryChanged()
        case .snippets: snippets.queryChanged()
        case .screenshots: screenshots.queryChanged()
        }
    }

    private func activeDidShow() {
        switch state.section {
        case .clipboard: clipboard.didShow()
        case .snippets: snippets.didShow()
        case .screenshots: screenshots.didShow()
        }
    }

    // MARK: Key handling

    func handle(event: NSEvent) -> Bool {
        guard let command = KeyRouter.command(for: event) else { return false }
        return handle(command)
    }

    @discardableResult
    func handle(_ command: PanelCommand) -> Bool {
        if showsWelcome {
            switch command {
            case .close: notch.close()
            case .primaryAction, .secondaryAction, .nextSection, .selectSection: settings.hasSeenWelcome = true
            default: break
            }
            return true
        }
        switch command {
        case .close:
            if activeHandle(command) { return true }
            notch.close()
            return true
        case .nextSection, .previousSection:
            // While editing a snippet, ⇥ moves between fields instead of switching sections.
            if snippets.isEditing { return false }
            select(command == .nextSection ? state.section.next : state.section.previous)
            return true
        case .selectSection(let section):
            select(section)
            return true
        case .openSettings:
            if snippets.isEditing { return false }
            openSettings()
            return true
        default:
            return activeHandle(command)
        }
    }

    private func activeHandle(_ command: PanelCommand) -> Bool {
        switch state.section {
        case .clipboard: clipboard.handle(command)
        case .snippets: snippets.handle(command)
        case .screenshots: screenshots.handle(command)
        }
    }

    func openSettings() {
        notch.close()
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: Footer

    struct Hint: Identifiable { let keys: String; let label: String; var id: String { keys } }

    func footerHints() -> [Hint] {
        let app = frontmost.previousAppName ?? "app"
        let enterCopies = settings.enterAction == .copy
        let copyKeys = enterCopies ? "↩" : "⌘↩", pasteKeys = enterCopies ? "⌘↩" : "↩"
        var hints: [Hint] = []
        switch state.section {
        case .clipboard:
            hints = [Hint(keys: copyKeys, label: "Copy"), Hint(keys: pasteKeys, label: "Paste to \(app)"),
                     Hint(keys: "⌘P", label: clipboard.selected?.isPinned == true ? "Unpin" : "Pin"),
                     Hint(keys: "⌘S", label: "Snippet"), Hint(keys: "⌘⌫", label: "Delete")]
        case .snippets:
            if snippets.isEditing {
                hints = [Hint(keys: "⌘S", label: "Save"), Hint(keys: "⇥", label: "Next field"), Hint(keys: "esc", label: "Cancel")]
            } else {
                hints = [Hint(keys: copyKeys, label: "Copy"), Hint(keys: pasteKeys, label: "Paste to \(app)"),
                         Hint(keys: "⌘N", label: "New"), Hint(keys: "⌘E", label: "Edit"), Hint(keys: "⌘⌫", label: "Delete")]
            }
        case .screenshots:
            hints = [Hint(keys: copyKeys, label: "Copy"), Hint(keys: pasteKeys, label: "Paste to \(app)"),
                     Hint(keys: "⌘Y", label: "Quick Look"), Hint(keys: "⌘R", label: "Finder"), Hint(keys: "⌘⌫", label: "Trash")]
        }
        if !snippets.isEditing { hints.append(Hint(keys: "⇥", label: "Section")) }
        return hints
    }

    // MARK: Automation

    func dump() -> [String: Any] {
        var d: [String: Any] = [
            "phase": state.isExpanded ? "expanded" : "collapsed",
            "section": state.section.rawValue,
            "query": state.query,
            "footerHint": state.footerHint ?? "",
            "welcome": showsWelcome,
            "toast": state.toast?.title ?? "",
        ]
        switch state.section {
        case .clipboard:
            d["selectedIndex"] = clipboard.selectedIndex
            d["results"] = clipboard.results.prefix(20).map(\.item.title)
            d["selected"] = clipboard.selected?.title ?? ""
        case .snippets:
            d["selectedIndex"] = snippets.selectedIndex
            d["results"] = snippets.results.prefix(20).map(\.item.name)
            d["selected"] = snippets.selected?.name ?? ""
            d["editing"] = snippets.isEditing
            d["draft"] = ["name": snippets.draft.name, "keyword": snippets.draft.keyword, "content": snippets.draft.content]
        case .screenshots:
            d["selectedIndex"] = screenshots.selectedIndex
            d["results"] = screenshots.results.prefix(20).map(\.item.filename)
            d["selected"] = screenshots.selected?.filename ?? ""
        }
        return d
    }
}

/// Keeps Carbon hotkey registrations in sync with settings.
@Observable
final class HotKeyBinder {
    private let settings: AppSettings
    private let coordinator: PanelCoordinator
    private(set) var effectiveToggle: HotKey?
    private(set) var toggleProblem: String?

    init(settings: AppSettings, coordinator: PanelCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
    }

    func apply() {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        effectiveToggle = nil
        toggleProblem = nil
        if let wanted = settings.toggleHotKey {
            do {
                try center.register(wanted) { [weak self] in self?.coordinator.toggle() }
                effectiveToggle = wanted
            } catch {
                toggleProblem = error.localizedDescription
                Log.input.error("toggle hotkey failed: \(error.localizedDescription)")
                if wanted != .fallbackToggle, (try? center.register(.fallbackToggle) { [weak self] in self?.coordinator.toggle() }) != nil {
                    effectiveToggle = .fallbackToggle
                    toggleProblem = "\(wanted.displayString) is taken by another app; using \(HotKey.fallbackToggle.displayString) instead."
                }
            }
        }
        for (section, hotKey) in settings.sectionHotKeys {
            do { try center.register(hotKey) { [weak self] in self?.coordinator.open(section: section) } }
            catch { Log.input.error("section hotkey \(section.rawValue) failed: \(error.localizedDescription)") }
        }
    }
}
