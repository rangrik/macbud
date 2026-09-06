import AppKit
import ApplicationServices

/// A current insertion point, never the application remembered at the beginning of a recording.
struct FocusedTextTarget {
    let element: AXUIElement
    let app: NSRunningApplication

    static func capture() -> FocusedTextTarget? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        let role = attribute(kAXRoleAttribute, on: element) as? String ?? ""
        let subrole = attribute(kAXSubroleAttribute, on: element) as? String ?? ""
        let enabled = attribute(kAXEnabledAttribute, on: element) as? Bool ?? true
        let editable = attribute("AXEditable", on: element) as? Bool
        let hasRange = attribute(kAXSelectedTextRangeAttribute, on: element) != nil
        guard accepts(role: role, subrole: subrole, enabled: enabled, editable: editable,
                      selectionSettable: isSettable(kAXSelectedTextAttribute, on: element),
                      valueSettable: isSettable(kAXValueAttribute, on: element), hasSelectionRange: hasRange) else { return nil }
        return FocusedTextTarget(element: element, app: app)
    }

    static func accepts(role: String, subrole: String, enabled: Bool, editable: Bool?,
                        selectionSettable: Bool, valueSettable: Bool, hasSelectionRange: Bool) -> Bool {
        guard enabled, editable != false, subrole != kAXSecureTextFieldSubrole else { return false }
        let textRole = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
        return (textRole || editable == true) && (selectionSettable || valueSettable || (editable == true && hasSelectionRange))
    }

    var isStillFocused: Bool {
        guard let current = Self.capture() else { return false }
        return current.app.processIdentifier == app.processIdentifier && CFEqual(current.element, element)
    }

    private static func attribute(_ name: String, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func isSettable(_ name: String, on element: AXUIElement) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }
}
