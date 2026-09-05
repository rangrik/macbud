import Foundation

nonisolated struct Snippet: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    /// Short trigger word shown as a badge and used for search (e.g. "sig").
    var keyword: String
    var content: String
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var useCount: Int = 0

    var searchText: String { "\(keyword) \(name) \(content.prefix(2000))" }
    var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !content.isEmpty }
}
