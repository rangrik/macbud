import AppKit

nonisolated enum DictationPhase: Equatable, Sendable {
    case idle, preparing(String), recording, finalizing, failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .recording, .finalizing: true
        case .idle, .failed: false
        }
    }
}

/// A recording owns its engine. Cancelled work can finish late without touching the next recording.
@Observable
final class DictationController {
    typealias Preparation = (@escaping @MainActor (Double) -> Void) async throws -> Locale

    private(set) var phase: DictationPhase = .idle {
        didSet {
            if (oldValue == .idle) != (phase == .idle) { onActivityChanged?(phase != .idle) }
        }
    }
    /// Settled words you may correct, plus the draft tail the engine still owns.
    private(set) var document = DictationTranscript()
    /// The word whose correction popover is open. While it is set the microphone is paused.
    private(set) var editingWordID: UUID?
    private(set) var levels: [Float] = Array(repeating: 0, count: 28)
    private(set) var elapsed: TimeInterval = 0
    private(set) var locale: Locale?
    private(set) var canRetry = false

    @ObservationIgnored private let makeEngine: () -> any DictationEngineSession
    @ObservationIgnored private let prepare: Preparation
    @ObservationIgnored private let deliverText: (String, DictationDelivery) -> Void
    @ObservationIgnored private let words: DictationWordStore?
    @ObservationIgnored private var engine: (any DictationEngineSession)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var delivery: DictationDelivery = .insert
    @ObservationIgnored private var pendingFinish: DictationDelivery?

    var onDidEnd: (() -> Void)?
    var onActivityChanged: ((Bool) -> Void)?

    init(makeEngine: @escaping () -> any DictationEngineSession = { DictationEngine() },
         prepare: @escaping Preparation, deliver: @escaping (String, DictationDelivery) -> Void,
         words: DictationWordStore? = nil) {
        self.makeEngine = makeEngine
        self.prepare = prepare
        self.deliverText = deliver
        self.words = words
    }

    var transcript: String { document.text }
    var isEditingWord: Bool { editingWordID != nil }

    convenience init(settings: AppSettings, context: ActionContext, clipboard: ClipboardStore,
                     history: DictationHistoryStore, words: DictationWordStore) {
        self.init(prepare: { progress in
            guard let locale = await DictationEngine.resolveLocale(preferred: settings.dictationLocale) else {
                throw DictationEngine.EngineError.localeUnsupported(Locale.current)
            }
            try Task.checkCancellation()
            try await DictationEngine.ensureAssets(for: locale, progress: progress)
            try Task.checkCancellation()
            return locale
        }, deliver: { text, action in
            if settings.isEnabled(.dictationHistory) { history.add(text) }
            context.deliverDictation(text, insert: action == .insert)
            if settings.isEnabled(.clipboard) {
                clipboard.add(ClipboardItem(id: UUID(), kind: .text, copiedAt: .now, text: text, byteCount: text.utf8.count,
                                        sourceBundleID: Bundle.main.bundleIdentifier, contentHash: ClipboardItem.hash(ofText: text)))
            }
        }, words: words)
    }

    var isActive: Bool { phase != .idle }

    func start() { begin(file: nil, delivery: .insert) }

    func transcribeFile(_ url: URL, paste: Bool) {
        begin(file: url, delivery: paste ? .insert : .copy)
    }

    private func begin(file: URL?, delivery: DictationDelivery) {
        guard !phase.isBusy else { return }
        abandonSession()
        let session = makeEngine()
        engine = session
        let token = attempt
        self.delivery = delivery
        pendingFinish = nil
        document = DictationTranscript()
        editingWordID = nil
        elapsed = 0
        canRetry = false
        levels = Array(repeating: 0, count: levels.count)
        phase = .preparing(file == nil ? "Getting ready…" : "Transcribing file…")
        bind(session, token: token)
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let locale = try await prepare { [weak self] fraction in
                    guard let self, attempt == token, phase.isBusy else { return }
                    phase = .preparing("Downloading speech model… \(Int(fraction * 100))%")
                }
                guard attempt == token, !Task.isCancelled else { return }
                self.locale = locale
                session.vocabulary = words?.vocabulary ?? []
                if let file {
                    phase = .finalizing
                    let text = try await session.transcribe(file: file, locale: locale)
                    guard attempt == token, !Task.isCancelled else { return }
                    complete(text, session: session)
                } else {
                    try await session.start(locale: locale)
                    guard attempt == token, !Task.isCancelled else { await session.cancel(); return }
                    phase = .recording
                    if let requested = pendingFinish {
                        pendingFinish = nil
                        finish(requested)
                    } else {
                        startTimer()
                    }
                }
            } catch {
                guard attempt == token, !Task.isCancelled else { return }
                fail(error.localizedDescription, session: session, token: token)
            }
        }
    }

    func finish(_ action: DictationDelivery) {
        if case .preparing = phase {
            if pendingFinish == nil { pendingFinish = action }
            return
        }
        guard phase == .recording, let engine else { return }
        cancelEditing()
        delivery = action
        finalize(engine, retry: false)
    }

    /// Compatibility for automation clients. Live controls use explicit actions.
    func finish(paste: Bool) { finish(paste ? .insert : .copy) }

    func retry() {
        guard case .failed = phase, canRetry, let engine else { return }
        finalize(engine, retry: true)
    }

    private func finalize(_ session: any DictationEngineSession, retry: Bool) {
        phase = .finalizing
        canRetry = false
        stopTimer()
        let token = attempt
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let result: DictationTranscript
                if retry { result = try await session.retry() } else { result = try await session.stop() }
                guard attempt == token, !Task.isCancelled else { return }
                complete(result, session: session)
            } catch {
                guard attempt == token, !Task.isCancelled else { return }
                fail(error.localizedDescription, session: session, token: token)
            }
        }
    }

    func cancel() {
        guard isActive else { return }
        abandonSession()
        phase = .idle
        document = DictationTranscript()
        canRetry = false
        delivery = .insert
        onDidEnd?()
    }

    private func abandonSession() {
        pendingFinish = nil
        editingWordID = nil
        attempt += 1
        operation?.cancel()
        operation = nil
        stopTimer()
        if let old = engine {
            old.onTranscript = nil
            old.onVolume = nil
            old.onError = nil
            old.discardRecording()
            Task { await old.cancel() }
        }
        engine = nil
    }

    private func bind(_ session: any DictationEngineSession, token: Int) {
        session.onTranscript = { [weak self] incoming in
            guard let self, attempt == token, phase.isBusy else { return }
            document = document.merging(incoming)
        }
        session.onVolume = { [weak self] level in
            guard let self, attempt == token, phase == .recording else { return }
            levels.removeFirst()
            levels.append(level)
        }
        session.onError = { [weak self, weak session] error in
            guard let self, let session, attempt == token, phase.isBusy else { return }
            fail(error.localizedDescription, session: session, token: token)
        }
    }

    private func complete(_ result: DictationTranscript, session: any DictationEngineSession) {
        // Corrections you made in the notch outrank the engine's own text.
        let merged = document.merging(result)
        let corrected = words?.apply(to: merged.text) ?? merged.text
        let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = delivery
        session.discardRecording()
        session.onError = nil
        phase = .idle
        document = DictationTranscript(settledText: trimmed)
        editingWordID = nil
        canRetry = false
        engine = nil
        delivery = .insert
        if trimmed.isEmpty { onDidEnd?() } else { deliverText(trimmed, action) }
    }

    // MARK: Correcting a word

    /// Opens the correction popover and pauses the microphone, so what you type is not transcribed.
    func beginEditing(_ id: UUID) {
        guard phase == .recording, document.word(id) != nil else { return }
        editingWordID = id
        engine?.setCapturePaused(true)
    }

    /// Closes the popover and hands the microphone back.
    func cancelEditing() {
        guard editingWordID != nil else { return }
        editingWordID = nil
        engine?.setCapturePaused(false)
    }

    /// Replaces the word being edited and teaches it. A word the recogniser already doubted, or a
    /// replacement taken from its own alternatives, is trusted at once; anything else waits for a
    /// second sighting so one rewording never becomes a permanent rule.
    func applyEdit(_ replacement: String) {
        guard let id = editingWordID, let word = document.word(id) else { return }
        let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { cancelEditing(); return }
        let trusted = word.isUncertain || word.alternatives.contains(trimmed)
        if let previous = document.replace(id, with: trimmed) {
            words?.record(heard: previous, meant: trimmed, confirmed: trusted)
        }
        cancelEditing()
    }

    /// Drops the word. Deletions teach nothing about spelling, so nothing is stored.
    func removeEditingWord() {
        guard let id = editingWordID else { return }
        document.remove(id)
        cancelEditing()
    }

    private func fail(_ message: String, session: any DictationEngineSession, token: Int) {
        guard phase.isBusy else { return }
        stopTimer()
        operation?.cancel()
        phase = .failed(message)
        canRetry = false
        Log.app.error("dictation failed: \(message)")
        operation = Task { [weak self] in
            await session.suspend()
            guard let self, attempt == token, !Task.isCancelled else { return }
            canRetry = session.canRetry
        }
    }

    private func startTimer() {
        stopTimer()
        let start = ContinuousClock.now
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                let duration = start.duration(to: .now).components
                elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            }
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}
