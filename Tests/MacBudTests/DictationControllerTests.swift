import Foundation
import SwiftUI
import Testing
@testable import MacBud

@MainActor @Suite struct DictationControllerTests {
    @Test func growingTranscriptKeepsItsLatestLineVisible() async throws {
        let engine = FakeDictationEngine()
        let controller = makeController(engine) { _, _ in Issue.record("The scroll check must not deliver text") }
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let notch = NotchController()
        notch.dictationProvider = {
            AnyView(DictationView(controller: controller, settings: settings, notchHeight: notch.state.geometry.notchRect.height))
        }
        notch.install()
        notch.openDictation()
        let window = notch.panel
        let host = try #require(window.contentView)
        defer { controller.cancel(); notch.close(); notch.base.orderOut(nil) }
        controller.start()
        try await waitUntil { controller.phase == .recording }

        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        for lines in [1, 12, 40, 80] {
            engine.onTranscript?(DictationTranscript(settledText: (1...lines).map { "Dictated sentence \($0): the newest words should remain visible." }.joined(separator: " ")))
            engine.onVolume?(0.5)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let scroll = try #require(scrollView(in: host))
            let document = try #require(scroll.documentView)
            if lines > 1 { #expect(document.bounds.height > scroll.bounds.height, "Long dictation must produce scrollable text") }
            let hiddenBelow = document.bounds.maxY - scroll.documentVisibleRect.maxY
            #expect(hiddenBelow <= 2, "The latest transcript line is \(hiddenBelow) points below the visible area after \(lines) lines")
        }
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/macbud-live-transcript-check.png"))
        }
        // A new layout must retain the end even when there is no new transcript callback that frame.
        window.setContentSize(CGSize(width: 440, height: 210))
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(scrollView(in: host))
        let document = try #require(scroll.documentView)
        #expect(document.bounds.maxY - scroll.documentVisibleRect.maxY <= 2,
                "Reflow must keep the newest line visible after the text layout changes")
    }

    @Test func releasingDuringPreparationFinishesOnceStartupCompletes() async throws {
        let engine = FakeDictationEngine()
        var pending: CheckedContinuation<Locale, Never>?
        var deliveries: [String] = []
        let controller = DictationController(makeEngine: { engine }, prepare: { _ in
            await withCheckedContinuation { pending = $0 }
        }, deliver: { text, _ in deliveries.append(text) })
        controller.start()
        try await waitUntil { pending != nil }
        controller.finish(.insert)
        pending?.resume(returning: Locale(identifier: "en-US"))
        for _ in 0..<100 { await Task.yield() }
        #expect(controller.phase == .idle)
        #expect(engine.stops == 1)
        #expect(deliveries == ["Hello from MacBud"])
        controller.cancel()
    }

    @Test func doubleStartAndFinishDeliverOnce() async throws {
        let engine = FakeDictationEngine()
        var deliveries: [(String, DictationDelivery)] = []
        let controller = makeController(engine) { deliveries.append(($0, $1)) }
        controller.start()
        controller.start()
        try await waitUntil { controller.phase == .recording }
        controller.finish(.insert)
        controller.finish(.insert)
        try await waitUntil { controller.phase == .idle }
        #expect(engine.starts == 1)
        #expect(engine.stops == 1)
        #expect(deliveries.count == 1)
        #expect(deliveries.first?.1 == .insert)
        #expect(engine.discards == 1)
    }

    @Test func retryReplaysAudioAndPreservesDeliveryChoice() async throws {
        let engine = FakeDictationEngine()
        engine.failStop = true
        var deliveries: [(String, DictationDelivery)] = []
        let controller = makeController(engine) { deliveries.append(($0, $1)) }
        controller.start()
        try await waitUntil { controller.phase == .recording }
        controller.finish(.insert)
        try await waitUntil { controller.canRetry }
        #expect(engine.discards == 0)
        #expect(engine.suspends == 1)
        controller.retry()
        controller.retry()
        try await waitUntil { controller.phase == .idle }
        #expect(engine.starts == 1, "Retry must not request another microphone recording")
        #expect(engine.retries == 1)
        #expect(deliveries.first?.0 == "Retried recording")
        #expect(deliveries.first?.1 == .insert)
        #expect(engine.discards == 1)
    }

    @Test func cancelledFinalizationCannotDeliverIntoNextSession() async throws {
        let old = FakeDictationEngine()
        old.holdStop = true
        let next = FakeDictationEngine()
        var engines = [old, next]
        var deliveries: [String] = []
        let controller = DictationController(makeEngine: { engines.removeFirst() },
                                              prepare: { _ in Locale(identifier: "en-US") },
                                              deliver: { text, _ in deliveries.append(text) })
        controller.start()
        try await waitUntil { controller.phase == .recording }
        controller.finish(.insert)
        try await waitUntil { old.pendingStop != nil }
        let staleTranscript = old.onTranscript
        controller.cancel()
        controller.start()
        try await waitUntil { next.starts == 1 && controller.phase == .recording }
        staleTranscript?(DictationTranscript(settledText: "Abandoned partial"))
        old.pendingStop?.resume(returning: DictationTranscript(settledText: "Abandoned final"))
        old.pendingStop = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(deliveries.isEmpty)
        #expect(controller.transcript.isEmpty)
        #expect(controller.phase == .recording)
        controller.finish(.insert)
        try await waitUntil { controller.phase == .idle }
        #expect(deliveries == ["Hello from MacBud"])
    }

    @Test func cancelledPreparationDoesNotStartMicrophoneOrChangeNewState() async throws {
        let engine = FakeDictationEngine()
        var pending: CheckedContinuation<Locale, Never>?
        var progress: (@MainActor (Double) -> Void)?
        let controller = DictationController(makeEngine: { engine }, prepare: { callback in
            progress = callback
            return await withCheckedContinuation { pending = $0 }
        }, deliver: { _, _ in Issue.record("Cancelled preparation delivered text") })
        controller.start()
        try await waitUntil { pending != nil }
        controller.cancel()
        progress?(0.8)
        pending?.resume(returning: Locale(identifier: "en-US"))
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.phase == .idle)
        #expect(engine.starts == 0)
    }

    @Test func silenceDoesNotSendOrCopy() async throws {
        let engine = FakeDictationEngine()
        engine.result = " \n "
        var ended = false
        let controller = makeController(engine) { _, _ in Issue.record("Silence must not deliver") }
        controller.onDidEnd = { ended = true }
        controller.start()
        try await waitUntil { controller.phase == .recording }
        controller.finish(.insert)
        try await waitUntil { ended }
        #expect(controller.transcript.isEmpty)
        #expect(engine.discards == 1)
    }

    @Test func interruptionRetainsAudioAndDiscardReleasesIt() async throws {
        let engine = FakeDictationEngine()
        let controller = makeController(engine) { _, _ in Issue.record("Interrupted capture delivered text") }
        controller.start()
        try await waitUntil { controller.phase == .recording }
        engine.onError?(FakeDictationEngine.Failure.interrupted)
        try await waitUntil { controller.canRetry }
        #expect(controller.phase == .failed("Microphone disconnected"))
        controller.cancel()
        try await waitUntil { engine.cancels == 1 }
        #expect(!engine.canRetry)
        #expect(!controller.canRetry)
        #expect(controller.phase == .idle)
    }

    private func makeController(_ engine: FakeDictationEngine,
                                deliver: @escaping (String, DictationDelivery) -> Void) -> DictationController {
        DictationController(makeEngine: { engine }, prepare: { _ in Locale(identifier: "en-US") }, deliver: deliver)
    }

    @Test func leavingTheTranscriptAloneKeepsTheRecordingGoing() async throws {
        let engine = FakeDictationEngine()
        let controller = DictationController(makeEngine: { engine },
                                             prepare: { _ in Locale(identifier: "en-US") },
                                             deliver: { _, _ in })
        var focus: [Bool] = []
        controller.onEditingChanged = { focus.append($0) }
        controller.start()
        try await waitUntil { controller.phase == .recording }
        engine.onTranscript?(DictationTranscript(settledText: "ship the Codex"))
        controller.beginEdit()
        #expect(engine.pauses == [true], "The microphone stops while you type")
        #expect(focus == [true], "And the notch takes the keyboard")
        controller.commitEdit(nil)
        #expect(!controller.isEditingTranscript)
        #expect(controller.phase == .recording, "Leaving the text alone must not end the recording")
        #expect(engine.pauses == [true, false])
        #expect(focus == [true, false])
        #expect(controller.transcript == "ship the Codex")
        controller.cancel()
        #expect(controller.phase == .idle)
    }

    @Test func typingOverAWordKeepsTheFixAndLearnsIt() async throws {
        let engine = FakeDictationEngine()
        let words = DictationWordStore()
        var delivered: [String] = []
        let controller = DictationController(makeEngine: { engine },
                                             prepare: { _ in Locale(identifier: "en-US") },
                                             deliver: { text, _ in delivered.append(text) },
                                             words: words)
        controller.start()
        try await waitUntil { controller.phase == .recording }

        let attempt = UUID()
        var heard = DictationSegment(text: "ship the Codex")
        heard.words[2].confidence = 0.3
        engine.onTranscript?(DictationTranscript(attemptID: attempt, settled: [heard]))

        controller.beginEdit()
        controller.commitEdit("ship the Kodex")
        #expect(controller.transcript == "ship the Kodex")
        #expect(words.rules.first?.isActive == true, "It doubted the word, so the fix is trusted at once")
        #expect(engine.pauses == [true, false])

        // More speech arrives, then the recording ends: the correction has to still be there.
        engine.finalTranscript = DictationTranscript(attemptID: attempt,
                                                     settled: [heard, DictationSegment(text: "integration")])
        controller.finish(.insert)
        try await waitUntil { controller.phase == .idle }
        #expect(delivered == ["ship the Kodex integration"])
    }

    @Test func deletingWordsChangesTheTextButTeachesNothing() async throws {
        let engine = FakeDictationEngine()
        let words = DictationWordStore()
        let controller = DictationController(makeEngine: { engine },
                                             prepare: { _ in Locale(identifier: "en-US") },
                                             deliver: { _, _ in }, words: words)
        controller.start()
        try await waitUntil { controller.phase == .recording }
        engine.onTranscript?(DictationTranscript(settledText: "ship the umm you know Codex"))
        controller.beginEdit()
        controller.commitEdit("ship the Codex")
        #expect(controller.transcript == "ship the Codex")
        #expect(words.rules.isEmpty)
        #expect(!controller.isEditingTranscript)
        controller.cancel()
    }

    @Test func theNotchUnderlinesTheWordItDoubtedAndLetsYouTypeOverIt() async throws {
        let engine = FakeDictationEngine()
        let words = DictationWordStore()
        let controller = DictationController(makeEngine: { engine },
                                             prepare: { _ in Locale(identifier: "en-US") },
                                             deliver: { _, _ in }, words: words)
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let notch = NotchController()
        var lines: [Int] = []
        notch.dictationProvider = {
            AnyView(DictationView(controller: controller, settings: settings,
                                  notchHeight: notch.state.geometry.notchRect.height,
                                  onLinesChanged: { lines.append($0); notch.setDictationLines($0) }))
        }
        notch.install()
        notch.openDictation()
        let host = try #require(notch.panel.contentView)
        defer { controller.cancel(); notch.close(); notch.base.orderOut(nil) }
        controller.start()
        try await waitUntil { controller.phase == .recording }

        var heard = DictationSegment(text: "okay so for the release notes let's ship the Codex integration today")
        heard.words[9].confidence = 0.34
        engine.onTranscript?(DictationTranscript(settled: [heard], draft: DictationSegment(text: "and then")))
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/private/tmp/macbud-dictation-editor.png"))

        #expect(controller.document.uncertainWordCount == 1)
        // The transcript is a real text view, so it is editable and selectable in place.
        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let text = try #require(textView(in: host))
        #expect(text.isEditable)
        #expect(text.isSelectable)
        #expect(text.string.contains("Codex"))
    }

    @Test func youCanSelectAWordInTheNotchTypeOverItAndItSticks() async throws {
        let engine = FakeDictationEngine()
        let words = DictationWordStore()
        let controller = DictationController(makeEngine: { engine },
                                             prepare: { _ in Locale(identifier: "en-US") },
                                             deliver: { _, _ in }, words: words)
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let notch = NotchController()
        notch.dictationProvider = {
            AnyView(DictationView(controller: controller, settings: settings,
                                  notchHeight: notch.state.geometry.notchRect.height,
                                  onLinesChanged: { notch.setDictationLines($0) }))
        }
        controller.onEditingChanged = { notch.setDictationKeyboardFocus($0) }
        notch.install()
        notch.openDictation()
        let host = try #require(notch.panel.contentView)
        defer { controller.cancel(); notch.close(); notch.base.orderOut(nil) }
        controller.start()
        try await waitUntil { controller.phase == .recording }

        var heard = DictationSegment(text: "let's ship the Codex today")
        heard.words[3].confidence = 0.3
        engine.onTranscript?(DictationTranscript(settled: [heard]))
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()

        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let text = try #require(textView(in: host))
        #expect(notch.panel.acceptsKeyboardFocus == false, "The notch leaves the keyboard alone until you touch the text")

        // Select "Codex" the way a double-click would, then type over it.
        let range = (text.string as NSString).range(of: "Codex")
        #expect(range.location != NSNotFound)
        text.setSelectedRange(range)
        controller.beginEdit()
        #expect(notch.panel.acceptsKeyboardFocus, "Typing needs the keyboard, so the notch asks for it")
        text.insertText("Kodex", replacementRange: range)
        #expect(text.string == "let's ship the Kodex today", "The keystrokes have to land in the text")

        controller.commitEdit(text.string)
        #expect(controller.transcript == "let's ship the Kodex today")
        #expect(words.rules.first?.heard == "Codex")
        #expect(words.rules.first?.meant == "Kodex")
        #expect(notch.panel.acceptsKeyboardFocus == false, "And handed straight back afterwards")
    }

    @Test func thePanelGrowsWithWhatYouSaidBetweenFourAndTenLines() {
        let notch = NotchController()
        let base = notch.state.metrics.dictationBaseHeight
        let line = notch.state.metrics.dictationLineHeight
        #expect(notch.state.metrics.dictationHeight(forLines: 1) == base, "Never smaller than four lines")
        #expect(notch.state.metrics.dictationHeight(forLines: 4) == base)
        #expect(notch.state.metrics.dictationHeight(forLines: 7) == base + 3 * line)
        #expect(notch.state.metrics.dictationHeight(forLines: 10) == base + 6 * line)
        #expect(notch.state.metrics.dictationHeight(forLines: 40) == base + 6 * line, "Never taller than ten")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition(), "Expected asynchronous state transition")
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }
}

@MainActor private final class FakeDictationEngine: DictationEngineSession {
    enum Failure: LocalizedError {
        case interrupted
        var errorDescription: String? { "Microphone disconnected" }
    }

    var onTranscript: (@MainActor @Sendable (DictationTranscript) -> Void)?
    var onVolume: (@MainActor @Sendable (Float) -> Void)?
    var onError: (@MainActor @Sendable (Error) -> Void)?
    var canRetry = false
    var vocabulary: [String] = []
    var pauses: [Bool] = []
    var starts = 0
    var stops = 0
    var retries = 0
    var cancels = 0
    var suspends = 0
    var discards = 0
    var failStop = false
    var holdStop = false
    var pendingStop: CheckedContinuation<DictationTranscript, Error>?
    var result = "Hello from MacBud"
    /// When set, `stop` returns this instead of wrapping `result`.
    var finalTranscript: DictationTranscript?

    func start(locale: Locale) async throws { starts += 1; canRetry = true }
    func stop() async throws -> DictationTranscript {
        stops += 1
        if failStop { throw Failure.interrupted }
        if holdStop { return try await withCheckedThrowingContinuation { pendingStop = $0 } }
        return finalTranscript ?? DictationTranscript(settledText: result)
    }
    func retry() async throws -> DictationTranscript { retries += 1; return DictationTranscript(settledText: "Retried recording") }
    func suspend() async { suspends += 1 }
    func discardRecording() { discards += 1; canRetry = false }
    func cancel() async { cancels += 1; canRetry = false }
    func setCapturePaused(_ paused: Bool) { pauses.append(paused) }
    func transcribe(file: URL, locale: Locale) async throws -> DictationTranscript { DictationTranscript(settledText: result) }
}
