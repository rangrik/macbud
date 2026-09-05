import AppKit
import QuickLookUI

/// Shared plumbing for section actions: copy-or-paste flow, toasts, footer hints, Quick Look.
final class ActionContext {
    let state: NotchState
    let notch: NotchController
    let settings: AppSettings
    let frontmost: FrontmostTracker
    let paster = Paster.shared
    private var hintTask: Task<Void, Never>?

    init(state: NotchState, notch: NotchController, settings: AppSettings, frontmost: FrontmostTracker) {
        self.state = state
        self.notch = notch
        self.settings = settings
        self.frontmost = frontmost
    }

    /// Whether `command` means "paste into the previous app" given the Enter preference.
    func wantsPaste(for command: PanelCommand) -> Bool {
        switch command {
        case .primaryAction: settings.enterAction == .paste
        case .secondaryAction: settings.enterAction == .copy
        default: false
        }
    }

    /// Runs `copy`, then either collapses with a "Copied" toast or pastes into the previous app.
    func perform(paste: Bool, description: String, charactersAfterCursor: Int? = nil, copy: () -> Void) {
        copy()
        let appName = frontmost.previousAppName ?? "the active app"
        guard paste else {
            finish(Toast(symbol: "checkmark.circle.fill", title: "Copied", subtitle: description))
            return
        }
        guard Paster.isAccessibilityTrusted else {
            finish(Toast(symbol: "exclamationmark.triangle.fill", title: "Copied · allow Accessibility to paste",
                         subtitle: description, tint: .orange), duration: .seconds(2.6))
            Paster.promptForAccessibility()
            return
        }
        finish(Toast(symbol: "arrow.down.doc.fill", title: "Pasted into \(appName)", subtitle: description))
        let target = frontmost.previousApp
        Task { await paster.paste(into: target, charactersAfterCursor: charactersAfterCursor) }
    }

    private func finish(_ toast: Toast, duration: Duration = .milliseconds(1400)) {
        if settings.showToasts { notch.closeWithToast(toast, duration: duration) } else { notch.close() }
    }

    func showHint(_ text: String, for duration: Duration = .seconds(3)) {
        hintTask?.cancel()
        state.footerHint = text
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.state.footerHint = nil
        }
    }

    func clearHint() {
        hintTask?.cancel()
        state.footerHint = nil
    }

    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        notch.close()
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func quickLook(_ urls: [URL]) {
        QuickLookPresenter.shared.present(urls)
    }
}

/// Minimal Quick Look data source for the shared preview panel.
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPresenter()
    private var urls: [URL] = []

    func present(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, panel.dataSource === self { panel.orderOut(nil); return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}
