import AVFoundation
import Speech

/// On-device speech-to-text using the macOS 26 Speech framework (`SpeechAnalyzer` + `DictationTranscriber`).
/// Audio from the microphone is converted to the analyzer's preferred format and streamed in; volatile
/// results give live text while speaking, final results arrive after `stop()`.
final class DictationEngine {
    enum EngineError: LocalizedError {
        case microphoneDenied, localeUnsupported(Locale), noAudioFormat, notRunning

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone access is off. Allow it in System Settings › Privacy & Security › Microphone."
            case .localeUnsupported(let l): "\(l.localizedString(forIdentifier: l.identifier) ?? l.identifier) isn't supported for dictation."
            case .noAudioFormat: "No compatible audio format for the speech model."
            case .notRunning: "Dictation isn't running."
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalSegments: [String] = []
    private var volatileSegment = ""

    /// Live text (finalized segments plus the current volatile guess).
    var onTranscript: ((String) -> Void)?
    /// 0…1 microphone level, ~20 times a second.
    var onVolume: ((Float) -> Void)?
    var onError: ((Error) -> Void)?

    private(set) var isRunning = false

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
        guard await Self.requestMicrophone() else { throw EngineError.microphoneDenied }
        finalSegments = []
        volatileSegment = ""

        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.noAudioFormat
        }
        self.transcriber = transcriber
        self.analyzer = analyzer

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { throw EngineError.noAudioFormat }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        nonisolated(unsafe) let unsafeConverter = converter
        let onVolume = self.onVolume
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            if let onVolume {
                let level = Self.rmsLevel(of: buffer)
                Task { @MainActor in onVolume(level) }
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            let status = unsafeConverter.convert(to: converted, error: &error) { _, outStatus in
                if consumed { outStatus.pointee = .noDataNow; return nil }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, converted.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalSegments.append(text)
                        volatileSegment = ""
                    } else {
                        volatileSegment = text
                    }
                    onTranscript?(assembledText)
                }
            } catch {
                self?.onError?(error)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        try await analyzer.start(inputSequence: stream)
        isRunning = true
    }

    /// Stops capturing, waits for the final transcript and returns it.
    func stop() async throws -> String {
        guard isRunning, let analyzer else { throw EngineError.notRunning }
        isRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        resultsTask = nil
        self.analyzer = nil
        transcriber = nil
        return assembledText
    }

    func cancel() async {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        isRunning = false
    }

    /// Transcribes an audio file with the same pipeline (used by tests and automation).
    func transcribe(file url: URL, locale: Locale) async throws -> String {
        finalSegments = []
        volatileSegment = ""
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)
        let collector = Task { [weak self] in
            for try await result in transcriber.results {
                guard let self else { return }
                let text = String(result.text.characters)
                if result.isFinal { finalSegments.append(text); volatileSegment = "" } else { volatileSegment = text }
                onTranscript?(assembledText)
            }
        }
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await collector.value
        return assembledText
    }

    // MARK: Helpers

    private var assembledText: String {
        (finalSegments + [volatileSegment]).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    nonisolated private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in 0..<n { sum += channel[i] * channel[i] }
        let rms = sqrt(sum / Float(n))
        return min(1, rms * 4)
    }
}
