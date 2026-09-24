import Foundation

/// Atomic JSON file storage under Application Support. All disk work happens on the actor.
actor DataStore {
    let directory: URL
    nonisolated var imagesDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }

    init(directory: URL) {
        self.directory = directory
    }

    static let `default` = DataStore(directory: {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacBud", isDirectory: true)
    }())

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }

    /// Returns nil when the file does not exist. A corrupt file is moved aside and nil is returned.
    func load<T: Decodable & Sendable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            Log.app.error("corrupt \(name): \(error.localizedDescription); moving aside")
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("broken"))
            return nil
        }
    }

    func save<T: Encodable & Sendable>(_ value: T, as name: String) throws {
        try ensureDirectories()
        let data = try Self.encoder.encode(value)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func writeImage(_ data: Data, named name: String) throws {
        try ensureDirectories()
        try data.write(to: imagesDirectory.appendingPathComponent(name), options: .atomic)
    }

    func removeImage(named name: String) {
        try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(name))
    }

    nonisolated func imageURL(named name: String) -> URL { imagesDirectory.appendingPathComponent(name) }

    // MARK: Plain files the owner can read (JSONL and Markdown)

    private static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Appends one JSON line; past `limit` bytes only the newer half is kept.
    func appendLine<T: Encodable & Sendable>(_ value: T, to name: String, limit: Int = 2_000_000) {
        guard var line = try? Self.lineEncoder.encode(value) else { return }
        line.append(0x0A)
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: url) else { try? line.write(to: url, options: .atomic); return }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.write(contentsOf: line)
        try? handle.close()
        guard size > limit, let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        try? Data((lines.suffix(lines.count / 2).joined(separator: [0x0A])) + [0x0A]).write(to: url, options: .atomic)
    }

    func lines<T: Decodable & Sendable>(_ type: T.Type, in name: String) -> [T] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(T.self, from: Data($0)) }
    }

    func text(_ name: String) -> (text: String, modified: Date?)? {
        let url = directory.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (text, try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    func writeText(_ text: String, to name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func remove(_ names: [String]) {
        for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }
}
