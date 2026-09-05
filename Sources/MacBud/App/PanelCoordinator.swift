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
    let dictation: DictationController
    /// Set by the app once hotkeys are bound; used by the welcome screen and footer.
    var hotKeys: HotKeyBinder?
    /// Whether Settings was already showing when the island opened (see `didClose`).
    @ObservationIgnored private var settingsVisibleAtOpen = false

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
        dictation = DictationController(settings: settings, context: context, clipboard: clipboardStore)
        clipboard.snippets = snippets
        dictation.onDidEnd = { [weak self] in self?.notch.close() }
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
        if state.isOpen { notch.close() } else { open() }
    }

    /// Global dictation hotkey: start recording; pressing it again while recording delivers the text.
    func startDictation() {
        if state.isDictating {
            if dictation.phase == .recording { dictation.finish(paste: settings.enterAction == .paste) }
            return
        }
        frontmost.capture()
        context.clearHint()
        notch.openDictation()
        dictation.start()
    }

    /// Called by the notch controller whenever the island collapses, for any reason.
    ///
    /// Also the moment Settings appears from the island (⌘, is handled by the app menu, which takes key
    /// focus away from the panel). MacBud is a background app, so macOS may refuse to activate it and the
    /// new window would sit behind the app the user was in; order it front regardless.
    func didClose() {
        if dictation.isActive { dictation.cancel() }
        guard !settingsVisibleAtOpen else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<15 {
                if let self, let window = Self.settingsWindow {
                    settingsVisibleAtOpen = true
                    window.orderFrontRegardless()
                    NSApp.activate()
                    window.makeKey()
                    Trace.log("settings window ordered front: \(window.title) active=\(NSApp.isActive)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Called by the notch controller right before the island appears.
    func willOpen() {
        frontmost.capture()
        context.clearHint()
        settingsVisibleAtOpen = Self.settingsWindow != nil
        activeDidShow()
    }

    static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NotchPanel) && !($0 is NotchBaseWindow) }
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
        guard let command = KeyRouter.command(for: event, bindings: settings.keyBindings) else { return false }
        return handle(command)
    }

    @discardableResult
    func handle(_ command: PanelCommand) -> Bool {
        if state.isDictating {
            switch command {
            case .close: dictation.cancel()
            case .primaryAction:
                if case .failed = dictation.phase { dictation.start() } else { dictation.finish(paste: context.wantsPaste(for: command)) }
            case .secondaryAction: dictation.finish(paste: context.wantsPaste(for: command))
            case .startDictation: dictation.finish(paste: settings.enterAction == .paste)
            default: break
            }
            return true
        }
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
        case .startDictation:
            if snippets.isEditing { return false }
            startDictation()
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

    /// Opens the Settings window the same way the app menu's "Settings…" item does (the only path SwiftUI
    /// reliably honours). When ⌘, itself is pressed in the island, the main menu handles it before the panel
    /// sees the key; `AppDelegate` then brings the window to the front, since a background app may not
    /// be allowed to activate itself.
    func openSettings() {
        notch.close()
        NSApp.activate()
        if let (menu, index) = Self.settingsMenuItem {
            menu.performActionForItem(at: index)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    private static var settingsMenuItem: (NSMenu, Int)? {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            if let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
                return (menu, index)
            }
        }
        return nil
    }

    // MARK: Footer

    /// A footer hint. Clicking it runs the command, so mouse users get the same actions.
    struct Hint: Identifiable {
        let keys: String
        let label: String
        let command: PanelCommand?
        var id: String { keys + label }
    }

    /// Display string of the first chord bound to a command (reflects the user's custom bindings).
    func keys(for command: BindableCommand) -> String {
        settings.keyBindings.chords(for: command).first?.displayString ?? "—"
    }

    private func hint(_ command: BindableCommand, _ label: String) -> Hint {
        Hint(keys: keys(for: command), label: label, command: command.panelCommand)
    }

    func footerHints() -> [Hint] {
        let app = frontmost.previousAppName ?? "app"
        let enterCopies = settings.enterAction == .copy
        let copy: BindableCommand = enterCopies ? .primaryAction : .secondaryAction
        let paste: BindableCommand = enterCopies ? .secondaryAction : .primaryAction
        var hints: [Hint] = []
        switch state.section {
        case .clipboard:
            hints = [hint(copy, "Copy"), hint(paste, "Paste to \(app)"),
                     hint(.togglePin, clipboard.selected?.isPinned == true ? "Unpin" : "Pin"),
                     hint(.saveAsSnippet, "Snippet"), hint(.delete, "Delete")]
        case .snippets:
            if snippets.isEditing {
                hints = [hint(.saveAsSnippet, "Save"), Hint(keys: "⇥", label: "Next field", command: nil), hint(.close, "Cancel")]
            } else {
                hints = [hint(copy, "Copy"), hint(paste, "Paste to \(app)"), hint(.newItem, "New"), hint(.editItem, "Edit"), hint(.delete, "Delete")]
            }
        case .screenshots:
            hints = [hint(copy, "Copy"), hint(paste, "Paste to \(app)"), hint(.quickLook, "Quick Look"),
                     hint(.revealInFinder, "Finder"), hint(.delete, "Trash")]
        }
        if !snippets.isEditing { hints.append(hint(.nextSection, "Section")) }
        return hints
    }

    // MARK: Automation

    func dump() -> [String: Any] {
        var d: [String: Any] = [
            "phase": state.isDictating ? "dictation" : state.isExpanded ? "expanded" : "collapsed",
            "dictation": ["phase": String(describing: dictation.phase), "transcript": dictation.transcript],
            "section": state.section.rawValue,
            "query": state.query,
            "footerHint": state.footerHint ?? "",
            "welcome": showsWelcome,
            "toast": state.toast?.title ?? "",
            "launchAtLogin": settings.launchAtLogin,
            "installedInApplications": AppDelegate.isInstalledInApplications,
            "bundlePath": Bundle.main.bundleURL.path,
            "showsTab": notch.showsTab,
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
        if let hotKey = settings.dictationHotKey {
            do { try center.register(hotKey) { [weak self] in self?.coordinator.startDictation() } }
            catch { Log.input.error("dictation hotkey failed: \(error.localizedDescription)") }
        }
    }
}
