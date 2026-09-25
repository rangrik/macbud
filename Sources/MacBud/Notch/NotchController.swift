import AppKit
import SwiftUI

@Observable
final class NotchController {
    let state: NotchState
    private(set) var panel: NotchPanel
    /// One entry per display, keyed by display id, so every screen carries its own notch.
    private(set) var screens: [ScreenNotch] = []
    private var panelHost: NSHostingView<NotchRootView>?
    var contentProvider: (() -> IslandContentView)?
    var shelfProvider: (() -> ShelfView)?
    var dictationProvider: (() -> AnyView)?
    private var isInstalled = false
    private var collapseTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var toastWork: (() -> Void)?
    private var hoverTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    /// Set when the notch closes under a resting pointer, so it does not reopen until the pointer leaves.
    private var hoverNeedsExit = false
    private var observers: [NSObjectProtocol] = []
    private var isSnapshotting = false

    var keyHandler: ((NSEvent) -> Bool)?
    var didClose: (() -> Void)?
    /// A click on a closed notch, and a pointer resting on one. The coordinator decides what opens.
    var onTabClick: ((ScreenNotch) -> Void)?
    var onHoverOpen: ((ScreenNotch) -> Void)?

    static let openAnimation: Animation = .spring(duration: 0.38, bounce: 0.18)
    static let closeAnimation: Animation = .spring(duration: 0.26, bounce: 0)
    static let toastAnimation: Animation = .spring(duration: 0.34, bounce: 0.2)

    init() {
        let geometry = NotchGeometry.activeScreen().map(NotchGeometry.detect(on:)) ?? .fallback
        state = NotchState(geometry: geometry)
        panel = NotchPanel(contentRect: state.metrics.panelFrame(.expanded, for: geometry))
        syncScreens()
    }

    /// The notch on the display the panel is currently targeting.
    var activeNotch: ScreenNotch {
        screens.first { $0.displayID == state.geometry.displayID } ?? screens[0]
    }

    /// Kept so callers that only care about the display in front still read naturally.
    var base: NotchBaseWindow { activeNotch.window }

    func install() {
        let panelHost = NotchHostingView(rootView: NotchRootView(state: state, controller: self, content: contentProvider,
                                                                 shelf: shelfProvider, dictation: dictationProvider))
        panelHost.sizingOptions = []
        panel.contentView = panelHost
        panel.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        self.panelHost = panelHost

        isInstalled = true
        for screen in screens { installHost(on: screen) }
        applyBaseFrame()
        for screen in screens { screen.window.orderFrontRegardless() }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelDidResignKey() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGeometry() }
        })
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
                Trace.log("app \(note.name.rawValue.replacingOccurrences(of: "NSApplication", with: "")) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
            })
        }
        Log.notch.info("installed; screens=\(self.screens.count) notch=\(String(describing: self.state.geometry.notchRect)) physical=\(self.state.geometry.hasPhysicalNotch)")
    }

    private func installHost(on screen: ScreenNotch) {
        guard screen.host == nil else { return }
        let host = ClickableHostingView(rootView: NotchBaseView(screen: screen, state: state, controller: self))
        host.sizingOptions = []
        host.onClick = { [weak self] point in self?.tabClicked(on: screen, at: point) }
        host.onHoverChange = { [weak self] hovering in self?.tabHoverChanged(hovering, on: screen) }
        host.onHoverMove = { [weak self] point in self?.toastHoverMoved(to: point, on: screen) }
        screen.window.contentView = host
        screen.host = host
    }

    // MARK: Screens

    /// Rebuild the per-display notches after a display is plugged in, unplugged or rearranged.
    private func syncScreens() {
        let geometries = NSScreen.screens.map(NotchGeometry.detect(on:))
        let live = geometries.isEmpty ? [NotchGeometry.fallback] : geometries
        let liveIDs = Set(live.map(\.displayID))

        for gone in screens where !liveIDs.contains(gone.displayID) {
            gone.window.orderOut(nil)
            gone.window.close()
        }
        screens.removeAll { !liveIDs.contains($0.displayID) }

        for geometry in live {
            if let existing = screens.first(where: { $0.displayID == geometry.displayID }) {
                existing.geometry = geometry
            } else {
                let screen = ScreenNotch(geometry: geometry)
                screens.append(screen)
                if isInstalled {
                    installHost(on: screen)
                    screen.window.orderFrontRegardless()
                }
            }
        }
        if !screens.contains(where: { $0.displayID == state.geometry.displayID }), let first = screens.first {
            state.geometry = first.geometry
        }
        markActive()
    }

    private func markActive() {
        let id = state.geometry.displayID
        for screen in screens { screen.isActive = screen.displayID == id }
    }

    /// Move the panel to the display the user is on. Called every time the notch is asked to open.
    private func retargetToActiveScreen() {
        syncScreens()
        guard let screen = NotchGeometry.activeScreen() else { return }
        let geometry = NotchGeometry.detect(on: screen)
        guard geometry != state.geometry else { return }
        state.geometry = geometry
        markActive()
        Trace.log("retarget display=\(geometry.displayID) frame=\(String(describing: geometry.screenFrame))")
    }

    private func tabClicked(on screen: ScreenNotch, at point: CGPoint) {
        Trace.log("tab clicked; display=\(screen.displayID) open=\(state.isOpen)")
        if screen === activeNotch, state.basePhase == .toast, state.toast?.action != nil,
           state.toastActionRect.contains(point) {
            performToastAction()
            return
        }
        // A hover may have opened the shelf while the button was down; the click asks for the keyboard.
        if state.isShelf, !panel.isKeyWindow { focusShelf(); return }
        if state.isOpen { close() } else { onTabClick?(screen) }
    }

    /// Passing the pointer through on the way to the menu bar must not open anything, so it has to rest.
    private func tabHoverChanged(_ hovering: Bool, on screen: ScreenNotch) {
        state.tabHovered = hovering
        hoverTask?.cancel()
        if !hovering { hoverNeedsExit = false }
        guard hovering, !hoverNeedsExit else { return }
        let started = ContinuousClock.now
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: HoverDwell.delay)
            guard !Task.isCancelled, let self,
                  HoverDwell.opens(enabled: state.opensShelfOnHover, phase: state.phase, toasting: state.basePhase == .toast,
                                   hoveredFor: ContinuousClock.now - started) else { return }
            Trace.log("hover open display=\(screen.displayID)")
            onHoverOpen?(screen)
        }
    }

    /// A hover-opened shelf closes once the pointer has been on it and then stays off it for a moment.
    /// Polled rather than tracked: a fast exit can skip the enter event a tracking area needs.
    private func watchPointerLeavingShelf() {
        leaveTask?.cancel()
        leaveTask = Task { [weak self] in
            var visited = false
            var awaySince: ContinuousClock.Instant?
            while !Task.isCancelled {
                guard let self, state.isShelf else { return }
                if panel.frame.contains(NSEvent.mouseLocation) {
                    visited = true
                    awaySince = nil
                } else if visited {
                    let since = awaySince ?? ContinuousClock.now
                    awaySince = since
                    if ContinuousClock.now - since >= HoverDwell.leaveDelay { Trace.log("shelf left by pointer"); close(); return }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func toastHoverMoved(to point: CGPoint, on screen: ScreenNotch) {
        let inside = screen === activeNotch && state.basePhase == .toast && state.toastActionRect.contains(point)
        guard inside != state.toastActionHovered else { return }
        state.toastActionHovered = inside
    }

    private func performToastAction() {
        let work = toastWork
        dismissToast()
        work?()
    }

    private func dismissToast() {
        toastTask?.cancel()
        toastWork = nil
        state.toastActionRect = .zero
        state.toastActionHovered = false
        withAnimation(Self.closeAnimation) { state.basePhase = .idle }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, state.basePhase == .idle else { return }
            state.toast = nil
            applyBaseFrame()
        }
    }

    /// Grows the dictation panel with what you have said — four lines at rest, ten at most.
    func setDictationLines(_ lines: Int) {
        let height = state.metrics.dictationHeight(forLines: lines)
        guard state.phase == .dictation, abs(state.metrics.dictationSize.height - height) > 0.5 else { return }
        state.metrics.dictationSize.height = height
        panel.setFrame(state.metrics.panelFrame(.dictation, for: state.geometry), display: true)
    }

    /// Lets the transcript take keystrokes while you edit it, and hands focus back afterwards.
    func setDictationKeyboardFocus(_ wanted: Bool) {
        guard state.phase == .dictation else { return }
        panel.acceptsKeyboardFocus = wanted
        if wanted { panel.makeKey() } else if panel.isKeyWindow { panel.resignKey() }
    }

    func openDictation() {
        retargetToActiveScreen()
        collapseTask?.cancel()
        toastTask?.cancel()
        state.toast = nil
        state.basePhase = .idle
        applyBaseFrame()
        state.wantsSearchFocus = false
        state.footerHint = nil
        panel.acceptsKeyboardFocus = false
        state.canvasPhase = .dictation
        state.metrics.dictationSize.height = state.metrics.dictationBaseHeight
        panel.setFrame(state.metrics.panelFrame(.dictation, for: state.geometry), display: false)
        activeNotch.window.orderOut(nil)
        panel.orderFrontRegardless()
        withAnimation(Self.openAnimation) { state.phase = .dictation }
        if panel.isKeyWindow { panel.resignKey() }
        Trace.log("openDictation key=\(panel.isKeyWindow)")
    }

    /// Shows the panel in `phase` on the display in use, or on `screen` when its tab was clicked.
    /// Without `focus` the keyboard stays with the app in front: a hover must never take it.
    func open(_ phase: NotchPhase = .expanded, focus: Bool = true, on screen: ScreenNotch? = nil) {
        let started = ContinuousClock.now
        if let screen {
            syncScreens()
            state.geometry = screen.geometry
            markActive()
        } else {
            retargetToActiveScreen()
        }
        collapseTask?.cancel()
        toastTask?.cancel()
        hoverTask?.cancel()
        state.toast = nil
        state.basePhase = .idle
        applyBaseFrame()
        state.footerHint = nil

        panel.acceptsKeyboardFocus = focus
        state.canvasPhase = phase
        panel.setFrame(state.metrics.panelFrame(phase, for: state.geometry), display: false)
        panel.orderFrontRegardless()
        if focus { panel.makeKey() }
        withAnimation(Self.openAnimation) { state.phase = phase }
        state.wantsSearchFocus = phase == .expanded
        if phase == .shelf, !focus { watchPointerLeavingShelf() }
        Trace.log("open \(phase) took=\(ContinuousClock.now - started) display=\(state.geometry.displayID) key=\(panel.isKeyWindow) firstResponder=\(String(describing: panel.firstResponder))")
    }

    /// Shelf to island, in place: the canvas grows first so the shelf does not move while the shape follows.
    func expand() {
        guard state.isShelf else { return }
        leaveTask?.cancel()
        panel.acceptsKeyboardFocus = true
        state.canvasPhase = .expanded
        panel.setFrame(state.metrics.panelFrame(.expanded, for: state.geometry), display: false)
        panel.makeKey()
        withAnimation(Self.openAnimation) { state.phase = .expanded }
        state.wantsSearchFocus = true
        Trace.log("expand key=\(panel.isKeyWindow)")
    }

    /// A shelf opened by hover takes the keyboard only when asked, by the hotkey.
    func focusShelf() {
        guard state.isShelf else { return }
        leaveTask?.cancel()
        panel.acceptsKeyboardFocus = true
        panel.makeKey()
    }

    func close() {
        guard state.isOpen else { return }
        leaveTask?.cancel()
        hoverNeedsExit = activeNotch.window.frame.contains(NSEvent.mouseLocation)
        state.wantsSearchFocus = false
        withAnimation(Self.closeAnimation) { state.phase = .collapsed }
        if panel.isKeyWindow { panel.resignKey() }
        for screen in screens { screen.window.orderFrontRegardless() }
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self, !self.state.isOpen else { return }
            self.panel.orderOut(nil)
        }
        didClose?()
        Log.notch.debug("close")
        Trace.log("close")
    }

    func closeWithToast(_ toast: Toast, duration: Duration = .milliseconds(1400)) {
        close()
        showToast(toast, duration: duration)
    }

    func showToast(_ toast: Toast, duration: Duration = .milliseconds(1400), action: (() -> Void)? = nil) {
        guard !state.isOpen else { return }
        activeNotch.window.orderFrontRegardless()
        toastTask?.cancel()
        toastWork = action
        state.toastActionRect = .zero
        state.toastActionHovered = false
        state.toast = toast
        applyBaseFrame(phase: .toast)
        withAnimation(Self.toastAnimation) { state.basePhase = .toast }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.toastWork = nil
            withAnimation(Self.closeAnimation) { self.state.basePhase = .idle }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, self.state.basePhase == .idle else { return }
            self.state.toast = nil
            self.applyBaseFrame()
        }
    }

    func refreshGeometry() {
        syncScreens()
        guard let current = screens.first(where: { $0.displayID == state.geometry.displayID }) else { return }
        if current.geometry != state.geometry {
            state.geometry = current.geometry
            if state.isOpen { panel.setFrame(state.metrics.panelFrame(state.canvasPhase, for: current.geometry), display: true) }
        }
        applyBaseFrame(phase: state.basePhase)
    }

    /// The tab is what makes a notch visible on a display that has no physical one.
    var showsTab: Bool { state.showsNotchTab }

    func applyBaseFrame(phase: BasePhase = .idle) {
        let active = activeNotch
        for screen in screens {
            let p = screen === active ? phase : .idle
            let g = screen.geometry
            let frame = p == .toast ? state.metrics.toastWindowFrame(for: g, withAction: state.toast?.action != nil)
                                    : state.metrics.collapsedWindowFrame(for: g, tab: showsTab)
            screen.canvasSize = frame.size
            screen.window.setFrame(frame, display: true)
            screen.window.ignoresMouseEvents = !(showsTab || g.hasPhysicalNotch || p == .toast)
            let grow = p == .idle && showsTab ? state.metrics.tabHoverGrowth : .zero
            screen.host?.hitInsets = NSEdgeInsets(top: 0, left: grow.width, bottom: grow.height, right: grow.width)
        }
    }

    func panelDidResignKey() {
        Trace.log("panel resigned key; phase=\(state.phase) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") active=\(NSApp.isActive)")
        if state.isExpanded || state.isShelf, !isSnapshotting { close() }
    }

    func snapshot(window: WindowKind, to url: URL) throws {
        let size = (window == .panel ? panel.frame.size : activeNotch.window.frame.size)
        let backdrop = Color(red: 0.55, green: 0.60, blue: 0.70)
        let content: AnyView = switch window {
        case .panel: AnyView(NotchRootView(state: state, controller: self, content: contentProvider, shelf: shelfProvider,
                                           dictation: dictationProvider))
        case .base: AnyView(NotchBaseView(screen: activeNotch, state: state, controller: self))
        }
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height).background(backdrop)
            .environment(\.snapshotMode, true))
        renderer.scale = 2
        isSnapshotting = true
        defer {
            isSnapshotting = false
            if state.isOpen, !panel.isKeyWindow { panel.makeKey() }
        }
        guard let cg = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    enum WindowKind: String { case panel, base }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Always-on window that sits exactly over the notch. Never becomes key.
final class NotchBaseWindow: NSWindow {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

}

/// Hosting view for the always-on notch window. That window can never become key, so AppKit only
/// delivers the first click if the hit view accepts first mouse; SwiftUI's own gesture views do not,
/// which is why the tab click did nothing. Taking over hit-testing, clicks and hover here makes the
/// whole window one reliable button.
final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    var onClick: ((CGPoint) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onHoverMove: ((CGPoint) -> Void)?
    /// Transparent margin around the drawn tab (top-down semantics); clicks and hover ignore it until hovered.
    var hitInsets = NSEdgeInsets() { didSet { window?.invalidateCursorRects(for: self) } }
    private var pressed = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    /// The drawn tab; the whole bounds while hovered so the grown edge does not flicker.
    private var activeRect: NSRect {
        if hovering { return bounds }
        var r = bounds
        r.origin.x += hitInsets.left
        r.size.width -= hitInsets.left + hitInsets.right
        r.size.height -= hitInsets.bottom
        if !isFlipped { r.origin.y += hitInsets.bottom }
        return r
    }

    private func contains(_ event: NSEvent) -> Bool { activeRect.contains(convert(event.locationInWindow, from: nil)) }

    /// SwiftUI measures from the top-left; AppKit may not. Report in SwiftUI's frame.
    private func topLeftPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return isFlipped ? p : CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { activeRect.contains(convert(point, from: superview)) ? self : nil }

    override func mouseDown(with event: NSEvent) { pressed = contains(event) }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, contains(event) else { return }
        onClick?(topLeftPoint(event))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(contains(event)); onHoverMove?(topLeftPoint(event)) }
    override func mouseMoved(with event: NSEvent) { setHovering(contains(event)); onHoverMove?(topLeftPoint(event)) }
    override func mouseExited(with event: NSEvent) { setHovering(false); onHoverMove?(CGPoint(x: -1, y: -1)) }

    private func setHovering(_ now: Bool) {
        guard now != hovering else { return }
        hovering = now
        Trace.log("tab hover=\(now)")
        onHoverChange?(now)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
}
