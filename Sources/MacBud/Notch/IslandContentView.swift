import SwiftUI

/// The island body: header band beside the notch, search row, section body, footer hints.
struct IslandContentView: View {
    @Bindable var state: NotchState
    let coordinator: PanelCoordinator
    @FocusState private var searchFocused: Bool

    var body: some View {
        let notchWidth = state.geometry.notchRect.width
        let sideWidth = (state.metrics.islandSize.width - notchWidth) / 2
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SectionTabs(selected: state.section) { coordinator.select($0) }
                    .padding(.leading, 14)
                    .frame(width: sideWidth, alignment: .leading)
                Spacer().frame(width: notchWidth)
                HeaderStatus(coordinator: coordinator)
                    .padding(.trailing, 18)
                    .frame(width: sideWidth, alignment: .trailing)
            }
            .frame(height: state.geometry.notchRect.height)

            if coordinator.showsWelcome {
                WelcomeView(coordinator: coordinator)
            } else {
                SearchRow(state: state, coordinator: coordinator, focused: $searchFocused)
                Rectangle().fill(Theme.separator).frame(height: 1)
                sectionBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Theme.separator).frame(height: 1)
                FooterBar(state: state, coordinator: coordinator)
            }
        }
        .onChange(of: state.wantsSearchFocus, initial: true) { _, wants in searchFocused = wants }
        .onChange(of: state.query) { coordinator.queryChanged() }
    }

    @ViewBuilder private var sectionBody: some View {
        switch state.section {
        case .clipboard: ClipboardSectionView(controller: coordinator.clipboard)
        case .snippets: SnippetsSectionView(controller: coordinator.snippets)
        case .screenshots: ScreenshotsSectionView(controller: coordinator.screenshots)
        }
    }
}

struct SectionTabs: View {
    let selected: Section
    let onSelect: (Section) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Section.allCases) { section in
                    let isSelected = section == selected
                    HStack(spacing: 6) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                        if isSelected {
                            Text(section.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.horizontal, isSelected ? 10 : 8)
                    .frame(height: 24)
                    .glassEffect(isSelected ? .regular.tint(.white.opacity(0.16)) : .identity, in: .capsule)
                    .contentShape(Capsule())
                    .onTapGesture { onSelect(section) }
                    .help(section.title)
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: selected)
    }
}

struct HeaderStatus: View {
    let coordinator: PanelCoordinator

    var body: some View {
        HStack(spacing: 8) {
            if coordinator.settings.clipboardPaused, coordinator.state.section == .clipboard {
                Label("Paused", systemImage: "pause.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
            }
            Text("\(coordinator.activeResultCount) \(coordinator.activeResultCount == 1 ? "item" : "items")")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
        }
    }
}

struct SearchRow: View {
    @Bindable var state: NotchState
    let coordinator: PanelCoordinator
    var focused: FocusState<Bool>.Binding
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            if snapshotMode {
                Text(state.query.isEmpty ? state.section.searchPlaceholder : state.query)
                    .font(Theme.search)
                    .foregroundStyle(state.query.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
            TextField("", text: $state.query, prompt: Text(state.section.searchPlaceholder).foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(Theme.search)
                .foregroundStyle(Theme.textPrimary)
                .focused(focused)
                .disabled(coordinator.snippets.isEditing && state.section == .snippets)
            }
            if !state.query.isEmpty {
                Text("\(coordinator.activeResultCount) results")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
    }
}

struct FooterBar: View {
    @Bindable var state: NotchState
    let coordinator: PanelCoordinator

    var body: some View {
        HStack(spacing: 14) {
            ForEach(coordinator.footerHints()) { hint in
                if let command = hint.command {
                    Button { coordinator.handle(command) } label: { KeyHint(keys: hint.keys, label: hint.label) }
                        .buttonStyle(FooterHintButtonStyle())
                        .help("Click to \(hint.label.lowercased())")
                } else {
                    KeyHint(keys: hint.keys, label: hint.label)
                }
            }
            Spacer(minLength: 8)
            if let hint = state.footerHint {
                Text(hint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(1)
                    .transition(.opacity)
            } else {
                Button { coordinator.handle(.close) } label: { KeyHint(keys: coordinator.keys(for: .close), label: "Close") }
                    .buttonStyle(FooterHintButtonStyle())
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 36)
        .animation(.easeOut(duration: 0.15), value: state.footerHint)
    }
}

/// Hairline-free, hover-brightening button used for the clickable footer hints.
struct FooterHintButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background((hovering || configuration.isPressed) ? Theme.rowHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Keyboard-driven vertical list with hover, click-to-select and double-click-to-activate.
struct ResultsList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void
    @ViewBuilder let row: (Item, Bool) -> Row

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SelectableRow(isSelected: index == selectedIndex) {
                            row(item, index == selectedIndex)
                        }
                        .onTapGesture(count: 2) { onActivate(index) }
                        .onTapGesture { onSelect(index) }
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .onChange(of: selectedIndex, initial: true) { _, index in
                guard items.indices.contains(index) else { return }
                proxy.scrollTo(items[index].id, anchor: nil)
            }
        }
    }
}

struct SelectableRow<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Theme.rowSelection : hovering ? Theme.rowHover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct WelcomeView: View {
    let coordinator: PanelCoordinator

    var body: some View {
        let hotKey = coordinator.hotKeys?.effectiveToggle?.displayString ?? HotKey.defaultToggle.displayString
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Image(systemName: "rectangle.topthird.inset.filled")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 6) {
                Text("MacBud lives in your notch")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Press **\(hotKey)** anywhere to open it. Everything is keyboard-first.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(alignment: .top, spacing: 26) {
                WelcomeStep(symbol: "doc.on.clipboard", title: "Clipboard",
                            text: "Everything you copy is captured. When macOS asks, choose “Always Allow” so history keeps flowing.")
                WelcomeStep(symbol: "text.badge.checkmark", title: "Snippets",
                            text: "Saved text you paste often. Placeholders like {date} and {clipboard} expand when used.")
                WelcomeStep(symbol: "photo.on.rectangle.angled", title: "Screenshots",
                            text: "Browse \(coordinator.settings.screenshotFolders.first.map { ($0 as NSString).lastPathComponent } ?? "Desktop") and copy any image or video. Add folders in Settings (⌘,).")
            }
            .padding(.horizontal, 36)
            if let problem = coordinator.hotKeys?.toggleProblem {
                Text(problem).font(Theme.caption).foregroundStyle(Theme.warning)
            }
            Spacer(minLength: 8)
            HStack(spacing: 16) {
                KeyHint(keys: "↩", label: "Get started", emphasized: true)
                KeyHint(keys: "⌘↩", label: "Paste directly needs Accessibility — grant it later in Settings")
            }
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeStep: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
