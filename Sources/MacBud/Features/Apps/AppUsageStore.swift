import AppKit

/// How often and how recently you use each app. Fed by real app activations, so the ranking
/// reflects what you actually switch to — not what you launched from here.
@Observable
final class AppUsageStore {
    nonisolated struct Entry: Codable, Sendable {
        var uses: Int
        var lastUsed: Date
    }

    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private let dataStore: DataStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private static let fileName = "app-usage.json"

    init(dataStore: DataStore = .default) {
        self.dataStore = dataStore
    }

    func load() async {
        entries = await dataStore.load([String: Entry].self, from: Self.fileName) ?? [:]
    }

    /// Watches every app switch on the machine, which is what makes "recent" mean anything on
    /// first run — we do not need you to launch apps from MacBud before the list is useful.
    func startObserving() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated { self.record(bundleID) }
        }
    }

    func record(_ bundleID: String) {
        var entry = entries[bundleID] ?? Entry(uses: 0, lastUsed: .now)
        entry.uses += 1
        entry.lastUsed = .now
        entries[bundleID] = entry
        scheduleSave()
    }

    /// Direct write, for tests and for backfilling history we did not observe live.
    func seed(_ bundleID: String, uses: Int, lastUsed: Date) {
        entries[bundleID] = Entry(uses: uses, lastUsed: lastUsed)
    }

    func lastUsed(for bundleID: String) -> Date? { entries[bundleID]?.lastUsed }

    /// Frecency: how often, weighted by how recently. An app used twice this hour beats one used
    /// twenty times last month, which is what you want from a "recent apps" list.
    func score(for bundleID: String) -> Int {
        guard let entry = entries[bundleID] else { return 0 }
        return entry.uses * Self.recencyWeight(for: Date.now.timeIntervalSince(entry.lastUsed))
    }

    /// Steep on purpose. A flatter curve lets an app you hammered last month outrank one you used
    /// twice this hour, which is the opposite of what "recent" should mean.
    nonisolated static func recencyWeight(for age: TimeInterval) -> Int {
        switch age {
        case ..<3_600: 1_000
        case ..<86_400: 400
        case ..<604_800: 120
        case ..<2_592_000: 40
        default: 10
        }
    }

    /// Best-scoring apps first, skipping anything already shown elsewhere.
    func ranked(_ candidates: [AppEntry], excluding excluded: Set<String>, limit: Int) -> [AppEntry] {
        candidates
            .filter { !excluded.contains($0.bundleID) && entries[$0.bundleID] != nil }
            .map { entry in
                var stamped = entry
                stamped.lastUsed = lastUsed(for: entry.bundleID)
                return stamped
            }
            .sorted { score(for: $0.bundleID) > score(for: $1.bundleID) }
            .prefix(limit)
            .map { $0 }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        saveTask = Task { [dataStore] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            try? await dataStore.save(snapshot, as: Self.fileName)
        }
    }

    func flush() async {
        saveTask?.cancel()
        try? await dataStore.save(entries, as: Self.fileName)
    }
}
