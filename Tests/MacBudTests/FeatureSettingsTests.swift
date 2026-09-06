import AppKit
import Testing
@testable import MacBud

@Suite @MainActor struct FeatureSettingsTests {
    @Test func configurationPersistsWithoutLosingDisabledTabPositions() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.enabledSections == Section.allCases)
        #expect(AppFeature.allCases.allSatisfy(settings.isEnabled))
        settings.setSectionOrder([.dictationHistory, .screenshots, .clipboard, .snippets])
        settings.setEnabled(false, for: .screenshots)
        settings.setEnabled(false, for: .dictation)
        settings.moveSection(.snippets, by: -1)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.sectionOrder == [.dictationHistory, .screenshots, .snippets, .clipboard])
        #expect(restored.enabledSections == [.dictationHistory, .snippets, .clipboard])
        #expect(!restored.isEnabled(.dictation))
        restored.setEnabled(true, for: .screenshots)
        #expect(restored.enabledSections == restored.sectionOrder)
    }

    @Test func savedOrderRecoversUnknownMissingAndDuplicateIDs() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(["screenshots", "unknown", "screenshots"], forKey: "sectionOrder")
        defaults.set(["unknown", "keepAwake"], forKey: "disabledFeatures")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.sectionOrder == [.screenshots, .clipboard, .snippets, .dictationHistory])
        #expect(settings.disabledFeatures == [.keepAwake])
        settings.moveSection(.screenshots, by: -1)
        #expect(settings.sectionOrder.first == .screenshots)
    }

    @Test func selectionAndKeyboardCyclingFollowEnabledOrder() {
        let coordinator = makeCoordinator()
        let settings = coordinator.settings
        settings.setSectionOrder([.dictationHistory, .screenshots, .snippets, .clipboard])
        coordinator.state.section = .screenshots
        settings.setEnabled(false, for: .screenshots)
        settings.setEnabled(false, for: .clipboard)
        coordinator.applyFeatureSettings()
        #expect(coordinator.state.section == .dictationHistory)
        #expect(coordinator.handle(.nextSection))
        #expect(coordinator.state.section == .snippets)
        #expect(coordinator.handle(.nextSection))
        #expect(coordinator.state.section == .dictationHistory)
        coordinator.select(.screenshots)
        #expect(coordinator.state.section == .dictationHistory)
        coordinator.open(section: .clipboard)
        #expect(!coordinator.state.isOpen)
    }

    @Test func allFeaturesCanBeDisabledWithoutOpeningHiddenTools() {
        let coordinator = makeCoordinator()
        for feature in AppFeature.allCases { coordinator.settings.setEnabled(false, for: feature) }
        coordinator.applyFeatureSettings()
        coordinator.startDictation()
        coordinator.startHoldToTalk()
        #expect(!coordinator.dictation.isActive)
        #expect(!coordinator.isHoldingToTalk)
        #expect(!coordinator.hasEnabledSection)
        #expect(coordinator.footerHints().isEmpty)
        #expect(!coordinator.handle(.saveAsSnippet))
        coordinator.open()
        #expect(coordinator.state.isExpanded)
        coordinator.notch.close()
    }

    @Test func disablingSnippetsBlocksCrossFeatureCreationAndKeepsHistory() {
        let coordinator = makeCoordinator()
        coordinator.state.section = .dictationHistory
        coordinator.dictationHistoryStore.add("Keep this saved dictation")
        coordinator.settings.setEnabled(false, for: .snippets)
        let item = coordinator.dictationHistoryStore.items[0]
        coordinator.dictationHistory.saveAsSnippet(item)
        #expect(!coordinator.snippets.isEditing)
        #expect(coordinator.state.section == .dictationHistory)
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
        settings.sectionHotKeys = [.screenshots: screenshots]
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
