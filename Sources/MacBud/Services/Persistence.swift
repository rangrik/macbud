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
}
