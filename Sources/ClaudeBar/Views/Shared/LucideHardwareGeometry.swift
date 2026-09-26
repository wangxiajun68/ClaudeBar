import SwiftUI

/// **Generated file — do not hand-edit.**
///
/// Lucide's own geometry for the four machine marks, converted from the
/// upstream SVGs by `Tools/gen-lucide-hardware.py`; run that script to
/// regenerate.
///
/// These are real icon-system drawings (24pt grid, 2pt stroke, round caps and
/// joins) rather than shapes invented in this file. The previous version of
/// `HardwareIllustration` hand-authored its silhouettes on a Canvas and produced
/// marks that were recognisable-ish and plainly amateur; using the upstream
/// geometry is what makes them read as designed.
///
/// ISC licensed — Lucide Icons and Contributors. `Sources/Licenses/Lucide.txt`
/// is copied into the bundle by `Sources/build.sh`.
enum LucideHardwareGeometry {
    /// Every mark is authored on Lucide's 24-point grid.
    static let grid: CGFloat = 24

    /// The outline of one hardware mark, in Lucide's coordinate space.
    static func path(for kind: Kind) -> Path {
        var p = Path()
        switch kind {
        /// Lucide `cpu`.
        case .cpu:
            p.move(to: CGPoint(x: 12, y: 20))
            p.addLine(to: CGPoint(x: 12, y: 22))
            p.move(to: CGPoint(x: 12, y: 2))
            p.addLine(to: CGPoint(x: 12, y: 4))
            p.move(to: CGPoint(x: 17, y: 20))
            p.addLine(to: CGPoint(x: 17, y: 22))
            p.move(to: CGPoint(x: 17, y: 2))
            p.addLine(to: CGPoint(x: 17, y: 4))
            p.move(to: CGPoint(x: 2, y: 12))
            p.addLine(to: CGPoint(x: 4, y: 12))
            p.move(to: CGPoint(x: 2, y: 17))
            p.addLine(to: CGPoint(x: 4, y: 17))
            p.move(to: CGPoint(x: 2, y: 7))
            p.addLine(to: CGPoint(x: 4, y: 7))
            p.move(to: CGPoint(x: 20, y: 12))
            p.addLine(to: CGPoint(x: 22, y: 12))
            p.move(to: CGPoint(x: 20, y: 17))
            p.addLine(to: CGPoint(x: 22, y: 17))
            p.move(to: CGPoint(x: 20, y: 7))
            p.addLine(to: CGPoint(x: 22, y: 7))
            p.move(to: CGPoint(x: 7, y: 20))
            p.addLine(to: CGPoint(x: 7, y: 22))
            p.move(to: CGPoint(x: 7, y: 2))
            p.addLine(to: CGPoint(x: 7, y: 4))
            p.addRoundedRect(in: CGRect(x: 4, y: 4, width: 16, height: 16), cornerSize: CGSize(width: 2, height: 2))
            p.addRoundedRect(in: CGRect(x: 8, y: 8, width: 8, height: 8), cornerSize: CGSize(width: 1, height: 1))
        /// Lucide `gpu`.
        case .gpu:
            p.move(to: CGPoint(x: 2, y: 17))
            p.addLine(to: CGPoint(x: 20, y: 17))
            p.addCurve(to: CGPoint(x: 22, y: 15), control1: CGPoint(x: 21.1046, y: 17), control2: CGPoint(x: 22, y: 16.1046))
            p.addLine(to: CGPoint(x: 22, y: 7))
            p.addCurve(to: CGPoint(x: 20, y: 5), control1: CGPoint(x: 22, y: 5.8954), control2: CGPoint(x: 21.1046, y: 5))
            p.addLine(to: CGPoint(x: 2, y: 5))
            p.move(to: CGPoint(x: 2, y: 21))
            p.addLine(to: CGPoint(x: 2, y: 3))
            p.move(to: CGPoint(x: 7, y: 17))
            p.addLine(to: CGPoint(x: 7, y: 20))
            p.addCurve(to: CGPoint(x: 8, y: 21), control1: CGPoint(x: 7, y: 20.5523), control2: CGPoint(x: 7.4477, y: 21))
            p.addLine(to: CGPoint(x: 13, y: 21))
            p.addCurve(to: CGPoint(x: 14, y: 20), control1: CGPoint(x: 13.5523, y: 21), control2: CGPoint(x: 14, y: 20.5523))
            p.addLine(to: CGPoint(x: 14, y: 17))
            p.addEllipse(in: CGRect(x: 14, y: 9, width: 4, height: 4))
            p.addEllipse(in: CGRect(x: 6, y: 9, width: 4, height: 4))
        /// Lucide `memory-stick`.
        case .memory:
            p.move(to: CGPoint(x: 12, y: 12))
            p.addLine(to: CGPoint(x: 12, y: 10))
            p.move(to: CGPoint(x: 12, y: 18))
            p.addLine(to: CGPoint(x: 12, y: 16))
            p.move(to: CGPoint(x: 16, y: 12))
            p.addLine(to: CGPoint(x: 16, y: 10))
            p.move(to: CGPoint(x: 16, y: 18))
            p.addLine(to: CGPoint(x: 16, y: 16))
            p.move(to: CGPoint(x: 2, y: 11))
            p.addLine(to: CGPoint(x: 3.5, y: 11))
            p.move(to: CGPoint(x: 20, y: 18))
            p.addLine(to: CGPoint(x: 20, y: 16))
            p.move(to: CGPoint(x: 20.5, y: 11))
            p.addLine(to: CGPoint(x: 22, y: 11))
            p.move(to: CGPoint(x: 4, y: 18))
            p.addLine(to: CGPoint(x: 4, y: 16))
            p.move(to: CGPoint(x: 8, y: 12))
            p.addLine(to: CGPoint(x: 8, y: 10))
            p.move(to: CGPoint(x: 8, y: 18))
            p.addLine(to: CGPoint(x: 8, y: 16))
            p.addRoundedRect(in: CGRect(x: 2, y: 6, width: 20, height: 10), cornerSize: CGSize(width: 2, height: 2))
        /// Lucide `hard-drive`.
        case .disk:
            p.move(to: CGPoint(x: 10, y: 16))
            p.addLine(to: CGPoint(x: 10.01, y: 16))
            p.move(to: CGPoint(x: 2.212, y: 11.577))
            p.addCurve(to: CGPoint(x: 2, y: 12.473), control1: CGPoint(x: 2.0726, y: 11.8551), control2: CGPoint(x: 2, y: 12.1619))
            p.addLine(to: CGPoint(x: 2, y: 18))
            p.addCurve(to: CGPoint(x: 4, y: 20), control1: CGPoint(x: 2, y: 19.1046), control2: CGPoint(x: 2.8954, y: 20))
            p.addLine(to: CGPoint(x: 20, y: 20))
            p.addCurve(to: CGPoint(x: 22, y: 18), control1: CGPoint(x: 21.1046, y: 20), control2: CGPoint(x: 22, y: 19.1046))
            p.addLine(to: CGPoint(x: 22, y: 12.473))
            p.addCurve(to: CGPoint(x: 21.788, y: 11.577), control1: CGPoint(x: 22, y: 12.1619), control2: CGPoint(x: 21.9274, y: 11.8551))
            p.addLine(to: CGPoint(x: 18.55, y: 5.11))
            p.addCurve(to: CGPoint(x: 16.76, y: 4), control1: CGPoint(x: 18.2123, y: 4.4303), control2: CGPoint(x: 17.5189, y: 4.0004))
            p.addLine(to: CGPoint(x: 7.24, y: 4))
            p.addCurve(to: CGPoint(x: 5.45, y: 5.11), control1: CGPoint(x: 6.4811, y: 4.0004), control2: CGPoint(x: 5.7877, y: 4.4303))
            p.closeSubpath()
            p.move(to: CGPoint(x: 21.946, y: 12.013))
            p.addLine(to: CGPoint(x: 2.054, y: 12.013))
            p.move(to: CGPoint(x: 6, y: 16))
            p.addLine(to: CGPoint(x: 6.01, y: 16))
        }
        return p
    }

    enum Kind { case cpu, gpu, memory, disk }
}
