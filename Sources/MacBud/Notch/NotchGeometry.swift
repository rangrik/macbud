import AppKit

nonisolated struct NotchGeometry: Equatable, Sendable {
    let screenFrame: CGRect
    let notchRect: CGRect
    let hasPhysicalNotch: Bool
    /// Identifies the display this geometry was measured on, so windows can be kept one-per-screen.
    var displayID: CGDirectDisplayID = 0

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
            return NotchGeometry(screenFrame: frame, notchRect: rect, hasPhysicalNotch: true, displayID: screen.displayID)
        }
        let menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, simulatedNotchSize.height)
        let rect = CGRect(x: frame.midX - simulatedNotchSize.width / 2,
                          y: frame.maxY - menuBarHeight,
                          width: simulatedNotchSize.width,
                          height: menuBarHeight)
        return NotchGeometry(screenFrame: frame, notchRect: rect, hasPhysicalNotch: false, displayID: screen.displayID)
    }

    static func preferredScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notched }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Where the user is right now. See `ActiveDisplay` for how that is decided.
    @MainActor static func activeScreen() -> NSScreen? { ActiveDisplay.screen() }

    static let fallback = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                        notchRect: CGRect(x: 620, y: 868, width: 200, height: 32),
                                        hasPhysicalNotch: false)
}

nonisolated extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

nonisolated struct NotchMetrics: Equatable, Sendable {
    var islandSize = CGSize(width: 760, height: 500)
    var toastSize = CGSize(width: 300, height: 76)
    var dictationSize = CGSize(width: 560, height: 238)
    var tabExtension: CGFloat = 42
    var tabHoverGrowth = CGSize(width: 6, height: 4)
    var dictationBottomRadius: CGFloat = 26
    var topFillet: CGFloat = 10
    var bottomRadius: CGFloat = 28
    var collapsedBottomRadius: CGFloat = 12
    var toastBottomRadius: CGFloat = 22

    func expandedWindowFrame(for g: NotchGeometry) -> CGRect {
        let w = islandSize.width + topFillet * 2
        return CGRect(x: g.notchCenterX - w / 2, y: g.topY - islandSize.height, width: w, height: islandSize.height)
    }

    func dictationWindowFrame(for g: NotchGeometry) -> CGRect {
        let w = dictationSize.width + topFillet * 2
        return CGRect(x: g.notchCenterX - w / 2, y: g.topY - dictationSize.height, width: w, height: dictationSize.height)
    }

    func collapsedWindowFrame(for g: NotchGeometry, tab: Bool) -> CGRect {
        guard tab else { return g.notchRect }
        let r = g.notchRect.insetBy(dx: -(tabExtension + tabHoverGrowth.width), dy: 0)
        return CGRect(x: r.minX, y: r.minY - tabHoverGrowth.height, width: r.width, height: r.height + tabHoverGrowth.height)
    }

    func toastWindowFrame(for g: NotchGeometry) -> CGRect {
        let w = toastSize.width + topFillet * 2
        return CGRect(x: g.notchCenterX - w / 2, y: g.topY - toastSize.height, width: w, height: toastSize.height)
    }

    func tabSize(for g: NotchGeometry, hovered: Bool) -> CGSize {
        let grow = hovered ? tabHoverGrowth : .zero
        return CGSize(width: g.notchRect.width + (tabExtension + grow.width) * 2, height: g.notchRect.height + grow.height)
    }
}
