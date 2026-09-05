import AppKit

/// URL-scheme control surface. `open`/`close`/`toggle` always work so Shortcuts or Raycast can drive
/// the island; input-injecting and introspection commands need `MACBUD_AUTOMATION=1` in the environment.
enum Automation {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MACBUD_AUTOMATION"] == "1" }
    static let notificationName = Notification.Name("com.rangrik.macbud.automation")

    /// Listens for `mbctl "<command>?<query>"` posts. Unlike `open macbud://…`, this never activates the app,
    /// so tests exercise the same focus behaviour as the global hotkey.
    static func installListener(app: AppDelegate) {
        guard isEnabled else { return }
        DistributedNotificationCenter.default().addObserver(forName: notificationName, object: nil, queue: .main) { note in
            guard let command = note.object as? String, let url = URL(string: "macbud://" + command) else { return }
            MainActor.assumeIsolated { handle(url, app: app) }
        }
    }

    static func handle(_ url: URL, app: AppDelegate) {
        guard url.scheme == "macbud" else { return }
        let command = url.host ?? ""
        let params = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })
        Log.app.info("automation: \(command) \(params)")
        Trace.log("automation \(command) \(params) active=\(NSApp.isActive) key=\(app.notch.panel.isKeyWindow)")
        switch command {
        case "open": app.coordinator.open(section: params["section"].flatMap(Section.init(rawValue:)))
        case "close": app.notch.close()
        case "toggle": app.coordinator.toggle()
        default:
            guard isEnabled else { Log.app.error("automation disabled; ignoring \(command)"); return }
            Task { await handlePrivileged(command, params: params, app: app) }
        }
    }

    private static func handlePrivileged(_ command: String, params: [String: String], app: AppDelegate) async {
        switch command {
        case "snapshot":
            guard let path = params["path"] else { return }
            let kind = NotchController.WindowKind(rawValue: params["window"] ?? "panel") ?? .panel
            do { try app.notch.snapshot(window: kind, to: URL(fileURLWithPath: path)) }
            catch { Log.app.error("snapshot failed: \(error)") }
        case "toast":
            app.notch.showToast(Toast(symbol: params["symbol"] ?? "checkmark.circle.fill",
                                      title: params["title"] ?? "Copied", subtitle: params["subtitle"]))
        case "key":
            for token in (params["seq"] ?? "").split(separator: ",").map(String.init) {
                if token.hasPrefix("wait:"), let ms = Int(token.dropFirst(5)) {
                    try? await Task.sleep(for: .milliseconds(ms))
                    continue
                }
                if let event = keyEvent(for: token, window: app.notch.panel) { app.notch.panel.sendEvent(event) }
                try? await Task.sleep(for: .milliseconds(40))
            }
        case "type":
            for ch in params["text"] ?? "" {
                let s = String(ch)
                let code = usKeyCodes[s.lowercased()] ?? 0
                if let event = makeKeyEvent(characters: s, keyCode: code, flags: [], window: app.notch.panel) { app.notch.panel.sendEvent(event) }
                try? await Task.sleep(for: .milliseconds(15))
            }
        case "dump":
            guard let path = params["path"] else { return }
            let dump = app.coordinator.dump()
            if let data = try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        case "reset-welcome":
            app.settings.hasSeenWelcome = false
        case "dictate":
            app.coordinator.startDictation()
        case "dictate-file":
            guard let path = params["path"] else { return }
            app.coordinator.frontmost.capture()
            app.notch.openDictation()
            app.coordinator.dictation.transcribeFile(URL(fileURLWithPath: path), paste: params["paste"] == "1")
        case "dictate-finish":
            app.coordinator.dictation.finish(paste: params["paste"] == "1")
        case "dictate-cancel":
            app.coordinator.dictation.cancel()
        default:
            Log.app.error("unknown automation command \(command)")
        }
    }

    // MARK: Synthetic key events

    private static let specialKeys: [String: (UInt16, String)] = [
        "return": (36, "\r"), "enter": (36, "\r"), "esc": (53, "\u{1B}"), "escape": (53, "\u{1B}"), "tab": (48, "\t"),
        "up": (126, ""), "down": (125, ""), "left": (123, ""), "right": (124, ""),
        "backspace": (51, "\u{7F}"), "delete": (51, "\u{7F}"), "space": (49, " "),
        "pageup": (116, ""), "pagedown": (121, ""), "home": (115, ""), "end": (119, ""),
    ]

    /// ANSI US layout key codes, used to build realistic events for letters and digits.
    static let usKeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]

    static func keyEvent(for token: String, window: NSWindow) -> NSEvent? {
        var parts = token.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.popLast() else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for mod in parts {
            switch mod {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: break
            }
        }
        if let (code, chars) = specialKeys[keyName] {
            return makeKeyEvent(characters: chars, keyCode: code, flags: flags, window: window)
        }
        return makeKeyEvent(characters: keyName, keyCode: usKeyCodes[keyName] ?? 0, flags: flags, window: window)
    }

    private static func makeKeyEvent(characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    }
}
