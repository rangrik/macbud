import AVFoundation
import Speech

/// Each engine owns one recording. Recognition attempts can be replaced without
/// losing that audio, and late results can only update their original attempt.
@MainActor final class DictationEngine {
    enum EngineError: LocalizedError {
        case microphoneDenied, localeUnsupported(Locale), noAudioFormat, notRunning
        case noRecording, microphoneChanged, startupTimedOut, finalizationTimedOut

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone access is off. Allow it in System Settings › Privacy & Security › Microphone."
            case .localeUnsupported(let locale): "\(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) isn't supported for dictation."
            case .noAudioFormat: "No compatible microphone audio format is available. Check your input device in System Settings › Sound."
            case .notRunning: "Dictation isn't running."
            case .noRecording: "There is no saved audio to retry. Start a new recording."
            case .microphoneChanged: "The microphone changed or disconnected. Retry the audio already recorded, or discard it and start again."
            case .startupTimedOut: "Dictation took too long to start. Try again."
            case .finalizationTimedOut: "Transcription took too long. Your recording is saved; try again."
            }
        }
    }

    private final class Attempt {
        let id = UUID()
        let transcriber: DictationTranscriber
        let analyzer: SpeechAnalyzer
        var collector: Task<Void, Error>?
        var settled: [DictationSegment] = []
        var draft: DictationSegment?
        var failure: Error?
        var valid = true

        init(locale: Locale) {
            transcriber = DictationTranscriber(locale: locale, preset: DictationEngine.preset)
            analyzer = SpeechAnalyzer(modules: [transcriber])
        }

        var transcript: DictationTranscript {
            DictationTranscript(attemptID: id, settled: settled, draft: draft)
        }
    }

    /// Apple's long-dictation preset plus the three things the notch needs: words settling after a
    /// pause instead of at the end, how sure the recogniser was, and what it nearly picked instead.
    static let preset: DictationTranscriber.Preset = {
        var preset = DictationTranscriber.Preset.progressiveLongDictation
        preset.reportingOptions.formUnion([.volatileResults, .frequentFinalization, .alternativeTranscriptions])
        preset.attributeOptions.formUnion([.transcriptionConfidence, .audioTimeRange])
        return preset
    }()

    private let audioEngine = AVAudioEngine()
    private var attempt: Attempt?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false
    private var audioCapture: DictationAudioCapture?
    private var recording: DictationRecording?
    private var recordingLocale: Locale?
    private var cleanupTask: Task<Void, Never>?
    private let recordingDirectory: URL

    init(recordingDirectory: URL = FileManager.default.temporaryDirectory) {
        self.recordingDirectory = recordingDirectory
    }

    var onTranscript: (@MainActor @Sendable (DictationTranscript) -> Void)?
    var onVolume: (@MainActor @Sendable (Float) -> Void)?
    var onError: (@MainActor @Sendable (Error) -> Void)?

    private(set) var isRunning = false
    /// Words to bias the recogniser towards. Read when an attempt starts.
    var vocabulary: [String] = []
    private(set) var isCapturePaused = false
    var canRetry: Bool { recording?.hasAudio == true && recordingLocale != nil }

    // MARK: Locales & assets

    static func supportedLocales() async -> [Locale] { await DictationTranscriber.supportedLocales }
    static func installedLocales() async -> [Locale] { await DictationTranscriber.installedLocales }

    static func resolveLocale(preferred identifier: String) async -> Locale? {
        let supported = await supportedLocales()
        func match(_ locale: Locale) -> Locale? {
            supported.first { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
                ?? supported.first { $0.language.languageCode == locale.language.languageCode }
        }
        if !identifier.isEmpty, let exact = match(Locale(identifier: identifier)) { return exact }
        if let current = match(Locale.current) { return current }
        return match(Locale(identifier: "en-US")) ?? supported.first
    }

    /// Makes sure the speech model for `locale` is on disk, downloading it if needed.
    static func ensureAssets(for locale: Locale, progress: @escaping @MainActor (Double) -> Void) async throws {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .unsupported:
            throw EngineError.localeUnsupported(locale)
        default:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
            let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
                let value = p.fractionCompleted
                Task { @MainActor in progress(value) }
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }
    }

    static func assetStatus(for locale: Locale) async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [DictationTranscriber(locale: locale, preset: .progressiveLongDictation)])
    }

    // MARK: Microphone session

    func start(locale: Locale) async throws {
        guard !isRunning else { return }
        await suspend()
        try Task.checkCancellation()
        discardRecording()
        let attempt = beginAttempt(locale: locale)
        do {
            guard await Self.requestMicrophone() else { throw EngineError.microphoneDenied }
            try checkCurrent(attempt)
            guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [attempt.transcriber]) else {
                throw EngineError.noAudioFormat
            }
            try checkCurrent(attempt)
            let input = audioEngine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw EngineError.noAudioFormat }
            let recording = try DictationRecording(format: inputFormat, directory: recordingDirectory)
            self.recording = recording
            recordingLocale = locale
            let capture = try DictationAudioCapture(inputFormat: inputFormat, targetFormat: targetFormat, recording: recording)
            audioCapture = capture
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            inputContinuation = continuation
            try await applyVocabulary(to: attempt)
            collectResults(for: attempt)
            do {
                try await DictationDeadline.run(timeout: .seconds(30)) {
                    try await attempt.analyzer.start(inputSequence: stream)
                }
            } catch EngineError.finalizationTimedOut {
                throw EngineError.startupTimedOut
            }
            try checkCurrent(attempt)

            // AVFAudio invokes this on its audio queue. Without @Sendable the
            // closure inherits MainActor isolation and traps on the first buffer.
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable [weak self] buffer, _ in
                do {
                    guard let output = try capture.process(buffer) else { return }
                    continuation.yield(output.input)
                    Task { @MainActor [weak self] in
                        guard let self, self.attempt === attempt, self.isRunning else { return }
                        self.onVolume?(output.volume)
                    }
                } catch {
                    Task { @MainActor [weak self] in self?.captureFailed(error, attempt: attempt) }
                }
            }
            tapInstalled = true
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil
            ) { [weak self] _ in
                // The notification arrives on an audio queue; tear down on the main actor.
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else { return }
                    self.captureFailed(EngineError.microphoneChanged, attempt: attempt)
                }
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
        } catch {
            endAttempt(attempt, cancelAnalyzer: true)
            throw error
        }
    }

    /// Stop the microphone and seal its file before waiting for the final words.
    func stop() async throws -> DictationTranscript {
        guard isRunning, let attempt else { throw EngineError.notRunning }
        let captureError = stopCapture(drainConverter: true)
        do {
            if let captureError { throw captureError }
            if recording?.hasAudibleAudio != true {
                try checkCurrent(attempt)
                let empty = DictationTranscript(attemptID: attempt.id)
                endAttempt(attempt, cancelAnalyzer: true)
                onTranscript?(empty)
                return empty
            }
            try await finish(attempt, duration: recording?.duration ?? 0)
            try checkCurrent(attempt)
            let transcript = attempt.transcript
            endAttempt(attempt, cancelAnalyzer: false)
            return transcript
        } catch {
            endAttempt(attempt, cancelAnalyzer: true)
            throw error
        }
    }

    /// Replay the sealed recording, without accessing the microphone again.
    func retry() async throws -> DictationTranscript {
        await suspend()
        try Task.checkCancellation()
        guard let recording, let locale = recordingLocale, recording.hasAudio else { throw EngineError.noRecording }
        return try await recognizeFile(recording.url, locale: locale, duration: recording.duration)
    }

    /// Stops microphone/analyzer resources while preserving the saved recording.
    func suspend() async {
        if let attempt { endAttempt(attempt, cancelAnalyzer: true) }
        else { stopCapture() }
        await cleanupTask?.value
    }

    /// Used after delivery/discard. This removes only MacBud's own temporary file.
    func discardRecording() {
        recording?.discard()
        recording = nil
        recordingLocale = nil
    }

    func cancel() async {
        if let attempt { endAttempt(attempt, cancelAnalyzer: true) }
        else { stopCapture() }
        discardRecording()
        await cleanupTask?.value
    }

    /// Imports and retains a private copy, so file-transcription failures can also retry.
    /// The caller's source file is never changed or removed.
    func transcribe(file url: URL, locale: Locale) async throws -> DictationTranscript {
        await suspend()
        try Task.checkCancellation()
        discardRecording()
        let source = try AVAudioFile(forReading: url)
        let recording = try DictationRecording(format: source.processingFormat, directory: recordingDirectory)
        self.recording = recording
        recordingLocale = locale
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_384) else {
            recording.close()
            throw EngineError.noAudioFormat
        }
        do {
            while source.framePosition < source.length {
                try Task.checkCancellation()
                try source.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try recording.append(buffer)
                // Imported audio can be long; allow cancellation between bounded chunks.
                await Task.yield()
                guard self.recording === recording else { throw CancellationError() }
            }
            recording.close()
            try Task.checkCancellation()
            return try await recognizeFile(recording.url, locale: locale, duration: recording.duration)
        } catch {
            recording.close()
            throw error
        }
    }

    // MARK: Recognition lifecycle

    /// Pauses the microphone while you correct a word, so keystrokes and muttering never reach
    /// the recogniser or the saved recording.
    func setCapturePaused(_ paused: Bool) {
        guard isRunning, isCapturePaused != paused else { return }
        isCapturePaused = paused
        audioCapture?.setPaused(paused)
    }

    private func applyVocabulary(to attempt: Attempt) async throws {
        guard !vocabulary.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        try await attempt.analyzer.setContext(context)
    }

    /// Words with the recogniser's own confidence and runners-up attached. A styling run can start
    /// or end mid-word, so a word keeps the lowest confidence of every run it spans.
    private static func segment(from result: DictationTranscriber.Result) -> DictationSegment {
        var texts: [String] = []
        var confidences: [Double?] = []
        var current = ""
        var currentConfidence: Double?
        func flush() {
            guard !current.isEmpty else { return }
            texts.append(current)
            confidences.append(currentConfidence)
            current = ""
            currentConfidence = nil
        }
        for run in result.text.runs {
            let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
            for character in result.text[run.range].characters {
                guard !character.isWhitespace else { flush(); continue }
                current.append(character)
                if let confidence { currentConfidence = min(currentConfidence ?? confidence, confidence) }
            }
        }
        flush()
        let runnersUp = result.alternatives.map { DictationSegment.split(String($0.characters)) }
        let alternatives = DictationTranscript.alignedAlternatives(chosen: texts, runnersUp: runnersUp)
        return DictationSegment(words: texts.indices.map {
            DictationWord(text: texts[$0], confidence: confidences[$0], alternatives: alternatives[$0])
        })
    }

    private func beginAttempt(locale: Locale) -> Attempt {
        let attempt = Attempt(locale: locale)
        self.attempt = attempt
        return attempt
    }

    private func collectResults(for attempt: Attempt) {
        attempt.collector = Task { [weak self, weak attempt] in
            guard let attempt else { return }
            do {
                for try await result in attempt.transcriber.results {
                    guard let self else { throw CancellationError() }
                    try self.checkCurrent(attempt)
                    let segment = DictationEngine.segment(from: result)
                    if result.isFinal {
                        if !segment.isEmpty { attempt.settled.append(segment) }
                        attempt.draft = nil
                    } else {
                        attempt.draft = segment.isEmpty ? nil : segment
                    }
                    self.onTranscript?(attempt.transcript)
                }
            } catch {
                if let self, self.attempt === attempt, attempt.valid, !Task.isCancelled {
                    attempt.failure = error
                    if self.isRunning { self.captureFailed(error, attempt: attempt) }
                }
                throw error
            }
        }
    }

    private func recognizeFile(_ url: URL, locale: Locale, duration: TimeInterval) async throws -> DictationTranscript {
        try Task.checkCancellation()
        // The retained copy measured every sample while writing. Avoid starting
        // speech services for silence, which must never become invented words.
        guard recording?.hasAudibleAudio == true else {
            let empty = DictationTranscript()
            onTranscript?(empty)
            return empty
        }
        let attempt = beginAttempt(locale: locale)
        do {
            let file = try AVAudioFile(forReading: url)
            try await applyVocabulary(to: attempt)
            collectResults(for: attempt)
            // Bound file startup as well as finalization: both can wait on model services.
            try await DictationDeadline.run(timeout: finalizationBudget(duration: duration)) {
                try await attempt.analyzer.start(inputAudioFile: file, finishAfterFile: true)
                try await attempt.analyzer.finalizeAndFinishThroughEndOfInput()
                try await attempt.collector?.value
            }
            try checkCurrent(attempt)
            let transcript = attempt.transcript
            endAttempt(attempt, cancelAnalyzer: false)
            return transcript
        } catch {
            endAttempt(attempt, cancelAnalyzer: true)
            throw error
        }
    }

    private func finish(_ attempt: Attempt, duration: TimeInterval) async throws {
        try await DictationDeadline.run(timeout: finalizationBudget(duration: duration)) {
            try await attempt.analyzer.finalizeAndFinishThroughEndOfInput()
            try await attempt.collector?.value
        }
    }

    private func finalizationBudget(duration: TimeInterval) -> Duration {
        .seconds(min(300, max(15, 10 + duration * 1.5)))
    }

    private func checkCurrent(_ attempt: Attempt) throws {
        try Task.checkCancellation()
        if let failure = attempt.failure { throw failure }
        guard self.attempt === attempt, attempt.valid else { throw CancellationError() }
    }

    private func captureFailed(_ error: Error, attempt: Attempt) {
        guard self.attempt === attempt, attempt.valid else { return }
        attempt.failure = error
        endAttempt(attempt, cancelAnalyzer: true)
        onError?(error)
    }

    @discardableResult
    private func stopCapture(drainConverter: Bool = false) -> Error? {
        isRunning = false
        isCapturePaused = false
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine.stop()
        var captureError: Error?
        if drainConverter {
            do {
                for input in try audioCapture?.finish() ?? [] { inputContinuation?.yield(input) }
            } catch {
                captureError = error
            }
        }
        audioCapture = nil
        recording?.close()
        inputContinuation?.finish()
        inputContinuation = nil
        return captureError
    }

    private func endAttempt(_ attempt: Attempt, cancelAnalyzer: Bool) {
        guard self.attempt === attempt else { return }
        attempt.valid = false
        stopCapture()
        self.attempt = nil
        attempt.collector?.cancel()
        attempt.collector = nil
        if cancelAnalyzer {
            let analyzer = attempt.analyzer
            cleanupTask = Task {
                // Framework cancellation must not keep Retry/Discard disabled indefinitely.
                try? await DictationDeadline.run(timeout: .seconds(2)) {
                    await analyzer.cancelAndFinishNow()
                }
            }
        }
    }

    private static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
