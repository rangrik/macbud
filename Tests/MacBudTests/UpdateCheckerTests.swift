import Testing
@testable import MacBud

@Suite struct UpdateCheckerTests {
    /// A string compare would offer 0.9.0 as an update over 0.10.0, and re-offer what you already run.
    @Test func onlyAHigherVersionCountsAsAnUpdate() {
        #expect(UpdateChecker.isNewer("0.10.0", than: "0.9.0"))
        #expect(UpdateChecker.isNewer("0.6.0", than: "0.5.1"))
        #expect(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        #expect(!UpdateChecker.isNewer("0.9.0", than: "0.10.0"))
        #expect(!UpdateChecker.isNewer("0.5.1", than: "0.5.1"))
        #expect(!UpdateChecker.isNewer("0.5.1", than: "0.5.1.1"))
    }
}
