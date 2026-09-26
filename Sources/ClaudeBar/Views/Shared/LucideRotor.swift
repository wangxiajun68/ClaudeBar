import SwiftUI

/// Illustrated turbine, animated by the render server without per-frame layout.
struct LucideRotor: View {
    var rpm: Int
    var maxRPM: Int
    var tint: Color
    /// True when the fan is being held at a speed the system did not ask for.
    var forced: Bool
    var size: CGFloat = 48
    var showsHousing = true
    var artwork: CGImage? = FanArtwork.leftRotor

    @State private var mounted = false
    @Environment(\.surfaceIsVisible) private var windowVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Below ~80 rpm a rotor's blades are not moving in any way a person would
    /// see; stopping there keeps an idle machine's chrome perfectly still.
    private var spinning: Bool { mounted && windowVisible && rpm >= 80 && !reduceMotion }

    /// Degrees per second, 12 at the floor of the visible range and 58 at rated
    /// max — about 30 s to 6 s per turn. Linear in `rpm / maxRPM` because the
    /// reading above the rotor is the RPM itself, and a second, differently
    /// curved mapping would make the picture disagree with the number.
    private var degreesPerSecond: Double {
        guard spinning else { return 0 }
        let load = min(1, Double(rpm) / Double(max(maxRPM, 1)))
        return 12 + load * 46
    }

    var body: some View {
        ZStack {
            if showsHousing {
            Circle()
                .fill(LinearGradient(colors: [Color.primary.opacity(0.04), Color.primary.opacity(0.10)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
            Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 2)
                .padding(size * 0.10)
            Circle()
                .trim(from: 0, to: min(1, max(0, Double(rpm) / Double(max(maxRPM, 1)))))
                .stroke(tint.opacity(forced ? 0.95 : 0.65), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(size * 0.10)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: rpm)
            }
            RotorLayer(tint: NSColor(tint), degreesPerSecond: degreesPerSecond, artwork: artwork)
                .frame(width: size * (showsHousing ? 0.74 : 1), height: size * (showsHousing ? 0.74 : 1))
        }
        .frame(width: size, height: size)
        .onAppear { mounted = true }
        .onDisappear { mounted = false }
        .accessibilityHidden(true)
    }
}

// MARK: - The layer

private struct RotorLayer: NSViewRepresentable {
    let tint: NSColor
    let degreesPerSecond: Double
    let artwork: CGImage?

    func makeNSView(context: Context) -> RotorLayerView { RotorLayerView() }

    func updateNSView(_ view: RotorLayerView, context: Context) {
        view.apply(tint: tint, degreesPerSecond: degreesPerSecond, artwork: artwork)
    }
}

final class RotorLayerView: NSView {
    private let rotor = CALayer()
    private var symbolTint: NSColor?
    private var currentArtwork: CGImage?
    private static let spinKey = "spin"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        rotor.speed = 0
        rotor.contentsGravity = .resizeAspect
        layer?.addSublayer(rotor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotor.bounds = CGRect(origin: .zero, size: bounds.size)
        rotor.position = CGPoint(x: bounds.midX, y: bounds.midY)
        rotor.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        rotor.contentsScale = scale
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ensureAnimation()
    }

    func apply(tint: NSColor, degreesPerSecond: Double, artwork: CGImage? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let artwork {
            if currentArtwork !== artwork {
                currentArtwork = artwork
                rotor.contents = artwork
                rotor.cornerRadius = min(bounds.width, bounds.height) / 2
                rotor.masksToBounds = true
            }
        } else if symbolTint != tint || currentArtwork != nil {
            currentArtwork = nil
            symbolTint = tint
            let configuration = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
                .applying(.init(paletteColors: [tint]))
            let image = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            rotor.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        CATransaction.commit()
        ensureAnimation()
        setSpeed(Float(degreesPerSecond / 360))
    }

    /// One turn per second of layer time; `speed` scales it to the RPM.
    private func ensureAnimation() {
        guard rotor.animation(forKey: Self.spinKey) == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 1
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        rotor.add(spin, forKey: Self.spinKey)
    }

    /// Retimes the layer without a jump: freeze the current local time into
    /// `timeOffset`, restart the clock now, then apply the new rate.
    private func setSpeed(_ speed: Float) {
        guard rotor.speed != speed else { return }
        let now = CACurrentMediaTime()
        let local = rotor.convertTime(now, from: nil)
        rotor.timeOffset = local
        rotor.beginTime = now
        rotor.speed = speed
    }
}


/// One decoded illustration and two circular blade crops, shared by every surface.
/// Coordinates are measured in the bundled 1536 × 1024 artwork, not host hardware.
enum FanArtwork {
    static let image: NSImage? = Bundle.main.url(forResource: "macbook-internals-illustration", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
    private static let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    static let leftRotor = crop(centerX: 300, centerY: 315)
    static let rightRotor = crop(centerX: 1237, centerY: 315)
    private static func crop(centerX: CGFloat, centerY: CGFloat) -> CGImage? {
        guard let cgImage else { return nil }
        let scale = CGFloat(cgImage.width) / 1536
        return cgImage.cropping(to: CGRect(x: (centerX - 108) * scale,
                                          y: (centerY - 108) * scale,
                                          width: 216 * scale, height: 216 * scale))
    }
}
