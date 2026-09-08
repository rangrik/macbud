import Testing
import SwiftUI
@testable import MacBud

@Suite @MainActor struct NotchFocusTests {
    @Test func transitioningControlsStayInsideTheBlackNotch() throws {
        let canvas = CGSize(width: 780, height: 500)
        // Freeze the real surface at sizes visited in either direction of its animation.
        for size in [CGSize(width: 300, height: 80), CGSize(width: 520, height: 260), canvas] {
            let surface = NotchSurface(size: size, canvasSize: canvas, topFillet: 10, bottomRadius: 24) {
                Color.green.opacity(0.5).frame(width: canvas.width, height: canvas.height)
            }
            let renderer = ImageRenderer(content: surface.frame(width: canvas.width, height: canvas.height, alignment: .top))
            let image = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let visible = try #require(bitmap.colorAt(x: Int(canvas.width / 2), y: 20))
            #expect(visible.alphaComponent > 0.99)
            let corner = try #require(bitmap.colorAt(x: 1, y: Int(canvas.height - 2)))
            #expect(corner.alphaComponent == 0, "Controls must not float outside the animated silhouette")
            if size.height < canvas.height {
                let below = try #require(bitmap.colorAt(x: Int(canvas.width / 2), y: Int(size.height + 20)))
                #expect(below.alphaComponent == 0, "The background must not leave controls behind during collapse")
            }
        }
    }

    @Test func baseHostingUsesTheExplicitWindowCanvasAndToastsDoNotCoverDictation() {
        let controller = NotchController()
        controller.applyBaseFrame()
        let host = NSHostingView(rootView: NotchBaseView(screen: controller.activeNotch, state: controller.state, controller: controller))
        #expect(host.fittingSize == controller.activeNotch.window.frame.size)
        controller.state.phase = .dictation
        controller.showToast(Toast(symbol: "checkmark", title: "Previous action"))
        #expect(controller.state.basePhase == .idle)
        #expect(controller.state.toast == nil)
    }

    @Test func dictationHostingViewHasAFiniteFixedCanvas() {
        let controller = NotchController()
        controller.openDictation()
        defer { controller.close() }
        let host = NSHostingView(rootView: NotchRootView(state: controller.state, controller: controller))
        #expect(host.fittingSize == controller.state.metrics.dictationWindowFrame(for: controller.state.geometry).size)
    }

    @Test func dictationOpensAtItsFinalFrameAndLeavesKeyboardFocusInTheTargetApp() {
        let controller = NotchController()
        controller.openDictation()
        defer { controller.close() }

        #expect(controller.panel.frame == controller.state.metrics.dictationWindowFrame(for: controller.state.geometry))
        #expect(!controller.panel.canBecomeKey)
    }

    @Test func focusLossKeepsDictationOpenWithoutCancellingItsSession() {
        let controller = NotchController()
        controller.state.phase = .dictation
        var cancellations = 0
        controller.didClose = { cancellations += 1 }

        controller.panelDidResignKey()

        #expect(controller.state.phase == .dictation)
        #expect(cancellations == 0)
    }

    @Test func focusLossStillDismissesTheExpandedTabs() {
        let controller = NotchController()
        controller.state.phase = .expanded
        var dismissals = 0
        controller.didClose = { dismissals += 1 }

        controller.panelDidResignKey()

        #expect(controller.state.phase == .collapsed)
        #expect(dismissals == 1)
    }
}
