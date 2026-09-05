import Foundation
import CryptoKit

nonisolated struct ClipboardItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable { case text, link, image, file }

    let id: UUID
    var kind: Kind
    /// Last time this content was copied (bumped on duplicates).
    var copiedAt: Date
    var text: String?
    /// Absolute paths for `.file` items.
    var filePaths: [String] = []
    /// File name (inside the images directory) of the full-resolution PNG for `.image` items.
    var imageFile: String?
    /// File name of a downscaled JPEG used for lists and previews.
    var previewFile: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteCount: Int
    var sourceBundleID: String?
    var isPinned = false
    /// Stable identity of the content, used for de-duplication.
    var contentHash: String

    var title: String {
        switch kind {
        case .text, .link:
            let firstLine = (text ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            return firstLine.isEmpty ? "Whitespace" : String(firstLine.prefix(200))
        case .image:
            if let w = pixelWidth, let h = pixelHeight { return "Image \(w)×\(h)" }
            return "Image"
        case .file:
            let names = filePaths.map { ($0 as NSString).lastPathComponent }
            return names.count > 2 ? "\(names[0]) and \(names.count - 1) more" : names.joined(separator: ", ")
        }
    }

    /// What search runs against.
    var searchText: String {
        switch kind {
        case .text, .link: return String((text ?? "").prefix(4000))
        case .image: return title
        case .file: return filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
        }
    }

    var lineCount: Int { text.map { $0.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count } ?? 0 }
    var characterCount: Int { text?.count ?? 0 }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    static func hash(ofText text: String) -> String { hash(of: Data(text.utf8)) }

    static func looksLikeLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return false }
        return true
    }
}
