import AppKit

/// Escape works whether AppKit routes the event to MacBud or to the app retaining keyboard focus.
/// Carbon consumes the global chord; these monitors cover events delivered directly to an application.
final class DictationEscapeMonitor {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var cancel: (() -> Void)?

    func start(cancel: @escaping () -> Void) {
        stop()
        self.cancel = cancel
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) == true }
            return handled ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handle(event) }
        }
    }

    func stop() {
        cancel = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        // Leave Command-Option-Escape and ordinary input to the system/target app.
        guard event.keyCode == 53, !event.modifierFlags.contains(.command), let cancel else { return false }
        cancel()
        return true
    }
}
