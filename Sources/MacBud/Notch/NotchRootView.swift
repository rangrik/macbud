import SwiftUI

/// Content of the expanded island window. The black silhouette animates between the notch rect and the island.
struct NotchRootView: View {
    @Bindable var state: NotchState
    let controller: NotchController
    var content: (() -> IslandContentView)?

    var body: some View {
        let m = state.metrics
        let g = state.geometry
        let expanded = state.isExpanded
        let shapeSize = expanded
            ? CGSize(width: m.islandSize.width + m.topFillet * 2, height: m.islandSize.height)
            : g.notchRect.size
        ZStack(alignment: .top) {
            NotchShape(topFillet: expanded ? m.topFillet : 0,
                       bottomRadius: expanded ? m.bottomRadius : m.collapsedBottomRadius)
                .fill(.black)
                .frame(width: shapeSize.width, height: shapeSize.height)
                .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 24, y: 10)

            Group {
                if let content { content() } else { Color.clear }
            }
                .frame(width: m.islandSize.width, height: m.islandSize.height)
                .padding(.horizontal, m.topFillet)
                .opacity(expanded ? 1 : 0)
                .scaleEffect(expanded ? 1 : 0.96, anchor: .top)
                .animation(expanded ? .easeOut(duration: 0.18).delay(0.10) : .easeIn(duration: 0.10), value: expanded)
                .allowsHitTesting(expanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }
}

/// Content of the always-on base window: the idle notch (black, or nothing on notch-less displays) and toasts.
struct NotchBaseView: View {
    @Bindable var state: NotchState
    let controller: NotchController

    var body: some View {
        let m = state.metrics
        let g = state.geometry
        let toasting = state.basePhase == .toast
        let size = toasting
            ? CGSize(width: m.toastSize.width + m.topFillet * 2, height: m.toastSize.height)
            : g.notchRect.size
        ZStack(alignment: .top) {
            NotchShape(topFillet: toasting ? m.topFillet : 0,
                       bottomRadius: toasting ? m.toastBottomRadius : m.collapsedBottomRadius)
                .fill(.black)
                .frame(width: size.width, height: size.height)
                .opacity(toasting || g.hasPhysicalNotch ? 1 : 0)
                .shadow(color: .black.opacity(toasting ? 0.35 : 0), radius: 14, y: 6)
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
