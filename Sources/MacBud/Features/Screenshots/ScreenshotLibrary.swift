import AppKit
import UniformTypeIdentifiers

/// Scans configured folders for images and videos and keeps the list fresh via folder watchers.
@Observable
final class ScreenshotLibrary {
    private(set) var items: [MediaItem] = []
    private(set) var isScanning = false
    private(set) var missingFolders: [URL] = []
    private(set) var lastScan: Date?
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            rebuildWatchers()
            if isEnabled {
                requestRescan(delay: .zero)
            } else {
                rescanTask?.cancel()
                scanTask?.cancel()
                isScanning = false
            }
        }
    }

    var folders: [URL] = [] { didSet { if folders != oldValue { rebuildWatchers(); requestRescan(delay: .zero) } } }
    var includeSubfolders = false { didSet { if includeSubfolders != oldValue { requestRescan(delay: .zero) } } }
    var includeVideos = true { didSet { if includeVideos != oldValue { requestRescan(delay: .zero) } } }

    @ObservationIgnored private var watchers: [FolderWatcher] = []
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<(items: [MediaItem], missing: [URL]), Never>?

    init() {}

    func results(for query: String) -> [(item: MediaItem, match: SearchMatch)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return items.map { ($0, SearchMatch(score: 0, ranges: [])) } }
        return SearchMatcher.rank(items, query: trimmed, text: \.filename)
    }

    func item(id: URL) -> MediaItem? { items.first { $0.url == id } }

    func requestRescan(delay: Duration = .milliseconds(400)) {
        guard isEnabled else { return }
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.rescan()
        }
    }

    func rescan() async {
        guard isEnabled else { return }
        scanTask?.cancel()
        isScanning = true
        let folders = folders, subfolders = includeSubfolders, videos = includeVideos
        let task = Task.detached(priority: .userInitiated) {
            Self.scan(folders: folders, includeSubfolders: subfolders, includeVideos: videos)
        }
        scanTask = task
        let result = await task.value
        guard isEnabled, !task.isCancelled else { return }
        items = result.items
        missingFolders = result.missing
        lastScan = .now
        isScanning = false
        Log.screenshots.info("scanned \(folders.count) folders → \(result.items.count) items, \(result.missing.count) missing")
    }

    func trash(_ item: MediaItem) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        items.removeAll { $0.url == item.url }
    }

    nonisolated static func scan(folders: [URL], includeSubfolders: Bool, includeVideos: Bool) -> (items: [MediaItem], missing: [URL]) {
        let fm = FileManager.default
        var items: [MediaItem] = []
        var missing: [URL] = []
        let keys: Set<URLResourceKey> = [.contentTypeKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey, .isRegularFileKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !includeSubfolders { options.insert(.skipsSubdirectoryDescendants) }
        for folder in folders {
            guard !Task.isCancelled else { break }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { missing.append(folder); continue }
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: options) else { continue }
            for case let url as URL in enumerator {
                guard !Task.isCancelled else { break }
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                      let type = values.contentType, let kind = MediaItem.kind(for: type) else { continue }
                if kind == .video, !includeVideos { continue }
                let date = values.creationDate ?? values.contentModificationDate ?? .distantPast
                items.append(MediaItem(url: url, kind: kind, createdAt: date, byteCount: values.fileSize ?? 0, folder: folder))
            }
        }
        items.sort { $0.createdAt > $1.createdAt }
        return (items, missing)
    }

    private func rebuildWatchers() {
        guard isEnabled else { watchers = []; return }
        watchers = folders.compactMap { url in
            FolderWatcher(url: url) { [weak self] in
                Task { @MainActor in self?.requestRescan() }
            }
        }
    }
}

/// Fires when a directory's contents change (file added, removed, renamed).
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, handler: @escaping @Sendable () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .global(qos: .utility))
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
