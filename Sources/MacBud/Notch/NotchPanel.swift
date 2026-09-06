import AppKit

/// Borderless, non-activating panel that can take keyboard focus without activating the app,
/// so the previously focused app stays frontmost (Spotlight-style).
final class NotchPanel: NSPanel {
    /// Return `true` to swallow the key event.
    var keyHandler: ((NSEvent) -> Bool)?
    var acceptsKeyboardFocus = true

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        // Must come after `isFloatingPanel`-style properties: they silently reset the level.
        level = .popUpMenu
    }

    /// AppKit normally keeps windows below the menu bar; the island must touch the screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var canBecomeKey: Bool { acceptsKeyboardFocus }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }
}
