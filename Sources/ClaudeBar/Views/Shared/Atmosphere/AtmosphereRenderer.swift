import AppKit
import CoreText
import Metal
import QuartzCore
import simd

/// Mirror of the shader's `Uniforms`. Field order and types must match the MSL
/// struct exactly; `AtmosphereGPU` checks the stride at load time.
struct AtmosphereUniforms {
    var resolution = SIMD2<Float>(1, 1)
    var time: Float = 0
    var scale: Float = 2
    var zenith = SIMD4<Float>()
    var mid = SIMD4<Float>()
    var horizon = SIMD4<Float>()
    var glow = SIMD4<Float>()
    var sun = SIMD4<Float>()
    var sunColor = SIMD4<Float>()
    var moon = SIMD4<Float>()
    var sky = SIMD4<Float>()
    var cloud = SIMD4<Float>()
    var precip = SIMD4<Float>()
    var effects = SIMD4<Float>()
    var textRect = SIMD4<Float>()
    var textStyle = SIMD4<Float>()
    var pointer = SIMD4<Float>()
    var parallax = SIMD4<Float>()
    var ripple = SIMD4<Float>(0, 0, -1, 0)
    var flash = SIMD4<Float>()
    var meteor = SIMD4<Float>()
    var meteorInfo = SIMD4<Float>(-1, 0, 0, 0)

    static let expectedStride = 16 + 19 * 16
}

/// The compiled pipeline and the shared noise texture. Compiling the MSL takes
/// a few hundred milliseconds, so it happens once, off the main thread; views
/// draw the SwiftUI fallback until `AtmosphereGPU.shared` is ready.
final class AtmosphereGPU: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    /// The slow picture (sky, clouds, fog), at half the drawable. Sampled by `pipeline`.
    let skyPipeline: MTLRenderPipelineState
    let noise: MTLTexture
    let emptyText: MTLTexture
    /// Precipitation plates. Baked once; the frame scrolls them.
    let rainFine: MTLTexture
    let rainCoarse: MTLTexture
    let snowFine: MTLTexture
    let snowCoarse: MTLTexture
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    static let skyPixelFormat = MTLPixelFormat.rgba16Float

    @MainActor private(set) static var shared: AtmosphereGPU?
    @MainActor private(set) static var failed = false
    @MainActor private static var waiters: [@MainActor () -> Void] = []
    @MainActor private static var loading = false

    /// Calls `ready` on the main actor once the pipeline exists (immediately if
    /// it already does). Never calls it if Metal is unavailable.
    @MainActor static func whenReady(_ ready: @escaping @MainActor () -> Void) {
        if shared != nil { ready(); return }
        guard !failed else { return }
        waiters.append(ready)
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let gpu = try? AtmosphereGPU()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    shared = gpu
                    failed = gpu == nil
                    loading = false
                    let pending = waiters
                    waiters.removeAll()
                    if gpu != nil { pending.forEach { $0() } }
                }
            }
        }
    }

    /// Synchronous load for tools and tests that have no run loop to wait on.
    @MainActor static func loadNow() -> AtmosphereGPU? {
        if shared == nil, !failed {
            shared = try? AtmosphereGPU()
            failed = shared == nil
        }
        return shared
    }

    enum LoadError: Error { case noDevice, noQueue, noFunction, layout }

    init() throws {
        guard MemoryLayout<AtmosphereUniforms>.stride == AtmosphereUniforms.expectedStride else { throw LoadError.layout }
        guard let device = MTLCreateSystemDefaultDevice() else { throw LoadError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw LoadError.noQueue }
        let library = try device.makeLibrary(source: AtmosphereShader.source, options: MTLCompileOptions())
        guard let vertex = library.makeFunction(name: "atmosphere_vertex"),
              let skyFragment = library.makeFunction(name: "atmosphere_sky"),
              let fragment = library.makeFunction(name: "atmosphere_fragment") else { throw LoadError.noFunction }
        let skyDescriptor = MTLRenderPipelineDescriptor()
        skyDescriptor.vertexFunction = vertex
        skyDescriptor.fragmentFunction = skyFragment
        skyDescriptor.colorAttachments[0].pixelFormat = Self.skyPixelFormat
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        self.device = device
        self.queue = queue
        self.skyPipeline = try device.makeRenderPipelineState(descriptor: skyDescriptor)
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.noise = try Self.makeNoise(device: device, queue: queue)
        self.emptyText = try Self.makeEmpty(device: device)
        guard let bakeFunction = library.makeFunction(name: "precip_bake") else { throw LoadError.noFunction }
        let bakeDescriptor = MTLRenderPipelineDescriptor()
        bakeDescriptor.vertexFunction = vertex
        bakeDescriptor.fragmentFunction = bakeFunction
        bakeDescriptor.colorAttachments[0].pixelFormat = .r8Unorm
        let bake = try device.makeRenderPipelineState(descriptor: bakeDescriptor)
        // Sizes are an integer number of cells, and they are the `world` values
        // the composite shader scrolls by. One point per pixel.
        self.rainFine = try Self.makePlate(device: device, queue: queue, pipeline: bake,
                                           width: 252, height: 512, cell: SIMD2(14, 64),
                                           shape: SIMD4(10, 0.9, 0, 0), seed: 1, kind: 0)
        self.rainCoarse = try Self.makePlate(device: device, queue: queue, pipeline: bake,
                                             width: 384, height: 640, cell: SIMD2(32, 128),
                                             shape: SIMD4(18, 1.6, 0, 0), seed: 13, kind: 0)
        self.snowFine = try Self.makePlate(device: device, queue: queue, pipeline: bake,
                                           width: 192, height: 192, cell: SIMD2(24, 24),
                                           shape: SIMD4(0, 0, 1.2, 0.6), seed: 3, kind: 1)
        self.snowCoarse = try Self.makePlate(device: device, queue: queue, pipeline: bake,
                                             width: 224, height: 224, cell: SIMD2(56, 56),
                                             shape: SIMD4(0, 0, 3.2, 2.2), seed: 21, kind: 1)
    }

    /// 256² tileable value noise, 64 lattice cells per side, two independent
    /// channels. Smooth (quintic) interpolation, so `fbm` built from it has no
    /// grid creases.
    private static func makeNoise(device: MTLDevice, queue: MTLCommandQueue) throws -> MTLTexture {
        let size = 256, cells = 64, cellSize = size / cells
        var state: UInt64 = 0x9E3779B97F4A7C15
        func random() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
        let latticeR = (0..<(cells * cells)).map { _ in random() }
        let latticeG = (0..<(cells * cells)).map { _ in random() }
        func sample(_ lattice: [Float], _ x: Int, _ y: Int) -> Float {
            let fx = Float(x) / Float(cellSize), fy = Float(y) / Float(cellSize)
            let x0 = Int(fx) % cells, y0 = Int(fy) % cells
            let x1 = (x0 + 1) % cells, y1 = (y0 + 1) % cells
            func fade(_ t: Float) -> Float { t * t * t * (t * (t * 6 - 15) + 10) }
            let tx = fade(fx - Float(Int(fx))), ty = fade(fy - Float(Int(fy)))
            let a = lattice[y0 * cells + x0], b = lattice[y0 * cells + x1]
            let c = lattice[y1 * cells + x0], d = lattice[y1 * cells + x1]
            return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty
        }
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                bytes[i] = UInt8(max(0, min(255, sample(latticeR, x, y) * 255)))
                bytes[i + 1] = UInt8(max(0, min(255, sample(latticeG, x, y) * 255)))
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw LoadError.noDevice }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: bytes, bytesPerRow: size * 4)
        if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        return texture
    }

    private static func makeEmpty(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw LoadError.noDevice }
        var zero: UInt8 = 0
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 1)
        return texture
    }

    /// One tileable precipitation plate, rendered once. `shape` is
    /// (streak length, streak width, flake size, flake blur).
    private static func makePlate(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState,
                                  width: Int, height: Int, cell: SIMD2<Float>, shape: SIMD4<Float>,
                                  seed: Float, kind: Float) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                                  width: width, height: height, mipmapped: true)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = queue.makeCommandBuffer() else { throw LoadError.noDevice }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { throw LoadError.noDevice }
        var bytes = [
            SIMD4<Float>(Float(width), Float(height), cell.x, cell.y),
            shape,
            SIMD4<Float>(seed, kind, 0, 0)
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&bytes, length: MemoryLayout<SIMD4<Float>>.stride * 3, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else { throw LoadError.noDevice }
        return texture
    }
}

/// Typesetting for the greeting and its name. Both are drawn into one texture,
/// so the name is the same glass as the phrase and moves with it under
/// parallax.
///
/// The texture has two channels. **R** is ink coverage. **G** is *when* that
/// ink is written, 0…1: the phrase occupies `0…phraseShare` from its first ink
/// to its last, left to right; the name `nameStart…1` the same way. The shader
/// shows every pixel whose G is behind the current reveal through a soft edge,
/// with the freshest ink still wet-bright, so the line develops like ink
/// following a pen rather than being uncovered by a hard wipe.
enum GreetingTypesetter {
    /// Share of the reveal the pen spends on the phrase; the name takes the
    /// tail, after a short pause.
    static let phraseShare: CGFloat = 0.86
    static let nameStart: CGFloat = 0.90

    struct Layout: Equatable {
        /// Script text, as drawn.
        var phrase: String
        /// Person's name, preserving its authored case.
        var name: String
        var typeface: GreetingTypeface
        var fontSize: CGFloat
        /// Pen origin: the left of the line's advance, on the baseline (card pt).
        var origin: CGPoint
        /// Ink bounds of the phrase (card pt).
        var phraseFrame: CGRect
        var nameSize: CGFloat
        /// Left of the name's advance, on its baseline (card pt).
        var nameOrigin: CGPoint
        var nameWidth: CGFloat
        /// Whether the name sits on the phrase's baseline or under its end.
        var nameInline: Bool
        /// Glow and edge-light room around the ink; part of the texture.
        var padding: CGFloat
        /// Seconds from the first touch of the pen to the last letter of the name.
        var writeDuration: Double

        /// Width of the stroke laid over the outline to give the face its weight.
        var outlineWidth: CGFloat { fontSize * typeface.weight * 2 }
        var nameFrame: CGRect {
            CGRect(x: nameOrigin.x, y: nameOrigin.y - nameSize * 0.78, width: nameWidth, height: nameSize * 1.02)
        }
        var textureFrame: CGRect {
            let union = name.isEmpty ? phraseFrame : phraseFrame.union(nameFrame)
            return union.insetBy(dx: -padding, dy: -padding).integral
        }
    }

    static func nameFont(size: CGFloat) -> CTFont {
        let font = NSFont.systemFont(ofSize: size, weight: .medium)
        let descriptor = font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor
        return (NSFont(descriptor: descriptor, size: size) ?? font) as CTFont
    }

    static func nameTracking(size: CGFloat) -> CGFloat { size * 0.015 }

    static func nameLine(_ text: String, size: CGFloat, color: CGColor? = nil) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [.font: nameFont(size: size), .kern: nameTracking(size: size)]
        if let color { attributes[.foregroundColor] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    static func measure(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Maximize measured ink inside the free band. Short greetings grow until
    /// height limits them; longer greetings shrink to fit the card width.
    /// Compare inline and dropped signatures without sacrificing phrase size.
    /// `topClear` / `bottomClear` bound the free band between the instruments
    /// along the top and bottom edges; the ink (and a dropped name) is centred
    /// in it, a touch above true centre so it reads as sitting, not sinking.
    static func layout(_ phrase: String, name: String, typeface: GreetingTypeface = .standard,
                       cardWidth: CGFloat, skyHeight: CGFloat, margin: CGFloat,
                       topClear: CGFloat? = nil, bottomClear: CGFloat? = nil) -> Layout {
        // The sheet asks on every body pass — each frame of a drag — with the
        // same arguments; measuring the name builds a CTLine each time.
        let key = LayoutKey(phrase: phrase, name: name, typeface: typeface, cardWidth: cardWidth,
                            skyHeight: skyHeight, margin: margin, topClear: topClear, bottomClear: bottomClear)
        layoutCache.lock.lock()
        if let hit = layoutCache.entries.first(where: { $0.key == key }) { layoutCache.lock.unlock(); return hit.layout }
        layoutCache.lock.unlock()
        let layout = computeLayout(phrase, name: name, typeface: typeface, cardWidth: cardWidth, skyHeight: skyHeight,
                                   margin: margin, topClear: topClear, bottomClear: bottomClear)
        layoutCache.lock.lock()
        layoutCache.entries.insert((key, layout), at: 0)
        if layoutCache.entries.count > 8 { layoutCache.entries.removeLast() }
        layoutCache.lock.unlock()
        return layout
    }

    private struct LayoutKey: Equatable {
        var phrase: String
        var name: String
        var typeface: GreetingTypeface
        var cardWidth: CGFloat
        var skyHeight: CGFloat
        var margin: CGFloat
        var topClear: CGFloat?
        var bottomClear: CGFloat?
    }

    private final class LayoutCache: @unchecked Sendable {
        let lock = NSLock()
        /// Most recent first; a handful covers both widths of a resize and the
        /// hour's phrase changing.
        var entries: [(key: LayoutKey, layout: Layout)] = []
    }
    private static let layoutCache = LayoutCache()

    static func invalidateLayouts() {
        layoutCache.lock.lock()
        layoutCache.entries.removeAll()
        layoutCache.lock.unlock()
    }

    private static func computeLayout(_ phrase: String, name: String, typeface: GreetingTypeface,
                                      cardWidth: CGFloat, skyHeight: CGFloat, margin: CGFloat,
                                      topClear: CGFloat?, bottomClear: CGFloat?) -> Layout {
        // All lower case, like the Mac's "hello": a script capital is the
        // heaviest shape in the line and pulls the eye off the rest of it.
        let text = phrase.lowercased()
        let caption = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = GreetingScript.line(text, typeface: typeface)
        let weight = typeface.weight
        let top = topClear ?? skyHeight * 0.24
        let band = max(1, (bottomClear ?? skyHeight * 0.82) - top)
        let available = cardWidth - margin * 2
        let ascent = max(0, -line.bounds.minY), descent = max(0, line.bounds.maxY)

        var nameWidths: [CGFloat: CGFloat] = [:]
        func nameMetrics(for size: CGFloat) -> (size: CGFloat, width: CGFloat) {
            let nameSize = min(28, max(18, (size * 0.18).rounded()))
            if caption.isEmpty { return (nameSize, 0) }
            if let width = nameWidths[nameSize] { return (nameSize, width) }
            let width = measure(nameLine(caption, size: nameSize))
            nameWidths[nameSize] = width
            return (nameSize, width)
        }
        func extents(size: CGFloat, inline: Bool) -> (head: CGFloat, hang: CGFloat, drop: CGFloat) {
            let name = nameMetrics(for: size)
            let head = (ascent + weight) * size
            let tail = (descent + weight) * size
            if caption.isEmpty { return (head, tail, 0) }
            if inline { return (max(head, name.size * 0.78), max(tail, name.size * 0.24), 0) }
            let drop = max(tail, name.size) + name.size * 1.6
            return (head, max(tail, drop + name.size * 0.24), drop)
        }
        func largestSize(inline: Bool) -> CGFloat {
            var low: CGFloat = 0
            var high = min(band / max(0.01, ascent + descent + weight * 2),
                           available / max(0.01, line.bounds.width + weight * 2))
            // Name size varies with the phrase, so solve their combined bounds
            // rather than subtracting a fixed line height or counting letters.
            for _ in 0..<24 {
                let candidate = (low + high) / 2
                let name = nameMetrics(for: candidate)
                let e = extents(size: candidate, inline: inline)
                let width = (line.bounds.width + weight * 2) * candidate
                let fitsWidth = caption.isEmpty || !inline
                    ? max(width, name.width) <= available
                    : width + candidate * 0.22 + name.width <= available
                if fitsWidth && e.head + e.hang <= band { low = candidate } else { high = candidate }
            }
            return low.rounded(.down)
        }
        let droppedSize = largestSize(inline: false)
        let inlineSize = caption.isEmpty ? droppedSize : largestSize(inline: true)
        let inline = !caption.isEmpty && inlineSize >= droppedSize
        let size = max(1, inline ? inlineSize : droppedSize)
        let name = nameMetrics(for: size)
        let e = extents(size: size, inline: inline)
        let drop = e.drop
        let spare = max(0, band - e.head - e.hang)
        let baseline = (top + spare * 0.46 + e.head).rounded()
        let origin = CGPoint(x: (margin + size * weight - line.bounds.minX * size).rounded(), y: baseline)
        let ink = CGRect(x: origin.x + line.bounds.minX * size, y: origin.y + line.bounds.minY * size,
                         width: line.bounds.width * size, height: line.bounds.height * size)
            .insetBy(dx: -size * weight, dy: -size * weight)
        let nameOrigin: CGPoint
        if inline {
            nameOrigin = CGPoint(x: (origin.x + line.bounds.maxX * size + size * 0.22).rounded(), y: baseline)
        } else {
            let right = min(ink.maxX - size * 0.05, cardWidth - margin)
            nameOrigin = CGPoint(x: max(margin, (right - name.width).rounded()),
                                 y: (baseline + drop).rounded())
        }
        // About 0.2 s an em of advance — the unhurried pace of the Mac's
        // "hello" — within bounds that keep a short word from being curt and a
        // festival name from dragging.
        let write = min(2.8, max(1.6, 0.9 + Double(line.advance) * 0.2))
        return Layout(phrase: text, name: caption, typeface: typeface, fontSize: size, origin: origin, phraseFrame: ink,
                      nameSize: name.size, nameOrigin: nameOrigin, nameWidth: name.width, nameInline: inline,
                      padding: (size * 0.3).rounded(), writeDuration: write / Double(phraseShare))
    }

    /// The phrase's outlines in card points (y down). Filled, then stroked
    /// `outlineWidth` wide, both here and in the SwiftUI fallback.
    static func phrasePath(_ layout: Layout) -> CGPath {
        GreetingScript.path(GreetingScript.line(layout.phrase, typeface: layout.typeface), size: layout.fontSize, origin: layout.origin)
    }

    /// Coverage (R) and write order (G), 16 bits each, interleaved.
    static func rasterize(_ layout: Layout, scale: CGFloat) -> (texels: [UInt16], width: Int, height: Int)? {
        let frame = layout.textureFrame
        let width = Int((frame.width * scale).rounded(.up)), height = Int((frame.height * scale).rounded(.up))
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        // Card points (y down) → bitmap points (y up).
        func place(_ context: CGContext) {
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -frame.minX, y: frame.maxY)
            context.scaleBy(x: 1, y: -1)
        }
        var coverage = [UInt8](repeating: 0, count: width * height)
        let inked: Bool = coverage.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setShouldAntialias(true)
            place(context)
            let outline = phrasePath(layout)
            context.setFillColor(gray: 1, alpha: 1)
            context.addPath(outline)
            context.fillPath()
            // A zero width still strokes a hairline in Core Graphics.
            if layout.outlineWidth > 0 {
                context.setStrokeColor(gray: 1, alpha: 1)
                context.setLineWidth(layout.outlineWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.addPath(outline)
                context.strokePath()
            }
            if !layout.name.isEmpty {
                // CoreText draws y-up; undo the flip around the name's baseline.
                context.saveGState()
                context.translateBy(x: layout.nameOrigin.x, y: layout.nameOrigin.y)
                context.scaleBy(x: 1, y: -1)
                context.textPosition = .zero
                context.setShouldSmoothFonts(false)
                // Hierarchy comes from size, not translucent, unreadable ink.
                CTLineDraw(nameLine(layout.name, size: layout.nameSize, color: CGColor(gray: 1, alpha: 1)), context)
                context.restoreGState()
            }
            return true
        }
        guard inked else { return nil }

        var order = [UInt16](repeating: 0, count: width * height)
        let ordered: Bool = order.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 16,
                                          bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }
            // No antialiasing: a soft clip edge would blend the ramp with the
            // background's 0 and let the rim of a glyph show early.
            context.setShouldAntialias(false)
            context.setAllowsAntialiasing(false)
            place(context)
            let space = CGColorSpaceCreateDeviceGray()
            func ramp(_ rect: CGRect, from: CGFloat, to: CGFloat) {
                let colors = [CGColor(gray: from, alpha: 1), CGColor(gray: to, alpha: 1)] as CFArray
                guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
                context.saveGState()
                context.clip(to: rect)
                context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
            }
            // The two rects never share ink: an inline name starts a gap after
            // the last glyph, a dropped one hangs below the lowest descender.
            ramp(layout.phraseFrame.insetBy(dx: -2, dy: -2), from: 0, to: phraseShare)
            if !layout.name.isEmpty { ramp(layout.nameFrame.insetBy(dx: -2, dy: -2), from: nameStart, to: 1) }
            return true
        }
        guard ordered else { return nil }

        var texels = [UInt16](repeating: 0, count: width * height * 2)
        for i in 0..<(width * height) {
            texels[i * 2] = UInt16(coverage[i]) * 257
            texels[i * 2 + 1] = order[i]
        }
        return (texels, width, height)
    }
}

/// Per-view state: the greeting texture, the event clocks (lightning, meteors,
/// ripples) and the smoothed parallax. Owned by one `AtmosphereMetalView`, or
/// created briefly to take a still.
final class AtmosphereRenderer {
    struct Input: Equatable {
        var scene: SkyScene
        var layout: GreetingTypesetter.Layout?
        var skyHeight: CGFloat
        var darkInk: Bool
        var darkAppearance: Bool
        var reduceMotion: Bool
        var rainbow: Bool = false
        var meteorShower: Bool = false
        /// The drag preview is showing; the entrance should not replay.
        var previewing: Bool = false
    }

    let gpu: AtmosphereGPU
    var input: Input? { didSet { if input?.layout?.phrase != oldValue?.layout?.phrase { phraseChanged = true } } }
    var pointer: CGPoint?
    var pointerNormalized = CGPoint.zero

    /// What a greeting texture was rasterised from; a new texture is needed
    /// exactly when this changes.
    private struct TextKey: Equatable, Sendable {
        var typeface: GreetingTypeface
        var phrase: String
        var name: String
        var fontSize: CGFloat
        var frame: CGRect
        var nameOrigin: CGPoint
        var scale: CGFloat

        init(_ layout: GreetingTypesetter.Layout, scale: CGFloat) {
            typeface = layout.typeface
            phrase = layout.phrase
            name = layout.name
            fontSize = layout.fontSize
            frame = layout.textureFrame
            nameOrigin = layout.nameOrigin
            self.scale = scale
        }
    }

    private struct TextJob: Sendable {
        var key: TextKey
        var layout: GreetingTypesetter.Layout
        var scale: CGFloat
    }

    /// Carries a finished texture back to the main thread. `MTLTexture` is
    /// thread-safe to hand over once its upload and mip blit are committed.
    private struct Rasterized: @unchecked Sendable {
        var texture: MTLTexture?
    }

    private final class WeakRenderer: @unchecked Sendable {
        weak var renderer: AtmosphereRenderer?
        init(_ renderer: AtmosphereRenderer) { self.renderer = renderer }
    }

    /// Rasterising the greeting takes several milliseconds at card size, so it
    /// runs here rather than inside a frame; serial, so jobs finish in order.
    private static let rasterQueue = DispatchQueue(label: "ClaudeBar.greeting-raster", qos: .userInitiated)

    /// The texture on screen and the frame (card pt) it was laid out for. The
    /// shader places it by this frame, not the current layout's, so while a
    /// new texture is being made the old one stays where it was drawn.
    private var textTexture: MTLTexture?
    private var textFrame = CGRect.zero
    private var textKey: TextKey?
    /// The newest layout not yet on screen, and the one being rasterised.
    private var requested: TextJob?
    private var rasterizing: TextKey?
    /// Called on the main thread when a new greeting texture is in place, so
    /// a paused view can draw it.
    var textDidChange: (() -> Void)?
    private let start = CACurrentMediaTime()
    private var appeared = CACurrentMediaTime()
    /// When the pen touches down: shortly after the sky develops on arrival,
    /// or immediately for a rewrite.
    private var writeStart = CACurrentMediaTime() + 0.45
    private var phraseChanged = false
    /// A still is always the settled frame, never a moment of the entrance.
    private var capturing = false
    private var lastFrame = CACurrentMediaTime()
    /// The slow picture. Redrawn on its own clock; precipitation samples it.
    private var skyTexture: MTLTexture?
    private var skySize = SIMD2<Int>(0, 0)
    private var lastSkyTime = -Double.infinity
    /// Whether the encode that just returned marched the clouds again.
    private(set) var drewSky = true
    private var parallax = SIMD2<Float>.zero
    private var nextFlash = CACurrentMediaTime() + 1.2
    private var flashStart: Double = -10
    private var flashBolt = false
    private var flashX: Float = 0.5
    private var flashSeed: Float = 0
    /// The strike's strokes: onset (s after `flashStart`) and peak brightness.
    private var flashStrokes: [SIMD2<Double>] = []
    /// A fixed strike for stills (previews and tests), in `lightning`'s
    /// uniform layout. `nil` keeps the default: a dim deck and no channel.
    var stillFlash: SIMD4<Float>?
    private var nextMeteor = CACurrentMediaTime() + 20
    private var meteorStart: Double = -10
    private var meteorPath = SIMD4<Float>()
    private var rippleStart: Double = -10
    private var rippleAt = SIMD2<Float>()
    private var rippleKind: Float = 0
    private var rng = SystemRandomNumberGenerator()
    /// Weather cross-fade: the scene as last drawn, the one the fade started
    /// from, and when. Time of day needs none — it arrives continuously.
    private var lastTarget: SkyScene?
    private var shownScene: SkyScene?
    private var fadeFrom: SkyScene?
    private var fadeStart: Double = -10
    static let weatherFade: Double = 1.2

    init(gpu: AtmosphereGPU) { self.gpu = gpu }

    func replayEntrance() {
        appeared = CACurrentMediaTime()
        writeStart = appeared + 0.45
    }

    func skipEntrance() {
        appeared = -100
        writeStart = -100
    }

    /// Writes the greeting again from the first stroke; the sky stays as it is.
    func rewrite() { writeStart = CACurrentMediaTime() + 0.08 }

    /// The frame rate this sky needs when nothing is touching it.
    ///
    /// Anything that *falls* (rain, snow, hail, glass drops, a storm) is a plate
    /// scrolling across the card and reads best at 30 Hz. A calm sky is not: the
    /// cloud deck drifts at `t · wind · 0.01` of a card width a second, the
    /// stars breathe at about one radian a second, and a meteor takes 0.85 s to
    /// cross a fifth of the band — every one of them moves well under a pixel
    /// per frame at 15 Hz, so drawing them twice as often was pure GPU and
    /// main-thread cost with nothing on screen to show for it.
    var restingRate: Int {
        guard let scene = input?.scene else { return 30 }
        let falling = scene.rain > 0.001 || scene.snow > 0.001 || scene.glassDrops > 0.001
            || scene.thunder > 0.001 || scene.hail
        return falling ? 30 : 15
    }

    /// The pen is on the page: the view should run at full rate until it lifts.
    var writing: Bool {
        guard let layout = input?.layout, input?.reduceMotion == false else { return false }
        let age = CACurrentMediaTime() - writeStart
        return age > -0.5 && age < layout.writeDuration + 0.4
    }

    func ripple(at point: CGPoint) {
        rippleStart = CACurrentMediaTime()
        rippleAt = SIMD2(Float(point.x), Float(point.y))
        guard let scene = input?.scene else { return }
        rippleKind = scene.rain > 0 || scene.snow > 0 || scene.nightness > 0.5 ? 1 : 0
    }

    // MARK: - Encoding

    func encode(pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer, pixelSize: CGSize, scale: CGFloat,
                now: Double = CACurrentMediaTime()) {
        guard let input else { return }
        updateText(input: input, scale: scale, commandBuffer: commandBuffer)
        var uniforms = makeUniforms(input: input, pixelSize: pixelSize, scale: scale, now: now)
        var stars = input.scene.stars.isEmpty ? [SIMD4<Float>()] : input.scene.stars
        drewSky = false
        if let sky = skyTarget(pixelSize: pixelSize), skyDue(now: now, flash: uniforms.flash) {
            // Half the drawable, with the scale reduced by the same factor, so
            // the shader's point space is still the card. The march then covers
            // a quarter of the pixels. The composite samples this with a linear
            // filter, which is the upscale.
            var deck = uniforms
            deck.resolution = SIMD2(Float(sky.width), Float(sky.height))
            deck.scale = uniforms.scale * Float(sky.width) / max(uniforms.resolution.x, 1)
            let skyPass = MTLRenderPassDescriptor()
            skyPass.colorAttachments[0].texture = sky
            skyPass.colorAttachments[0].loadAction = .dontCare
            skyPass.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: skyPass) {
                encoder.setRenderPipelineState(gpu.skyPipeline)
                encoder.setFragmentBytes(&deck, length: MemoryLayout<AtmosphereUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&stars, length: MemoryLayout<SIMD4<Float>>.stride * stars.count, index: 1)
                encoder.setFragmentTexture(gpu.noise, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
                lastSkyTime = now
                drewSky = true
            }
        }
        guard let sky = skyTexture else { return }
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(gpu.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AtmosphereUniforms>.stride, index: 0)
        encoder.setFragmentTexture(sky, index: 0)
        encoder.setFragmentTexture(textTexture ?? gpu.emptyText, index: 1)
        encoder.setFragmentTexture(gpu.rainFine, index: 2)
        encoder.setFragmentTexture(gpu.rainCoarse, index: 3)
        encoder.setFragmentTexture(gpu.snowFine, index: 4)
        encoder.setFragmentTexture(gpu.snowCoarse, index: 5)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// The deck is a slow picture. Clouds drift, the sun crawls, and a baked
    /// rain plate does not need the deck to move with it. 30 Hz is the rate a
    /// cloud actually changes; 15 Hz under Low Power Mode or thermal pressure.
    /// A strike lights the deck from inside, so the deck follows that pulse.
    private func skyDue(now: Double, flash: SIMD4<Float>) -> Bool {
        if capturing || flash.x > 0.02 || flash.w > 0.02 { return true }
        let elapsed = now - lastSkyTime
        if elapsed < 0 { return true }
        let info = ProcessInfo.processInfo
        let constrained = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        return elapsed >= (constrained ? 1.0 / 15 : 1.0 / 30)
    }

    /// Half the drawable on each axis. The card is authored in points, and a
    /// retina drawable is twice that, so this is one pixel per point.
    private func skyTarget(pixelSize: CGSize) -> MTLTexture? {
        let width = max(1, Int((pixelSize.width / 2).rounded(.down)))
        let height = max(1, Int((pixelSize.height / 2).rounded(.down)))
        guard width > 0, height > 0 else { return nil }
        if let skyTexture, skySize.x == width, skySize.y == height { return skyTexture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: AtmosphereGPU.skyPixelFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        skyTexture = gpu.device.makeTexture(descriptor: descriptor)
        skySize = SIMD2(width, height)
        lastSkyTime = -Double.infinity
        return skyTexture
    }

    /// A still frame, for Reduce Motion, previews and tests. `time` fixes the
    /// drift phase so a still is reproducible.
    func snapshot(size: CGSize, scale: CGFloat, time: Double = 42) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: AtmosphereGPU.pixelFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let target = gpu.device.makeTexture(descriptor: descriptor),
              let commandBuffer = gpu.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        capturing = true
        defer { capturing = false }
        encode(pass: pass, commandBuffer: commandBuffer, pixelSize: CGSize(width: width, height: height),
               scale: scale, now: start + time)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - Private

    private func updateText(input: Input, scale: CGFloat, commandBuffer: MTLCommandBuffer) {
        guard let layout = input.layout else {
            textTexture = nil; textKey = nil; requested = nil
            return
        }
        let key = TextKey(layout, scale: scale)
        guard key != textKey else { requested = nil; return }
        if capturing {
            // A still is taken in one call; it cannot wait for the queue.
            install(Self.makeTexture(layout, scale: scale, gpu: gpu, commandBuffer: commandBuffer),
                    frame: layout.textureFrame, key: key, reduceMotion: input.reduceMotion)
            return
        }
        if requested?.key != key { requested = TextJob(key: key, layout: layout, scale: scale) }
        startRasterizing()
    }

    /// One job at a time; a resize that asks for many sizes in a row gets the
    /// one in flight and then the newest, never the ones in between.
    private func startRasterizing() {
        guard rasterizing == nil, let job = requested else { return }
        rasterizing = job.key
        let gpu = self.gpu, owner = WeakRenderer(self)
        Self.rasterQueue.async {
            let result = Rasterized(texture: Self.makeTexture(job.layout, scale: job.scale, gpu: gpu, commandBuffer: nil))
            DispatchQueue.main.async {
                owner.renderer?.finishRasterizing(job, result: result)
            }
        }
    }

    private func finishRasterizing(_ job: TextJob, result: Rasterized) {
        rasterizing = nil
        // The input went back to the texture already shown, or lost its
        // greeting, while this one was being made.
        guard let requested else { return }
        install(result.texture, frame: job.layout.textureFrame, key: job.key,
                reduceMotion: input?.reduceMotion ?? true)
        if requested.key == job.key { self.requested = nil } else { startRasterizing() }
        textDidChange?()
    }

    private func install(_ texture: MTLTexture?, frame: CGRect, key: TextKey, reduceMotion: Bool) {
        // A new phrase (the hour turned) is written in, not swapped in.
        if phraseChanged, textTexture != nil, !reduceMotion, !capturing { rewrite() }
        phraseChanged = false
        textTexture = texture
        textFrame = frame
        textKey = key
    }

    /// Coverage and write order as a mipmapped `rg16Unorm` texture. Safe off
    /// the main thread. With no `commandBuffer` the mip blit is committed on
    /// its own, ahead of any frame that can sample the texture.
    private static func makeTexture(_ layout: GreetingTypesetter.Layout, scale: CGFloat, gpu: AtmosphereGPU,
                                    commandBuffer: MTLCommandBuffer?) -> MTLTexture? {
        guard let mask = GreetingTypesetter.rasterize(layout, scale: scale) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: mask.width,
                                                                  height: mask.height, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else { return nil }
        mask.texels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, mask.width, mask.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: mask.width * 4)
        }
        let buffer = commandBuffer ?? gpu.queue.makeCommandBuffer()
        if let buffer, let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            if commandBuffer == nil { buffer.commit() }
        }
        return texture
    }

    /// A change of weather eases over `weatherFade` instead of cutting; a
    /// second change mid-fade starts from what is on screen, so rapid picks
    /// never jump.
    private func displayedScene(_ target: SkyScene, now: Double, settled: Bool) -> SkyScene {
        defer { lastTarget = target }
        guard !settled else { fadeFrom = nil; shownScene = target; return target }
        if let last = lastTarget, last.weather != target.weather, let shown = shownScene {
            fadeFrom = shown
            fadeStart = now
        }
        var scene = target
        if let from = fadeFrom {
            let p = (now - fadeStart) / Self.weatherFade
            if p >= 1 { fadeFrom = nil } else { scene = SkyScene.mix(from, target, Float(p * p * (3 - 2 * p))) }
        }
        shownScene = scene
        return scene
    }

    private func makeUniforms(input: Input, pixelSize: CGSize, scale: CGFloat, now: Double) -> AtmosphereUniforms {
        let still = input.reduceMotion
        let scene = displayedScene(input.scene, now: now, settled: still || capturing)
        let dt = Float(max(0, min(0.1, now - lastFrame)))
        lastFrame = now
        let t = still ? 42 : now - start

        let targetParallax = still ? SIMD2<Float>.zero
            : SIMD2(Float(-pointerNormalized.x) * 24, Float(-pointerNormalized.y) * 14)
        parallax += (targetParallax - parallax) * (1 - exp(-dt * 7))

        let settled = still || input.previewing || capturing
        let sinceAppear = settled ? 10 : now - appeared
        let entrance = Float(min(1, max(0, sinceAppear / 0.9)))
        let reveal = settled ? 1 : Float(Self.pen((now - writeStart) / (input.layout?.writeDuration ?? 1)))

        var u = AtmosphereUniforms()
        u.resolution = SIMD2(Float(pixelSize.width), Float(pixelSize.height))
        // Straight `t`: every shader use of it is a linear phase offset
        // (wind/cirrus/fog drift, the rain and snow plates, drop life, the
        // dither), none branches on its magnitude, and wrapping it at 3600 s
        // re-phased the entire sky — deck, fog, precipitation and dither — in
        // a single frame once an hour, measured as a ~10× step in frame-to-frame
        // luma against the neighbouring seconds. Float keeps ~7.8 ms of
        // resolution at a day's uptime, far past anything this needs; if a
        // rebase ever is wanted for precision it must happen while the view is
        // paused or hidden, never on a live frame.
        u.time = Float(t)
        u.scale = Float(scale)
        u.zenith = SIMD4(scene.zenith, Float(input.skyHeight))
        u.mid = SIMD4(scene.mid, 1)
        u.horizon = SIMD4(scene.horizon, scene.nightness)
        u.glow = SIMD4(scene.glow, scene.glowStrength)
        u.sun = SIMD4(scene.sunUV.x, scene.sunUV.y, scene.sunRadius, scene.sunVisibility)
        u.sunColor = SIMD4(scene.sunColor, scene.sunAltitude)
        u.moon = SIMD4(scene.moonUV.x, scene.moonUV.y, scene.moonRadius, scene.moonVisibility)
        u.sky = SIMD4(scene.moonPhase, scene.starVisibility, scene.starDrift, Float(scene.stars.count))
        u.cloud = SIMD4(scene.cloudCover, scene.cloudDarkness, scene.windSpeed, scene.windAngle)
        u.precip = SIMD4(scene.rain, scene.snow, scene.fog, scene.thunder)
        u.effects = SIMD4(scene.glassDrops, scene.hail ? 1 : 0, input.rainbow ? 1 : 0, entrance)
        if textTexture != nil {
            let frame = textFrame
            u.textRect = SIMD4(Float(frame.minX), Float(frame.minY), Float(frame.width), Float(frame.height))
        }
        u.textStyle = SIMD4(reveal, scene.rimStrength, scene.textGlow, input.darkInk ? 1 : 0)
        if let pointer, !still {
            u.pointer = SIMD4(Float(pointer.x), Float(pointer.y), 1, 0)
        }
        u.parallax = SIMD4(parallax.x, parallax.y, input.darkAppearance ? 1 : 0, 0)

        let rippleAge = now - rippleStart
        if !still, rippleAge < 1.1 { u.ripple = SIMD4(rippleAt.x, rippleAt.y, Float(rippleAge), rippleKind) }

        u.flash = lightning(scene: scene, now: now, still: still || capturing)
        (u.meteor, u.meteorInfo) = meteor(scene: scene, input: input, now: now, still: still)
        return u
    }

    /// Pen position 0…1 for elapsed/duration. Half linear, half sine ease: the
    /// pen leaves and lands gently but keeps a hand's steady pace in between,
    /// rather than the rush-then-crawl of an ease-out.
    static func pen(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return 0.5 * t + 0.5 * (0.5 - 0.5 * cos(.pi * t))
    }

    /// A thunderstorm's strikes, modelled on how lightning reads — within
    /// WCAG 2.3.1 (at most three flashes in any second):
    ///
    /// - **Cloud-to-ground** (60 %): one channel, re-lit by 2–3 return strokes
    ///   40–130 ms apart. Each stroke is a ~30 ms peak with a fast decay, so the
    ///   bolt visibly flickers; the channel keeps its shape (`flashSeed`)
    ///   because real return strokes reuse the ionised path.
    /// - **In-cloud sheet** (40 %): no channel, the deck alone lights.
    ///
    /// Only the thin channel flickers. The deck — most of the card — takes one
    /// smooth pulse per strike: it rises with the first stroke, holds through
    /// the rest and then decays, never dipping between strokes. The next
    /// strike starts at least 1.1 s after the last stroke, so no one-second
    /// window holds more than three channel peaks or more than one deck pulse.
    ///
    /// Strikes cluster the way storm cells do: a quick follow-up 1.1–2.5 s
    /// later a third of the time, otherwise 2.5–8 s.
    ///
    /// `x`: sky illumination, `y`: strike x (uv), `z`: channel seed,
    /// `w`: channel brightness (0 for a sheet flash).
    private func lightning(scene: SkyScene, now: Double, still: Bool) -> SIMD4<Float> {
        guard scene.thunder > 0 else { return .zero }
        if still { return stillFlash.map { SIMD4($0.x * scene.thunder, $0.y, $0.z, $0.w * scene.thunder) } ?? SIMD4(0.18, 0.5, 0, 0) }
        if now >= nextFlash {
            flashStart = now
            flashBolt = Double.random(in: 0...1, using: &rng) < 0.6
            flashX = Float.random(in: 0.14...0.86, using: &rng)
            flashSeed = Float.random(in: 0...64, using: &rng)
            let count = flashBolt ? Int.random(in: 2...3, using: &rng) : 1
            var onset = 0.0
            flashStrokes = (0..<count).map { index in
                if index > 0 { onset += Double.random(in: 0.04...0.13, using: &rng) }
                return SIMD2(onset, index == 0 ? 1 : Double.random(in: 0.5...0.95, using: &rng))
            }
            let quick = Double.random(in: 0...1, using: &rng) < 0.33
            nextFlash = now + onset + (quick ? Double.random(in: 1.1...2.5, using: &rng)
                                             : Double.random(in: 2.5...8, using: &rng))
        }
        let age = now - flashStart
        guard age >= 0, let last = flashStrokes.last?.x else { return .zero }
        var channel = 0.0
        for stroke in flashStrokes {
            let a = age - stroke.x
            guard a >= 0 else { continue }
            channel = max(channel, stroke.y * min(1, a / 0.012) * exp(-max(0, a - 0.03) * 22))
        }
        let hold = last + 0.05
        let sky = (flashBolt ? 1 : 0.75) * min(1, age / 0.02) * (age < hold ? 1 : exp(-(age - hold) * 6))
        let thunder = Double(scene.thunder)
        return SIMD4(Float(sky * thunder), flashX, flashSeed, Float((flashBolt ? channel : 0) * thunder))
    }

    private func meteor(scene: SkyScene, input: Input, now: Double, still: Bool) -> (SIMD4<Float>, SIMD4<Float>) {
        guard !still, scene.starVisibility > 0.5 else { return (.zero, SIMD4(-1, 0, 0, 0)) }
        if now >= nextMeteor {
            meteorStart = now
            let x = Float.random(in: 0.25...0.95, using: &rng), y = Float.random(in: 0.04...0.28, using: &rng)
            meteorPath = SIMD4(x, y, x - Float.random(in: 0.12...0.22, using: &rng), y + Float.random(in: 0.12...0.2, using: &rng))
            nextMeteor = now + (input.meteorShower ? Double.random(in: 12...40, using: &rng) : Double.random(in: 70...160, using: &rng))
        }
        let progress = (now - meteorStart) / 0.85
        guard progress <= 1 else { return (.zero, SIMD4(-1, 0, 0, 0)) }
        return (meteorPath, SIMD4(Float(progress), scene.starVisibility, 0, 0))
    }
}
