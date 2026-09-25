import AppKit
import SwiftUI

struct ClipboardPreview: View {
    let item: ClipboardItem?
    let store: ClipboardStore

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                content(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(Theme.separator).frame(height: 1)
                metadata(for: item)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
            }
        } else {
            EmptyState(symbol: "arrow.up.and.down", title: "Select an item", detail: "Use ↑ ↓ to browse; ↩ copies it.")
        }
    }

    @ViewBuilder private func content(for item: ClipboardItem) -> some View {
        switch item.kind {
        case .text, .link:
            let text = item.text ?? ""
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if item.kind == .link, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        HStack(spacing: 6) {
                            Image(systemName: "globe").foregroundStyle(Theme.textSecondary)
                            Text(url.host() ?? "Link").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Text(String(text.prefix(20_000)))
                        .font(Self.looksLikeCode(text) ? Theme.mono : Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .scrollIndicators(.automatic)
        case .image:
            DiskImage(url: store.previewURL(for: item), maxPixelSize: 1600) {
                ProgressView().controlSize(.small)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.filePaths, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Text((path as NSString).deletingLastPathComponent).font(Theme.rowSubtitle).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func metadata(for item: ClipboardItem) -> some View {
        HStack(spacing: 6) {
            if let app = AppInfo.name(for: item.sourceBundleID) { Text("From \(app)"); Text("·") }
            Text(item.copiedAt.relativeDescription)
            Text("·")
            switch item.kind {
            case .text, .link: Text("\(item.characterCount.formatted()) chars · \(item.lineCount) \(item.lineCount == 1 ? "line" : "lines")")
            case .image: Text("\(item.pixelWidth ?? 0) × \(item.pixelHeight ?? 0) · PNG · \(item.byteCount.byteCountDescription)")
            case .file: Text("\(item.filePaths.count) \(item.filePaths.count == 1 ? "file" : "files") · \(item.byteCount.byteCountDescription)")
            }
            Spacer()
            if item.isPinned { Label("Pinned", systemImage: "pin.fill").foregroundStyle(Theme.accent) }
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
    }

    static func looksLikeCode(_ text: String) -> Bool {
        guard text.contains("\n") else { return false }
        let signals = ["{", "};", "=>", "func ", "def ", "import ", "</", "#include", "const ", "let ", "var ", "class ", "return ", "SELECT ", "$ "]
        return signals.contains { text.contains($0) }
    }
}
