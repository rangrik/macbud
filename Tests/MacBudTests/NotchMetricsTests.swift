import CoreGraphics
import Testing
@testable import MacBud

@Suite struct NotchMetricsTests {
    private let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                                         notchRect: CGRect(x: 918, y: 1291, width: 220, height: 38), hasPhysicalNotch: true)

    @Test func framesHugTheScreenTopAndCentreOnTheNotch() {
        let m = NotchMetrics()
        for frame in [m.expandedWindowFrame(for: geometry), m.dictationWindowFrame(for: geometry),
                      m.collapsedWindowFrame(for: geometry, tab: true), m.collapsedWindowFrame(for: geometry, tab: false)] {
            #expect(frame.maxY == 1329)
            #expect(abs(frame.midX - 1028) < 0.01)
        }
        #expect(m.collapsedWindowFrame(for: geometry, tab: false) == geometry.notchRect)
        #expect(m.collapsedWindowFrame(for: geometry, tab: true).width == 220 + m.tabExtension * 2)
        #expect(m.dictationWindowFrame(for: geometry).height == m.dictationSize.height)
    }

    @Test func everyBindableCommandHasADefaultChord() {
        for command in BindableCommand.allCases {
            #expect(!KeyBindings.defaults.chords(for: command).isEmpty, "\(command) has no default chord")
        }
    }
}
