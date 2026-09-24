import SwiftUI

/// The island silhouette: a full-width top edge that flares into the body
/// through two concave quarter-curves, then a rounded bottom. With
/// `topFlare = r`, the body is `width - 2r` wide — the collapsed island sets
/// its width to `notch + 2r` so the body lines up with the hardware notch.
///
/// The path is left open along the top edge: fills close it implicitly, and
/// a stroke (rim light, finish glint) never draws against the screen edge.
struct IslandShape: Shape {
    var topFlare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topFlare, bottomRadius) }
        set { topFlare = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let flare = min(topFlare, rect.width / 4, rect.height / 2)
        let radius = min(bottomRadius, (rect.width - 2 * flare) / 2, rect.height - flare)
        let left = rect.minX + flare
        let right = rect.maxX - flare

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + flare),
                          control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: rect.maxY),
                          control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - radius),
                          control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + flare))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: right, y: rect.minY))
        return path
    }
}
