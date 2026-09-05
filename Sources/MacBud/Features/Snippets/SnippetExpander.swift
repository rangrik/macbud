import Foundation

/// Expands `{placeholders}` inside snippet text.
///
/// Supported: `{clipboard}`, `{date}`, `{time}`, `{datetime}`, `{date:FORMAT}` (DateFormatter pattern),
/// `{uuid}`, `{cursor}` (removed; its position is reported so the caret can be moved back after pasting),
/// `{{` / `}}` for literal braces.
nonisolated enum SnippetExpander {
    nonisolated struct Context: Sendable {
        var clipboard: String?
        var now: Date = .now
        var uuid: @Sendable () -> String = { UUID().uuidString }
        var locale: Locale = .autoupdatingCurrent
        var timeZone: TimeZone = .autoupdatingCurrent
    }

    nonisolated struct Expansion: Equatable, Sendable {
        var text: String
        /// Characters between the `{cursor}` marker and the end of the text, if a marker was present.
        var charactersAfterCursor: Int?
    }

    static let knownPlaceholders = ["{clipboard}", "{date}", "{time}", "{datetime}", "{date:yyyy-MM-dd}", "{uuid}", "{cursor}"]

    static func expand(_ template: String, context: Context) -> Expansion {
        var output = ""
        var cursorOffset: Int?
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            if c == "{" {
                let next = template.index(after: i)
                if next < template.endIndex, template[next] == "{" {
                    output.append("{"); i = template.index(after: next); continue
                }
                if let close = template[next...].firstIndex(of: "}") {
                    let name = String(template[next..<close])
                    if let replacement = value(for: name, context: context) {
                        output.append(replacement)
                        i = template.index(after: close); continue
                    }
                    if name == "cursor" {
                        cursorOffset = output.count
                        i = template.index(after: close); continue
                    }
                }
                output.append(c); i = next; continue
            }
            if c == "}" {
                let next = template.index(after: i)
                if next < template.endIndex, template[next] == "}" {
                    output.append("}"); i = template.index(after: next); continue
                }
            }
            output.append(c)
            i = template.index(after: i)
        }
        let after = cursorOffset.map { output.count - $0 }
        return Expansion(text: output, charactersAfterCursor: after)
    }

    /// Placeholder ranges (character offsets) for syntax highlighting in editors and previews.
    static func placeholderRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "{", i + 1 < chars.count, chars[i + 1] != "{" {
                if let close = chars[(i + 1)...].firstIndex(of: "}") {
                    let name = String(chars[(i + 1)..<close])
                    if !name.isEmpty, !name.contains(" "), name == "cursor" || value(for: name, context: Context(now: .distantPast)) != nil {
                        ranges.append(i..<(close + 1))
                    }
                    i = close + 1; continue
                }
            } else if chars[i] == "{" { i += 2; continue }
            i += 1
        }
        return ranges
    }

    private static func value(for name: String, context: Context) -> String? {
        switch name {
        case "clipboard": return context.clipboard ?? ""
        case "uuid": return context.uuid()
        case "date": return formatted(context, date: .medium, time: .none)
        case "time": return formatted(context, date: .none, time: .short)
        case "datetime": return formatted(context, date: .medium, time: .short)
        default:
            if name.hasPrefix("date:") {
                let pattern = String(name.dropFirst(5))
                guard !pattern.isEmpty else { return nil }
                let f = DateFormatter()
                f.locale = context.locale
                f.timeZone = context.timeZone
                f.dateFormat = pattern
                return f.string(from: context.now)
            }
            return nil
        }
    }

    private static func formatted(_ context: Context, date: DateFormatter.Style, time: DateFormatter.Style) -> String {
        let f = DateFormatter()
        f.locale = context.locale
        f.timeZone = context.timeZone
        f.dateStyle = date
        f.timeStyle = time
        return f.string(from: context.now)
    }
}
