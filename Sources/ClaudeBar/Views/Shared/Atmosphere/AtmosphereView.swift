import MetalKit
import SwiftUI

/// Relays SwiftUI-side events (taps, entrance policy) to the Metal view of one
/// card. A plain reference, not observable: nothing it holds should re-render
/// SwiftUI.
@MainActor final class AtmosphereController {
    fileprivate weak var view: AtmosphereMTKView?
    /// The full write-on plays once per half hour; switching pages and back
    /// inside that window shows the finished greeting at once.
    private static var lastEntrance = Date.distantPast

    fileprivate func attach(_ view: AtmosphereMTKView) {
        self.view = view
        if Date().timeIntervalSince(Self.lastEntrance) < 1800 {
            view.renderer.skipEntrance()
        } else {
            Self.lastEntrance = Date()
            view.renderer.replayEntrance()
            view.boostWhileWriting()
        }
    }

    func ripple(at point: CGPoint) {
        view?.renderer.ripple(at: point)
        view?.kick()
    }

    /// Writes the greeting again, pen and all.
    func rewrite() {
        view?.renderer.rewrite()
        view?.boostWhileWriting()
    }
}

/// The card's sky: a live `MTKView`, or a still for Reduce Motion and for
/// tools that capture with `ImageRenderer` (which cannot see AppKit views).
struct AtmosphereSurface: View {
    var input: AtmosphereRenderer.Input
    var controller: AtmosphereController
    var active: Bool

    /// Preview tools set this so the capture draws the same shader as a still.
    @MainActor static var stills = false

    var body: some View {
        if input.reduceMotion || Self.stills {
            AtmosphereStill(input: input)
        } else {
            AtmosphereMetal(input: input, controller: controller, active: active)
        }
    }
}

private struct AtmosphereMetal: NSViewRepresentable {
    var input: AtmosphereRenderer.Input
    var controller: AtmosphereController
    var active: Bool

    func makeNSView(context: Context) -> AtmosphereMTKView {
        let view = AtmosphereMTKView(gpu: AtmosphereGPU.shared!)
        view.renderer.input = input
        controller.attach(view)
        view.setActive(active)
        return view
    }

    func updateNSView(_ view: AtmosphereMTKView, context: Context) {
        if view.renderer.input != input {
            let weatherChanged = view.renderer.input.map { $0.scene.weather != input.scene.weather } ?? false
            view.renderer.input = input
            // The cross-fade is motion too; the rate also has to be re-chosen
            // afterwards, since the new weather may want 60 Hz or only 30.
            if weatherChanged { view.boost(for: AtmosphereRenderer.weatherFade) }
        }
        view.setActive(active)
    }

    static func dismantleNSView(_ view: AtmosphereMTKView, coordinator: ()) {
        view.setActive(false)
    }
}

/// Draws itself; tracks the pointer with its own tracking area so parallax and
/// wiping drops never invalidate the SwiftUI graph.
final class AtmosphereMTKView: MTKView, MTKViewDelegate {
    let renderer: AtmosphereRenderer
    private var tracking: NSTrackingArea?
    private var active = false
    private var pointerInside = false
    private var boostedUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []

    init(gpu: AtmosphereGPU) {
        renderer = AtmosphereRenderer(gpu: gpu)
        super.init(frame: .zero, device: gpu.device)
        colorPixelFormat = AtmosphereGPU.pixelFormat
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        framebufferOnly = true
        autoResizeDrawable = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        layer?.isOpaque = true
        delegate = self
        isPaused = true
        enableSetNeedsDisplay = true
        renderer.textDidChange = { [weak self] in
            guard let self else { return }
            if renderer.writing { boostWhileWriting() } else { kick() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retime() }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retime() }
        })
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { (observers + windowObservers).forEach(NotificationCenter.default.removeObserver) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        if let window {
            // Occlusion pauses the view; a new screen may have another refresh rate.
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window,
                                                                              queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.retime() }
                })
            }
        }
        retime()
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { retime(); return }
        self.active = active
        retime()
    }

    /// 60 Hz while the pen is moving: a line written at 30 Hz visibly steps.
    func boostWhileWriting() {
        guard let duration = renderer.input?.layout?.writeDuration else { return }
        boost(for: duration + 0.6)
    }

    /// Full rate for `seconds`, then back to whatever the scene warrants.
    func boost(for seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        if until > boostedUntil { boostedUntil = until }
        retime()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.1) { [weak self] in self?.retime() }
    }

    /// One redraw while paused (a ripple, an input change under a paused view).
    func kick() {
        if isPaused { needsDisplay = true }
    }

    /// Frame rate is the cheapest rate that still reads as motion. Anything
    /// the hand is driving — the pen writing, a weather fade, the pointer
    /// steering parallax, a drag through the day — runs at the display's
    /// full rate (120 Hz on ProMotion), because that is where a step is felt.
    /// Unattended precipitation gets 60 Hz, drifting cloud 30 Hz, and Low
    /// Power Mode or thermal pressure 30 / 15 Hz. A frame costs well under a
    /// millisecond of GPU time on Apple silicon (`Tools/bench-atmosphere.py`).
    /// Hidden, occluded or inactive surfaces do not draw at all.
    private func retime() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let running = active && visible && renderer.input?.reduceMotion == false
        if running {
            let info = ProcessInfo.processInfo
            let constrained = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
            let boosted = boostedUntil > Date()
            let display = max(60, window?.screen?.maximumFramesPerSecond ?? 60)
            let rate = constrained ? (boosted ? 30 : 15)
                : boosted || pointerInside ? display
                : renderer.wantsHighRate ? 60 : 30
            if preferredFramesPerSecond != rate { preferredFramesPerSecond = rate }
            enableSetNeedsDisplay = false
            isPaused = false
        } else {
            isPaused = true
            enableSetNeedsDisplay = true
            needsDisplay = true
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        retime()
        updatePointer(event)
    }

    override func mouseMoved(with event: NSEvent) { updatePointer(event) }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        renderer.pointer = nil
        renderer.pointerNormalized = .zero
        retime()
    }

    private func updatePointer(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        renderer.pointer = point
        renderer.pointerNormalized = CGPoint(x: point.x / max(1, bounds.width) - 0.5,
                                             y: point.y / max(1, bounds.height) - 0.5)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { kick() }

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let commandBuffer = renderer.gpu.queue.makeCommandBuffer() else { return }
        let scale = window?.backingScaleFactor ?? 2
        renderer.encode(pass: pass, commandBuffer: commandBuffer, pixelSize: drawableSize, scale: scale)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// The shader drawn once into an image. Re-rendered only when the input, size
/// or scale changes (a minute tick, a weather refresh), so a still sky costs
/// nothing between those.
private struct AtmosphereStill: View {
    var input: AtmosphereRenderer.Input
    @Environment(\.displayScale) private var scale
    @State private var cache = StillCache()

    var body: some View {
        GeometryReader { geo in
            if let image = cache.image(input: input, size: geo.size, scale: scale) {
                Image(decorative: image, scale: scale).resizable()
            } else {
                Color(red: Double(input.scene.mid.x), green: Double(input.scene.mid.y), blue: Double(input.scene.mid.z))
            }
        }
    }
}

@MainActor private final class StillCache {
    private var key: (AtmosphereRenderer.Input, CGSize, CGFloat)?
    private var image: CGImage?
    private var renderer: AtmosphereRenderer?

    func image(input: AtmosphereRenderer.Input, size: CGSize, scale: CGFloat) -> CGImage? {
        if let key, key.0 == input, key.1 == size, key.2 == scale { return image }
        guard size.width > 1, size.height > 1, let gpu = AtmosphereGPU.shared else { return nil }
        let renderer = self.renderer ?? AtmosphereRenderer(gpu: gpu)
        self.renderer = renderer
        renderer.input = input
        image = renderer.snapshot(size: size, scale: scale)
        key = (input, size, scale)
        return image
    }
}
