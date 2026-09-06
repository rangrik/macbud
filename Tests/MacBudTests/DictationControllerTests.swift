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
            engine.onTranscript?((1...lines).map { "Dictated sentence \($0): the newest words should remain visible." }.joined(separator: " "))
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
        staleTranscript?("Abandoned partial")
        old.pendingStop?.resume(returning: "Abandoned final")
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

    var onTranscript: (@MainActor @Sendable (String) -> Void)?
    var onVolume: (@MainActor @Sendable (Float) -> Void)?
    var onError: (@MainActor @Sendable (Error) -> Void)?
    var canRetry = false
    var starts = 0
    var stops = 0
    var retries = 0
    var cancels = 0
    var suspends = 0
    var discards = 0
    var failStop = false
    var holdStop = false
    var pendingStop: CheckedContinuation<String, Error>?
    var result = "Hello from MacBud"

    func start(locale: Locale) async throws { starts += 1; canRetry = true }
    func stop() async throws -> String {
        stops += 1
        if failStop { throw Failure.interrupted }
        if holdStop { return try await withCheckedThrowingContinuation { pendingStop = $0 } }
        return result
    }
    func retry() async throws -> String { retries += 1; return "Retried recording" }
    func suspend() async { suspends += 1 }
    func discardRecording() { discards += 1; canRetry = false }
    func cancel() async { cancels += 1; canRetry = false }
    func transcribe(file: URL, locale: Locale) async throws -> String { result }
}
