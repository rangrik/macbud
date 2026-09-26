import AppKit

/// Opens the shelf and the island, routes key commands, and owns everything their views need.
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
    let shelf: ShelfController
    let appIndex: AppIndex
    let apps: AppsSectionController
    let windowPreviews: WindowPreviewCache
    let predictor: SectionPredictor
    private(set) var isHoldingToTalk = false
    private(set) var dictationSessionHotKey: HotKey?
    let keepAwake = KeepAwakeController()
    let clock = ClockController()
    /// Set by the app once hotkeys are bound; used by the welcome screen and footer.
    var hotKeys: HotKeyBinder?
    /// Whether Settings was already showing when the island opened (see `didClose`).
    @ObservationIgnored private var settingsVisibleAtOpen = false
    /// When the toggle hotkey opened the shelf, so letting go after a hold can close it again.
    @ObservationIgnored private var peekStarted: ContinuousClock.Instant?
    /// Whether this open has read the windows All searches.
    @ObservationIgnored private var appsLoaded = false
    static let peekHold: Duration = .milliseconds(350)

    init(state: NotchState, notch: NotchController, settings: AppSettings,
         clipboardStore: ClipboardStore, snippetStore: SnippetStore, library: ScreenshotLibrary,
         appIndex: AppIndex = AppIndex(), runner: any ModelRunner = CodexRunner(), shadow: (any ModelRunner)? = JevRunner()) {
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
        shelf = ShelfController(state: state, settings: settings, clipboard: clipboard, screenshots: screenshots,
                                dictations: dictationHistory, snippets: snippets, apps: apps)
        predictor = SectionPredictor(settings: settings, memory: DataStore(directory: snippetStore.dataStore.directory.appendingPathComponent("predict")),
                                     runner: runner, shadow: shadow) { [dictationHistoryStore] in
            PredictionContext.capture(clipboard: clipboardStore.items, media: library.items, dictations: dictationHistoryStore.items,
                                      app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                      running: AppIndex.runningInFrontToBackOrder().compactMap(\.bundleIdentifier), kinds: settings.visibleKinds)
        }
        clipboard.snippets = snippets
        context.onUse = { [weak self] action, outcome in
            guard let self else { return }
            predictor.noteAction(action, outcome: outcome, in: place)
        }
        dictation.onDidEnd = { [weak self] in self?.notch.close() }
        dictation.onActivityChanged = { [weak self] active in
            guard let self else { return }
            if !active { isHoldingToTalk = false }
            hotKeys?.dictationActivityChanged(active)
        }
        notch.onTabClick = { [weak self] screen in self?.openShelf(on: screen) }
        notch.onHoverOpen = { [weak self] screen in self?.openShelf(on: screen, focus: false) }
    }

    var showsWelcome: Bool { !settings.hasSeenWelcome }
    /// False only when every feature that shows items is off.
    var hasContent: Bool { !settings.visibleChips.isEmpty }
    /// Where the owner is acting, as the prediction log names it.
    private var place: String { state.isShelf ? "shelf" : state.chip.rawValue }

    /// The time to show, or nil when the Clock feature is off.
    var clockText: String? { settings.isEnabled(.clock) ? clock.text : nil }

    func applyClockSettings() {
        let on = settings.isEnabled(.clock)
        clock.setEnabled(on)
        state.clockText = clockText
        state.metrics.tabExtension = on ? NotchMetrics.clockTabExtension : NotchMetrics.plainTabExtension
    }

    func applyFeatureSettings() {
        if !settings.isEnabled(.dictation), dictation.isActive { dictation.cancel() }
        if !settings.isEnabled(.keepAwake), keepAwake.isActive { keepAwake.stop() }
        applyClockSettings()
        if !settings.isEnabled(.snippets), snippets.isEditing { snippets.cancelEditing() }
        if !settings.visibleChips.contains(state.chip) {
            state.chip = settings.visibleChips.first ?? .all
            state.query = ""
            state.footerHint = nil
            shelf.select(nil)
        }
    }

    // MARK: Opening

    /// A plain open (hotkey, tab click, hover) lands where the prediction says, and is scored.
    func openShelf(on screen: ScreenNotch? = nil, focus: Bool = true) {
        if dictation.isActive { dictation.cancel() }
        // The welcome and "choose your features" screens live in the island, which a hover must not open.
        guard hasContent, !showsWelcome else {
            if focus { prepareToOpen(); notch.open(.expanded, on: screen) }
            return
        }
        // With only Apps on there is nothing to put on the shelf.
        if settings.visibleChips == [.apps] {
            if focus { open(chip: .apps) }
            return
        }
        let started = ContinuousClock.now
        prepareToOpen()
        func landing(_ intent: LandingIntent?) -> Landing {
            shelf.suggested = apps.suggestion(for: intent)
            let recents = shelf.recents
            let landing = Shelf.landing(for: intent, recents: recents)
            return landing.expanded && !focus ? Landing(card: recents.first?.id) : landing
        }
        // Once only: naming an app reads every open window.
        var landed = landing(nil)
        if settings.prediction.enabled { _ = predictor.intentForOpen { landed = landing($0); return landed.place } }
        state.chip = landed.chip
        notch.open(landed.expanded ? .expanded : .shelf, focus: focus, on: screen)
        shelf.select(landed.card)
        if state.chip == .apps { apps.didShow() }
        Trace.log("plain open \(landed.place) focus=\(focus) took=\(ContinuousClock.now - started)")
    }

    /// Per-chip hotkeys and menu items go straight to the island on that chip. Not scored.
    func open(chip: Chip) {
        guard settings.visibleChips.contains(chip) else { return }
        if dictation.isActive { dictation.cancel() }
        if !state.isOpen {
            prepareToOpen()
            notch.open(.expanded)
        } else if state.isShelf {
            notch.expand()
        }
        select(chip)
    }

    /// The toggle hotkey. A shelf opened by hover takes the keys; anything else open closes.
    func toggle() {
        peekStarted = nil
        if state.isShelf, !notch.panel.isKeyWindow { notch.focusShelf(); return }
        if state.isOpen { notch.close(); return }
        openShelf()
        peekStarted = .now
    }

    /// Letting go of the hotkey after holding it closes the shelf it opened: a peek.
    func toggleReleased() {
        guard let started = peekStarted else { return }
        peekStarted = nil
        if state.isShelf, ContinuousClock.now - started >= Self.peekHold { notch.close() }
    }

    /// Shelf to island. ↓ and the Search everything chip land on the first Earlier row.
    func expand() {
        guard state.isShelf else { return }
        notch.expand()
        shelf.selectFirstRow()
    }

    private func prepareToOpen() {
        applyFeatureSettings()
        frontmost.capture()
        context.clearHint()
        clipboard.cancelClearAll()
        if snippets.isEditing { snippets.cancelEditing() }
        settingsVisibleAtOpen = Self.settingsWindow != nil
        // Folder watchers miss subfolders and folders that appear later; the old Screenshots tab rescanned on show.
        if settings.isEnabled(.screenshots), library.lastScan.map({ Date.now.timeIntervalSince($0) > 30 }) ?? true {
            library.requestRescan(delay: .zero)
        }
        state.query = ""
        state.chip = settings.visibleChips.first ?? .all
        shelf.suggested = nil
        appsLoaded = false
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
        peekStarted = nil
        predictor.sessionEnded()
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

    static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NotchPanel) && !($0 is NotchBaseWindow)
            && $0.identifier != PredictionActivityWindow.id }
    }

    /// Chips filter; they keep the query, so a search can be narrowed after it is typed.
    func select(_ chip: Chip) {
        guard settings.visibleChips.contains(chip) else { return }
        if snippets.isEditing { snippets.cancelEditing() }
        state.chip = chip
        state.wantsSearchFocus = true
        context.clearHint()
        if chip == .apps { apps.didShow() } else { loadAppsForSearch(); shelf.selectFirstRow() }
    }

    func queryChanged() {
        if state.chip == .apps { apps.queryChanged() } else { loadAppsForSearch(); shelf.selectFirstRow() }
    }

    /// All searches windows too. Reading them is slow, so it waits for the first search of an open.
    private func loadAppsForSearch() {
        guard !appsLoaded, state.chip == .all, !state.query.isEmpty, settings.visibleKinds.contains(.app) else { return }
        appsLoaded = true
        apps.load()
    }

    // MARK: Key handling

    func handle(event: NSEvent) -> Bool {
        guard let command = KeyRouter.command(for: event, bindings: settings.keyBindings) else {
            return typeIntoSearch(event)
        }
        if command == .startDictation, !state.isDictating, !snippets.isEditing {
            startDictation(trigger: HotKey(keyCode: event.keyCode, modifiers: event.modifierFlags))
            return true
        }
        return handle(command)
    }

    /// Typing on the shelf opens the island with the search started. Keys that arrive before the
    /// search field has focus would be lost, so they go into the query too.
    private func typeIntoSearch(_ event: NSEvent) -> Bool {
        let fieldReady = notch.panel.firstResponder is NSTextView
        guard state.isShelf || (state.isExpanded && !fieldReady && !showsWelcome && !snippets.isEditing),
              event.modifierFlags.intersection([.command, .control]).isEmpty,
              let text = event.characters, text.contains(where: { !$0.isWhitespace && !$0.isNewline }) || !state.query.isEmpty,
              // Arrows and function keys arrive as private-use characters.
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
        else { return false }
        expand()
        state.query += text
        queryChanged()
        return true
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
            case .primaryAction, .secondaryAction, .nextChip, .selectChip: settings.hasSeenWelcome = true
            default: break
            }
            return true
        }
        if state.isShelf {
            switch command {
            case .moveDown: expand(); return true
            case .nextChip, .previousChip, .selectChip: expand()
            // These show an editor or a warning the shelf has no room for; the card stays selected.
            case .newItem, .editItem, .saveAsSnippet, .clearAll: notch.expand()
            default: break
            }
        }
        switch command {
        case .close:
            if shelf.handle(.close) { return true }
            notch.close()
            return true
        case .nextChip, .previousChip:
            // While editing a snippet, ⇥ moves between fields instead.
            if snippets.isEditing { return false }
            let chips = settings.visibleChips
            guard !chips.isEmpty else { return true }
            let index = chips.firstIndex(of: state.chip) ?? 0
            select(chips[(index + (command == .nextChip ? 1 : chips.count - 1)) % chips.count])
            return true
        case .selectChip(let chip):
            if snippets.isEditing { return false }
            select(chip)
            return true
        case .openSettings:
            if snippets.isEditing { return false }
            openSettings()
            return true
        case .openPredictionActivity:
            if snippets.isEditing { return false }
            openPredictionActivity()
            return true
        case .startDictation:
            if snippets.isEditing { return false }
            startDictation()
            return true
        default:
            guard hasContent else { return false }
            if state.isExpanded, state.chip == .apps { return appsHandle(command) }
            switch command {
            case .primaryAction, .secondaryAction, .delete, .togglePin, .saveAsSnippet, .editItem, .revealInFinder, .quickLook:
                // Before acting: acting may close the island, which ends the session.
                if let outcome = shelf.selectedOutcome { predictor.noteAction(String(describing: command), outcome: outcome, in: place) }
            default: break
            }
            return shelf.handle(command)
        }
    }

    private func appsHandle(_ command: PanelCommand) -> Bool {
        if command == .primaryAction || command == .secondaryAction, let entry = apps.selected {
            predictor.noteAction(String(describing: command), outcome: .app(entry, switchTarget: apps.switchTarget), in: place)
        }
        return apps.handle(command)
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

    func openPredictionActivity() {
        notch.close()
        PredictionActivityWindow.show(predictor: predictor, settings: settings)
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

    // MARK: Hints

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

    /// The chord that jumps to a chip, for its tooltip.
    func chipShortcut(_ chip: Chip) -> String? {
        guard let index = Chip.allCases.firstIndex(of: chip) else { return nil }
        return settings.keyBindings.chords(for: BindableCommand.chipSlots[index]).first?.displayString
    }

    private func hint(_ command: BindableCommand, _ label: String, systemImage: String? = nil) -> Hint {
        Hint(keys: keys(for: command), label: label, command: command.panelCommand, systemImage: systemImage)
    }

    /// Return and ⌘Return, labelled for what they do to this kind of item. Both switch to an app, so it gets one.
    func useHints(for item: ShelfItem?) -> [Hint] {
        if case .app(let entry) = item { return [hint(.primaryAction, entry.verb, systemImage: "arrow.up.forward.app")] }
        let app = frontmost.previousAppName ?? "app"
        let paste = item.map { if case .dictation = $0 { "Insert" } else { "Paste to \(app)" } } ?? "Paste to \(app)"
        let copy = hint(.primaryAction, "Copy", systemImage: "doc.on.doc")
        return settings.enterAction == .copy
            ? [copy, hint(.secondaryAction, paste)]
            : [hint(.primaryAction, paste), hint(.secondaryAction, "Copy", systemImage: "doc.on.doc")]
    }

    func footerHints() -> [Hint] {
        guard hasContent else { return [] }
        if state.chip == .apps {
            return [hint(.primaryAction, apps.selected?.verb ?? "Open app", systemImage: "arrow.up.forward.app"),
                    Hint(keys: "↑↓←→", label: "Move", command: nil), hint(.nextChip, "Filter")]
        }
        if snippets.isEditing {
            return [hint(.saveAsSnippet, "Save"), Hint(keys: "⇥", label: "Next field", command: nil), hint(.close, "Cancel")]
        }
        let item = shelf.selected
        var hints = useHints(for: item)
        switch item {
        case .clip(let clip):
            if clip.kind == .image || clip.kind == .file { hints.append(hint(.quickLook, "Quick Look")) }
            hints += [hint(.togglePin, clip.isPinned ? "Unpin" : "Pin")]
            if clip.text != nil { hints.append(hint(.saveAsSnippet, "Snippet")) }
            hints.append(hint(.delete, "Delete"))
        case .media:
            hints += [hint(.quickLook, "Quick Look"), hint(.revealInFinder, "Finder"), hint(.delete, "Trash")]
        case .dictation:
            hints += [hint(.saveAsSnippet, "Snippet"), hint(.delete, "Delete")]
        case .snippet:
            hints += [hint(.editItem, "Edit"), hint(.newItem, "New"), hint(.delete, "Delete")]
        case .app: break
        case nil:
            if state.chip == .snippets { hints = [hint(.newItem, "New snippet")] } else { hints = [] }
        }
        hints.append(hint(.nextChip, "Filter"))
        return hints.filter { ($0.command != .saveAsSnippet && $0.command != .newItem) || settings.isEnabled(.snippets) }
    }

    // MARK: Automation

    func dump() -> [String: Any] {
        func describe(_ item: ShelfItem) -> [String: Any] { ["id": item.id, "kind": item.kind.rawValue, "title": item.title] }
        let layout = shelf.layout
        var d: [String: Any] = [
            "phase": String(describing: state.phase),
            "panelVisible": notch.panel.isVisible,
            "panelKey": notch.panel.isKeyWindow,
            "accessibilityTrusted": Paster.isAccessibilityTrusted,
            "focusedEditableInput": FocusedTextTarget.capture() != nil,
            "panelFrame": ["x": notch.panel.frame.minX, "y": notch.panel.frame.minY, "width": notch.panel.frame.width, "height": notch.panel.frame.height],
            "holdingToTalk": isHoldingToTalk,
            "dictation": ["phase": String(describing: dictation.phase), "transcript": dictation.transcript, "canRetry": dictation.canRetry],
            "keepAwake": ["active": keepAwake.isActive, "error": keepAwake.errorMessage ?? ""],
            "chip": state.chip.rawValue,
            "visibleChips": settings.visibleChips.map(\.rawValue),
            "shelf": shelf.recents.map(describe),
            "cards": layout.cards.map(describe),
            "rows": layout.rows.prefix(20).map(describe),
            "rowCount": layout.rows.count,
            "selected": shelf.selected.map(describe) ?? [:],
            "editing": snippets.isEditing,
            "draft": ["name": snippets.draft.name, "keyword": snippets.draft.keyword, "content": snippets.draft.content],
            "footer": footerHints().map { "\($0.keys) \($0.label)" },
            "prediction": predictor.dump(),
            "disabledFeatures": settings.disabledFeatures.map(\.rawValue).sorted(),
            "opensShelfOnHover": settings.opensShelfOnHover,
            "query": state.query,
            "footerHint": state.footerHint ?? "",
            "welcome": showsWelcome,
            "toast": state.toast?.title ?? "",
            "launchAtLogin": settings.launchAtLogin,
            "installedInApplications": AppDelegate.isInstalledInApplications,
            "bundlePath": Bundle.main.bundleURL.path,
            "showsTab": notch.showsTab,
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            "chipHotKeys": Dictionary(uniqueKeysWithValues: settings.chipHotKeys.map { ($0.key.rawValue, $0.value.displayString) }),
            "registeredChipHotKeys": Dictionary(uniqueKeysWithValues: (hotKeys?.registeredChipHotKeys ?? [:]).map { ($0.key.rawValue, $0.value.displayString) }),
            "chipHotKeyProblems": Dictionary(uniqueKeysWithValues: (hotKeys?.chipProblems ?? [:]).map { ($0.key.rawValue, $0.value) }),
            "activeDisplay": notch.state.geometry.displayID,
            "displays": notch.screens.map { screen in
                ["id": screen.displayID, "active": screen.isActive, "physicalNotch": screen.geometry.hasPhysicalNotch,
                 "visible": screen.window.isVisible,
                 "notch": ["x": screen.window.frame.minX, "y": screen.window.frame.minY,
                           "width": screen.window.frame.width, "height": screen.window.frame.height]]
            },
        ]
        if state.chip == .apps {
            let grid = apps.grid
            d["appsSelectedIndex"] = apps.selectedIndex
            d["apps"] = grid.items.prefix(30).map(\.displayName)
            d["appsSelected"] = apps.selected?.displayName ?? ""
            d["appsSelectedWindow"] = apps.selected?.windowID ?? ""
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
    private(set) var chipProblems: [Chip: String] = [:]
    private(set) var registeredChipHotKeys: [Chip: HotKey] = [:]
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
        chipProblems = [:]
        registeredChipHotKeys = [:]
        let released: () -> Void = { [weak self] in self?.coordinator.toggleReleased() }
        if let wanted = settings.toggleHotKey {
            do {
                try center.register(wanted, onRelease: released) { [weak self] in self?.coordinator.toggle() }
                effectiveToggle = wanted
            } catch {
                toggleProblem = error.localizedDescription
                Log.input.error("toggle hotkey failed: \(error.localizedDescription)")
                if wanted != .fallbackToggle,
                   (try? center.register(.fallbackToggle, onRelease: released) { [weak self] in self?.coordinator.toggle() }) != nil {
                    effectiveToggle = .fallbackToggle
                    toggleProblem = "\(wanted.displayString) is taken by another app; using \(HotKey.fallbackToggle.displayString) instead."
                }
            }
        }
        for (chip, hotKey) in settings.chipHotKeys where settings.visibleChips.contains(chip) {
            do {
                try center.register(hotKey) { [weak self] in self?.coordinator.open(chip: chip) }
                registeredChipHotKeys[chip] = hotKey
            } catch {
                chipProblems[chip] = error.localizedDescription
                Log.input.error("chip hotkey \(chip.rawValue) failed: \(error.localizedDescription)")
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
