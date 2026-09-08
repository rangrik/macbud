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
    let dictationHistoryStore: DictationHistoryStore
    let dictationWordStore: DictationWordStore
    let dictationHistory: DictationHistorySectionController
    let appIndex: AppIndex
    let apps: AppsSectionController
    let windowPreviews: WindowPreviewCache
    private(set) var isHoldingToTalk = false
    private(set) var dictationSessionHotKey: HotKey?
    let keepAwake = KeepAwakeController()
    /// Set by the app once hotkeys are bound; used by the welcome screen and footer.
    var hotKeys: HotKeyBinder?
    /// Whether Settings was already showing when the island opened (see `didClose`).
    @ObservationIgnored private var settingsVisibleAtOpen = false

    init(state: NotchState, notch: NotchController, settings: AppSettings,
         clipboardStore: ClipboardStore, snippetStore: SnippetStore, library: ScreenshotLibrary,
         appIndex: AppIndex = AppIndex()) {
        self.state = state
        self.notch = notch
        self.settings = settings
        self.clipboardStore = clipboardStore
        self.snippetStore = snippetStore
        self.library = library
        self.appIndex = appIndex
        context = ActionContext(state: state, notch: notch, settings: settings, frontmost: frontmost)
        clipboard = ClipboardSectionController(store: clipboardStore, context: context)
        snippets = SnippetsSectionController(store: snippetStore, clipboard: clipboardStore, context: context)
        screenshots = ScreenshotsSectionController(library: library, context: context)
        dictationHistoryStore = DictationHistoryStore(dataStore: snippetStore.dataStore)
        dictationWordStore = DictationWordStore(dataStore: snippetStore.dataStore)
        dictationHistory = DictationHistorySectionController(store: dictationHistoryStore, context: context, snippets: snippets)
        dictation = DictationController(settings: settings, context: context, clipboard: clipboardStore,
                                        history: dictationHistoryStore, words: dictationWordStore)
        let previews = WindowPreviewCache()
        windowPreviews = previews
        apps = AppsSectionController(index: appIndex, context: context, previews: previews)
        clipboard.snippets = snippets
        dictation.onDidEnd = { [weak self] in self?.notch.close() }
        dictation.onActivityChanged = { [weak self] active in
            guard let self else { return }
            if !active { isHoldingToTalk = false }
            hotKeys?.dictationActivityChanged(active)
        }
    }

    var showsWelcome: Bool { !settings.hasSeenWelcome }
    var hasEnabledSection: Bool { settings.isEnabled(state.section.feature) }

    func applyFeatureSettings() {
        if !settings.isEnabled(.dictation), dictation.isActive { dictation.cancel() }
        if !settings.isEnabled(.keepAwake), keepAwake.isActive { keepAwake.stop() }
        if !settings.isEnabled(.snippets), snippets.isEditing { snippets.cancelEditing() }
        if !hasEnabledSection {
            if let first = settings.enabledSections.first { state.section = first; settings.lastSection = first }
            state.query = ""
            state.footerHint = nil
            activeDidShow()
        }
    }

    // MARK: Opening

    func open(section: Section? = nil) {
        if let section, !settings.isEnabled(section.feature) { return }
        if dictation.isActive { dictation.cancel() }
        let preferred = settings.rememberLastSection ? settings.lastSection : (settings.enabledSections.first ?? .clipboard)
        let target = section ?? (settings.isEnabled(preferred.feature) ? preferred : settings.enabledSections.first)
        notch.open(section: target)
    }

    func toggle() {
        if state.isOpen { notch.close() } else { open() }
    }

    /// Global dictation hotkey: start recording; pressing it again while recording delivers the text.
    func startDictation(trigger: HotKey? = nil) {
        guard settings.isEnabled(.dictation) else { return }
        if dictation.isActive {
            if dictation.canRetry { dictation.retry() }
            else { dictation.finish(.insert) }
            return
        }
        isHoldingToTalk = false
        dictationSessionHotKey = trigger ?? settings.dictationHotKey
        beginDictation()
    }

    func startHoldToTalk() {
        guard settings.isEnabled(.dictation), !dictation.isActive else { return }
        isHoldingToTalk = true
        dictationSessionHotKey = settings.holdToTalkHotKey
        beginDictation()
    }

    func endHoldToTalk() {
        guard isHoldingToTalk, dictation.isActive else { return }
        dictation.finish(.insert)
    }

    private func beginDictation() {
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
        applyFeatureSettings()
        frontmost.capture()
        context.clearHint()
        settingsVisibleAtOpen = Self.settingsWindow != nil
        activeDidShow()
    }

    static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NotchPanel) && !($0 is NotchBaseWindow) }
    }

    func select(_ section: Section) {
        guard settings.isEnabled(section.feature), section != state.section else { return }
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
        case .dictationHistory: dictationHistory.queryChanged()
        case .apps: apps.queryChanged()
        }
    }

    private func activeDidShow() {
        switch state.section {
        case .clipboard: clipboard.didShow()
        case .snippets: snippets.didShow()
        case .screenshots: screenshots.didShow()
        case .dictationHistory: dictationHistory.didShow()
        case .apps: apps.didShow()
        }
    }

    // MARK: Key handling

    func handle(event: NSEvent) -> Bool {
        guard let command = KeyRouter.command(for: event, bindings: settings.keyBindings) else { return false }
        if command == .startDictation, !state.isDictating, !snippets.isEditing {
            startDictation(trigger: HotKey(keyCode: event.keyCode, modifiers: event.modifierFlags))
            return true
        }
        return handle(command)
    }

    @discardableResult
    func handle(_ command: PanelCommand) -> Bool {
        if state.isDictating {
            switch command {
            case .close:
                // Escape leaves the transcript you are editing before it cancels the recording.
                if dictation.isEditingTranscript { dictation.commitEdit(nil) } else { dictation.cancel() }
            case .startDictation:
                if dictation.canRetry { dictation.retry() } else { dictation.finish(.insert) }
            default: return false
            }
            return true
        }
        if showsWelcome {
            switch command {
            case .close: notch.close()
            case .primaryAction, .secondaryAction, .nextSection, .selectSectionAt: settings.hasSeenWelcome = true
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
            let sections = settings.enabledSections
            guard let index = sections.firstIndex(of: state.section), !sections.isEmpty else { return true }
            let offset = command == .nextSection ? 1 : sections.count - 1
            select(sections[(index + offset) % sections.count])
            return true
        case .selectSectionAt(let index):
            let sections = settings.enabledSections
            if sections.indices.contains(index) { select(sections[index]) }
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
        guard hasEnabledSection else { return false }
        if command == .saveAsSnippet, !settings.isEnabled(.snippets) { return false }
        return switch state.section {
        case .clipboard: clipboard.handle(command)
        case .snippets: snippets.handle(command)
        case .screenshots: screenshots.handle(command)
        case .dictationHistory: dictationHistory.handle(command)
        case .apps: apps.handle(command)
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
        var systemImage: String?
        var id: String { keys + label }
    }

    /// Display string of the first chord bound to a command (reflects the user's custom bindings).
    func keys(for command: BindableCommand) -> String {
        settings.keyBindings.chords(for: command).first?.displayString ?? "—"
    }

    /// The chord that opens the tab at this position, for tab tooltips. Positions past the last
    /// slot (or with no chord bound) have none.
    func sectionShortcut(at index: Int) -> String? {
        guard let slot = BindableCommand.sectionSlot(at: index) else { return nil }
        return settings.keyBindings.chords(for: slot).first?.displayString
    }

    private func hint(_ command: BindableCommand, _ label: String, systemImage: String? = nil) -> Hint {
        Hint(keys: keys(for: command), label: label, command: command.panelCommand, systemImage: systemImage)
    }

    func footerHints() -> [Hint] {
        guard hasEnabledSection else { return [] }
        let app = frontmost.previousAppName ?? "app"
        let enterCopies = settings.enterAction == .copy
        let copy: BindableCommand = enterCopies ? .primaryAction : .secondaryAction
        let paste: BindableCommand = enterCopies ? .secondaryAction : .primaryAction
        var hints: [Hint] = []
        switch state.section {
        case .clipboard:
            hints = [hint(copy, "Copy", systemImage: "doc.on.doc"), hint(paste, "Paste to \(app)"),
                     hint(.togglePin, clipboard.selected?.isPinned == true ? "Unpin" : "Pin"),
                     hint(.saveAsSnippet, "Snippet"), hint(.delete, "Delete")]
        case .snippets:
            if snippets.isEditing {
                hints = [hint(.saveAsSnippet, "Save"), Hint(keys: "⇥", label: "Next field", command: nil), hint(.close, "Cancel")]
            } else {
                hints = [hint(copy, "Copy", systemImage: "doc.on.doc"), hint(paste, "Paste to \(app)"), hint(.newItem, "New"), hint(.editItem, "Edit"), hint(.delete, "Delete")]
            }
        case .screenshots:
            hints = [hint(copy, "Copy", systemImage: "doc.on.doc"), hint(paste, "Paste to \(app)"), hint(.quickLook, "Quick Look"),
                     hint(.revealInFinder, "Finder"), hint(.delete, "Trash")]
        case .dictationHistory:
            hints = [hint(copy, "Copy", systemImage: "doc.on.doc"), hint(paste, "Insert"), hint(.saveAsSnippet, "Save as snippet"), hint(.delete, "Delete")]
        case .apps:
            let target = apps.selected
            let verb = target?.windowID != nil ? "Switch to window" : target?.isRunning == true ? "Switch to app" : "Open app"
            hints = [hint(.primaryAction, verb, systemImage: "arrow.up.forward.app"),
                     Hint(keys: "↑↓←→", label: "Move", command: nil)]
        }
        if !snippets.isEditing { hints.append(hint(.nextSection, "Section")) }
        return hints.filter { $0.command != .saveAsSnippet || settings.isEnabled(.snippets) }
    }

    // MARK: Automation

    func dump() -> [String: Any] {
        var d: [String: Any] = [
            "phase": state.isDictating ? "dictation" : state.isExpanded ? "expanded" : "collapsed",
            "panelVisible": notch.panel.isVisible,
            "panelKey": notch.panel.isKeyWindow,
            "accessibilityTrusted": Paster.isAccessibilityTrusted,
            "focusedEditableInput": FocusedTextTarget.capture() != nil,
            "panelFrame": ["x": notch.panel.frame.minX, "y": notch.panel.frame.minY, "width": notch.panel.frame.width, "height": notch.panel.frame.height],
            "holdingToTalk": isHoldingToTalk,
            "dictation": ["phase": String(describing: dictation.phase), "transcript": dictation.transcript, "canRetry": dictation.canRetry],
            "keepAwake": ["active": keepAwake.isActive, "error": keepAwake.errorMessage ?? ""],
            "section": state.section.rawValue,
            "enabledSections": settings.enabledSections.map(\.rawValue),
            "disabledFeatures": settings.disabledFeatures.map(\.rawValue).sorted(),
            "query": state.query,
            "footerHint": state.footerHint ?? "",
            "welcome": showsWelcome,
            "toast": state.toast?.title ?? "",
            "launchAtLogin": settings.launchAtLogin,
            "installedInApplications": AppDelegate.isInstalledInApplications,
            "bundlePath": Bundle.main.bundleURL.path,
            "showsTab": notch.showsTab,
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            "tabPlan": {
                let sections = settings.enabledSections
                let side = (state.metrics.islandSize.width - state.geometry.notchRect.width) / 2
                let plan = SectionTabLayout.plan(sections, selected: state.section, leftWidth: side - 14,
                                                 rightWidth: side - 18 - state.headerStatusWidth - 10)
                return ["left": plan.left.map(\.rawValue), "right": plan.right.map(\.rawValue),
                        "showsLabel": plan.showsLabel, "sideWidth": side,
                        "headerStatusWidth": state.headerStatusWidth]
            }(),
            "sectionHotKeys": Dictionary(uniqueKeysWithValues: settings.sectionHotKeys.map { ($0.key.rawValue, $0.value.displayString) }),
            "registeredSectionHotKeys": Dictionary(uniqueKeysWithValues: (hotKeys?.registeredSectionHotKeys ?? [:]).map { ($0.key.rawValue, $0.value.displayString) }),
            "sectionHotKeyProblems": Dictionary(uniqueKeysWithValues: (hotKeys?.sectionProblems ?? [:]).map { ($0.key.rawValue, $0.value) }),
            "activeDisplay": notch.state.geometry.displayID,
            "displays": notch.screens.map { screen in
                ["id": screen.displayID, "active": screen.isActive, "physicalNotch": screen.geometry.hasPhysicalNotch,
                 "visible": screen.window.isVisible,
                 "notch": ["x": screen.window.frame.minX, "y": screen.window.frame.minY,
                           "width": screen.window.frame.width, "height": screen.window.frame.height]]
            },
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
        case .dictationHistory:
            d["selectedIndex"] = dictationHistory.selectedIndex
            d["results"] = dictationHistory.results.prefix(20).map(\.text)
            d["selected"] = dictationHistory.selected?.text ?? ""
        case .apps:
            let grid = apps.grid
            d["selectedIndex"] = apps.selectedIndex
            d["results"] = grid.items.prefix(30).map(\.displayName)
            d["selected"] = apps.selected?.displayName ?? ""
            d["selectedWindow"] = apps.selected?.windowID ?? ""
            d["appGroups"] = grid.groups.map { ["title": $0.title, "items": $0.items.map(\.displayName)] }
            d["openWindows"] = apps.windows.map { ["app": $0.appName, "title": $0.shortTitle, "id": $0.id, "focused": $0.isFocused] }
            d["installedApps"] = appIndex.installed.count
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
    private(set) var dictationProblem: String?
    private(set) var holdToTalkProblem: String?
    private(set) var sectionProblems: [Section: String] = [:]
    private(set) var registeredSectionHotKeys: [Section: HotKey] = [:]
    private var escapeID: UInt32?
    private var sessionTriggerID: UInt32?
    private let escapeMonitor = DictationEscapeMonitor()

    init(settings: AppSettings, coordinator: PanelCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
    }

    func apply() {
        let center = HotKeyCenter.shared
        // Rebinding while held must not lose the release and leave the microphone running.
        if coordinator.isHoldingToTalk { coordinator.endHoldToTalk() }
        center.unregisterAll()
        escapeID = nil
        sessionTriggerID = nil
        effectiveToggle = nil
        toggleProblem = nil
        dictationProblem = nil
        holdToTalkProblem = nil
        sectionProblems = [:]
        registeredSectionHotKeys = [:]
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
        for (section, hotKey) in settings.sectionHotKeys where settings.isEnabled(section.feature) {
            do {
                try center.register(hotKey) { [weak self] in self?.coordinator.open(section: section) }
                registeredSectionHotKeys[section] = hotKey
            } catch {
                sectionProblems[section] = error.localizedDescription
                Log.input.error("section hotkey \(section.rawValue) failed: \(error.localizedDescription)")
            }
        }
        if settings.isEnabled(.dictation), let hotKey = settings.dictationHotKey {
            do { try center.register(hotKey) { [weak self] in self?.coordinator.startDictation(trigger: hotKey) } }
            catch { dictationProblem = error.localizedDescription }
        }
        if settings.isEnabled(.dictation), let hotKey = settings.holdToTalkHotKey {
            do {
                try center.register(hotKey, onRelease: { [weak self] in self?.coordinator.endHoldToTalk() }) { [weak self] in
                    self?.coordinator.startHoldToTalk()
                }
            } catch { holdToTalkProblem = error.localizedDescription }
        }
        dictationActivityChanged(coordinator.dictation.isActive)
    }

    func dictationActivityChanged(_ active: Bool) {
        let center = HotKeyCenter.shared
        escapeMonitor.stop()
        if let escapeID { center.unregister(id: escapeID) }
        if let sessionTriggerID { center.unregister(id: sessionTriggerID) }
        escapeID = nil
        sessionTriggerID = nil
        guard active else { return }
        escapeMonitor.start { [weak self] in
            guard let dictation = self?.coordinator.dictation else { return }
            // While a word is open for correction, Escape backs out of the word, not the recording.
            if dictation.isEditingTranscript { dictation.commitEdit(nil) } else { dictation.cancel() }
        }
        do {
            escapeID = try center.register(HotKey(keyCode: 53, modifiers: [])) { [weak self] in
                self?.coordinator.dictation.cancel()
            }
            if let trigger = coordinator.dictationSessionHotKey, trigger.isUsableGlobally,
               trigger != settings.dictationHotKey, trigger != settings.holdToTalkHotKey {
                sessionTriggerID = try center.register(trigger) { [weak self] in self?.coordinator.startDictation() }
            }
        } catch { dictationProblem = error.localizedDescription }
    }
}
