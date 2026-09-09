import AppKit
import Testing
@testable import MacBud

@MainActor @Suite struct DictationTranscriptEditorTests {
    /// A live editor wired the way the notch wires it, so edits go through the real delegate path.
    private func makeEditor(_ document: DictationTranscript,
                            onCommit: @escaping (String) -> Void)
        -> (DictationTranscriptEditor.Coordinator, EditableTranscriptView) {
        let editor = DictationTranscriptEditor(
            document: document, isEditing: false, placeholder: "Start talking…",
            onBeginEditing: {}, onCommit: onCommit, onLinesChanged: { _ in })
        let view = EditableTranscriptView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let coordinator = editor.makeCoordinator()
        coordinator.textView = view
        view.coordinator = coordinator
        view.delegate = coordinator
        coordinator.apply(document, force: true)
        return (coordinator, view)
    }

    private func replace(_ word: String, with new: String, in view: EditableTranscriptView) {
        let range = (view.string as NSString).range(of: word)
        #expect(range.location != NSNotFound)
        view.setSelectedRange(range)
        view.insertText(new, replacementRange: range)
    }

    @Test func fixingAWordDoesNotEatTheEndOfTheLine() {
        var committed: String?
        let (coordinator, view) = makeEditor(DictationTranscript(settledText: "let's ship the Codex"),
                                             onCommit: { committed = $0 })
        // The fix is two characters longer than what was heard — the case that used to truncate.
        replace("ship", with: "shippp", in: view)
        coordinator.commit()
        #expect(committed == "let's shippp the Codex")
    }

    @Test func fixingAWordWhileTheEngineIsStillTalkingLeavesTheDraftAlone() {
        var committed: String?
        let document = DictationTranscript(settled: [DictationSegment(text: "ship the Codex")],
                                           draft: DictationSegment(text: "today please"))
        let (coordinator, view) = makeEditor(document, onCommit: { committed = $0 })
        // Shorter this time: the commit must stop at the settled words, not borrow from the draft.
        replace("Codex", with: "Kx", in: view)
        coordinator.commit()
        #expect(committed == "ship the Kx")
    }

    @Test func theDraftStaysOutOfReach() {
        let document = DictationTranscript(settled: [DictationSegment(text: "ship the Codex")],
                                           draft: DictationSegment(text: "today"))
        let (coordinator, view) = makeEditor(document, onCommit: { _ in })
        let draft = (view.string as NSString).range(of: "today")
        view.setSelectedRange(draft)
        view.insertText("tomorrow", replacementRange: draft)
        #expect(view.string == "ship the Codex today", "The engine still owns the draft")
    }

    @Test func theEditableRegionAbsorbsEveryLengthChange() {
        var region = DictationEditableRegion()
        region.reset(settledLength: 14, totalLength: 20)  // "ship the Codex" + " today"
        #expect(region.allowsEdit(in: NSRange(location: 9, length: 5)))
        #expect(!region.allowsEdit(in: NSRange(location: 9, length: 7)), "That reaches into the draft")
        region.textChanged(totalLength: 22)
        #expect(region.settledLength == 16, "Two characters longer means two more characters are yours")
        region.textChanged(totalLength: 17)
        #expect(region.settledLength == 11)
    }
}
