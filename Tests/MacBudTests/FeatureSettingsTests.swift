import AppKit
import Testing
@testable import MacBud

@Suite @MainActor struct FeatureSettingsTests {
    /// Seam: feature toggles → chips and kinds. Catches a hidden feature leaving its chip, or All, behind.
    @Test func disabledFeaturesPersistAndHideTheirChips() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.visibleChips == Chip.allCases)
        settings.setEnabled(false, for: .clipboard)
        settings.setEnabled(false, for: .dictation)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.visibleChips == [.all, .screenshots, .dictations, .snippets, .apps])
        #expect(!restored.visibleKinds.contains(.text) && restored.visibleKinds.contains(.dictation))
        for feature in [AppFeature.screenshots, .dictationHistory, .snippets] { restored.setEnabled(false, for: feature) }
        #expect(restored.visibleChips == [.apps], "All has nothing left to show")
    }

    /// Seam: settings written by 0.7.0 → this build. Catches the owner losing a shortcut to the redesign.
    @Test func shortcutsSavedForTabsKeepWorkingOnChips() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        // 0.7.0 saved global shortcuts by tab name, like this.
        let saved = #"["clipboard",{"keyCode":9,"modifierRawValue":655360},"dictationHistory",{"keyCode":2,"modifierRawValue":655360},"apps",{"keyCode":4,"modifierRawValue":1048576}]"#
        defaults.set(Data(saved.utf8), forKey: "sectionHotKeys")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.chipHotKeys.mapValues(\.keyCode) == [.all: 9, .dictations: 2, .apps: 4])

        let tab = HotKey(keyCode: 48, modifiers: .control), two = HotKey(keyCode: 19, modifiers: .control)
        let seven = HotKey(keyCode: 26, modifiers: .control), end = HotKey(keyCode: 28, modifiers: .command)
        let chords = ["chords": ["nextSection": [tab], "selectSection2": [two], "selectSnippets": [seven], "moveToEnd": [end]]]
        let bindings = try JSONDecoder().decode(KeyBindings.self, from: JSONEncoder().encode(chords))
        #expect(bindings.chords(for: .nextChip) == [tab])
        #expect(bindings.chords(for: .selectChip2) == [two], "a numbered slot keeps its number")
        #expect(bindings.chords(for: .selectChip7) == [seven], "a per-tab command goes to its tab's chip")
        #expect(bindings.chords(for: .selectChip6) == KeyBindings.defaults.chords(for: .selectChip6), "new commands get their defaults")
        #expect(bindings.chords(for: .selectChip8).isEmpty, "but never a chord the owner gave to something else")
    }

    @Test func allFeaturesCanBeDisabledWithoutOpeningHiddenTools() {
        let coordinator = makeCoordinator()
        for feature in AppFeature.allCases { coordinator.settings.setEnabled(false, for: feature) }
        coordinator.applyFeatureSettings()
        coordinator.startDictation()
        coordinator.startHoldToTalk()
        #expect(!coordinator.dictation.isActive)
        #expect(!coordinator.isHoldingToTalk)
        #expect(!coordinator.hasContent)
        #expect(coordinator.footerHints().isEmpty)
        #expect(!coordinator.handle(.saveAsSnippet))
        coordinator.openShelf()
        #expect(coordinator.state.isExpanded, "the island says how to turn features back on")
        coordinator.notch.close()
    }

    @Test func disablingSnippetsBlocksCrossFeatureCreationAndKeepsHistory() {
        let coordinator = makeCoordinator()
        coordinator.state.chip = .dictations
        coordinator.dictationHistoryStore.add("Keep this saved dictation")
        coordinator.settings.setEnabled(false, for: .snippets)
        let item = coordinator.dictationHistoryStore.items[0]
        coordinator.dictationHistory.saveAsSnippet(item)
        #expect(!coordinator.snippets.isEditing)
        #expect(coordinator.state.chip == .dictations)
        #expect(!coordinator.footerHints().contains { $0.command == .saveAsSnippet })
        coordinator.settings.setEnabled(false, for: .dictationHistory)
        coordinator.applyFeatureSettings()
        #expect(coordinator.dictationHistoryStore.items == [item])
    }

    @Test func disablingKeepAliveReleasesTheActiveSession() {
        let coordinator = makeCoordinator()
        coordinator.keepAwake.start()
        defer { coordinator.keepAwake.stop() }
        #expect(coordinator.keepAwake.isActive)
        coordinator.settings.setEnabled(false, for: .keepAwake)
        coordinator.applyFeatureSettings()
        #expect(!coordinator.keepAwake.isActive)
    }

    @Test func disabledBackgroundFeaturesDoNotRun() async {
        let coordinator = makeCoordinator()
        coordinator.settings.setEnabled(false, for: .clipboard)
        let monitor = ClipboardMonitor(store: coordinator.clipboardStore, settings: coordinator.settings)
        monitor.start()
        #expect(!monitor.isRunning)
        coordinator.settings.setEnabled(true, for: .clipboard)
        monitor.start()
        #expect(monitor.isRunning)
        monitor.stop()
        #expect(!monitor.isRunning)
        coordinator.library.isEnabled = false
        coordinator.library.requestRescan(delay: .zero)
        await coordinator.library.rescan()
        #expect(!coordinator.library.isScanning)
        #expect(coordinator.library.lastScan == nil)
    }

    @Test func disabledFeaturesReleaseTheirGlobalShortcuts() throws {
        let coordinator = makeCoordinator()
        let settings = coordinator.settings
        let toggle = HotKey(keyCode: 79, modifiers: [.control, .option, .command])
        let hold = HotKey(keyCode: 90, modifiers: [.control, .option, .command])
        let screenshots = HotKey(keyCode: 80, modifiers: [.control, .shift, .command])
        settings.toggleHotKey = nil
        settings.chipHotKeys = [.screenshots: screenshots]
        settings.dictationHotKey = toggle
        settings.holdToTalkHotKey = hold
        let binder = HotKeyBinder(settings: settings, coordinator: coordinator)
        let center = HotKeyCenter.shared
        defer { center.unregisterAll() }
        binder.apply()
        #expect(binder.dictationProblem == nil)
        #expect(binder.holdToTalkProblem == nil)
        #expect(throws: HotKeyError.self) { try center.register(toggle) {} }
        settings.setEnabled(false, for: .dictation)
        settings.setEnabled(false, for: .screenshots)
        binder.apply()
        for chord in [toggle, hold, screenshots] {
            let id = try center.register(chord) {}
            center.unregister(id: id)
        }
    }

    private func makeCoordinator() -> PanelCoordinator {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.hasSeenWelcome = true
        let notch = NotchController()
        let data = DataStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return PanelCoordinator(state: notch.state, notch: notch, settings: settings,
                                clipboardStore: ClipboardStore(dataStore: data), snippetStore: SnippetStore(dataStore: data),
                                library: ScreenshotLibrary())
    }
}
