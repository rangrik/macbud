import AppKit
import Testing
@testable import MacBud

@Suite @MainActor struct DictationWorkflowTests {
    @Test func escapeCancelsOnlyDuringDictationAndReturnIsUntouched() {
        let monitor = DictationEscapeMonitor()
        var cancellations = 0
        func event(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: keyCode)!
        }
        #expect(!monitor.handle(event(53)))
        monitor.start { cancellations += 1 }
        defer { monitor.stop() }
        #expect(!monitor.handle(event(36)))
        #expect(!monitor.handle(event(36, .command)))
        #expect(!monitor.handle(event(53, [.command, .option])))
        #expect(monitor.handle(event(53)))
        #expect(cancellations == 1)
        monitor.stop()
        #expect(!monitor.handle(event(53)))
    }

    @Test func legacyImportPreservesDictationsAndDoesNotImportOtherApps() {
        let store = DictationHistoryStore()
        let first = ClipboardItem(id: UUID(), kind: .text, copiedAt: .now, text: "Previous dictation", byteCount: 18,
                                  sourceBundleID: "com.rangrik.macbud", contentHash: "first")
        var other = first
        other.sourceBundleID = "com.example.other"
        let older = ClipboardItem(id: UUID(), kind: .text, copiedAt: .now.addingTimeInterval(-60), text: "Older dictation", byteCount: 15,
                                  sourceBundleID: "com.rangrik.macbud", contentHash: "older")
        store.importLegacy([first, other, older], sourceBundleID: "com.rangrik.macbud")
        store.importLegacy([first, older], sourceBundleID: "com.rangrik.macbud")
        #expect(store.items.map(\.text) == ["Previous dictation", "Older dictation"])
        #expect(store.items.map(\.id) == [first.id, older.id])
    }

    @Test func ordinaryReturnActionsAreNotHandledByDictation() {
        let notch = NotchController()
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let coordinator = PanelCoordinator(state: notch.state, notch: notch, settings: settings,
                                           clipboardStore: ClipboardStore(), snippetStore: SnippetStore(), library: ScreenshotLibrary())
        notch.state.phase = .dictation
        #expect(!coordinator.handle(.primaryAction))
        #expect(!coordinator.handle(.secondaryAction))
        #expect(!coordinator.handle(.saveAsSnippet))
    }

    @Test func editableFocusRejectsButtonsReadOnlyAndPasswordFields() {
        #expect(FocusedTextTarget.accepts(role: "AXTextArea", subrole: "", enabled: true, editable: true,
                                         selectionSettable: false, valueSettable: false, hasSelectionRange: true))
        #expect(FocusedTextTarget.accepts(role: "AXTextField", subrole: "", enabled: true, editable: nil,
                                         selectionSettable: true, valueSettable: true, hasSelectionRange: true))
        for (role, subrole, enabled, editable) in [("AXButton", "", true, nil), ("AXTextArea", "", true, false),
                                                 ("AXTextField", "AXSecureTextField", true, true), ("AXTextField", "", false, true)] as [(String, String, Bool, Bool?)] {
            #expect(!FocusedTextTarget.accepts(role: role, subrole: subrole, enabled: enabled, editable: editable,
                                              selectionSettable: true, valueSettable: true, hasSelectionRange: true))
        }
    }

    @Test func pressRepeatAndReleaseDispatchOnlyOnce() throws {
        let center = HotKeyCenter.shared
        var presses = 0
        var releases = 0
        let id = try center.register(HotKey(keyCode: 80, modifiers: [.control, .option, .command]),
                                     onRelease: { releases += 1 }) { presses += 1 }
        defer { center.unregister(id: id) }
        center.fire(id: id)
        center.fire(id: id)
        center.fire(id: id, released: true)
        center.fire(id: id, released: true)
        #expect(presses == 1)
        #expect(releases == 1)
        center.fire(id: id)
        center.fire(id: id, released: true)
        #expect(presses == 2)
        #expect(releases == 2)
    }

    @Test func historyPersistsPrunesSearchesAndDeletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataStore = DataStore(directory: directory)
        let store = DictationHistoryStore(dataStore: dataStore)
        store.limit = 2
        store.add("Before loading")
        await store.load()
        store.add("  First transcript  ")
        store.add("Second transcript\nwith a second line")
        store.add(" \n ")
        await store.flush()
        let restored = DictationHistoryStore(dataStore: dataStore)
        await restored.load()
        #expect(restored.items.map(\.text) == ["Second transcript\nwith a second line", "First transcript"])
        #expect(restored.results(for: "FIRST").map(\.text) == ["First transcript"])
        restored.remove(restored.items[0].id)
        await restored.flush()
        let persisted = await dataStore.load([DictationHistoryItem].self, from: "dictation-history.json")
        #expect(persisted?.map(\.text) == ["First transcript"])
    }

    @Test func historyOpensASnippetDraftWithTheExactTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notch = NotchController()
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let snippetStore = SnippetStore(dataStore: DataStore(directory: directory))
        let coordinator = PanelCoordinator(state: notch.state, notch: notch, settings: settings,
                                           clipboardStore: ClipboardStore(), snippetStore: snippetStore, library: ScreenshotLibrary())
        let text = "Meeting notes\nKeep all the words, punctuation, and line breaks."
        coordinator.dictationHistoryStore.add(text)
        notch.state.section = .dictationHistory
        #expect(coordinator.dictationHistory.handle(.saveAsSnippet))
        #expect(notch.state.section == .snippets)
        #expect(coordinator.snippets.isEditing)
        #expect(coordinator.snippets.draft.content == text)
        #expect(coordinator.snippets.saveDraft())
        #expect(snippetStore.snippets.first?.content == text)
        #expect(coordinator.dictationHistoryStore.items.first?.text == text)
    }
}
