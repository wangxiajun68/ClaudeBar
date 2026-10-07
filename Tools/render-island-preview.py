#!/usr/bin/env python3
"""Render the production notch island in its three states, both themes.

Every declaration below is taken out of the app's own Swift sources, so a PNG
cannot drift from what the island actually draws; the store layer is replaced by
synthetic value snapshots and an inert `AppPreferences`, and nothing under
`Sources/` is written. No `~/.claude`, no `~/.codex`, no network, no persisted
preferences.

`NotchIslandView` is taken nearly whole — only its `body`'s two `AppPreferences`
`onReceive`s and the `@State` seed they drive are stripped, because the island
never reads that preference for anything the picture shows.

The island is *black in both themes* — it sits on the hardware notch — so the
two output files differ only in the panel the island is pasted onto and the ink
`ProductBrandMark` picks, not in the island itself. `--check` reads every
production slice and compiles the generated probe, then stops before the launch:
it fails loudly on a declaration that moved and on a slice set that no longer
forms a program. The render itself uses a hosting-view snapshot rather than
`ImageRenderer` because the expanded session grid is a real `ScrollView`, whose
content `ImageRenderer` does not lay out.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = root / '.build/island-preview'
out.mkdir(parents=True, exist_ok=True)

CHECK = '--check' in sys.argv


def declaration(path, start):
    """The brace-balanced declaration beginning at `start`, or a loud failure.

    A preview that cannot find the declaration it needs has to render *nothing*
    and say so: the alternative is a stale copy that keeps producing a plausible
    PNG while the app has moved on (exactly the drift this renderer exists to
    catch).
    """
    text = (root / path).read_text()
    pos = text.find(start)
    if pos == -1:
        raise SystemExit(f"render-island-preview: {start!r} not found in {path} — "
                         "the production declaration moved or was renamed")
    opening = text.index('{', pos)
    level = 1
    end = opening + 1
    while level:
        level += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[pos:end] + "\n"


def file_from(path, start=None, end=None):
    """A whole file, or a `[start, end)` slice of one, with existence checks."""
    try:
        text = (root / path).read_text()
    except OSError:
        raise SystemExit(f'render-island-preview: {path} is missing — the slice list is stale')
    if start is None:
        return text + "\n"
    pos = text.find(start)
    if pos == -1:
        raise SystemExit(f"render-island-preview: {start!r} not found in {path}")
    stop = text.find(end, pos) if end else len(text)
    if stop == -1:
        raise SystemExit(f"render-island-preview: {end!r} not found after {start!r} in {path}")
    return text[pos:stop] + "\n"


# The island draws product artwork; a missing asset silently becomes the
# instrument-glyph fallback and every render check still passes.
brand_marks = root / 'Sources/BrandAssets'
for mark in ('anthropic', 'openai', 'cursor'):
    for variant in ('light', 'dark'):
        assert (brand_marks / f'{mark}-{variant}.png').is_file(), \
            f'{mark}-{variant}.png missing — ProductBrandMark would draw its fallback'

source = "import SwiftUI\nimport AppKit\n"
source += 'let brandMarkRoot = URL(fileURLWithPath: "' + str(brand_marks) + '")\n'
source += "import Combine\n"

# --- Foundation scalars the island reads -------------------------------------
source += declaration('Sources/ClaudeBar/Theme/Theme.swift', 'extension Color {')
source += declaration('Sources/ClaudeBar/Theme/Theme.swift', 'enum Theme {')
source += declaration('Sources/ClaudeBar/Models/ModelUsage.swift', 'enum UsageSource: String, CaseIterable, Identifiable {')
source += declaration('Sources/ClaudeBar/Models/ModelUsage.swift', 'struct DayUsage: Identifiable, Equatable {')
source += declaration('Sources/ClaudeBar/Models/ModelUsage.swift', 'struct ModelUsage: Identifiable, Hashable {')
source += declaration('Sources/ClaudeBar/Models/ModelUsage.swift', 'enum UsagePeriod: String, CaseIterable, Identifiable {')
source += declaration('Sources/ClaudeBar/Models/Provider.swift', 'struct ModelConfig')
source += declaration('Sources/ClaudeBar/Models/Provider.swift', 'struct Provider')
source += declaration('Sources/ClaudeBar/Models/AppPreferences.swift', 'enum TokenUnitStyle: String {')
source += declaration('Sources/ClaudeBar/Utils/UsageStats.swift', 'struct UsageStats {')
# The token formatter `UsageStats.formatTokens` delegates to (the slice above
# names it).
source += declaration('Sources/ClaudeBar/Utils/TokenMagnitude.swift', 'enum TokenMagnitude {')

# --- Codex quota window (the alert's quota path and the popup's gauges) -------
source += declaration('Sources/ClaudeBar/Utils/CodexQuotaFetcher.swift', 'struct CodexQuotaWindow: Equatable, Identifiable {')

# --- Price table + costing ---------------------------------------------------
source += declaration('Sources/ClaudeBar/Utils/ModelPricing.swift', 'enum CostDisplay: String, CaseIterable, Identifiable {')
source += declaration('Sources/ClaudeBar/Utils/ModelPricing.swift', 'enum ModelPricing {')
source += (root / 'Sources/ClaudeBar/Utils/ModelPriceTable.swift').read_text().replace(
    'private typealias R = ModelPricing.Rate', 'typealias R = ModelPricing.Rate') + '\n'

# --- Geometry + island value types -------------------------------------------
source += declaration('Sources/ClaudeBar/Utils/NotchGeometry.swift', 'struct NotchGeometry: Equatable {')
source += declaration('Sources/ClaudeBar/NotchIslandController.swift', 'final class NotchIslandState: ObservableObject {')
source += file_from('Sources/ClaudeBar/Models/IslandLiveModel.swift',
                    start='enum IslandAlert: Equatable, Identifiable {',
                    end='/// Feeds the notch island from the stores')

# --- Shared drawing pieces the island composes --------------------------------
source += file_from('Sources/ClaudeBar/Views/Shared/ProductBrandMark.swift',
                    end='/// The client mark a `StatusPill` can lead with')
# The island's own pieces, whole files.
source += declaration('Sources/ClaudeBar/Theme/Theme.swift', 'struct AppGlyph: View {')
source += file_from('Sources/ClaudeBar/Views/Shared/SignatureGlyph.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/DecorativeMotion.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/LucideHardwareGeometry.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/LucideHardwarePaths.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/InstrumentGlyph.swift')
source += file_from('Sources/ClaudeBar/Views/Island/IslandShape.swift')
source += file_from('Sources/ClaudeBar/Views/Island/IslandComponents.swift')

# `Interaction.swift` carries `rollingNumber` and the `RollingNumberText` the
# island's figures use; the action-button section is popup-only and is dropped.
_interaction = (root / 'Sources/ClaudeBar/Views/Shared/Interaction.swift').read_text()
source += _interaction[:_interaction.index('// MARK: - Action buttons')] + '\n'
source += _interaction[_interaction.index('// MARK: - HoverState'):] + '\n'

# --- The production island view, with its preferences stripped out -----------
# `NotchIslandView`'s `body` is the only thing that reads `AppPreferences` (a
# `@State` seed and two `onReceive`s). Everything else about the view — the
# morph, the wings, the alert strip, the expanded header + session grid + usage
# card — is untouched, so replacing the body (and that one property) keeps the
# drawing identical while letting the fixture compile with an inert preferences
# stub. If the body stops looking like this the slice changes and the compile
# fails, which is the point.
_island = (root / 'Sources/ClaudeBar/Views/Island/NotchIslandView.swift').read_text()
PREF_SEED = '    @State private var tokenStyle = AppPreferences.shared.tokenUnitStyle\n'
PREF_BODY = '''    var body: some View {
        island
            .frame(width: IslandStyle.panelSize.width, height: IslandStyle.panelSize.height, alignment: .top)
            .environment(\\.colorScheme, .dark)
            .onReceive(AppPreferences.shared.$tokenUnitStyle.removeDuplicates()) { tokenStyle = $0 }
            .onReceive(AppPreferences.shared.$vpnEnabled.removeDuplicates()) { vpnEnabled = $0 }
    }
'''
BODY_REPLACEMENT = '''    private var fixtureTokenStyle: TokenUnitStyle { AppPreferences.shared.tokenUnitStyle }

    var body: some View {
        island
            .frame(width: IslandStyle.panelSize.width, height: IslandStyle.panelSize.height, alignment: .top)
            .environment(\\.colorScheme, .dark)
    }

    private var tokenStyle: TokenUnitStyle { fixtureTokenStyle }
'''
if PREF_SEED not in _island or PREF_BODY not in _island:
    raise SystemExit("render-island-preview: NotchIslandView.body no longer matches the "
                     "shape this renderer strips preferences out of — update the slice")
_island = _island.replace(PREF_SEED, '').replace(PREF_BODY, BODY_REPLACEMENT)
# `reduceMotion` is read by no island code path (the orbit gates on its own
# environment value), but the property must still resolve.
source += _island + '\n'

# --- The fixture: a synthetic model, an inert preferences stub ---------------
source += '''
// MARK: - Fixture stand-ins (synthetic; no store, no disk, no network).

/// `AppPreferences` is `@Observable` in the app and reads/writes real defaults.
/// The island asks it for the token style, the VPN flag, the currency display
/// and (through `ExchangeRate.effectiveRate`) the manual rate — nothing else.
/// `isDark` is set per render by the probe.
final class AppPreferences: ObservableObject, @unchecked Sendable {
    static let shared = AppPreferences()
    var isDark = false
    var tokenUnitStyle: TokenUnitStyle = .chinese
    var vpnEnabled = true
    /// `@Published` because the island's two money rows subscribe to it
    /// (`$costDisplay`), exactly as they do in the app.
    @Published var costDisplay: CostDisplay = .split
}

/// `ExchangeRate` reduced to the one member the island's money rows read
/// (`fx.effectiveRate`): a fixed rate, no fetch, no defaults.
final class ExchangeRate: ObservableObject {
    static let shared = ExchangeRate()
    var effectiveRate: Double? { 7.12 }
}
private struct SurfaceVisibleKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var surfaceIsVisible: Bool {
        get { self[SurfaceVisibleKey.self] }
        set { self[SurfaceVisibleKey.self] = newValue }
    }
}

/// The store-facing model, frozen. `IslandLiveModel` in the app is fed by
/// `ProviderStore`; here every published value is set once from synthetic data.
final class IslandLiveModel: ObservableObject {
    @Published var sessions: [IslandSession] = []
    @Published var sessionCosts: [String: ModelPricing.Estimate] = [:]
    @Published var usage = IslandUsage()
    @Published var claudeRoute = ""
    @Published var codexRoute = ""
    @Published var vpnRunning = false
    var busySessions: [IslandSession] { sessions.filter(\\.isBusy) }
}

extension NotchGeometry {
    init(size: CGSize, hasHardwareNotch: Bool, screenFrame: CGRect) {
        self.size = size
        self.hasHardwareNotch = hasHardwareNotch
        self.screenFrame = screenFrame
    }
}

// MARK: - Synthetic snapshots

func fixtureSessions() -> [IslandSession] {
    let now = Date()
    return [
        IslandSession(id: "claude:1", agent: .claude, project: "ClaudeBar", activity: "Bash · build.sh",
                      model: "deepseek-v4.1-flash", isBusy: true, contextRatio: 0.62,
                      updatedAt: now.addingTimeInterval(-4), cwd: "/Users/x/Project/ClaudeBar",
                      sessionId: "4f3a", completionID: "t1|a"),
        IslandSession(id: "codex:2", agent: .codex, project: "api", activity: "Read · routes.ts",
                      model: "gpt-6-astra", isBusy: true, contextRatio: 0.12,
                      updatedAt: now.addingTimeInterval(-12), cwd: "/Users/x/Project/api",
                      sessionId: "9c1d", completionID: "turn-3"),
        IslandSession(id: "claude:3", agent: .claude, project: "api-server", activity: "",
                      model: "deepseek-v4.1-flash", isBusy: false, contextRatio: 0.08,
                      updatedAt: now.addingTimeInterval(-620), cwd: "/Users/x/Project/api-server",
                      sessionId: "77ab"),
        IslandSession(id: "cursor:4", agent: .cursor, project: "cursor", activity: "",
                      model: "claude-opus-4-6", isBusy: false, contextRatio: 0.40,
                      updatedAt: now.addingTimeInterval(-130), cwd: "/Users/x/Project/cursor",
                      sessionId: "composer-1"),
    ]
}

func fixtureCost(_ cny: Double, _ usd: Double) -> ModelPricing.Estimate {
    var estimate = ModelPricing.Estimate()
    var cost = ModelPricing.Cost()
    cost.cny = cny
    cost.usd = usd
    estimate.cost = cost
    estimate.lines = [ModelPricing.Estimate.Line(model: "deepseek-v4.1-flash", cost: cost, unpriced: nil)]
    return estimate
}

func fixtureUsage() -> IslandUsage {
    var usage = IslandUsage()
    usage.today = 312_000_000
    usage.todayCalls = 1_204
    usage.todayCost = fixtureCost(128.40, 0)
    usage.yesterday = 278_000_000
    usage.month = 3_390_000_000
    usage.lastMonthSameSpan = 3_420_000_000
    usage.monthBySource = [1_470_000_000, 1_740_000_000, 180_000_000]
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    // 30 days, oldest first; a shape with a quiet weekend dip and a spike.
    let shares: [Double] = [0.30, 0.44, 0.58, 0.35, 0.22, 0.61, 0.72, 0.40, 0.33, 0.52,
                            0.66, 0.48, 0.29, 0.37, 0.55, 0.70, 0.83, 0.46, 0.31, 0.42,
                            0.60, 0.75, 0.88, 0.52, 0.34, 0.47, 0.64, 0.79, 0.95, 1.00]
    usage.days = (0..<30).reversed().map { offset in
        let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
        let index = 29 - offset
        let tokens = Int(312_000_000 * shares[index])
        return IslandDay(date: date, tokens: tokens, cost: fixtureCost(Double(tokens) / 2_400_000, 0))
    }
    return usage
}
'''
source += r'''
// MARK: - Probe

/// The island root, hosted the way the app hosts it (a fixed transparent panel
/// at a notch-sized frame) but fed a fixture model. The state object is built
/// *outside* `body` so the probe's own writes are what the view reads.
struct IslandProbe: View {
    @ObservedObject var state: NotchIslandState
    @ObservedObject var model: IslandLiveModel
    let target: CGSize

    var body: some View {
        NotchIslandView(state: state, model: model,
                        actions: IslandActions(openSession: { _ in }, openMainWindow: {},
                                               expandFromAlert: {}, dismissAlert: {}))
            // Crop to the black shape: the PNG should be the surface, not the
            // fixed transparent panel it morphs inside.
            .frame(width: target.width, height: target.height, alignment: .top)
            .padding(EdgeInsets(top: 26, leading: 30, bottom: 30, trailing: 30))
    }
}

@main struct Probe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        ProductBrandMark.resourceRoot = brandMarkRoot
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let notch = CGSize(width: 200, height: 46)
        let geometry = NotchGeometry(size: notch, hasHardwareNotch: true,
                                     screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let sessions = fixtureSessions()
        let usage = fixtureUsage()
        let finished = IslandAlert.finished(sessions[0])
        let scenes: [(String, NotchIslandState.Mode, IslandAlert?)] = [
            ("collapsed", .collapsed, nil),
            ("alert", .alert, finished),
            ("expanded", .expanded, nil),
        ]
        // A hosting-view snapshot, not `ImageRenderer`: the session grid is a
        // real `ScrollView`, and `ImageRenderer` lays none of its content out —
        // it would publish an expanded island with an empty session lane and no
        // error. The busy orbit is an `NSViewRepresentable` and needs a live
        // window for the same reason. This is the one deviation from the other
        // preview tools, and it exists so the picture matches the surface.
        for dark in [false, true] {
            AppPreferences.shared.isDark = dark
            for (name, mode, alert) in scenes {
                let state = NotchIslandState(geometry: geometry, showsWings: true)
                state.mode = mode
                state.alert = alert
                let model = IslandLiveModel()
                model.sessions = sessions
                model.usage = usage
                model.vpnRunning = true
                model.claudeRoute = "DeepSeek · v4"
                model.codexRoute = "OpenAI · gpt-6-astra"
                model.sessionCosts = ["claude:1": fixtureCost(34.20, 0),
                                      "codex:2": fixtureCost(18.60, 2.10),
                                      "claude:3": fixtureCost(6.40, 0)]
                // The crop is the state's own `islandSize` — the one formula
                // the panel uses. The tool used to re-implement all three
                // branches here, so a changed `IslandStyle` constant cropped
                // the PNG to the old rectangle while `--check` still passed
                // (finding 747). `showsWings` matches the state built above.
                let target = state.islandSize
                let view = IslandProbe(state: state, model: model, target: target)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Theme.bgPrimary)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: target.width + 60, height: target.height + 56)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.35))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    fatalError("render failed: \(name)")
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    fatalError("PNG encode failed: \(name)")
                }
                try png.write(to: out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                window.orderOut(nil)
            }
        }
        print("Rendered island preview to \(out.path)")
    }
}
'''

path = out / 'Probe.swift'
path.write_text(source)
binary = out / 'probe'
subprocess.run(['/usr/bin/swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                str(path), '-o', str(binary)], check=True)
if CHECK:
    # `--check` runs every declaration lookup and the compile, and stops before
    # the launch — the only step that needs a window server. Returning before
    # the sources were read (the old shape) passed on a tree whose probe could
    # not compile at all.
    print('render-island-preview: --check: declarations present and the probe compiles')
else:
    subprocess.run([str(binary), str(out)], check=True)
