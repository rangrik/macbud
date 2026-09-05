import Foundation
import os

/// Central loggers. Watch with `make log`.
nonisolated enum Log {
    static let app = Logger(subsystem: "com.rangrik.macbud", category: "app")
    static let notch = Logger(subsystem: "com.rangrik.macbud", category: "notch")
    static let clipboard = Logger(subsystem: "com.rangrik.macbud", category: "clipboard")
    static let snippets = Logger(subsystem: "com.rangrik.macbud", category: "snippets")
    static let screenshots = Logger(subsystem: "com.rangrik.macbud", category: "screenshots")
    static let input = Logger(subsystem: "com.rangrik.macbud", category: "input")
}

/// Plain-text trace written only when automation is enabled; `log show` is unreliable for debug-level messages.
nonisolated enum Trace {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacBud.log")
    static let enabled = ProcessInfo.processInfo.environment["MACBUD_AUTOMATION"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) \(message())\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
