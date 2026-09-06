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
                SectionTabs(sections: coordinator.settings.enabledSections, selected: state.section) { coordinator.select($0) }
                    .padding(.leading, 14)
                    .frame(width: sideWidth, alignment: .leading)
                Spacer().frame(width: notchWidth)
                HeaderStatus(coordinator: coordinator)
                    .padding(.trailing, 18)
                    .frame(width: sideWidth, alignment: .trailing)
            }
            .frame(height: state.geometry.notchRect.height)

            if !coordinator.hasEnabledSection {
                VStack(spacing: 12) {
                    Text("Choose your features").font(.headline)
                    Text("Enable a section in Settings to show it here.").foregroundStyle(.secondary)
                    Button("Open Settings") { coordinator.openSettings() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if coordinator.showsWelcome {
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
        case .dictationHistory: DictationHistorySectionView(controller: coordinator.dictationHistory)
        }
    }
}

struct SectionTabs: View {
    let sections: [Section]
    let selected: Section
    let onSelect: (Section) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(sections) { section in
                    let isSelected = section == selected
                    Button { onSelect(section) } label: {
                    HStack(spacing: 6) {
                        FeatureBadge(kind: section.artwork, size: 19)
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
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            if coordinator.settings.isEnabled(.keepAwake) {
            HStack(spacing: 5) {
                FeatureBadge(kind: .keepAwake, size: 21)
                Text("Keep Alive")
                Toggle("Keep Alive", isOn: Binding(
                    get: { coordinator.keepAwake.isActive },
                    set: { coordinator.keepAwake.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                .help(coordinator.keepAwake.errorMessage ?? "Keep your Mac awake until you turn this off")
                .accessibilityIdentifier("keepAwakeToggle")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            }
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
                    Button { coordinator.handle(command) } label: {
                        KeyHint(keys: hint.keys, label: hint.label, systemImage: hint.systemImage)
                    }
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
            MacBudMark(size: 48)
            VStack(spacing: 6) {
                Text("MacBud lives in your notch")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Press **\(hotKey)** anywhere to open it. Everything is keyboard-first.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(alignment: .top, spacing: 26) {
                WelcomeStep(artwork: .clipboard, title: "Clipboard",
                            text: "Everything you copy is captured. When macOS asks, choose “Always Allow” so history keeps flowing.")
                WelcomeStep(artwork: .snippets, title: "Snippets",
                            text: "Saved text you paste often. Placeholders like {date} and {clipboard} expand when used.")
                WelcomeStep(artwork: .screenshots, title: "Screenshots",
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
    let artwork: FeatureArt
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FeatureBadge(kind: artwork, size: 25)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
