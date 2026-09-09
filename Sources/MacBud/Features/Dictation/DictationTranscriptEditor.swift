import AppKit
import SwiftUI

/// How much of the text view you may edit: everything before the draft the recogniser is still
/// forming. You can never touch the draft, so its length is fixed — after you type, the settled
/// part is simply whatever is left. Without this, an edit that changed the length silently cut
/// characters off the end of the transcript.
nonisolated struct DictationEditableRegion: Equatable {
    private(set) var settledLength = 0
    private(set) var tailLength = 0

    /// Fresh text arrived from the recogniser: relearn where the settled part ends.
    mutating func reset(settledLength: Int, totalLength: Int) {
        self.settledLength = max(0, min(settledLength, totalLength))
        tailLength = max(0, totalLength - self.settledLength)
    }

    /// You typed: the tail kept its length, so the settled part absorbed the whole change.
    mutating func textChanged(totalLength: Int) {
        settledLength = max(0, totalLength - tailLength)
    }

    func allowsEdit(in range: NSRange) -> Bool { NSMaxRange(range) <= settledLength }
}

/// The transcript as real, editable text. You can put the cursor anywhere, select across words,
/// backspace, and type — the things a text field gives you for free and word buttons never could.
///
/// Only the settled part is editable. The draft tail trails it in grey and is refused edits,
/// because the engine is still rewriting it.
struct DictationTranscriptEditor: NSViewRepresentable {
    let document: DictationTranscript
    let isEditing: Bool
    let placeholder: String
    let onBeginEditing: () -> Void
    let onCommit: (String) -> Void
    let onLinesChanged: (Int) -> Void

    static let font = NSFont.systemFont(ofSize: 14)
    static let lineHeight: CGFloat = 19

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed

        let text = EditableTranscriptView()
        text.delegate = context.coordinator
        text.coordinator = context.coordinator
        text.drawsBackground = false
        text.isRichText = false
        text.isEditable = true
        text.isSelectable = true
        text.allowsUndo = true
        text.font = Self.font
        text.textColor = NSColor.white.withAlphaComponent(0.94)
        text.insertionPointColor = NSColor.white.withAlphaComponent(0.8)
        text.textContainerInset = CGSize(width: 0, height: 0)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        context.coordinator.textView = text
        context.coordinator.apply(document, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(document, force: false)
        context.coordinator.reportLines(width: scroll.contentSize.width)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DictationTranscriptEditor
        weak var textView: EditableTranscriptView?
        /// How much of the text is yours to change. Everything past it is the engine's draft.
        private(set) var region = DictationEditableRegion()
        private var shown = ""
        private var reportedLines = 0

        init(_ parent: DictationTranscriptEditor) { self.parent = parent }

        /// The engine's words only reach the view when you are not in the middle of editing them.
        func apply(_ document: DictationTranscript, force: Bool) {
            guard let textView, force || !parent.isEditing else { return }
            let settled = document.settledText
            let draft = document.draft?.text ?? ""
            let combined = [settled, draft].filter { !$0.isEmpty }.joined(separator: " ")
            defer {
                region.reset(settledLength: (settled as NSString).length,
                             totalLength: textView.textStorage?.length ?? 0)
            }
            guard combined != shown else { return }
            shown = combined
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(Self.styled(document, placeholder: parent.placeholder))
            textView.typingAttributes = [.font: DictationTranscriptEditor.font,
                                         .foregroundColor: NSColor.white.withAlphaComponent(0.94)]
            if selection.location <= (combined as NSString).length {
                textView.setSelectedRange(selection)
            }
            // Keep the newest words in view; you are watching the end, not the start.
            if !parent.isEditing {
                let length = textView.textStorage?.length ?? 0
                textView.scrollRangeToVisible(NSRange(location: length, length: 0))
            }
        }

        /// The text you can edit, ignoring the draft trailing it.
        var editableText: String {
            guard let storage = textView?.textStorage else { return "" }
            let length = min(region.settledLength, storage.length)
            return storage.attributedSubstring(from: NSRange(location: 0, length: length)).string
        }

        func beginEditing() { parent.onBeginEditing() }

        func commit() {
            parent.onCommit(editableText)
            shown = ""
        }

        /// Refuse edits that reach into the draft the engine still owns.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            parent.onBeginEditing()
            return region.allowsEdit(in: range)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            region.textChanged(totalLength: textView.textStorage?.length ?? 0)
            shown = textView.string
            reportLines(width: textView.bounds.width)
        }

        func reportLines(width: CGFloat) {
            guard let textView, width > 1 else { return }
            let size = NSSize(width: width, height: .greatestFiniteMagnitude)
            let attributed = textView.attributedString()
            let used = attributed.length == 0 ? DictationTranscriptEditor.lineHeight
                : attributed.boundingRect(with: size, options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            let lines = max(1, Int(ceil(used / DictationTranscriptEditor.lineHeight)))
            guard lines != reportedLines else { return }
            reportedLines = lines
            parent.onLinesChanged(lines)
        }

        /// Words the recogniser doubted get a red dotted underline; the draft tail stays grey.
        static func styled(_ document: DictationTranscript, placeholder: String) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let base: [NSAttributedString.Key: Any] = [
                .font: DictationTranscriptEditor.font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.94),
            ]
            for segment in document.settled {
                for word in segment.words {
                    var attributes = base
                    if word.isUncertain {
                        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                        attributes[.underlineColor] = NSColor.systemOrange
                    }
                    if result.length > 0 { result.append(NSAttributedString(string: " ", attributes: base)) }
                    result.append(NSAttributedString(string: word.text, attributes: attributes))
                }
            }
            if let draft = document.draft, !draft.isEmpty {
                let dim: [NSAttributedString.Key: Any] = [
                    .font: DictationTranscriptEditor.font,
                    .foregroundColor: NSColor.white.withAlphaComponent(0.5),
                ]
                if result.length > 0 { result.append(NSAttributedString(string: " ", attributes: base)) }
                result.append(NSAttributedString(string: draft.text, attributes: dim))
            }
            if result.length == 0 {
                return NSAttributedString(string: placeholder, attributes: [
                    .font: DictationTranscriptEditor.font,
                    .foregroundColor: NSColor.white.withAlphaComponent(0.38),
                ])
            }
            return result
        }
    }
}

/// Return and Escape finish the edit rather than typing a newline or killing the recording.
final class EditableTranscriptView: NSTextView {
    weak var coordinator: DictationTranscriptEditor.Coordinator?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { coordinator?.beginEditing() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.beginEditing()
        super.mouseDown(with: event)
    }

    /// Clicking away finishes the edit too, so the microphone can never stay paused by accident.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.commit() }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 53, !event.modifierFlags.contains(.command) {
            coordinator?.commit()
            return
        }
        super.keyDown(with: event)
    }
}
