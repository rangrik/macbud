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
    var dictationProvider: (() -> AnyView)?
    private var isInstalled = false
    private var collapseTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isSnapshotting = false

    var keyHandler: ((NSEvent) -> Bool)?
    var willOpen: (() -> Void)?
    var didClose: (() -> Void)?

    static let openAnimation: Animation = .spring(duration: 0.38, bounce: 0.18)
    static let closeAnimation: Animation = .spring(duration: 0.26, bounce: 0)
    static let toastAnimation: Animation = .spring(duration: 0.34, bounce: 0.2)

    init() {
        let geometry = NotchGeometry.activeScreen().map(NotchGeometry.detect(on:)) ?? .fallback
        state = NotchState(geometry: geometry)
        panel = NotchPanel(contentRect: state.metrics.expandedWindowFrame(for: geometry))
        syncScreens()
    }

    /// The notch on the display the panel is currently targeting.
    var activeNotch: ScreenNotch {
        screens.first { $0.displayID == state.geometry.displayID } ?? screens[0]
    }

    /// Kept so callers that only care about the display in front still read naturally.
    var base: NotchBaseWindow { activeNotch.window }

    func install() {
        let panelHost = NotchHostingView(rootView: NotchRootView(state: state, controller: self, content: contentProvider, dictation: dictationProvider))
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
        host.onClick = { [weak self] in self?.tabClicked(on: screen) }
        host.onHoverChange = { [weak self] hovering in self?.state.tabHovered = hovering }
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

    func toggle(section: Section? = nil) {
        if state.isOpen, section == nil || section == state.section { close() } else { open(section: section) }
    }

    private func tabClicked(on screen: ScreenNotch) {
        Trace.log("tab clicked; display=\(screen.displayID) open=\(state.isOpen)")
        if state.isOpen { close() } else { open(on: screen) }
    }

    /// Grows the dictation panel with what you have said — four lines at rest, ten at most.
    func setDictationLines(_ lines: Int) {
        let height = state.metrics.dictationHeight(forLines: lines)
        guard state.phase == .dictation, abs(state.metrics.dictationSize.height - height) > 0.5 else { return }
        state.metrics.dictationSize.height = height
        panel.setFrame(state.metrics.dictationWindowFrame(for: state.geometry), display: true)
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
        state.panelUsesDictationSize = true
        state.metrics.dictationSize.height = state.metrics.dictationBaseHeight
        panel.setFrame(state.metrics.dictationWindowFrame(for: state.geometry), display: false)
        activeNotch.window.orderOut(nil)
        panel.orderFrontRegardless()
        withAnimation(Self.openAnimation) { state.phase = .dictation }
        if panel.isKeyWindow { panel.resignKey() }
        Trace.log("openDictation key=\(panel.isKeyWindow)")
    }

    func open(section: Section? = nil) { open(section: section, on: nil) }

    /// `screen` pins the panel to a clicked tab; otherwise it follows the pointer / focused display.
    func open(on screen: ScreenNotch) { open(section: nil, on: screen) }

    private func open(section: Section?, on screen: ScreenNotch?) {
        if let screen {
            syncScreens()
            state.geometry = screen.geometry
            markActive()
        } else {
            retargetToActiveScreen()
        }
        collapseTask?.cancel()
        toastTask?.cancel()
        state.toast = nil
        state.basePhase = .idle
        applyBaseFrame()
        if let section { state.section = section }
        state.query = ""
        state.footerHint = nil
        willOpen?()

        panel.acceptsKeyboardFocus = true
        state.panelUsesDictationSize = false
        panel.setFrame(state.metrics.expandedWindowFrame(for: state.geometry), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        withAnimation(Self.openAnimation) { state.phase = .expanded }
        state.wantsSearchFocus = true
        Log.notch.debug("open \(self.state.section.rawValue)")
        Trace.log("open \(state.section.rawValue) display=\(state.geometry.displayID) key=\(panel.isKeyWindow) firstResponder=\(String(describing: panel.firstResponder))")
    }

    func close() {
        guard state.isOpen else { return }
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

    func showToast(_ toast: Toast, duration: Duration = .milliseconds(1400)) {
        guard !state.isOpen else { return }
        activeNotch.window.orderFrontRegardless()
        toastTask?.cancel()
        state.toast = toast
        applyBaseFrame(phase: .toast)
        withAnimation(Self.toastAnimation) { state.basePhase = .toast }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
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
            if state.isExpanded { panel.setFrame(state.metrics.expandedWindowFrame(for: current.geometry), display: true) }
            if state.isDictating { panel.setFrame(state.metrics.dictationWindowFrame(for: current.geometry), display: true) }
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
            let frame = p == .toast ? state.metrics.toastWindowFrame(for: g)
                                    : state.metrics.collapsedWindowFrame(for: g, tab: showsTab)
            screen.canvasSize = frame.size
            screen.window.setFrame(frame, display: true)
            screen.window.ignoresMouseEvents = !(showsTab || g.hasPhysicalNotch)
            let grow = p == .idle && showsTab ? state.metrics.tabHoverGrowth : .zero
            screen.host?.hitInsets = NSEdgeInsets(top: 0, left: grow.width, bottom: grow.height, right: grow.width)
        }
    }

    func panelDidResignKey() {
        Trace.log("panel resigned key; expanded=\(state.isExpanded) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") active=\(NSApp.isActive)")
        if state.isExpanded, !isSnapshotting { close() }
    }

    func snapshot(window: WindowKind, to url: URL) throws {
        let size = (window == .panel ? panel.frame.size : activeNotch.window.frame.size)
        let backdrop = Color(red: 0.55, green: 0.60, blue: 0.70)
        let content: AnyView = switch window {
        case .panel: AnyView(NotchRootView(state: state, controller: self, content: contentProvider, dictation: dictationProvider))
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
    var onClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { activeRect.contains(convert(point, from: superview)) ? self : nil }

    override func mouseDown(with event: NSEvent) { pressed = contains(event) }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, contains(event) else { return }
        onClick?()
    }

    override func mouseEntered(with event: NSEvent) { setHovering(contains(event)) }
    override func mouseMoved(with event: NSEvent) { setHovering(contains(event)) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

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
