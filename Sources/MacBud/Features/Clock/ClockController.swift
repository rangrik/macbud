import Foundation
import Observation

/// The time shown in the notch. Minutes are all it displays, so it sleeps to the
/// next minute instead of ticking every second.
@Observable
final class ClockController {
    private(set) var text: String
    private(set) var isRunning = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        text = Self.format(now())
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    func start() {
        guard task == nil else { return }
        isRunning = true
        tick()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(Self.secondsToNextMinute(from: now())))
                guard !Task.isCancelled else { return }
                tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func tick() {
        let next = Self.format(now())
        guard next != text else { return }
        text = next
        onChange?()
    }

    nonisolated static func format(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Land just after the minute turns, never just before it.
    nonisolated static func secondsToNextMinute(from date: Date) -> Double {
        let second = Double(Calendar.current.component(.second, from: date))
        return max(60 - second, 1) + 0.2
    }
}
