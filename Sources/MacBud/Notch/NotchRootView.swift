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
        ZStack(alignment: .top) {
            IslandSilhouette(topFillet: open ? m.topFillet : 0, bottomRadius: radius)
                .frame(width: shapeSize.width, height: shapeSize.height)

            Group {
                if let content { content() } else { Color.clear }
            }
            .frame(width: m.islandSize.width, height: m.islandSize.height)
            .padding(.horizontal, m.topFillet)
            .opacity(phase == .expanded ? 1 : 0)
            .scaleEffect(phase == .expanded ? 1 : 0.96, anchor: .top)
            .animation(phase == .expanded ? .easeOut(duration: 0.18).delay(0.10) : .easeIn(duration: 0.10), value: phase)
            .allowsHitTesting(phase == .expanded)

            if let dictation {
                dictation()
                    .frame(width: m.dictationSize.width, height: m.dictationSize.height)
                    .padding(.horizontal, m.topFillet)
                    .opacity(phase == .dictation ? 1 : 0)
                    .animation(phase == .dictation ? .easeOut(duration: 0.16).delay(0.10) : .easeIn(duration: 0.08), value: phase)
                    .allowsHitTesting(phase == .dictation)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
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
    @Bindable var state: NotchState
    let controller: NotchController

    var body: some View {
        let m = state.metrics
        let g = state.geometry
        let toasting = state.basePhase == .toast
        let tab = controller.showsTab
        let size: CGSize = toasting
            ? CGSize(width: m.toastSize.width + m.topFillet * 2, height: m.toastSize.height)
            : (tab ? CGSize(width: g.notchRect.width + m.tabExtension * 2, height: g.notchRect.height) : g.notchRect.size)
        ZStack(alignment: .top) {
            IslandSilhouette(topFillet: toasting || tab ? min(m.topFillet, 8) : 0,
                             bottomRadius: toasting ? m.toastBottomRadius : m.collapsedBottomRadius)
                .frame(width: size.width, height: size.height)
                .opacity(toasting || g.hasPhysicalNotch ? 1 : 0)

            if tab, !toasting {
                NotchTabContent(state: state, notchWidth: g.notchRect.width, wing: m.tabExtension, height: g.notchRect.height)
                    .frame(width: size.width, height: size.height)
            }

            if let toast = state.toast {
                ToastContentView(toast: toast)
                    .frame(width: m.toastSize.width, height: m.toastSize.height - g.notchRect.height)
                    .padding(.top, g.notchRect.height)
                    .opacity(toasting ? 1 : 0)
                    .animation(toasting ? .easeOut(duration: 0.16).delay(0.08) : .easeIn(duration: 0.1), value: toasting)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }
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
            Image(systemName: "rectangle.topthird.inset.filled")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.62))
                .frame(width: wing, height: height)
            Spacer().frame(width: notchWidth)
            Image(systemName: state.notchStatusSymbol ?? "chevron.down")
                .font(.system(size: state.notchStatusSymbol == nil ? 9 : 10, weight: .bold))
                .foregroundStyle(state.notchStatusSymbol == nil ? .white.opacity(hovered ? 0.95 : 0.42) : Theme.warning)
                .frame(width: wing, height: height)
        }
        .scaleEffect(hovered ? 1.06 : 1, anchor: .top)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .accessibilityLabel("MacBud")
        .accessibilityHint("Click to open MacBud")
    }
}

struct ToastContentView: View {
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
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
