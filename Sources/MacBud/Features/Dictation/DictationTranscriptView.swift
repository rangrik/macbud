import SwiftUI

/// Wrapping rows of words. The transcript reads as ordinary text, but every settled word is its own
/// hit target — which is what makes clicking one to correct it possible.
struct WordFlow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, limit), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Settled words you can correct, then the draft tail the engine is still rewriting.
struct DictationTranscriptView: View {
    let controller: DictationController
    var isInteractive = true

    var body: some View {
        WordFlow {
            ForEach(controller.document.settled) { segment in
                ForEach(segment.words) { word in
                    DictationWordChip(word: word, isEditing: controller.editingWordID == word.id,
                                      isInteractive: isInteractive) {
                        controller.beginEditing(word.id)
                    }
                }
            }
            if let draft = controller.document.draft {
                ForEach(draft.words) { word in
                    Text(word.text)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DictationWordChip: View {
    let word: DictationWord
    let isEditing: Bool
    let isInteractive: Bool
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        if isInteractive {
            Button(action: tap) { label }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityLabel(word.isUncertain ? "\(word.text), unsure" : word.text)
                .accessibilityHint("Correct this word")
        } else {
            label
        }
    }

    private var label: some View {
        Text(word.text)
            .underline(word.isUncertain, pattern: .dot, color: Theme.warning)
            .font(.system(size: 14))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(background))
    }

    private var background: Color {
        if isEditing { return Theme.rowSelection }
        return hovering && isInteractive ? Theme.rowHover : .clear
    }
}

/// Correcting happens inside the notch. A second window would mean looking away mid-sentence.
struct DictationCorrectionBar: View {
    let controller: DictationController
    let word: DictationWord
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Heard").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                Text(word.text).font(Theme.caption).foregroundStyle(Theme.warning)
                if let confidence = word.confidence {
                    Text("· \(Int((confidence * 100).rounded()))% sure")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                Text("⏎ save · ⎋ leave it").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 6) {
                ForEach(word.alternatives.prefix(3), id: \.self) { alternative in
                    Button { controller.applyEdit(alternative) } label: {
                        Text(alternative).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.chipFill))
                    }
                    .buttonStyle(.plain)
                }
                TextField("", text: $typed, prompt: Text("Type the right word").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit { controller.applyEdit(typed) }
                    .frame(minWidth: 110)
                Button { controller.removeEditingWord() } label: {
                    Text("Remove").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.chipFill))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.rowHover)
        .onAppear {
            typed = word.text
            focused = true
        }
    }
}
