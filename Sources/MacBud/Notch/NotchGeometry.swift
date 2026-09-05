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
    var dictationSize = CGSize(width: 560, height: 132)
    /// How far the idle tab extends beyond the notch on each side (icon plus comfortable padding).
    var tabExtension: CGFloat = 42
    /// How much the whole tab grows on hover: per side horizontally, and downwards.
    var tabHoverGrowth = CGSize(width: 6, height: 4)
    var dictationBottomRadius: CGFloat = 26
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

    func dictationWindowFrame(for g: NotchGeometry) -> CGRect {
        let w = dictationSize.width + topFillet * 2
        return CGRect(x: g.notchCenterX - w / 2, y: g.topY - dictationSize.height, width: w, height: dictationSize.height)
    }

    /// The base window's idle frame. With the tab it is padded by `tabHoverGrowth` so the tab can
    /// grow on hover without the window changing size; the padding is transparent and not clickable.
    func collapsedWindowFrame(for g: NotchGeometry, tab: Bool) -> CGRect {
        guard tab else { return g.notchRect }
        let r = g.notchRect.insetBy(dx: -(tabExtension + tabHoverGrowth.width), dy: 0)
        return CGRect(x: r.minX, y: r.minY - tabHoverGrowth.height, width: r.width, height: r.height + tabHoverGrowth.height)
    }

    /// Size of the drawn tab (idle or hovered) inside the frame above.
    func tabSize(for g: NotchGeometry, hovered: Bool) -> CGSize {
        let grow = hovered ? tabHoverGrowth : .zero
        return CGSize(width: g.notchRect.width + (tabExtension + grow.width) * 2, height: g.notchRect.height + grow.height)
    }
}
