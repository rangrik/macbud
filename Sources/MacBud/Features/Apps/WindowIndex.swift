import AppKit
import ApplicationServices

/// One window you can jump to. Identity is the app plus the window's slot in that app's own list,
/// because AX gives no stable id and titles change under you as you type.
nonisolated struct WindowEntry: Identifiable, Hashable, Sendable {
    let bundleID: String
    let appName: String
    let appURL: URL
    let title: String
    /// Position in the owning app's AX window list, which is that app's own front-to-back order.
    let slot: Int
    var isMinimized = false

    var id: String { "\(bundleID)#\(slot)" }
    /// Falls back to the app name so a titleless window is still nameable in the list.
    var displayTitle: String { title.isEmpty ? appName : title }
}

/// Every open window, and how to bring one to the front. Uses the Accessibility API, which MacBud
/// already holds permission for — no Screen Recording needed until we show window contents.
enum WindowIndex {
    /// Apps in front-to-back order, each with its windows in that app's own order.
    static func windows(limitPerApp: Int = 12) -> [WindowEntry] {
        guard Paster.isAccessibilityTrusted else { return [] }
        return AppIndex.runningInFrontToBackOrder().flatMap { app -> [WindowEntry] in
            guard let bundleID = app.bundleIdentifier, let url = app.bundleURL else { return [] }
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            return elements(for: app).prefix(limitPerApp).enumerated().compactMap { slot, element in
                guard isRealWindow(element) else { return nil }
                return WindowEntry(bundleID: bundleID, appName: name, appURL: url,
                                   title: string(element, kAXTitleAttribute) ?? "", slot: slot,
                                   isMinimized: bool(element, kAXMinimizedAttribute) ?? false)
            }
        }
    }

    /// Brings one window forward. Raising alone leaves the app in the background, and activating
    /// alone lands on whichever window that app last had in front — both are needed.
    @discardableResult
    static func raise(_ entry: WindowEntry) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID).first else { return false }
        let list = elements(for: app)
        guard list.indices.contains(entry.slot) else { return false }
        let window = list[entry.slot]
        if bool(window, kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                     kAXFocusedWindowAttribute as CFString, window)
        let activated = app.activate(options: [.activateAllWindows])
        Log.app.info("raise \(entry.appName) slot \(entry.slot): raised=\(raised) activated=\(activated)")
        return raised || activated
    }

    /// Diagnostics for the automation surface: what AX and the window server each report, before
    /// any filtering. This is what tells an empty switcher entry apart from an app on another Space.
    static func diagnostics() -> [[String: Any]] {
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return AppIndex.runningInFrontToBackOrder().map { app in
            let element = AXUIElementCreateApplication(app.processIdentifier)
            return ["app": app.localizedName ?? "?",
                    "axWindows": copyWindows(element).count,
                    "onScreenWindows": onScreen.filter { $0[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier }.count,
                    "focusedWindow": focusedWindow(element).flatMap { string($0, kAXTitleAttribute) } ?? "-",
                    "listed": elements(for: app).filter(isRealWindow).map { element in
                        ["role": string(element, kAXRoleAttribute) ?? "-",
                         "subrole": string(element, kAXSubroleAttribute) ?? "-",
                         "title": string(element, kAXTitleAttribute) ?? "-",
                         "size": size(element).map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"]
                    }]
        }
    }

    // MARK: - Accessibility plumbing

    private static func elements(for app: NSRunningApplication) -> [AXUIElement] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let windows = copyWindows(element)
        guard windows.isEmpty else { return windows }
        // Electron apps ship with their accessibility tree switched off, so asking for it is worth
        // a try before giving up on them.
        enableManualAccessibility(element, pid: app.processIdentifier)
        let retried = copyWindows(element)
        guard retried.isEmpty else { return retried }
        // Chromium apps still answer for their focused window while the full list stays empty.
        // One entry is far better than the app vanishing from the switcher altogether.
        return focusedWindow(element).map { [$0] } ?? []
    }

    private static func focusedWindow(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value else { return nil }
        return (window as! AXUIElement)
    }

    private static func copyWindows(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    private static var manuallyEnabled: Set<pid_t> = []

    private static func enableManualAccessibility(_ element: AXUIElement, pid: pid_t) {
        guard manuallyEnabled.insert(pid).inserted else { return }
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Finder's desktop comes back as a giant scroll area, and Electron apps expose hidden helpers
    /// and popovers alongside real windows. A window you can switch to is an AXWindow, with a
    /// standard subrole where one is given, and big enough to be worth landing on.
    private static func isRealWindow(_ element: AXUIElement) -> Bool {
        guard string(element, kAXRoleAttribute) == kAXWindowRole as String else { return false }
        if let subrole = string(element, kAXSubroleAttribute), subrole != kAXStandardWindowSubrole as String { return false }
        guard let size = size(element) else { return true }
        return size.width >= 120 && size.height >= 80
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &result) else { return nil }
        return result
    }
}
