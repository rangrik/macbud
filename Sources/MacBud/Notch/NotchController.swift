import AppKit
import SwiftUI

/// Owns the two windows that make up the notch experience:
/// - `base`: always present over the notch; draws the idle notch and action toasts; catches clicks.
/// - `panel`: the expanded island; key-capable, ordered out when collapsed.
@Observable
final class NotchController {
    let state: NotchState
    private(set) var panel: NotchPanel
    private(set) var base: NotchBaseWindow
    private var panelHost: NSHostingView<NotchRootView>?
    /// Builds the island body. Set before `install()`.
    var contentProvider: (() -> IslandContentView)?
    /// Builds the dictation pill body. Set before `install()`.
    var dictationProvider: (() -> AnyView)?
    private var baseHost: ClickableHostingView<NotchBaseView>?
    private var collapseTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isSnapshotting = false

    /// Installed by the app; return `true` to swallow the key event.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Called right before the island opens so callers can record the frontmost app etc.
    var willOpen: (() -> Void)?
    var didClose: (() -> Void)?

    static let openAnimation: Animation = .spring(duration: 0.38, bounce: 0.18)
    static let closeAnimation: Animation = .spring(duration: 0.26, bounce: 0)
    static let toastAnimation: Animation = .spring(duration: 0.34, bounce: 0.2)

    init() {
        let screen = NotchGeometry.preferredScreen()
        let geometry = screen.map(NotchGeometry.detect(on:))
            ?? NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             notchRect: CGRect(x: 620, y: 868, width: 200, height: 32), hasPhysicalNotch: false)
        state = NotchState(geometry: geometry)
        panel = NotchPanel(contentRect: state.metrics.expandedWindowFrame(for: geometry))
        base = NotchBaseWindow(contentRect: geometry.notchRect)
    }

    func install() {
        let panelHost = NSHostingView(rootView: NotchRootView(state: state, controller: self, content: contentProvider, dictation: dictationProvider))
        panelHost.sizingOptions = []
        panel.contentView = panelHost
        panel.keyHandler = { [weak self] event in self?.keyHandler?(event) ?? false }
        self.panelHost = panelHost

        let baseHost = ClickableHostingView(rootView: NotchBaseView(state: state, controller: self))
        baseHost.sizingOptions = []
        baseHost.onClick = { [weak self] in self?.tabClicked() }
        baseHost.onHoverChange = { [weak self] hovering in self?.state.tabHovered = hovering }
        base.contentView = baseHost
        self.baseHost = baseHost
        applyBaseFrame()
        base.orderFrontRegardless()

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
        Log.notch.info("installed; notch=\(String(describing: self.state.geometry.notchRect)) physical=\(self.state.geometry.hasPhysicalNotch)")
    }

    // MARK: - Open / close

    func toggle(section: Section? = nil) {
        if state.isOpen, section == nil || section == state.section { close() } else { open(section: section) }
    }

    /// Mouse fallback (spec S8): a click on the notch tab, the bare notch, or a toast opens the island.
    private func tabClicked() {
        Trace.log("tab clicked; open=\(state.isOpen)")
        if state.isOpen { close() } else { open() }
    }

    /// Shows the compact dictation pill (from collapsed, or shrinking down from the island).
    func openDictation() {
        refreshGeometry()
        collapseTask?.cancel()
        toastTask?.cancel()
        state.toast = nil
        state.basePhase = .idle
        applyBaseFrame()
        state.wantsSearchFocus = false
        state.footerHint = nil
        // Animate inside the larger frame, then shrink the window so the desktop around the pill stays clickable.
        panel.setFrame(state.metrics.expandedWindowFrame(for: state.geometry), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        withAnimation(Self.openAnimation) { state.phase = .dictation }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, let self, self.state.isDictating else { return }
            self.panel.setFrame(self.state.metrics.dictationWindowFrame(for: self.state.geometry), display: true)
        }
        Trace.log("openDictation key=\(panel.isKeyWindow)")
    }

    func open(section: Section? = nil) {
        refreshGeometry()
        collapseTask?.cancel()
        toastTask?.cancel()
        state.toast = nil
        state.basePhase = .idle
        applyBaseFrame()
        if let section { state.section = section }
        state.query = ""
        state.footerHint = nil
        willOpen?()

        panel.setFrame(state.metrics.expandedWindowFrame(for: state.geometry), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        withAnimation(Self.openAnimation) { state.phase = .expanded }
        state.wantsSearchFocus = true
        Log.notch.debug("open \(self.state.section.rawValue)")
        Trace.log("open \(state.section.rawValue) key=\(panel.isKeyWindow) firstResponder=\(String(describing: panel.firstResponder))")
    }

    func close() {
        guard state.isOpen else { return }
        state.wantsSearchFocus = false
        withAnimation(Self.closeAnimation) { state.phase = .collapsed }
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

    /// Collapse and flash a confirmation pill under the notch.
    func closeWithToast(_ toast: Toast, duration: Duration = .milliseconds(1400)) {
        close()
        showToast(toast, duration: duration)
    }

    func showToast(_ toast: Toast, duration: Duration = .milliseconds(1400)) {
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

    // MARK: - Geometry

    func refreshGeometry() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let g = NotchGeometry.detect(on: screen)
        guard g != state.geometry else { return }
        state.geometry = g
        base.ignoresMouseEvents = !g.hasPhysicalNotch
        if state.isExpanded { panel.setFrame(state.metrics.expandedWindowFrame(for: g), display: true) }
        if state.isDictating { panel.setFrame(state.metrics.dictationWindowFrame(for: g), display: true) }
        applyBaseFrame(phase: state.basePhase)
    }

    /// Whether the idle base window shows the wider clickable tab (only meaningful on a real notch).
    var showsTab: Bool { state.showsNotchTab && state.geometry.hasPhysicalNotch }

    func applyBaseFrame(phase: BasePhase = .idle) {
        let g = state.geometry
        let frame: CGRect
        switch phase {
        case .idle: frame = state.metrics.collapsedWindowFrame(for: g, tab: showsTab)
        case .toast:
            let s = state.metrics.toastSize
            let w = s.width + state.metrics.topFillet * 2
            frame = CGRect(x: g.notchCenterX - w / 2, y: g.topY - s.height, width: w, height: s.height)
        }
        base.setFrame(frame, display: true)
        base.ignoresMouseEvents = !g.hasPhysicalNotch
        let grow = phase == .idle && showsTab ? state.metrics.tabHoverGrowth : .zero
        baseHost?.hitInsets = NSEdgeInsets(top: 0, left: grow.width, bottom: grow.height, right: grow.width)
    }

    private func panelDidResignKey() {
        // Clicking anywhere else (or another app grabbing focus) dismisses the island.
        Trace.log("panel resigned key; expanded=\(state.isExpanded) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") active=\(NSApp.isActive)")
        if state.isOpen, !isSnapshotting { close() }
    }

    // MARK: - Automation support

    /// Renders the island (or base) view tree to a PNG via `ImageRenderer` — no Screen Recording permission needed.
    /// AppKit-backed controls (the text field) render empty; verify typed text through `dump` instead.
    func snapshot(window: WindowKind, to url: URL) throws {
        let size = (window == .panel ? panel : base).frame.size
        let backdrop = Color(red: 0.55, green: 0.60, blue: 0.70)
        let content: AnyView = switch window {
        case .panel: AnyView(NotchRootView(state: state, controller: self, content: contentProvider, dictation: dictationProvider))
        case .base: AnyView(NotchBaseView(state: state, controller: self))
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
