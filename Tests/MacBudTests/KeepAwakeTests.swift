import IOKit.pwr_mgt
import Testing
@testable import MacBud

@Suite struct KeepAwakeTests {
    @Test func startsOffWithoutAcquiringAssertions() {
        let driver = FakeDriver()
        let controller = KeepAwakeController(driver: driver)
        #expect(!controller.isActive)
        #expect(driver.active.isEmpty)
    }

    @Test func checkboxKeepsSystemAndDisplayAwakeUntilUnchecked() {
        let driver = FakeDriver()
        let controller = KeepAwakeController(driver: driver)
        controller.setEnabled(true)
        #expect(controller.isActive)
        #expect(driver.active == [1: .system, 2: .display])
        controller.setEnabled(true)
        #expect(driver.active == [1: .system, 2: .display], "Repeated enable cannot leak assertions")
        controller.setEnabled(false)
        controller.stop()
        #expect(!controller.isActive)
        #expect(driver.active.isEmpty)
        #expect(driver.released == [1, 2])
    }

    @Test func failedStartLeavesCheckboxOff() {
        let driver = FakeDriver()
        driver.failingKind = .system
        let controller = KeepAwakeController(driver: driver)
        controller.start()
        #expect(!controller.isActive)
        #expect(controller.errorMessage != nil)
        #expect(driver.active.isEmpty)
    }

    @Test func partialFailureRollsBackThenCanBeRetried() {
        let driver = FakeDriver()
        driver.failingKind = .display
        let controller = KeepAwakeController(driver: driver)
        controller.start()
        #expect(!controller.isActive)
        #expect(controller.errorMessage != nil)
        #expect(driver.active.isEmpty)
        #expect(driver.released == [1])
        driver.failingKind = nil
        controller.start()
        #expect(controller.isActive)
        #expect(controller.errorMessage == nil)
        #expect(driver.active == [2: .system, 3: .display])
        controller.stop()
    }

    @Test func callbackMirrorsCheckboxAndFailure() {
        let driver = FakeDriver()
        let controller = KeepAwakeController(driver: driver)
        var states: [Bool] = []
        controller.onChange = { states.append(controller.isActive) }
        controller.start()
        controller.stop()
        driver.failingKind = .system
        controller.start()
        #expect(states == [true, false, false])
        controller.onChange = nil
    }

    private final class FakeDriver: KeepAwakeAssertionDriver {
        var active: [IOPMAssertionID: KeepAwakeAssertionKind] = [:]
        var released: [IOPMAssertionID] = []
        var failingKind: KeepAwakeAssertionKind?
        private var nextID: IOPMAssertionID = 1

        func acquire(_ kind: KeepAwakeAssertionKind) throws -> IOPMAssertionID {
            if kind == failingKind { throw Failure() }
            let id = nextID
            nextID += 1
            active[id] = kind
            return id
        }

        func release(_ assertion: IOPMAssertionID) {
            released.append(assertion)
            active.removeValue(forKey: assertion)
        }

        private struct Failure: Error {}
    }
}
