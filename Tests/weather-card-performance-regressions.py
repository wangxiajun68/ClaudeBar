#!/usr/bin/env python3
"""Production weather scheduling and still images; invisible synthetic surfaces only."""
from pathlib import Path
import argparse
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--probe', action='store_true')
p.add_argument('--baseline-ref')
p.add_argument('--keep-fixture', type=Path)
a = p.parse_args()


def read(path):
    if a.baseline_ref and path.endswith(('AtmosphereView.swift', 'AtmosphereRenderer.swift')):
        return subprocess.check_output(['git', 'show', f'{a.baseline_ref}:{path}'], cwd=root, text=True)
    return (root / path).read_text()


def declaration(path, marker):
    source = read(path)
    start = source.index(marker)
    opening = source.index('{', start)
    end, level = opening + 1, 1
    while level:
        level += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end] + '\n'


source = 'import AppKit\nimport SwiftUI\nimport CryptoKit\n'
source += read('Sources/ClaudeBar/Utils/SkyAstronomy.swift')
source += declaration('Sources/ClaudeBar/Utils/WeatherForecastFetcher.swift', 'struct WeatherDay: Equatable, Identifiable {')
source += declaration('Sources/ClaudeBar/Utils/WeatherFetcher.swift', 'struct WeatherReading: Equatable {')
source += read('Sources/ClaudeBar/Views/Shared/WeatherReadingSky.swift')
for name in ('SkyScene', 'AtmosphereShader', 'AtmosphereRenderer', 'GreetingScript', 'AtmosphereView'):
    source += read(f'Sources/ClaudeBar/Views/Shared/Atmosphere/{name}.swift') + '\n'
source = source.replace('final class AtmosphereMTKView:', 'class AtmosphereMTKView:')

# Exercise production scene selection and the cached-reading branch with synthetic inputs.
# The small glyph/text dependencies record what the actual SwiftUI builder selects.
source += declaration('Sources/ClaudeBar/Views/Shared/GreetingInstruments.swift', 'enum PinnedSky {')
source += r'''
@MainActor enum WeatherPresentationProbe {
    static var temperatures: [Double] = []
    static var symbols: [String] = []
    static func reset() { temperatures = []; symbols = [] }
}
@MainActor struct WeatherGlyph: View {
    init(symbol: String, size: CGFloat, ink: Color, vivid: Bool) { WeatherPresentationProbe.symbols.append(symbol) }
    var body: some View { EmptyView() }
}
@MainActor struct GreetingWeatherFixture {
    var manual = false
    var manualWeather = SkyScene.Weather.thunder
    var weatherRendering = true
    var manualWeatherFetch = false
    var reading: WeatherReading?
    var focusedDay: WeatherDay?
    var weatherLoading = false
    var skyDate = Date(timeIntervalSince1970: 1_790_570_000)
    var rainbowUntil: Date? = Date(timeIntervalSince1970: 1_790_570_030)
    var astronomy = SkyAstronomy.snapshot(date: Date(timeIntervalSince1970: 1_790_570_000), latitude: 23.13, longitude: 113.26)
    func bigTemperature(_ value: Double, ink: Color) -> some View {
        WeatherPresentationProbe.temperatures.append(value); return EmptyView()
    }
    func caption(_ value: String, high: Double?, low: Double?, ink: Color) -> some View { EmptyView() }
'''
for marker in ('    private var liveWeather: Bool {', '    private func scene(for weather:',
               '    private func makeScene()', '    private static func sample(',
               '    private func conditionRow(', '    private func rainbowVisible('):
    source += declaration('Sources/ClaudeBar/Views/Shared/GreetingCard.swift', marker).replace('private ', '')
source += '}\nstruct SkyModeFixture {\nvar skyMode: String\nvar rendering: Bool\n'
for marker in ('    private var manual: Bool {', '    private var none: Bool {', '    private var selection: Int {'):
    source += declaration('Sources/ClaudeBar/Views/Shared/GreetingInstruments.swift', marker).replace('private ', '')
source += '}\n'


main = r'''
final class FixtureWindow: NSWindow {
    var shown = true
    override var occlusionState: NSWindow.OcclusionState { shown ? [.visible] : [] }
}
final class CountingSurface: AtmosphereMTKView {
    var acquisitions = 0
    var redrawRequests = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { if newValue { redrawRequests += 1 }; super.needsDisplay = newValue }
    }
    override var currentRenderPassDescriptor: MTLRenderPassDescriptor? { acquisitions += 1; return nil }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { if PROBE { print("BASELINE VIOLATION:", message) } else { fatalError(message) } }
}
func hash(_ image: CGImage) -> String {
    SHA256.hash(data: image.dataProvider!.data! as Data).map { String(format: "%02x", $0) }.joined()
}
@main struct Regression {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        GreetingScript.resourceRoot = URL(fileURLWithPath: "FONT_ROOT")

        let reading = WeatherReading(place: "fixture", temperatureC: 22, feelsLikeC: 20, conditionCode: 200,
            conditionText: "雷雨", highC: 26, lowC: 18, humidity: 70, windKph: 20, windDirection: "东南",
            isDay: true, sunrise: "06:00", sunset: "18:00", rainChance: 90,
            observedAt: Date(timeIntervalSince1970: 1_790_570_000), skyHint: .thunder)
        for manual in [false, true] {
            for picked in [SkyScene.Weather.clear, .cloudy, .overcast, .lightRain, .heavyRain, .thunder, .snow, .fog] {
                var fixture = GreetingWeatherFixture(manual: manual, manualWeather: picked, reading: reading)
                let enabled = fixture.makeScene()
                require(enabled.weather == (manual ? picked : .thunder), "Enabled auto/manual scene must retain weather")
                fixture.weatherRendering = false
                let disabled = fixture.makeScene()
                require(disabled.weather == .clear && disabled.rain == 0 && disabled.snow == 0
                    && disabled.fog == 0 && disabled.thunder == 0 && disabled.glassDrops == 0
                    && disabled.cloudCover == 0 && disabled.stars.isEmpty && disabled.starVisibility == 0,
                    "Disabled weather must remove layers even with manual weather and a cached reading")
                WeatherPresentationProbe.reset()
                _ = fixture.conditionRow(night: false, ink: .black, vivid: true)
                require(WeatherPresentationProbe.temperatures.isEmpty, "Disabled weather must hide cached temperature")
                require(WeatherPresentationProbe.symbols == [PinnedSky.sky(for: nil).symbol(night: false)], "Disabled weather must use the daylight glyph")
                require(!fixture.rainbowVisible(disabled), "Disabled weather must hide a pending rainbow")
                fixture.weatherRendering = true
                require(fixture.makeScene().weather == enabled.weather, "Re-enabling must restore the previous auto/manual weather")
                WeatherPresentationProbe.reset()
                _ = fixture.conditionRow(night: false, ink: .black, vivid: true)
                require(WeatherPresentationProbe.temperatures == [22], "Enabled weather must restore cached temperature")
            }
            let mode = SkyModeFixture(skyMode: manual ? "manual" : "auto", rendering: false)
            require(mode.none && mode.selection == 0, "Disabled preference must show selected photo mode even if manual is persisted")
        }
        var empty = GreetingWeatherFixture(weatherRendering: false)
        require(empty.makeScene().weather == .clear, "Disabled weather without cache must retain daylight")
        empty.manual = true; empty.manualWeather = .thunder; empty.manualWeatherFetch = true
        require(empty.makeScene().rain == 0, "Preview fetch policy must not bypass the disabled preference")
        print("PASS weather rendering switch: cached conditions, all manual modes, daylight layers and re-enable")
        let gpu = AtmosphereGPU.loadNow()!
        let scene = SkyScene.make(sky: .rain, rainChance: 90, windKph: 12, windDirection: "东南",
                                  astronomy: SkyAstronomy.snapshot(date: Date(timeIntervalSince1970: 1_790_570_000), latitude: 23.13, longitude: 113.26))
        let layout = GreetingTypesetter.layout("good afternoon,", name: "FIXTURE", cardWidth: 1100, skyHeight: 418, margin: 32)
        var input = AtmosphereRenderer.Input(scene: scene, layout: layout, skyHeight: 418,
                                             darkInk: scene.prefersDarkInk, darkAppearance: false, reduceMotion: false)
        let window = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 474), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = CountingSurface(gpu: gpu)
        view.renderer.input = input
        window.contentView = view
        func blocked(_ label: String) {
            let before = view.acquisitions
            let requests = view.redrawRequests
            view.kick()
            require(view.redrawRequests == requests, label + " must not enqueue redraw")
            view.draw(in: view)
            require(view.acquisitions == before, label + " must not acquire a drawable")
        }
        blocked("inactive")
        view.setActive(true)
        let before = view.acquisitions
        view.draw(in: view)
        require(view.acquisitions == before + 1, "visible active sky must draw")
        view.setHeld(true); blocked("scroll held")
        view.setHeld(false)
        window.shown = false; view.setActive(true); blocked("occluded")
        window.shown = true
        input.reduceMotion = true; view.renderer.input = input; view.setActive(true); blocked("Reduce Motion")
        input.reduceMotion = false; view.renderer.input = input; view.setActive(false); blocked("dismantled")
        window.contentView = nil; view.setActive(true); blocked("detached")

        input.reduceMotion = true
        let cache = StillCache()
        let size = CGSize(width: 1100, height: 474)
        var daylightInput = input
        daylightInput.scene = empty.makeScene()
        let daylightRenderer = AtmosphereRenderer(gpu: gpu)
        daylightRenderer.input = daylightInput
        let daylight = daylightRenderer.snapshot(size: size, scale: 1)!
        daylightInput.scene.cloudDarkness = 0.9
        daylightInput.scene.windSpeed = 90
        daylightRenderer.input = daylightInput
        let windyDaylight = daylightRenderer.snapshot(size: size, scale: 1)!
        require(hash(daylight) == hash(windyDaylight), "Zero cloud cover must suppress both cirrus and cloud deck in the production shader")
        print("PASS disabled weather shader: no residual cloud layers")
        if CommandLine.arguments.contains("--profile") {
            for i in 0..<180 {
                PROFILE_RENDER
                try await Task.sleep(for: .milliseconds(20))
            }
            return
        }
        let sync = cache.image(input: input, size: size, scale: 2)!
        print("SNAPSHOT_SHA256", hash(sync))
        var durations: [Double] = []
        for i in 0..<20 {
            let start = CACurrentMediaTime()
            _ = cache.image(input: input, size: CGSize(width: 1100 + i, height: 474), scale: 2)
            durations.append((CACurrentMediaTime() - start) * 1000)
        }
        print("SYNC_SNAPSHOT_MEDIAN_MS", durations.sorted()[10])
        ASYNC_CHECKS
        print("PASS weather card draw lifecycle and production snapshot")
    }
}
'''
asynchronous = 'func update(_ request: Request)' in source
main = main.replace('PROBE', 'true' if a.probe else 'false').replace('FONT_ROOT', str(root / 'Sources/Fonts'))
main = main.replace('ASYNC_CHECKS', r'''
        let live = StillCache()
        let request = StillCache.Request(input: input, size: size, scale: 2, active: true)
        await live.update(request)
        require(live.readyImage != nil && hash(live.readyImage!) == hash(sync), "async still must match preview pixels")
        let held = live.readyImage!
        await live.update(.init(input: input, size: CGSize(width: 620, height: 436), scale: 2, active: false))
        require(live.readyImage === held, "inactive still must hold the previous frame")
        let cancelled = Task { await live.update(.init(input: input, size: CGSize(width: 800, height: 436), scale: 2, active: true)) }
        cancelled.cancel(); await cancelled.value
        require(live.readyImage === held, "cancelled still must not publish")
        await live.update(.init(input: input, size: CGSize(width: 620, height: 436), scale: 2, active: true))
        require(live.readyImage?.width == 1240 && live.readyImage?.height == 872, "resumed still must use latest dimensions")
''' if asynchronous else '')
main = main.replace('PROFILE_RENDER', r'''
                await cache.update(.init(input: input, size: CGSize(width: 1100 + i % 3, height: 474), scale: 2, active: true))
''' if asynchronous else '_ = cache.image(input: input, size: CGSize(width: 1100 + i % 3, height: 474), scale: 2)')

# Exercise queue ownership with a deliberately blocked backend. The cache and
# cancellation bridge are production declarations, not a copied state machine.
worker_fixture = r'''
import AppKit
import SwiftUI
enum Backend {
    static let lock = NSLock()
    static let release = DispatchSemaphore(value: 0)
    static var calls: [Int] = []
    static var mainThread = false
    static var running = 0
    static var maximum = 0
    static var failures = 1
    static var count: Int { lock.withLock { calls.count } }
}
final class AtmosphereGPU: @unchecked Sendable {
    @MainActor static let shared: AtmosphereGPU? = AtmosphereGPU()
}
final class AtmosphereRenderer {
    struct Input: Equatable { let id: Int }
    var input: Input?
    init(gpu: AtmosphereGPU) {}
    func snapshot(size: CGSize, scale: CGFloat) -> CGImage? {
        let id = input!.id
        Backend.lock.withLock {
            Backend.calls.append(id)
            Backend.mainThread = Backend.mainThread || Thread.isMainThread
            Backend.running += 1
            Backend.maximum = max(Backend.maximum, Backend.running)
        }
        defer { Backend.lock.withLock { Backend.running -= 1 } }
        if id == 1 { Backend.release.wait() }
        if id == 5, Backend.lock.withLock({ if Backend.failures > 0 { Backend.failures -= 1; return true }; return false }) { return nil }
        let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()
    }
}
CACHE
@main struct WorkerRegression {
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        precondition(condition(), "Worker did not arrive")
    }
    @MainActor static func main() async {
        let cache = StillCache()
        func request(_ id: Int, active: Bool = true) -> StillCache.Request {
            .init(input: .init(id: id), size: CGSize(width: id * 10, height: 20), scale: 2, active: active)
        }
        let first = Task { await cache.update(request(1)) }
        await waitUntil { Backend.count == 1 }
        let second = Task { await cache.update(request(2)) }
        let third = Task { await cache.update(request(3)) }
        try? await Task.sleep(for: .milliseconds(20))
        first.cancel(); second.cancel(); third.cancel()
        let latest = Task { await cache.update(request(4)) }
        try? await Task.sleep(for: .milliseconds(20))
        Backend.release.signal()
        await first.value; await second.value; await third.value; await latest.value
        precondition(Backend.calls == [1, 4], "Cancelled queued sizes must not render")
        precondition(!Backend.mainThread && Backend.maximum == 1, "Snapshot waits must use a single background worker")
        precondition(cache.readyImage?.width == 80, "Only the latest result may publish")
        let image = cache.readyImage!
        await cache.update(request(4))
        await cache.update(request(6, active: false))
        precondition(Backend.count == 2 && cache.readyImage === image, "Cache hits and hidden stills must do no work")
        await cache.update(request(5))
        precondition(cache.readyImage === image, "Failed snapshots must retain the valid frame")
        await cache.update(request(5))
        precondition(Backend.calls == [1, 4, 5, 5] && cache.readyImage?.width == 100, "A failed key must be retried")
        await cache.update(.init(input: .init(id: 7), size: .zero, scale: 2, active: true))
        precondition(Backend.count == 4, "Zero geometry must not render")
        print("PASS production still worker background ownership, cancellation, cache and failure retry")
    }
}
'''
if asynchronous:
    cache_source = read('Sources/ClaudeBar/Views/Shared/Atmosphere/AtmosphereView.swift')
    worker_fixture = worker_fixture.replace('CACHE', cache_source[cache_source.index('@Observable @MainActor private final class StillCache'):])

raster_method = declaration('Sources/ClaudeBar/Views/Shared/Atmosphere/AtmosphereRenderer.swift', '    private func finishRasterizing(').replace('private func', 'func', 1)
raster_fixture = r'''
import Foundation
import CoreGraphics
struct TextJob { let key: Int; let layout: Layout }
struct Layout { let textureFrame: CGRect }
struct Rasterized { let texture: Int? }
struct Input { let reduceMotion: Bool }
final class Fixture {
    var rasterizing: Int? = 1
    var requested: TextJob? = TextJob(key: 2, layout: Layout(textureFrame: .zero))
    var input: Input? = Input(reduceMotion: false)
    var installed: [Int] = []
    var starts = 0
    var notifications = 0
    lazy var textDidChange: (() -> Void)? = { self.notifications += 1 }
    func install(_ texture: Int?, frame: CGRect, key: Int, reduceMotion: Bool) { installed.append(key) }
    func startRasterizing() { starts += 1; rasterizing = requested?.key }
    METHOD
}
@main struct RasterRegression {
    static func main() {
        let fixture = Fixture()
        fixture.finishRasterizing(.init(key: 1, layout: .init(textureFrame: .zero)), result: .init(texture: 1))
        let obsoletePublished = !fixture.installed.isEmpty || fixture.notifications != 0
        if PROBE { print("OBSOLETE_RASTER_PUBLISHED", obsoletePublished) }
        else { precondition(!obsoletePublished, "Obsolete raster must not install or wake a hidden view") }
        precondition(fixture.rasterizing == 2 && fixture.starts == 1)
        fixture.finishRasterizing(.init(key: 2, layout: .init(textureFrame: .zero)), result: .init(texture: 2))
        precondition(fixture.requested == nil && fixture.installed.last == 2)
        fixture.requested = nil
        let before = fixture.notifications
        fixture.finishRasterizing(.init(key: 3, layout: .init(textureFrame: .zero)), result: .init(texture: 3))
        precondition(fixture.notifications == before, "Removed greeting must ignore pending raster")
        print("PASS production text raster supersession")
    }
}
'''.replace('METHOD', raster_method).replace('PROBE', 'true' if a.probe else 'false')
with tempfile.TemporaryDirectory(prefix='claudebar-weather-') as temporary:
    out = a.keep_fixture or Path(temporary)
    out.mkdir(parents=True, exist_ok=True)
    path = out / 'Weather.swift'
    path.write_text(source + main)
    binary = out / 'weather'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    for name, fixture in [('raster', raster_fixture)] + ([('worker', worker_fixture)] if asynchronous else []):
        path = out / (name + '.swift')
        path.write_text(fixture)
        binary = out / name
        subprocess.run(['swiftc', '-O', '-parse-as-library', str(path), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
