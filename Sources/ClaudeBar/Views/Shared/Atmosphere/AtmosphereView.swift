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
            AtmosphereStill(input: input, active: active, synchronous: Self.stills)
        } else {
            AtmosphereMetal(input: input, controller: controller, active: active)
        }
    }
}

/// The hosting page's scroll state, for the live skies on it.
///
/// While the page moves (tracking, decelerating, animating) or once the card
/// has scrolled out of the viewport, a sky holds the frame it has: the
/// compositor then translates a still layer instead of blending — and
/// re-blurring the glass sill over — a new frame on every scroll step.
///
/// A reference handed down once, not an environment flag: the state changes
/// at the start and end of every scroll, and routing that through SwiftUI
/// would re-evaluate the page (and the card's closures) at exactly the moment
/// the scroll needs the main thread.
@MainActor final class PageScrollActivity {
    var moving = false { didSet { if moving != oldValue { update() } } }
    var onScreen = true { didSet { if onScreen != oldValue { update() } } }
    private let views = NSHashTable<AtmosphereMTKView>.weakObjects()

    fileprivate func attach(_ view: AtmosphereMTKView) {
        views.add(view)
        view.setHeld(moving || !onScreen)
    }

    private func update() {
        for view in views.allObjects { view.setHeld(moving || !onScreen) }
    }
}

private struct PageScrollActivityKey: EnvironmentKey {
    static let defaultValue: PageScrollActivity? = nil
}

extension EnvironmentValues {
    var pageScrollActivity: PageScrollActivity? {
        get { self[PageScrollActivityKey.self] }
        set { self[PageScrollActivityKey.self] = newValue }
    }
}

private struct AtmosphereMetal: NSViewRepresentable {
    var input: AtmosphereRenderer.Input
    var controller: AtmosphereController
    var active: Bool
    @Environment(\.pageScrollActivity) private var scrollActivity

    func makeNSView(context: Context) -> AtmosphereMTKView {
        let view = AtmosphereMTKView(gpu: AtmosphereGPU.shared!)
        view.renderer.input = input
        controller.attach(view)
        scrollActivity?.attach(view)
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
        scrollActivity?.attach(view)
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
    /// Held on its last frame while the page scrolls.
    private var held = false
    private var pointerInside = false
    /// Frames acquired and not yet presented, and when the last was acquired.
    /// `currentDrawable` blocks the main thread (up to a second) when every
    /// drawable is taken — which is exactly when the compositor is behind, in
    /// a scroll. With one on screen and at most one pending, a third is always
    /// free, so a frame is skipped instead.
    private var pending = 0
    private var lastAcquired: CFTimeInterval = 0
    private var boostedUntil = Date.distantPast
    /// The pointer moved inside the card recently, so the parallax is still
    /// travelling. It eases toward its target with a time constant of ~140 ms,
    /// so once the pointer has rested for `pointerSettle` it has arrived and
    /// the view falls back to the resting rate instead of presenting an
    /// unchanged frame at 60 Hz for as long as the pointer stays there.
    private var pointerActiveUntil = Date.distantPast
    private static let pointerSettle: TimeInterval = 0.8
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

    func setHeld(_ held: Bool) {
        guard self.held != held else { return }
        self.held = held
        retime()
    }

    /// The display rate while the pen is moving: a line written at the resting
    /// rate visibly steps.
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
        if drawingAllowed && isPaused { needsDisplay = true }
    }

    /// Also checked at draw time: AppKit can deliver a queued redraw after a
    /// scroll hold, occlusion or dismantle has paused the display link.
    private var drawingAllowed: Bool {
        active && !held && window?.occlusionState.contains(.visible) == true
            && renderer.input?.reduceMotion == false
    }

    /// The resting card presents at `AtmosphereRenderer.restingRate` (30 Hz for
    /// falling weather, 15 Hz for a calm sky). Rain and snow are a plate being
    /// scrolled, and a scrolled plate is continuous at 30 Hz the way a blurred
    /// film frame is; pushing precipitation to the display rate was redrawing
    /// the pane (and the glass sill over it) for motion the plate already
    /// contains. The display rate is for the hand: the pen, a weather fade,
    /// parallax, a drag through the day. The cloud deck has its own slower
    /// clock inside the renderer. Low Power Mode or thermal pressure is 30 Hz
    /// while the hand is down and 15 Hz otherwise. Hidden, occluded or inactive
    /// surfaces do not draw; a scrolling page holds the frame on screen.
    private func retime() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let running = active && visible && renderer.input?.reduceMotion == false
        if running && held {
            isPaused = true
            enableSetNeedsDisplay = true
        } else if running {
            let info = ProcessInfo.processInfo
            let constrained = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
            let now = Date()
            let boosted = boostedUntil > now
            // The pen and a weather fade own the display rate. The pointer
            // only needs 60 Hz — the parallax is a smoothed offset, and 60
            // samples a second of an exponential ease read as continuous —
            // and only while it is moving and the window can actually take it.
            let hand = pointerInside && pointerActiveUntil > now && window?.isKeyWindow == true
            let display = max(60, window?.screen?.maximumFramesPerSecond ?? 60)
            let resting = renderer.restingRate
            let rate = constrained ? (boosted ? 30 : min(resting, 15))
                : boosted ? display
                : hand ? min(display, 60)
                : resting
            if preferredFramesPerSecond != rate { preferredFramesPerSecond = rate }
            enableSetNeedsDisplay = false
            isPaused = false
        } else {
            isPaused = true
            enableSetNeedsDisplay = true
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
        pointerActiveUntil = Date().addingTimeInterval(Self.pointerSettle)
        retime()
        updatePointer(event)
        scheduleSettle()
    }

    override func mouseMoved(with event: NSEvent) {
        let wasMoving = pointerActiveUntil > Date()
        pointerActiveUntil = Date().addingTimeInterval(Self.pointerSettle)
        updatePointer(event)
        if !wasMoving { retime() }
        scheduleSettle()
    }

    private var settleScheduled = false
    /// One trailing `retime()` once the pointer has rested, however many moves
    /// arrived in between.
    private func scheduleSettle() {
        guard !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pointerSettle + 0.05) { [weak self] in
            guard let self else { return }
            settleScheduled = false
            if pointerActiveUntil > Date() { scheduleSettle() } else { retime() }
        }
    }

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
        guard drawingAllowed else { return }
        let now = CACurrentMediaTime()
        // A presented handler that never fired must not stop the sky for good.
        if pending >= 2, now - lastAcquired < 0.25 { return }
        if pending >= 2 { pending = 0 }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let commandBuffer = renderer.gpu.queue.makeCommandBuffer() else { return }
        pending += 1
        lastAcquired = now
        drawable.addPresentedHandler { [weak self] _ in
            DispatchQueue.main.async { if let self, self.pending > 0 { self.pending -= 1 } }
        }
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
    var active: Bool
    var synchronous: Bool
    @Environment(\.displayScale) private var scale
    @State private var cache = StillCache()
    @State private var onScreen = true

    var body: some View {
        GeometryReader { geo in
            let request = StillCache.Request(input: input, size: geo.size, scale: scale, active: active && onScreen)
            Group {
                if let image = synchronous ? cache.image(input: input, size: geo.size, scale: scale) : cache.readyImage {
                    Image(decorative: image, scale: scale).resizable()
                } else {
                    Color(red: Double(input.scene.mid.x), green: Double(input.scene.mid.y), blue: Double(input.scene.mid.z))
                }
            }
            .task(id: request) {
                if !synchronous { await cache.update(request) }
            }
        }
        .onScrollVisibilityChange(threshold: 0.02) { onScreen = $0 }
    }
}

@Observable @MainActor private final class StillCache {
    /// Value snapshots passed to the serial worker; no view or mutable renderer
    /// crosses the queue boundary. The GPU's shared pipeline is thread safe.
    struct Request: Equatable, @unchecked Sendable {
        let input: AtmosphereRenderer.Input
        let size: CGSize
        let scale: CGFloat
        let active: Bool
    }

    private(set) var readyImage: CGImage?
    @ObservationIgnored private var readyKey: Request?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var worker: StillWorker?

    func update(_ request: Request) async {
        guard !Task.isCancelled else { return }
        revision += 1
        let revision = self.revision
        guard request.active, request.size.width > 1, request.size.height > 1,
              let gpu = AtmosphereGPU.shared, readyKey != request else { return }
        let worker = self.worker ?? StillWorker(gpu: gpu)
        self.worker = worker
        guard let image = await worker.snapshot(request), !Task.isCancelled,
              revision == self.revision else { return }
        readyImage = image
        readyKey = request
    }

    // ImageRenderer previews have no asynchronous presentation cycle. Keep
    // their deterministic capture separate from the live Reduce Motion path.
    @ObservationIgnored
    private var key: (AtmosphereRenderer.Input, CGSize, CGFloat)?
    @ObservationIgnored
    private var image: CGImage?
    @ObservationIgnored
    private var renderer: AtmosphereRenderer?

    func image(input: AtmosphereRenderer.Input, size: CGSize, scale: CGFloat) -> CGImage? {
        if let key, key.0 == input, key.1 == size, key.2 == scale { return image }
        guard size.width > 1, size.height > 1, let gpu = AtmosphereGPU.shared else { return nil }
        let renderer = self.renderer ?? AtmosphereRenderer(gpu: gpu)
        self.renderer = renderer
        renderer.input = input
        guard let image = renderer.snapshot(size: size, scale: scale) else { return nil }
        self.image = image
        key = (input, size, scale)
        return image
    }
}

/// Owns its renderer exclusively on a serial queue. GPU completion and image
/// readback can block, so they use a Dispatch worker rather than an executor
/// thread in Swift's cooperative task pool. Cancelled queued sizes are skipped;
/// an already committed frame can finish, but cannot publish into a cancelled view.
private final class StillWorker: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "claudebar.atmosphere.still", qos: .userInitiated)
    private let gpu: AtmosphereGPU
    private var renderer: AtmosphereRenderer?

    init(gpu: AtmosphereGPU) { self.gpu = gpu }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    func snapshot(_ request: StillCache.Request) async -> CGImage? {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.queue.async { [self] in
                    guard !cancellation.isCancelled else { continuation.resume(returning: nil); return }
                    let image = autoreleasepool {
                        let renderer = self.renderer ?? AtmosphereRenderer(gpu: gpu)
                        self.renderer = renderer
                        renderer.input = request.input
                        return renderer.snapshot(size: request.size, scale: request.scale)
                    }
                    continuation.resume(returning: image)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
