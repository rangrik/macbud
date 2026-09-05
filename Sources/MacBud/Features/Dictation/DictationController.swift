import AppKit

nonisolated enum DictationPhase: Equatable, Sendable {
    case idle
    case preparing(String)
    case recording
    case finalizing
    case failed(String)

    var isBusy: Bool { self == .recording || self == .finalizing || { if case .preparing = self { return true }; return false }() }
}

/// Push-to-talk dictation: hotkey → speak → ↩ inserts (or copies) the text, esc discards.
@Observable
final class DictationController {
    private(set) var phase: DictationPhase = .idle
    private(set) var transcript = ""
    /// Recent microphone levels, newest last, for the level meter.
    private(set) var levels: [Float] = Array(repeating: 0, count: 28)
    private(set) var elapsed: TimeInterval = 0
    private(set) var locale: Locale?

    @ObservationIgnored private let engine = DictationEngine()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let context: ActionContext
    @ObservationIgnored private let clipboard: ClipboardStore
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var attempt = 0

    /// Fired when dictation ends without delivering text (cancel / empty), so the island can close.
    var onDidEnd: (() -> Void)?

    init(settings: AppSettings, context: ActionContext, clipboard: ClipboardStore) {
        self.settings = settings
        self.context = context
        self.clipboard = clipboard
        engine.onTranscript = { [weak self] text in self?.transcript = text }
        engine.onVolume = { [weak self] level in self?.pushLevel(level) }
        engine.onError = { [weak self] error in self?.fail(error.localizedDescription) }
    }

    var isActive: Bool { phase != .idle }

    // MARK: Lifecycle

    func start() {
        guard !phase.isBusy else { return }
        attempt += 1
        let myAttempt = attempt
        transcript = ""
        elapsed = 0
        levels = Array(repeating: 0, count: levels.count)
        phase = .preparing("Getting ready…")
        Task {
            do {
                guard let locale = await DictationEngine.resolveLocale(preferred: settings.dictationLocale) else {
                    throw DictationEngine.EngineError.localeUnsupported(Locale.current)
                }
                self.locale = locale
                try await DictationEngine.ensureAssets(for: locale) { [weak self] fraction in
                    guard let self, attempt == myAttempt else { return }
                    phase = .preparing("Downloading speech model… \(Int(fraction * 100))%")
                }
                guard attempt == myAttempt else { return }
                try await engine.start(locale: locale)
                guard attempt == myAttempt else { await engine.cancel(); return }
                phase = .recording
                startedAt = .now
                startTimer()
                Log.app.info("dictation recording in \(locale.identifier)")
            } catch {
                guard attempt == myAttempt else { return }
                fail(error.localizedDescription)
            }
        }
    }

    /// Stops recording and delivers the text (paste into the previous app, or copy).
    func finish(paste: Bool) {
        guard phase == .recording else { return }
        phase = .finalizing
        stopTimer()
        let myAttempt = attempt
        Task {
            do {
                let text = try await engine.stop()
                guard attempt == myAttempt else { return }
                deliver(text, paste: paste)
            } catch {
                guard attempt == myAttempt else { return }
                fail(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard isActive else { return }
        attempt += 1
        stopTimer()
        phase = .idle
        transcript = ""
        Task { await engine.cancel() }
        onDidEnd?()
    }

    /// Runs the pipeline on an audio file instead of the microphone (automation and tests).
    func transcribeFile(_ url: URL, paste: Bool) {
        guard !phase.isBusy else { return }
        attempt += 1
        let myAttempt = attempt
        transcript = ""
        phase = .preparing("Transcribing file…")
        Task {
            do {
                guard let locale = await DictationEngine.resolveLocale(preferred: settings.dictationLocale) else {
                    throw DictationEngine.EngineError.localeUnsupported(Locale.current)
                }
                self.locale = locale
                try await DictationEngine.ensureAssets(for: locale) { [weak self] fraction in
                    self?.phase = .preparing("Downloading speech model… \(Int(fraction * 100))%")
                }
                phase = .finalizing
                let text = try await engine.transcribe(file: url, locale: locale)
                guard attempt == myAttempt else { return }
                deliver(text, paste: paste)
            } catch {
                guard attempt == myAttempt else { return }
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: Internals

    private func deliver(_ text: String, paste: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .idle
        guard !trimmed.isEmpty else {
            context.showHint("Nothing heard")
            transcript = ""
            onDidEnd?()
            return
        }
        transcript = trimmed
        let paster = context.paster
        let description = trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : trimmed
        context.perform(paste: paste, description: description) {
            paster.write(text: trimmed)
        }
        clipboard.add(ClipboardItem(id: UUID(), kind: .text, copiedAt: .now, text: trimmed, byteCount: trimmed.utf8.count,
                                    sourceBundleID: Bundle.main.bundleIdentifier, contentHash: ClipboardItem.hash(ofText: trimmed)))
    }

    private func fail(_ message: String) {
        stopTimer()
        phase = .failed(message)
        Log.app.error("dictation failed: \(message)")
        Task { await engine.cancel() }
    }

    private func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let startedAt else { return }
                elapsed = Date.now.timeIntervalSince(startedAt)
            }
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}
