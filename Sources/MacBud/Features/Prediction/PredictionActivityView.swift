import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Prediction Activity window. AppKit, so the island, the menu bar and Settings can all open it.
enum PredictionActivityWindow {
    static let id = NSUserInterfaceItemIdentifier("PredictionActivity")
    private static var window: NSWindow?
    private static let frameKey = "predictionActivityFrame"

    static func show(predictor: SectionPredictor, settings: AppSettings) {
        let window = window ?? make(PredictionActivityView(predictor: predictor, settings: settings))
        self.window = window
        // MacBud is a background app and macOS may refuse to activate it, so order the window front regardless.
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKey()
    }

    private static func make(_ view: PredictionActivityView) -> NSWindow {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Prediction Activity"
        window.identifier = id
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 640))
        window.center()
        // Not AppKit's frame autosave: it moves the window to the main display once the menu bar has changed screens.
        if let saved = UserDefaults.standard.string(forKey: frameKey).map(NSRectFromString),
           NSScreen.screens.contains(where: { $0.frame.intersects(saved) }) { window.setFrame(saved, display: false) }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameKey) }
            }
        }
        return window
    }
}

struct PredictionActivityView: View {
    let predictor: SectionPredictor
    let settings: AppSettings
    @State private var filter = ActivityFilter.all
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var showsStrategies = false

    var body: some View {
        let shown = PredictionActivity.timeline(calls: predictor.calls, sessions: predictor.sessions, cap: settings.prediction.dailyCallCap)
            .filter { filter.includes($0) && $0.matches(query) }
        VStack(spacing: 0) {
            header(shown)
            Divider()
            HStack {
                Picker("Show", selection: $filter) { ForEach(ActivityFilter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField("Search summaries, prompts and replies", text: $query).textFieldStyle(.roundedBorder)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { entry in
                            ActivityRow(entry: entry, isExpanded: expanded.contains(entry.id)) {
                                if expanded.remove(entry.id) == nil { expanded.insert(entry.id) }
                            } reveal: { id in
                                filter = .all
                                query = ""
                                expanded.insert(id)
                                Task { proxy.scrollTo(id, anchor: .top) }
                            }
                            Divider()
                        }
                    }
                }
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView("Nothing here", systemImage: "sparkles",
                                               description: Text(predictor.calls.isEmpty && predictor.sessions.isEmpty
                                                                 ? "Model calls and opens show up here as they happen." : "No rows match this filter."))
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private func header(_ shown: [ActivityEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Today").font(.caption.bold()).foregroundStyle(.secondary)
                    let usage = PredictionActivity.usageToday(predictor.calls)
                    if usage.isEmpty { Text("No calls") }
                    ForEach(usage, id: \.model) { Text("\($0.model): \($0.calls) calls · \($0.tokens) tokens (\($0.cached) cached)") }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Last 7 days").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("Model \(predictor.rates.model.text)")
                    Text("Rules \(predictor.rates.heuristic.text)")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    HStack {
                        Button("Review now") { Task { await predictor.review() } }
                            .disabled(predictor.isBusy || !settings.prediction.useModel || predictor.sessions.isEmpty)
                        Button("Open memory folder") {
                            try? FileManager.default.createDirectory(at: predictor.memory.directory, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(predictor.memory.directory)
                        }
                        Button("Export…") { export(shown) }.disabled(shown.isEmpty)
                    }
                    if predictor.isBusy {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("A model call is running…") }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup(isExpanded: $showsStrategies) {
                Text(predictor.strategies.isEmpty ? "None yet. The reviewer writes these once misses build up." : predictor.strategies)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            } label: {
                Text("Strategies the driver reads" + (predictor.lastReview.map { " · written \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
            }
        }
        .padding(12)
    }

    private func export(_ shown: [ActivityEntry]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacBud prediction activity \(Date.now.formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scope = "Filter: \(filter.rawValue)" + (query.isEmpty ? "" : ", search “\(query)”")
        do { try Data(PredictionActivity.markdown(shown, scope: scope).utf8).write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry
    let isExpanded: Bool
    let toggle: () -> Void
    let reveal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.caption2).foregroundStyle(.tertiary).frame(width: 10)
                    Image(systemName: icon.name).foregroundStyle(icon.tint).frame(width: 18)
                    Text(Calendar.current.isDateInToday(entry.t) ? entry.t.formatted(date: .omitted, time: .standard)
                         : entry.t.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))
                        .monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 84, alignment: .leading)
                    Text(entry.summary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(Array(PredictionActivity.details(entry).enumerated()), id: \.offset) { DetailSection(detail: $0.element, reveal: reveal) }
                    .padding(.leading, 36)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .id(entry.id)
    }

    private var icon: (name: String, tint: Color) {
        switch entry.kind {
        case .driver: ("sparkles", .purple)
        case .reviewer: ("brain.head.profile", .blue)
        case .open: ("rectangle.topthird.inset.filled", .secondary)
        case .hit: ("checkmark.circle.fill", .green)
        case .miss: ("xmark.circle.fill", .orange)
        case .capReached: ("hourglass", .yellow)
        case .error: ("exclamationmark.triangle.fill", .red)
        }
    }
}

private struct DetailSection: View {
    let detail: ActivityDetail
    let reveal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(detail.title).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if let link = detail.link { Button("Show") { reveal(link) }.buttonStyle(.link).font(.caption) }
                // Through Paster, so MacBud's clipboard history does not file the copy as dictation output.
                Button("Copy") { Paster.shared.write(text: detail.text) }.buttonStyle(.link).font(.caption)
            }
            Group {
                if let diff = detail.diff {
                    VStack(alignment: .leading, spacing: 0) {
                        if diff.isEmpty { Text("No strategies before or after.") }
                        ForEach(Array(diff.enumerated()), id: \.offset) { DiffRow(line: $0.element) }
                    }
                } else {
                    Text(detail.text)
                }
            }
            .font(detail.isCode ? .system(size: 11, design: .monospaced) : .callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct DiffRow: View {
    let line: DiffLine

    var body: some View {
        let (mark, text, tint): (String, String, Color?) = switch line {
        case .same(let text): (" ", text, nil)
        case .added(let text): ("+", text, .green)
        case .removed(let text): ("-", text, .red)
        }
        Text("\(mark) \(text)")
            .foregroundStyle(tint ?? .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tint ?? .clear).opacity(0.12))
    }
}
