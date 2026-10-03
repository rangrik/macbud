import AppKit
import ApplicationServices

/// What was in front at one moment: the app, its window title, a web address and the focused role. Never field text.
nonisolated struct ActivityEvent: Codable, Equatable, Sendable {
    var t: Date
    var app: String?
    var title: String?
    var url: String?
    var role: String?

    /// Words that make a window with unknown focus look like a sign-in page. Extend here.
    static let signInWords = ["login", "log in", "sign in", "signin", "password", "auth", "2fa", "verify"]

    /// A secure field yields the marker alone: that window's title and address are never read. With focus unknown a
    /// secure field cannot be ruled out, so a window that looks like a sign-in page keeps only the app (best effort).
    static func read(t: Date, app: String?, role: String?, subrole: String?, window: () -> (title: String?, url: Any?)) -> ActivityEvent {
        guard role != kAXSecureTextFieldSubrole, subrole != kAXSecureTextFieldSubrole else { return ActivityEvent(t: t, app: app, role: "secure field") }
        let (title, url) = window()
        let address = webAddress(url)
        if role == nil {
            let path = address?.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            if [title ?? "", path].contains(where: { text in signInWords.contains { text.localizedCaseInsensitiveContains($0) } }) {
                return ActivityEvent(t: t, app: app, role: "focus unknown")
            }
        }
        return ActivityEvent(t: t, app: app, title: title.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }, url: address,
                             role: role.map(words) ?? "focus unknown")
    }

    /// Web pages only, as host and path: no file paths, queries or fragments.
    static func webAddress(_ raw: Any?) -> String? {
        guard let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased()),
              let host = url.host(), !host.isEmpty else { return nil }
        let path = url.path(percentEncoded: false)
        return String((host + (path == "/" ? "" : path)).prefix(300))
    }

    /// "AXTextField" → "text field".
    private static func words(_ role: String) -> String {
        role.dropFirst(role.hasPrefix("AX") ? 2 : 0).reduce(into: "") { out, c in
            if c.isUppercase, !out.isEmpty { out += " " }
            out.append(c)
        }.lowercased()
    }
}

/// Reads the front app through Accessibility, which MacBud already holds for paste. No Apple Events, no pixels.
nonisolated enum ActivityProbe {
    static func read(pid: pid_t, app: String?) -> ActivityEvent? {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return gate(trusted: AXIsProcessTrusted(), locked: locked, idle: idle) {
            let application = AXUIElementCreateApplication(pid)
            // A hung app must not stall the log.
            AXUIElementSetMessagingTimeout(application, 0.2)
            let focused = element(kAXFocusedUIElementAttribute, on: application)
            return ActivityEvent.read(t: .now, app: app, role: focused.flatMap { value(kAXRoleAttribute, on: $0) as? String },
                                      subrole: focused.flatMap { value(kAXSubroleAttribute, on: $0) as? String }) {
                let window = element(kAXFocusedWindowAttribute, on: application)
                return (window.flatMap { value(kAXTitleAttribute, on: $0) as? String },
                        window.flatMap { value("AXURL", on: $0) ?? value(kAXDocumentAttribute, on: $0) })
            }
        }
    }

    /// Nothing is read while the screen is locked, after five idle minutes, or without Accessibility.
    static func gate(trusted: Bool, locked: Bool, idle: TimeInterval, read: () -> ActivityEvent?) -> ActivityEvent? {
        guard trusted, !locked, idle < 300 else { return nil }
        return read()
    }

    private static func element(_ name: String, on parent: AXUIElement) -> AXUIElement? {
        guard let raw = value(name, on: parent), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func value(_ name: String, on element: AXUIElement) -> CFTypeRef? {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success ? raw : nil
    }
}

/// A rolling local log of what was in front, and the one line both models read from it.
final class ActivityLog {
    static let file = "activity.jsonl"
    /// Under 2 MB even with the line that crosses it.
    private static let maxBytes = 1_990_000
    private let memory: DataStore
    private let probe: @Sendable (pid_t, String?) -> ActivityEvent?
    /// Newest last; the line needs only the last few minutes.
    private(set) var events: [ActivityEvent] = []
    /// When the app, title or address last changed; the focused role alone does not count.
    private(set) var changedAt: Date?
    private var prunedAt = Date.distantPast

    init(memory: DataStore, probe: @escaping @Sendable (pid_t, String?) -> ActivityEvent? = ActivityProbe.read) {
        self.memory = memory
        self.probe = probe
    }

    func load() async {
        prunedAt = .now
        await prune(before: prunedAt - 23 * 3600)
        events = Array(await memory.lines(ActivityEvent.self, in: Self.file).suffix(50))
    }

    /// Reads the front app off the main thread and records it when anything changed.
    func sample() async {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        let pid = front.processIdentifier, app = front.bundleIdentifier, probe = probe
        guard let event = await Task.detached(operation: { probe(pid, app) }).value else { return }
        await record(event)
    }

    func record(_ event: ActivityEvent) async {
        let last = events.last
        guard event.app != last?.app || event.title != last?.title || event.url != last?.url || event.role != last?.role else { return }
        if event.app != last?.app || event.title != last?.title || event.url != last?.url { changedAt = event.t }
        events.append(event)
        if events.count > 50 { events.removeFirst(events.count - 50) }
        await memory.appendLine(event, to: Self.file, limit: Self.maxBytes)
    }

    /// Every half hour, drops what is older than 23 hours, so nothing in the file reaches a day.
    func pruneIfDue(now: Date) {
        guard now.timeIntervalSince(prunedAt) >= 1800 else { return }
        prunedAt = now
        Task { await prune(before: now - 23 * 3600) }
    }

    private func prune(before cutoff: Date) async {
        await memory.keepLines(ActivityEvent.self, in: Self.file) { $0.t > cutoff }
    }

    /// Up to 8 events from the last 10 minutes, oldest first, in words both models read.
    func line(now: Date) -> String {
        let recent = events.filter { now.timeIntervalSince($0.t) <= 600 }.suffix(8)
        guard !recent.isEmpty else { return "No recent activity." }
        return recent.map { e in
            let minutes = Int(now.timeIntervalSince(e.t) / 60)
            return (minutes < 1 ? "just now: " : "\(minutes) min ago: ")
                + ([e.app ?? "unknown app", e.title.map { "“\($0)”" }, e.url, e.role].compactMap { $0 }).joined(separator: ", ")
        }.joined(separator: "; ")
    }

    /// App, web host and title of the newest event, hashed, while that app is still in front; nil once it is stale.
    func focus(app: String?, now: Date) -> String? {
        guard let e = events.last, e.app == app, now.timeIntervalSince(e.t) <= 600 else { return nil }
        let host = e.url?.split(separator: "/").first.map(String.init)
        return String([e.app, host, e.title].map { $0 ?? "-" }.joined(separator: "|").hashValue, radix: 36)
    }

    func reset() async {
        events = []
        changedAt = nil
        await memory.remove([Self.file])
    }
}
