import SwiftUI

struct SnippetPreview: View {
    let snippet: Snippet?
    let controller: SnippetsSectionController

    var body: some View {
        if let snippet {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Text(highlighted(snippet.content))
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                Rectangle().fill(Theme.separator).frame(height: 1)
                HStack(spacing: 6) {
                    Text("Used \(snippet.useCount) \(snippet.useCount == 1 ? "time" : "times")")
                    Text("·")
                    Text("Updated \(snippet.updatedAt.relativeDescription)")
                    if !SnippetExpander.placeholderRanges(in: snippet.content).isEmpty {
                        Text("·")
                        Label("Placeholders expand when used", systemImage: "curlybraces")
                    }
                    Spacer()
                    KeyHint(keys: "⌘E", label: "Edit")
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: 30)
            }
        } else {
            EmptyState(symbol: "text.badge.plus", title: "Snippets are text you paste often",
                       detail: "Press ⌘N to create one. Use {date}, {time}, {clipboard} or {cursor} inside.")
        }
    }

    private func highlighted(_ content: String) -> AttributedString {
        AttributedString.highlighting(content, ranges: SnippetExpander.placeholderRanges(in: content)) { container in
            container.foregroundColor = Theme.accent
            container.font = Theme.mono
        }
    }
}

struct SnippetEditor: View {
    @Bindable var draft: SnippetDraft
    let controller: SnippetsSectionController
    @FocusState private var field: Field?
    @Environment(\.snapshotMode) private var snapshotMode

    enum Field: Hashable { case name, keyword, content }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(draft.isNew ? "New snippet" : "Edit snippet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !draft.isValid {
                    Text("Needs a name and content").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            HStack(spacing: 10) {
                EditorField(title: "Name", text: $draft.name).focused($field, equals: .name)
                EditorField(title: "Keyword", text: $draft.keyword, monospaced: true).frame(width: 130).focused($field, equals: .keyword)
            }
            if snapshotMode {
                Text(draft.content.isEmpty ? " " : draft.content)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                    .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
            TextEditor(text: $draft.content)
                .font(Theme.mono)
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($field, equals: .content)
            }
            HStack(spacing: 6) {
                Text("Insert").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                ForEach(SnippetExpander.knownPlaceholders, id: \.self) { placeholder in
                    Text(placeholder)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.chipFill, in: Capsule())
                        .onTapGesture { draft.content += placeholder; field = .content }
                }
                Spacer()
            }
        }
        .padding(16)
        .defaultFocus($field, .name)
        .task {
            // Focus once the fields are in the window; setting it in onAppear is too early.
            try? await Task.sleep(for: .milliseconds(60))
            field = draft.name.isEmpty ? .name : .content
        }
    }
}

private struct EditorField: View {
    let title: String
    @Binding var text: String
    var monospaced = false
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Group {
                if snapshotMode {
                    Text(text.isEmpty ? " " : text).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: $text).textFieldStyle(.plain)
                }
            }
            .font(monospaced ? Theme.mono : Theme.body)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}
