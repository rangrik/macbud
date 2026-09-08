import AppKit
import ApplicationServices

/// Which display the user is working on right now.
///
/// The focused window wins, because that is where the typing is going. The pointer is the
/// fallback for apps that refuse accessibility, and the menu-bar screen is the last resort.
enum ActiveDisplay {
    static func screen() -> NSScreen? {
        let index = choose(focusedWindow: focusedWindowFrame(), mouse: NSEvent.mouseLocation,
                           frames: NSScreen.screens.map(\.frame))
        guard let index else { return NSScreen.main ?? NSScreen.screens.first }
        return NSScreen.screens[index]
    }

    /// Focused window first, pointer second. Pure, so the priority rules are testable without hardware.
    nonisolated static func choose(focusedWindow: CGRect?, mouse: CGPoint, frames: [CGRect]) -> Int? {
        if let focusedWindow, let best = frames.indices
            .map({ ($0, frames[$0].intersection(focusedWindow)) })
            .filter({ !$0.1.isNull && !$0.1.isEmpty })
            .max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) { return best.0 }
        return frames.firstIndex { $0.contains(mouse) }
    }

    /// Accessibility reports window frames flipped from the top of the primary display.
    nonisolated static func cocoaFrame(fromAccessibility frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func focusedWindowFrame() -> CGRect? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let primaryHeight = NSScreen.screens.first?.frame.maxY else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must never stall the hot key; fall through to the pointer instead.
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let window = element(kAXFocusedWindowAttribute, on: application),
              let position = value(kAXPositionAttribute, on: window, type: .cgPoint, as: CGPoint.self),
              let size = value(kAXSizeAttribute, on: window, type: .cgSize, as: CGSize.self),
              size.width > 0, size.height > 0 else { return nil }
        return cocoaFrame(fromAccessibility: CGRect(origin: position, size: size), primaryHeight: primaryHeight)
    }

    private static func element(_ name: String, on parent: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, name as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func value<T>(_ name: String, on element: AXUIElement, type: AXValueType, as: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AXValueGetValue(raw as! AXValue, type, out) else { return nil }
        return out.pointee
    }
}
