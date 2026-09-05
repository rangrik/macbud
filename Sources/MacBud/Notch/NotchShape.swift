import SwiftUI

/// The island silhouette: flat top flush with the screen edge, concave fillets at the top corners
/// (so it appears to grow out of the bezel like the real notch), rounded bottom corners.
struct NotchShape: Shape {
    var topFillet: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topFillet, bottomRadius) }
        set { topFillet = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let f = max(0, min(topFillet, rect.width / 4, rect.height / 2))
        let bodyMinX = rect.minX + f
        let bodyMaxX = rect.maxX - f
        let r = max(0, min(bottomRadius, (bodyMaxX - bodyMinX) / 2, rect.height - f))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        if f > 0 {
            p.addQuadCurve(to: CGPoint(x: bodyMinX, y: rect.minY + f),
                           control: CGPoint(x: bodyMinX, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: bodyMinX, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: bodyMinX, y: rect.maxY),
                 tangent2End: CGPoint(x: bodyMinX + r, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: bodyMaxX - r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: bodyMaxX, y: rect.maxY),
                 tangent2End: CGPoint(x: bodyMaxX, y: rect.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY + f))
        if f > 0 {
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                           control: CGPoint(x: bodyMaxX, y: rect.minY))
        }
        p.closeSubpath()
        return p
    }
}
