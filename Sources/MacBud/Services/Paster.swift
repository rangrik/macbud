import AppKit
import ApplicationServices
import UniformTypeIdentifiers

/// Writes to the system pasteboard and, when allowed, pastes into the previously active app.
final class Paster {
    static let shared = Paster()

    /// Change count produced by our own most recent write, so the monitor can tell it apart.
    private(set) var ownChangeCount = -1

    private init() {}

    func isOwnChange(_ changeCount: Int) -> Bool { changeCount == ownChangeCount }

    // MARK: Writing

    func write(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ownChangeCount = pb.changeCount
    }

    func write(fileURLs: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(fileURLs as [NSURL])
        ownChangeCount = pb.changeCount
    }

    /// Puts an image on the pasteboard as PNG + TIFF so both modern and legacy apps accept it.
    func write(imageData png: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
        ownChangeCount = pb.changeCount
    }

    /// Puts a media file on the pasteboard. Images carry the file URL plus bitmap data on one item, so
    /// Finder/Slack receive the file while image editors and chat apps receive pixels; videos carry the URL.
    func write(mediaFile url: URL, kind: MediaItem.Kind) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if kind == .image, let data = try? Data(contentsOf: url) {
            if let type = UTType(filenameExtension: url.pathExtension) {
                item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            }
            if let image = NSImage(data: data) {
                if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
                if url.pathExtension.lowercased() != "png", let png = image.pngData { item.setData(png, forType: .png) }
            }
        }
        pb.writeObjects([item])
        ownChangeCount = pb.changeCount
    }

    // MARK: Pasting into another app

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openPasteboardPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Activates `app` and sends ⌘V. Optionally moves the caret left afterwards (for `{cursor}`).
    /// Returns false when Accessibility permission is missing.
    @discardableResult
    func paste(into app: NSRunningApplication?, charactersAfterCursor: Int? = nil) async -> Bool {
        guard Self.isAccessibilityTrusted else { return false }
        if let app, !app.isTerminated {
            app.activate()
            for _ in 0..<10 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        Self.postKey(keyCode: 9, flags: .maskCommand) // V
        if let back = charactersAfterCursor, back > 0 {
            try? await Task.sleep(for: .milliseconds(80))
            for _ in 0..<back { Self.postKey(keyCode: 123, flags: []) } // ←
        }
        return true
    }

    private static func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Remembers which app was frontmost before the island took keyboard focus.
final class FrontmostTracker {
    private(set) var previousApp: NSRunningApplication?

    func capture() {
        let app = NSWorkspace.shared.frontmostApplication
        if app?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = app }
    }

    var previousAppName: String? { previousApp?.localizedName }
}
