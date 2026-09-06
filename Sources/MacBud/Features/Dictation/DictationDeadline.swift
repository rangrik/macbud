import Foundation

/// An unstructured race lets a timeout return even if a framework operation does
/// not promptly cooperate with task cancellation. Only the winner resumes the waiter.
@MainActor final class DictationDeadline {
    private var continuation: CheckedContinuation<Void, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    static func run(
        timeout: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        let deadline = DictationDeadline()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                deadline.continuation = continuation
                deadline.work = Task {
                    do {
                        try await operation()
                        deadline.finish(.success(()))
                    } catch {
                        deadline.finish(.failure(error))
                    }
                }
                deadline.timer = Task {
                    do {
                        try await Task.sleep(for: timeout)
                        deadline.finish(.failure(DictationEngine.EngineError.finalizationTimedOut))
                    } catch { /* The operation or its caller already finished. */ }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor in deadline.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        work?.cancel()
        timer?.cancel()
        work = nil
        timer = nil
        continuation.resume(with: result)
    }
}
