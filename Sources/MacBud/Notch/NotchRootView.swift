import SwiftUI

/// Content of the expanded island window. The black silhouette animates between the notch rect, the
/// dictation pill and the full island. Pure black with no shadow or edge, so it reads as part of the notch.
struct NotchRootView: View {
    @Bindable var state: NotchState
    let controller: NotchController
    var content: (() -> IslandContentView)?
    var dictation: (() -> AnyView)?

    var body: some View {
        let m = state.metrics
        let g = state.geometry
        let phase = state.phase
        let shapeSize: CGSize = switch phase {
        case .expanded: CGSize(width: m.islandSize.width + m.topFillet * 2, height: m.islandSize.height)
        case .dictation: CGSize(width: m.dictationSize.width + m.topFillet * 2, height: m.dictationSize.height)
        case .collapsed: g.notchRect.size
        }
        let radius: CGFloat = switch phase {
        case .expanded: m.bottomRadius
        case .dictation: m.dictationBottomRadius
        case .collapsed: m.collapsedBottomRadius
        }
        let open = phase != .collapsed
        let canvas = state.panelUsesDictationSize ? m.dictationSize : m.islandSize
        // An invisible expanded view must not determine the smaller dictation window's layout width.
        Color.clear.overlay(alignment: .top) {
            NotchSurface(size: shapeSize, canvasSize: CGSize(width: canvas.width + m.topFillet * 2, height: canvas.height),
                         topFillet: open ? m.topFillet : 0, bottomRadius: radius) {
                if phase == .expanded, let content {
                    content()
                        .frame(width: m.islandSize.width, height: m.islandSize.height)
                        .padding(.horizontal, m.topFillet)
                        .transition(.opacity)
                }
                if phase == .dictation, let dictation {
                    dictation()
                        .frame(width: m.dictationSize.width, height: m.dictationSize.height)
                        .padding(.horizontal, m.topFillet)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: canvas.width + m.topFillet * 2, height: canvas.height, alignment: .top)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }
}

/// The background and controls share one surface throughout expansion and collapse.
struct NotchSurface<Content: View>: View {
    let size: CGSize
    let canvasSize: CGSize
    let topFillet: CGFloat
    let bottomRadius: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        Color.black
            .overlay(alignment: .top) { content() }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .mask(alignment: .top) {
                NotchShape(topFillet: topFillet, bottomRadius: bottomRadius)
                    .frame(width: size.width, height: size.height)
            }
    }
}

/// Pure black, like the notch itself: no shadow and no edge stroke, so the island reads as
/// the notch growing rather than a window floating in front of it.
struct IslandSilhouette: View {
    var topFillet: CGFloat
    var bottomRadius: CGFloat

    var body: some View {
        NotchShape(topFillet: topFillet, bottomRadius: bottomRadius)
            .fill(.black)
    }
}

/// Content of the always-on base window: the idle notch (widened into a clickable tab with an icon on a
/// real notch; nothing on notch-less displays) and action toasts.
struct NotchBaseView: View {
    @Bindable var screen: ScreenNotch
    @Bindable var state: NotchState
    let controller: NotchController

    var body: some View {
        let m = state.metrics
        let g = screen.geometry
        let toasting = screen.isActive && state.basePhase == .toast
        let tab = controller.showsTab
        let hovered = tab && !toasting && state.tabHovered
        let toastSize = m.toastSize(withAction: state.toast?.action != nil)
        let size: CGSize = toasting
            ? CGSize(width: toastSize.width + m.topFillet * 2, height: toastSize.height)
            : (tab ? m.tabSize(for: g, hovered: hovered) : g.notchRect.size)
        ZStack(alignment: .top) {
            IslandSilhouette(topFillet: toasting || tab ? min(m.topFillet, 8) : 0,
                             bottomRadius: toasting ? m.toastBottomRadius : m.collapsedBottomRadius)
                .frame(width: size.width, height: size.height)
                .opacity(toasting || tab || g.hasPhysicalNotch ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: hovered)

            if tab, !toasting {
                NotchTabContent(state: state, notchWidth: g.notchRect.width,
                                wing: m.tabExtension + (hovered ? m.tabHoverGrowth.width : 0), height: size.height)
                    .frame(width: size.width, height: size.height)
                    .animation(.easeOut(duration: 0.18), value: hovered)
            }

            if let toast = state.toast {
                ToastContentView(state: state, toast: toast)
                    .frame(width: toastSize.width, height: toastSize.height - g.notchRect.height)
                    .padding(.top, g.notchRect.height)
                    .opacity(toasting ? 1 : 0)
                    .animation(toasting ? .easeOut(duration: 0.16).delay(0.08) : .easeIn(duration: 0.1), value: toasting)
            }
        }
        .frame(width: screen.canvasSize.width, height: screen.canvasSize.height, alignment: .top)
        .coordinateSpace(.named(NotchBaseView.space))
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }

    /// Toast clicks are hit-tested in AppKit, so the button reports its frame in this space.
    nonisolated static let space = "notchBase"
}

/// The wings beside the notch. Hover and click are handled by `ClickableHostingView` in AppKit
/// (the base window can never become key, so SwiftUI gestures never received the first click).
struct NotchTabContent: View {
    @Bindable var state: NotchState
    let notchWidth: CGFloat
    let wing: CGFloat
    let height: CGFloat

    var body: some View {
        let hovered = state.tabHovered
        HStack(spacing: 0) {
            leftWing(hovered: hovered).frame(width: wing, height: height)
            Spacer().frame(width: notchWidth)
            rightWing(hovered: hovered).frame(width: wing, height: height)
        }
        .animation(.easeOut(duration: 0.18), value: hovered)
        .accessibilityLabel(state.keepsAwake ? "MacBud · Keep Awake is on" : "MacBud")
        .accessibilityHint("Click to open MacBud")
    }

    /// With the clock on, the logo moves across to sit beside Keep Awake at the outer edge.
    @ViewBuilder private func leftWing(hovered: Bool) -> some View {
        if let clock = state.clockText {
            Text(clock)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.78))
                .accessibilityLabel("Time \(clock)")
        } else {
            MacBudMark(size: hovered ? 19 : 17)
        }
    }

    @ViewBuilder private func rightWing(hovered: Bool) -> some View {
        if state.clockText != nil {
            HStack(spacing: 6) {
                if let symbol = statusSymbol { statusGlyph(symbol) }
                MacBudMark(size: hovered ? 19 : 17)
            }
        } else {
            statusGlyph(statusSymbol ?? "chevron.down", idle: statusSymbol == nil, hovered: hovered)
        }
    }

    private var statusSymbol: String? {
        state.keepsAwake ? "sun.max.fill" : state.notchStatusSymbol
    }

    private func statusGlyph(_ symbol: String, idle: Bool = false, hovered: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: idle ? 9 : 10, weight: .bold))
            .foregroundStyle(state.keepsAwake ? .orange : (idle ? .white.opacity(hovered ? 0.95 : 0.42) : Theme.warning))
    }
}

struct ToastContentView: View {
    @Bindable var state: NotchState
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(toast.tint)
                .symbolEffect(.bounce, options: .nonRepeating)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                if let subtitle = toast.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            if let action = toast.action {
                Spacer(minLength: 10)
                ToastActionButton(action: action, hovered: state.toastActionHovered)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(NotchBaseView.space)) }
                        action: { state.toastActionRect = $0 }
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: toast.action == nil ? .center : .leading)
    }
}

/// Looks like a button but is not one: the base window never becomes key, so
/// `ClickableHostingView` matches the click against the frame reported above.
struct ToastActionButton: View {
    let action: ToastAction
    let hovered: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: action.symbol).font(.system(size: 11, weight: .semibold))
            Text(action.title).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(hovered ? 1 : 0.85))
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(.white.opacity(hovered ? 0.24 : 0.14), in: .capsule)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityLabel(action.title)
    }
}
