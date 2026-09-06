import Foundation

/// The controller's session boundary lets lifecycle tests run without microphone permission.
@MainActor
protocol DictationEngineSession: AnyObject {
    var onTranscript: (@MainActor @Sendable (String) -> Void)? { get set }
    var onVolume: (@MainActor @Sendable (Float) -> Void)? { get set }
    var onError: (@MainActor @Sendable (Error) -> Void)? { get set }
    var canRetry: Bool { get }
    func start(locale: Locale) async throws
    func stop() async throws -> String
    func retry() async throws -> String
    func suspend() async
    func discardRecording()
    func cancel() async
    func transcribe(file: URL, locale: Locale) async throws -> String
}

extension DictationEngine: DictationEngineSession {}

nonisolated enum DictationDelivery: Equatable, Sendable {
    case insert, copy
}
