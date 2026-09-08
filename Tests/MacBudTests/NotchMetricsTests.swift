import AppKit
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
        #expect(m.collapsedWindowFrame(for: geometry, tab: true).width == 220 + (m.tabExtension + m.tabHoverGrowth.width) * 2)
        #expect(m.collapsedWindowFrame(for: geometry, tab: true).height == 38 + m.tabHoverGrowth.height)
        #expect(m.tabSize(for: geometry, hovered: false) == CGSize(width: 220 + m.tabExtension * 2, height: 38))
        #expect(m.tabSize(for: geometry, hovered: true).width == 220 + (m.tabExtension + m.tabHoverGrowth.width) * 2)
        #expect(m.dictationWindowFrame(for: geometry).height == m.dictationSize.height)
    }

    @Test func everyBindableCommandHasADefaultChord() {
        for command in BindableCommand.allCases {
            #expect(!KeyBindings.defaults.chords(for: command).isEmpty, "\(command) has no default chord")
        }
    }
}

@Suite @MainActor struct MultiDisplayNotchTests {
    @Test func everyAttachedDisplayGetsItsOwnNotchWindow() {
        let controller = NotchController()
        #expect(controller.screens.count == NSScreen.screens.count)
        #expect(Set(controller.screens.map(\.displayID)).count == controller.screens.count)
        #expect(controller.activeNotch.isActive)
        controller.applyBaseFrame()
        for screen in controller.screens {
            #expect(screen.window.frame.maxY == screen.geometry.screenFrame.maxY)
            #expect(abs(screen.window.frame.midX - screen.geometry.notchCenterX) < 0.01)
        }
    }

    @Test func openingTargetsTheDisplayTheUserIsOn() {
        let controller = NotchController()
        defer { controller.close() }
        for screen in controller.screens {
            controller.open(on: screen)
            #expect(controller.state.geometry.displayID == screen.displayID)
            #expect(controller.panel.frame == controller.state.metrics.expandedWindowFrame(for: screen.geometry))
            #expect(screen.isActive)
            #expect(controller.screens.filter(\.isActive).count == 1)
            controller.close()
        }
    }

    @Test func theFocusedWindowWinsAndThePointerIsTheFallback() {
        let builtIn = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let external = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let frames = [builtIn, external]
        let onExternal = CGRect(x: 1500, y: 100, width: 900, height: 700)
        let onBuiltIn = CGRect(x: 100, y: 100, width: 900, height: 700)
        let mouseOnBuiltIn = CGPoint(x: 200, y: 200)

        // A focused window beats the pointer, even when the pointer sits on the other display.
        #expect(ActiveDisplay.choose(focusedWindow: onExternal, mouse: mouseOnBuiltIn, frames: frames) == 1)
        #expect(ActiveDisplay.choose(focusedWindow: onBuiltIn, mouse: CGPoint(x: 2000, y: 200), frames: frames) == 0)
        // A window straddling both displays belongs to whichever shows more of it.
        #expect(ActiveDisplay.choose(focusedWindow: CGRect(x: 1240, y: 0, width: 600, height: 600),
                                     mouse: mouseOnBuiltIn, frames: frames) == 1)
        // No accessibility answer: follow the pointer.
        #expect(ActiveDisplay.choose(focusedWindow: nil, mouse: mouseOnBuiltIn, frames: frames) == 0)
        #expect(ActiveDisplay.choose(focusedWindow: nil, mouse: CGPoint(x: 2000, y: 200), frames: frames) == 1)
        // Offscreen everything: let the caller fall back to the menu-bar screen.
        #expect(ActiveDisplay.choose(focusedWindow: nil, mouse: CGPoint(x: -50, y: -50), frames: frames) == nil)
    }

    @Test func accessibilityWindowCoordinatesAreFlippedIntoScreenSpace() {
        #expect(ActiveDisplay.cocoaFrame(fromAccessibility: CGRect(x: 100, y: 0, width: 800, height: 600),
                                         primaryHeight: 900) == CGRect(x: 100, y: 300, width: 800, height: 600))
        #expect(ActiveDisplay.cocoaFrame(fromAccessibility: CGRect(x: 0, y: -540, width: 2560, height: 1440),
                                         primaryHeight: 900) == CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }
}
