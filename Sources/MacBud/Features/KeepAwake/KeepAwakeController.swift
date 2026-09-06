import Foundation
import IOKit.pwr_mgt
import Observation

enum KeepAwakeAssertionKind: Equatable {
    case system
    case display
}

protocol KeepAwakeAssertionDriver {
    func acquire(_ kind: KeepAwakeAssertionKind) throws -> IOPMAssertionID
    func release(_ assertion: IOPMAssertionID)
}

struct SystemKeepAwakeAssertionDriver: KeepAwakeAssertionDriver {
    func acquire(_ kind: KeepAwakeAssertionKind) throws -> IOPMAssertionID {
        let type = kind == .system
            ? kIOPMAssertionTypePreventUserIdleSystemSleep
            : kIOPMAssertionTypePreventUserIdleDisplaySleep
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacBud Keep Awake" as CFString,
            &assertion
        )
        guard result == kIOReturnSuccess else { throw AssertionError(code: result) }
        return assertion
    }

    func release(_ assertion: IOPMAssertionID) {
        IOPMAssertionRelease(assertion)
    }

    private struct AssertionError: LocalizedError {
        let code: IOReturn

        var errorDescription: String? {
            "macOS couldn’t enable Keep Awake (\(code)). Try again."
        }
    }
}

/// Owns an indefinite session independently of whether the notch is open.
@Observable
final class KeepAwakeController {
    private(set) var isActive = false
    private(set) var errorMessage: String?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let driver: any KeepAwakeAssertionDriver
    @ObservationIgnored private var assertions: [IOPMAssertionID] = []

    init(driver: any KeepAwakeAssertionDriver = SystemKeepAwakeAssertionDriver()) {
        self.driver = driver
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    func start() {
        guard !isActive else { return }
        var acquired: [IOPMAssertionID] = []
        do {
            acquired.append(try driver.acquire(.system))
            acquired.append(try driver.acquire(.display))
        } catch {
            acquired.forEach(driver.release)
            errorMessage = error.localizedDescription
            onChange?()
            return
        }
        assertions = acquired
        isActive = true
        errorMessage = nil
        onChange?()
    }

    /// Safe to call repeatedly, including when the app quits.
    func stop() {
        assertions.forEach(driver.release)
        assertions.removeAll()
        isActive = false
        errorMessage = nil
        onChange?()
    }
}
