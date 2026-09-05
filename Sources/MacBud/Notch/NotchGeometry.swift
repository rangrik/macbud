import AppKit

/// Where the notch is on a given screen, in AppKit screen coordinates (origin bottom-left).
nonisolated struct NotchGeometry: Equatable, Sendable {
    let screenFrame: CGRect
    /// The physical notch cut-out, or a simulated one on displays without a notch.
    let notchRect: CGRect
    let hasPhysicalNotch: Bool

    var notchCenterX: CGFloat { notchRect.midX }
    var topY: CGFloat { screenFrame.maxY }

    static let simulatedNotchSize = CGSize(width: 200, height: 32)

    static func detect(on screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            let rect = CGRect(x: left.maxX,
                              y: frame.maxY - screen.safeAreaInsets.top,
                              width: right.minX - left.maxX,
                              height: screen.safeAreaInsets.top)
            return NotchGeometry(screenFrame: frame, notchRect: rect, hasPhysicalNotch: true)
        }
        let menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, simulatedNotchSize.height)
        let rect = CGRect(x: frame.midX - simulatedNotchSize.width / 2,
                          y: frame.maxY - menuBarHeight,
                          width: simulatedNotchSize.width,
                          height: menuBarHeight)
        return NotchGeometry(screenFrame: frame, notchRect: rect, hasPhysicalNotch: false)
    }

    /// The built-in display when it has a notch, otherwise the screen with the keyboard focus (main).
    static func preferredScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notched }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

/// Fixed sizes of the island. All values in points.
nonisolated struct NotchMetrics: Equatable, Sendable {
    var islandSize = CGSize(width: 760, height: 500)
    var toastSize = CGSize(width: 300, height: 76)
    /// Concave flare at the two top corners where the island meets the screen edge.
    var topFillet: CGFloat = 10
    var bottomRadius: CGFloat = 28
    var collapsedBottomRadius: CGFloat = 12
    var toastBottomRadius: CGFloat = 22

    /// Window frame large enough for the island plus its fillets, anchored to the screen top and centred on the notch.
    func expandedWindowFrame(for g: NotchGeometry) -> CGRect {
        let w = islandSize.width + topFillet * 2
        return CGRect(x: g.notchCenterX - w / 2, y: g.topY - islandSize.height, width: w, height: islandSize.height)
    }

    func collapsedWindowFrame(for g: NotchGeometry) -> CGRect { g.notchRect }
}
