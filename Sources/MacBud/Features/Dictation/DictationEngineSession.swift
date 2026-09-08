import Foundation

/// The controller's session boundary lets lifecycle tests run without microphone permission.
@MainActor
protocol DictationEngineSession: AnyObject {
    var onTranscript: (@MainActor @Sendable (DictationTranscript) -> Void)? { get set }
    var onVolume: (@MainActor @Sendable (Float) -> Void)? { get set }
    var onError: (@MainActor @Sendable (Error) -> Void)? { get set }
    var canRetry: Bool { get }
    var vocabulary: [String] { get set }
    func start(locale: Locale) async throws
    func stop() async throws -> DictationTranscript
    func retry() async throws -> DictationTranscript
    func suspend() async
    func discardRecording()
    func cancel() async
    func setCapturePaused(_ paused: Bool)
    func transcribe(file: URL, locale: Locale) async throws -> DictationTranscript
}

extension DictationEngine: DictationEngineSession {}

nonisolated enum DictationDelivery: Equatable, Sendable {
    case insert, copy
}
