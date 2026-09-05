import SwiftUI

/// Content of the expanded island window. The black silhouette animates between the notch rect, the
/// dictation pill and the full island. No drop shadow: a hairline edge keeps it crisp on any wallpaper.
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
            IslandSilhouette(topFillet: open ? m.topFillet : 0, bottomRadius: radius, edge: open)
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

/// Black notch silhouette with an optional hairline edge (never drawn along the screen edge).
struct IslandSilhouette: View {
    var topFillet: CGFloat
    var bottomRadius: CGFloat
    var edge: Bool

    var body: some View {
        NotchShape(topFillet: topFillet, bottomRadius: bottomRadius)
            .fill(.black)
            .overlay {
                NotchShape(topFillet: topFillet, bottomRadius: bottomRadius)
                    .stroke(.white.opacity(edge ? 0.14 : 0), lineWidth: 1)
                    .mask(Rectangle().padding(.top, 2))
            }
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
                             bottomRadius: toasting ? m.toastBottomRadius : m.collapsedBottomRadius,
                             edge: toasting)
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
        .contentShape(Rectangle())
        .onHover { state.tabHovered = $0 }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }
}

/// The two small wings beside the physical notch: app glyph on the left, status / chevron on the right.
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
                .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.6))
                .frame(width: wing, height: height)
            Spacer().frame(width: notchWidth)
            Image(systemName: state.notchStatusSymbol ?? "chevron.down")
                .font(.system(size: state.notchStatusSymbol == nil ? 9 : 10, weight: .bold))
                .foregroundStyle(state.notchStatusSymbol == nil ? .white.opacity(hovered ? 0.9 : 0.4) : Theme.warning)
                .frame(width: wing, height: height)
        }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .help("Open MacBud")
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
