import AppKit
import CryptoKit

/// One-click update from the project's GitHub releases.
@Observable
final class UpdateChecker {
    nonisolated struct Release: Equatable, Sendable {
        var version: String
        var notes: String
        var page: URL
        var archive: URL
        var checksum: URL?
    }

    enum Phase: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var lastChecked: Date?

    @ObservationIgnored private let latestURL: URL
    @ObservationIgnored private let installedApp: URL?
    @ObservationIgnored private var work: Task<Void, Never>?

    nonisolated static let releasesPage = URL(string: "https://github.com/rangrik/macbud/releases")!

    init(latestURL: URL = URL(string: "https://api.github.com/repos/rangrik/macbud/releases/latest")!,
         installedApp: URL? = Bundle.main.bundleURL) {
        self.latestURL = latestURL
        self.installedApp = installedApp
    }

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Replacing the bundle in place only makes sense for a real install, not a build folder.
    var canInstallInPlace: Bool {
        guard let installedApp else { return false }
        return installedApp.path.hasPrefix("/Applications/") || installedApp.path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    func check() {
        guard !phase.isBusy else { return }
        phase = .checking
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await Self.fetchLatest(from: latestURL)
                guard !Task.isCancelled else { return }
                lastChecked = .now
                phase = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
                Log.app.error("update check failed: \(error.localizedDescription)")
            }
        }
    }

    func install(_ release: Release) {
        guard !phase.isBusy, canInstallInPlace, let installedApp else { return }
        phase = .downloading(0)
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let staged = try await Self.download(release) { [weak self] fraction in
                    guard let self, case .downloading = phase else { return }
                    phase = .downloading(fraction)
                }
                guard !Task.isCancelled else { return }
                phase = .installing
                try Self.verifySigningMatches(staged, installed: installedApp)
                try Self.swapAndRelaunch(staged, into: installedApp)
                NSApp.terminate(nil)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
                Log.app.error("update install failed: \(error.localizedDescription)")
            }
        }
    }

    func dismiss() {
        work?.cancel()
        phase = .idle
    }

    // MARK: Release feed

    nonisolated private static func fetchLatest(from url: URL) async throws -> Release {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacBud", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.message("GitHub did not answer with a release.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw UpdateError.message("The release feed was unreadable.") }
        let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { asset -> (String, URL)? in
            guard let name = asset["name"] as? String,
                  let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (name, link)
        }
        guard let archive = assets.first(where: { $0.0.hasSuffix(".zip") })?.1 else {
            throw UpdateError.message("That release has no download to install.")
        }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       notes: json["body"] as? String ?? "",
                       page: (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage,
                       archive: archive,
                       checksum: assets.first { $0.0.hasSuffix(".zip.sha256") }?.1)
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: Download and install

    nonisolated private static func download(_ release: Release,
                                             progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let (archive, response) = try await URLSession.shared.data(from: release.archive)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.message("The download did not complete.")
        }
        await progress(0.7)
        if let checksum = release.checksum {
            let (text, _) = try await URLSession.shared.data(from: checksum)
            let expected = String(decoding: text, as: UTF8.self).split(separator: " ").first.map(String.init)
            let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
            guard expected?.lowercased() == actual else { throw UpdateError.message("The download did not match its checksum.") }
        }
        await progress(0.85)

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("macbud-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let zip = staging.appendingPathComponent("MacBud.zip")
        try archive.write(to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        try FileManager.default.removeItem(at: zip)
        guard let unpacked = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.message("The download did not contain MacBud.")
        }
        await progress(1)
        return unpacked
    }

    /// The real guard: only install a bundle signed by whoever signed the copy already running.
    nonisolated private static func verifySigningMatches(_ candidate: URL, installed: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        let wanted = try signingIdentity(of: installed)
        let found = try signingIdentity(of: candidate)
        guard !wanted.isEmpty, wanted == found else {
            throw UpdateError.message("The download is signed by someone else and was not installed.")
        }
    }

    nonisolated private static func signingIdentity(of app: URL) throws -> String {
        let output = try run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        return output.split(separator: "\n")
            .filter { $0.hasPrefix("Authority=") || $0.hasPrefix("TeamIdentifier=") }
            .joined(separator: "\n")
    }

    /// The app cannot replace itself while running, so a detached script waits for it to quit.
    nonisolated private static func swapAndRelaunch(_ staged: URL, into destination: URL) throws {
        let script = staged.deletingLastPathComponent().appendingPathComponent("swap.sh")
        let body = """
        #!/bin/bash
        set -uo pipefail
        staged=$1; destination=$2; pid=$3; backup=$(dirname "$staged")/previous.app
        for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        if [[ -e "$destination" ]]; then mv "$destination" "$backup" || exit 1; fi
        if ! mv "$staged" "$destination"; then
            [[ -e "$backup" ]] && mv "$backup" "$destination"
            exit 1
        fi
        open -n "$destination"
        sleep 3
        rm -rf "$(dirname "$staged")"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path, staged.path, destination.path, String(ProcessInfo.processInfo.processIdentifier)]
        try task.run()
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard task.terminationStatus == 0 else {
            throw UpdateError.message("\((tool as NSString).lastPathComponent) failed: \(output.prefix(200))")
        }
        return output
    }

    nonisolated enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
    }
}
