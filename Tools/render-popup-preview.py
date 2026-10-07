#!/usr/bin/env python3
"""Render the production menu-bar popup at its real 460pt width, both themes.

The popup is rendered directly from the production Swift sources. Every type
below is sliced out of the app's own Swift sources (the same
`declaration(path, start)` pattern `render-greeting-preview.py` uses) so the PNG
cannot drift; only the store layer is replaced, by inert stand-ins fed synthetic
data. No `~/.claude`, no `~/.codex`, no network, no preference writes.

Two subviews of the real `MenuBarView` are **not** drawn, because they cannot be
reached without touching `Sources/` and without live hardware:

  * `MachineKpiStrip` — reads `ProcessSampler.shared.host` (SMC/`vm_statistics`),
    `FanMonitor.shared` (SMC fan keys) and `AudioAccessoryMonitor.shared`. Its
    four values (`CPU 48% · GPU 44% · 内存 15.2G · 风扇 2977`) are rendered by a
    fixture strip drawn to the same geometry (`EqualRowGrid`, 62pt cells) so the
    popup's own rhythm is intact, but the production view is not the thing on
    screen and the figures are synthetic.
  * `PowerFlowCard` — needs `ProcessSampler.HostStats`'s SMC power readings
    (adapter/system/battery watts) plus the Core Animation `SankeyWaveLayer`;
    omitted entirely.

`CompactBatteryChargeControl` (conditional in the production action bar on
`ProcessSampler.shared.host.batteryInstalled`) is not drawn either: the stub
sampler cannot read the SMC, so the bar sits in its no-battery shape.

Everything else (`PanelHeader` with its status row and three switcher chips,
`SessionsPanelView` with real session cards, `UsagePanel`, the `IconChipRow`
action bar) is the production view code.

`--check` reads every production slice and compiles the generated probe, then
stops before the launch: it catches a declaration that moved and a slice set that
no longer forms a program, which is the work a maintainer would otherwise do by
eye after touching `Sources/`.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = root / '.build/popup-preview'
out.mkdir(parents=True, exist_ok=True)

CHECK = '--check' in sys.argv


def declaration(path, start):
    text = (root / path).read_text()
    pos = text.find(start)
    if pos == -1:
        raise SystemExit(f"render-popup-preview: {start!r} not found in {path} — "
                         "the production declaration moved or was renamed")
    opening = text.index('{', pos)
    level = 1
    end = opening + 1
    while level:
        level += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[pos:end] + "\n"


def indent(text, prefix='    '):
    return ''.join(prefix + line if line.strip() else line for line in text.splitlines(True))


def file_from(path, start=None, end=None):
    try:
        text = (root / path).read_text()
    except OSError:
        raise SystemExit(f"render-popup-preview: {path} is missing — the slice list is stale")
    if start is None:
        return text + "\n"
    pos = text.find(start)
    if pos == -1:
        raise SystemExit(f"render-popup-preview: {start!r} not found in {path}")
    stop = text.find(end, pos) if end else len(text)
    if stop == -1:
        raise SystemExit(f"render-popup-preview: {end!r} not found after {start!r} in {path}")
    return text[pos:stop] + "\n"


brand_marks = root / 'Sources/BrandAssets'
for mark in ('anthropic', 'openai', 'cursor'):
    for variant in ('light', 'dark'):
        assert (brand_marks / f'{mark}-{variant}.png').is_file(), \
            f'{mark}-{variant}.png missing — ProductBrandMark would draw its fallback'

source = "import SwiftUI\nimport AppKit\nimport Combine\n"
source += 'let brandMarkRoot = URL(fileURLWithPath: "' + str(brand_marks) + '")\n'

# --- Theme + foundation ------------------------------------------------------
source += declaration('Sources/ClaudeBar/Theme/Theme.swift', 'extension Color {')
source += declaration('Sources/ClaudeBar/Theme/Theme.swift', 'enum Theme {')
# The build's own identity: `FilePaths` and the Codex scanner read
# `BuildChannel.allowsSystemIntegration`, so the probe compiles the real file
# (dev channel — no macro at all, which is the fallback it documents).
source += file_from('Sources/Shared/BuildChannel.swift')
# The token formatter `UsageStats.formatTokens` delegates to.
source += declaration('Sources/ClaudeBar/Utils/TokenMagnitude.swift', 'enum TokenMagnitude {')
source += declaration('Sources/ClaudeBar/Models/ModelUsage.swift', 'enum UsageSource: String, CaseIterable, Identifiable {')
source += declaration('Sources/ClaudeBar/Models/ModelUsage.swift', 'struct DayUsage: Identifiable, Equatable {')
source += declaration('Sources/ClaudeBar/Models/ModelUsage.swift', 'struct ModelUsage: Identifiable, Hashable {')
source += declaration('Sources/ClaudeBar/Models/ModelUsage.swift', 'struct TodayUsage: Equatable {')
source += declaration('Sources/ClaudeBar/Models/ModelUsage.swift', 'enum UsagePeriod: String, CaseIterable, Identifiable {')
source += declaration('Sources/ClaudeBar/Models/AppPreferences.swift', 'enum TokenUnitStyle: String {')
source += declaration('Sources/ClaudeBar/Models/AppPreferences.swift', 'enum AppearanceMode: String, CaseIterable, Identifiable {')
source += declaration('Sources/ClaudeBar/Utils/UsageStats.swift', 'struct UsageStats {')
source += declaration('Sources/ClaudeBar/Utils/CodexQuotaFetcher.swift', 'struct CodexQuotaWindow: Equatable, Identifiable {')

# --- Providers (values) ------------------------------------------------------
source += declaration('Sources/ClaudeBar/Models/Provider.swift', 'struct ModelConfig: Codable, Identifiable, Equatable {')
source += declaration('Sources/ClaudeBar/Models/Provider.swift', 'struct Provider: Codable, Identifiable, Equatable {')
source += declaration('Sources/ClaudeBar/Models/Preset.swift', 'struct EnvConfig: Codable, Equatable {')
source += declaration('Sources/ClaudeBar/Models/CodexProvider.swift', 'struct CodexModelConfig: Codable, Identifiable, Equatable {')
source += declaration('Sources/ClaudeBar/Models/CodexProvider.swift', 'struct CodexProvider: Codable, Identifiable, Equatable {')

# --- The real FilePaths ------------------------------------------------------
source += declaration('Sources/ClaudeBar/Utils/FilePaths.swift', 'enum FilePaths {')

# --- Sessions (values) -------------------------------------------------------
source += declaration('Sources/ClaudeBar/Utils/WorkflowMonitor.swift', 'enum WorkflowStatus: String {')
source += declaration('Sources/ClaudeBar/Utils/SessionMonitor.swift', 'struct SessionInfo: Identifiable, Equatable {')
source += declaration('Sources/ClaudeBar/Utils/SessionMonitor.swift', 'enum SessionStatus: String {')
source += declaration('Sources/ClaudeBar/Utils/SessionMonitor.swift', 'enum SubagentStatus: String {')
source += declaration('Sources/ClaudeBar/Utils/SessionMonitor.swift', 'struct SubagentInfo: Identifiable, Equatable {')
source += declaration('Sources/ClaudeBar/Utils/SessionMonitor.swift', 'struct WorkflowInfo: Identifiable, Equatable {')
source += declaration('Sources/ClaudeBar/Utils/SessionTitle.swift', 'struct SessionTitle: Equatable {')
source += declaration('Sources/ClaudeBar/Utils/CursorSessionMonitor.swift', 'struct CursorSessionInfo: Identifiable, Equatable {')
source += declaration('Sources/ClaudeBar/Utils/CursorSessionMonitor.swift', 'enum CursorStatus: String {')
source += declaration('Sources/ClaudeBar/Utils/CursorSessionMonitor.swift', 'enum CursorSubagentStatus: String, Equatable {')
source += declaration('Sources/ClaudeBar/Utils/CursorSessionMonitor.swift', 'struct CursorSubagentInfo: Identifiable, Equatable {')
source += declaration('Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift', 'struct ExternalSessionInfo: Identifiable, Equatable {')
source += declaration('Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift', 'enum ExternalAgentKind: String, CaseIterable {')

# --- Pricing + Cursor readings ----------------------------------------------
source += declaration('Sources/ClaudeBar/Utils/ModelPricing.swift', 'enum CostDisplay: String, CaseIterable, Identifiable {')
source += declaration('Sources/ClaudeBar/Utils/ModelPricing.swift', 'enum ModelPricing {')
source += (root / 'Sources/ClaudeBar/Utils/ModelPriceTable.swift').read_text().replace(
    'private typealias R = ModelPricing.Rate', 'typealias R = ModelPricing.Rate') + '\n'
source += '''
/// `CursorUsageFetcher` owns the network probe in the app; the fixture keeps
/// only its two value types, which is all the popup reads.
enum CursorUsageFetcher {
'''
source += indent(declaration('Sources/ClaudeBar/Utils/CursorUsageFetcher.swift', 'struct PlanUsage: Equatable, Codable {'))
source += indent(declaration('Sources/ClaudeBar/Utils/CursorUsageFetcher.swift', 'struct GrokUsage: Equatable, Codable {'))
source += '''
    static func money(_ cents: Double) -> String {
        let dollars = cents / 100
        let whole = dollars.rounded() == dollars
        return "$" + dollars.formatted(.number.precision(.fractionLength(whole ? 0 : 2)))
    }
}
'''

# --- Shared visuals ----------------------------------------------------------
_theme = (root / 'Sources/ClaudeBar/Theme/Theme.swift').read_text()
source += _theme[_theme.index('struct PanelCardModifier: ViewModifier {'):] + '\n'
source += file_from('Sources/ClaudeBar/Views/Shared/SignatureGlyph.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/DecorativeMotion.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/LucideHardwareGeometry.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/LucideHardwarePaths.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/InstrumentGlyph.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/ProductBrandMark.swift',
                    end='/// The client mark a `StatusPill` can lead with')
source += file_from('Sources/ClaudeBar/Views/Shared/CodexModelMark.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/ContextBar.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/HeartbeatSparkline.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/StandbyEmptyState.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/SectionHeader.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/FeedbackToast.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/SessionCardView.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/CursorSessionCardView.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/ExternalSessionCardView.swift')
source += file_from('Sources/ClaudeBar/Views/Shared/CodexCleanupDialog.swift')
# `SessionLoadChip`/`HardwareSiliconMark` live in `ResourceStrip.swift`; the
# strip's other readers need the sampler, so take the two pieces the cards use.
_resource = (root / 'Sources/ClaudeBar/Views/Shared/ResourceStrip.swift').read_text()
source += _resource[_resource.index('/// One-line CPU / memory for a tracked session'):_resource.index('/// Dashboard / sessions pages need attribution sampling while visible.')] + '\n'
# `Tile.swift` up to the metric-tile section: modifiers, `EqualRowGrid`, grids.
_tile = (root / 'Sources/ClaudeBar/Views/Shared/Tile.swift').read_text()
source += _tile + '\n'
source += file_from('Sources/ClaudeBar/Views/Shared/UiverseSurfaces.swift').replace('private struct SegmentedItem', 'struct SegmentedItem')
source += file_from('Sources/ClaudeBar/Views/Shared/AgentSwarmView.swift')
_controls = (root / 'Sources/ClaudeBar/Views/Shared/InstrumentControls.swift').read_text()
source += _controls[: _controls.index("// MARK: - The page band's own control")] + '\n'
source += file_from('Sources/ClaudeBar/Views/Shared/CodexQuotaGauges.swift')
_interaction = (root / 'Sources/ClaudeBar/Views/Shared/Interaction.swift').read_text()
source += _interaction[:_interaction.index('// MARK: - Action buttons')] + '\n'
source += _interaction[_interaction.index('// MARK: - HoverState'):] + '\n'

# --- VPN chrome: the status pill, the Cursor panel, the delay style ----------
source += file_from('Sources/ClaudeBar/Views/Shared/VpnTopChrome.swift',
                    start='enum VpnDelayStyle {')
# --- Usage heatmap + period tabs --------------------------------------------
source += file_from('Sources/ClaudeBar/Views/Shared/UsageHeatmap.swift')

# --- The popup's own views ---------------------------------------------------
source += file_from('Sources/ClaudeBar/Views/Popup/PanelState.swift')
source += file_from('Sources/ClaudeBar/Views/Popup/PanelHeader.swift')
source += file_from('Sources/ClaudeBar/Views/Popup/SessionsPanel.swift')
source += file_from('Sources/ClaudeBar/Views/Popup/UsagePanel.swift')
# The action bar's two state-dependent faces (bell on/off, theme sun/moon).
# Production, not restated: the fixture used to keep its own literals and had
# already drifted from the real bar (finding 571).
source += declaration('Sources/ClaudeBar/Views/MenuBarView.swift', 'enum ActionBarFaces {')

# --- Store stand-ins ---------------------------------------------------------
source += '''
// MARK: - Fixture stand-ins (synthetic; no disk, no network, no real prefs).

final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    @Published var isDark = false
    @Published var appearance: AppearanceMode = .light
    /// On, so the still shows the enabled bell the promo describes
    /// (`FixtureActionBar` reads this through the production `ActionBarFaces`).
    @Published var idleNotifyEnabled = true
    @Published var tokenUnitStyle: TokenUnitStyle = .chinese
    /// `UsagePanel` reads this through the production `ModelPricing.present`.
    @Published var costDisplay: CostDisplay = .split
    @Published var codexProxyPort: Int = 15721
    @Published var codexRoutingEnabled = true
    @Published var vpnMixedPort: Int = 7890
}

/// `ExchangeRate` reduced to the one member the sliced views read
/// (`UsagePanel`'s `fx.effectiveRate`): a fixed rate, no fetch, no defaults.
final class ExchangeRate: ObservableObject {
    static let shared = ExchangeRate()
    var effectiveRate: Double? { 7.12 }
}

/// `@ProviderState` in the app reads `\\.providerSource` off the environment and
/// traps when it is absent, so the fixture mounts the store the same way
/// `MenuBarController.makeHostingView` does.
private struct ProviderSourceKey: EnvironmentKey { static let defaultValue: ProviderStore? = nil }
extension EnvironmentValues {
    var providerSource: ProviderStore? {
        get { self[ProviderSourceKey.self] }
        set { self[ProviderSourceKey.self] = newValue }
    }
}
private struct SurfaceVisibleKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var surfaceIsVisible: Bool {
        get { self[SurfaceVisibleKey.self] }
        set { self[SurfaceVisibleKey.self] = newValue }
    }
}
struct ProviderFields: OptionSet {
    let rawValue: Int
    static let configuration = Self(rawValue: 1 << 0)
    static let usage = Self(rawValue: 1 << 1)
    static let sessions = Self(rawValue: 1 << 2)
    static let heartbeats = Self(rawValue: 1 << 3)
    static let expansion = Self(rawValue: 1 << 4)
}
@propertyWrapper struct ProviderState: DynamicProperty {
    @Environment(\\.providerSource) private var source
    private let fields: ProviderFields
    init(_ fields: ProviderFields, store: ProviderStore? = nil) { self.fields = fields }
    var wrappedValue: ProviderStore { source! }
    var projectedValue: StoreBindings<ProviderStore> { StoreBindings(store: wrappedValue) }
}
@dynamicMemberLookup struct StoreBindings<Store: AnyObject> {
    let store: Store
    subscript<Value>(dynamicMember path: ReferenceWritableKeyPath<Store, Value>) -> Binding<Value> {
        Binding(get: { store[keyPath: path] }, set: { store[keyPath: path] = $0 })
    }
}

/// `ProviderStore` reduced to what the popup reads. The store layer is the one
/// layer these previews replace; the views that consume it are production code.
final class ProviderStore: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var activeProviderID: UUID? = nil
    @Published var currentEnv: EnvConfig? = nil
    @Published var hasSettingsFile = true
    @Published var errorMessage: String? = nil
    @Published var usageStats: [ModelUsage] = []
    @Published var usageDays: [DayUsage] = []
    /// The popup's week strip reads this (a day-scoped `usageDays` cannot fill
    /// a seven-cell week), so the fixture has to publish it too.
    @Published var usageWeekDays: [DayUsage] = []
    @Published var usageLoading = false
    @Published var usagePeriod: UsagePeriod = .month
    @Published var usageReferenceDate = Date()
    @Published var sessions: [SessionInfo] = []
    @Published var cursorSessions: [CursorSessionInfo] = []
    @Published var externalSessions: [ExternalSessionInfo] = []
    @Published var heartbeats: [Int: [Bool]] = [:]

    var usageEstimate = ModelPricing.Estimate()
    var usageCostLines: [String: ModelPricing.Estimate.Line] = [:]

    var aliveSessions: [SessionInfo] { sessions.filter(\\.isAlive) }
    var busySessionCount: Int { aliveSessions.filter { $0.status == .busy }.count }
    var aliveCursorSessions: [CursorSessionInfo] { cursorSessions }
    var activeCursorCount: Int { cursorSessions.filter { $0.status == .active }.count }
    var activeExternalCount: Int { externalSessions.filter { $0.isAlive && !$0.isSubagent && $0.isActive }.count }
    var totalUsageTokens: Int { usageStats.reduce(0) { $0 + $1.totalTokens } }
    var totalUsageLabel: String { UsageStats.formatTokens(totalUsageTokens, style: .chinese) }
    var costEstimate: ModelPricing.Estimate { usageEstimate }
    var activeProvider: Provider? { providers.first { $0.id == activeProviderID } }
    func costLine(for model: String) -> ModelPricing.Estimate.Line? { usageCostLines[model] }

    struct ExternalSessionNode: Identifiable {
        var id: String { session.id }
        let session: ExternalSessionInfo
        let children: [ExternalSessionNode]
        /// Every sub-agent below this node, at any depth, in pre-order —
        /// stored, exactly as the app builds it (`ProviderStore+Derived`).
        let descendants: [ExternalSessionInfo]
        let activeDescendantCount: Int

        init(session: ExternalSessionInfo, children: [ExternalSessionNode]) {
            self.session = session
            self.children = children
            self.descendants = children.flatMap { [$0.session] + $0.descendants }
            self.activeDescendantCount = children.reduce(0) {
                $0 + $1.activeDescendantCount + ($1.session.isActive ? 1 : 0)
            }
        }

        var descendantCount: Int { descendants.count }
    }
    func externalSessionTree(kind: ExternalAgentKind) -> [ExternalSessionNode] {
        externalSessions.filter { $0.kind == kind && $0.isAlive && !$0.isSubagent }
            .map { ExternalSessionNode(session: $0, children: []) }
    }
    func refresh() {}
    func refreshUsage(rescan: Bool = true) {}
    func restoreOfficial() {}
    func activateModel(providerID: UUID, modelID: UUID) {}
    /// The session cards' 清理 action. The preview never presses it; it only has
    /// to exist for `SessionsPanel` to compile against this stub.
    func cleanUpExternalSession(_ session: ExternalSessionInfo) {}
    func viewChanges(_ fields: ProviderFields) -> [AnyPublisher<Void, Never>] { [] }
}

@MainActor final class CodexProviderStore: ObservableObject {
    @Published var providers: [CodexProvider] = []
    @Published var activeProviderID: UUID? = nil
    @Published var proxyRunning = true
    @Published var quotaWindows: [CodexQuotaWindow] = []
    @Published var quotaLoading = false
    @Published var quotaNote: String? = nil
    @Published var configuredModel: String? = nil
    @Published var usesOfficialAccount = false
    @Published var configuredProviderID: UUID? = nil
    var activeProvider: CodexProvider? { providers.first { $0.id == activeProviderID } }
    func refreshConfiguredModel() {}
    func refreshQuota(manual: Bool = false) {}
    func restoreOfficial() {}
    func activate(providerID: UUID, modelID: UUID) {}
}

@MainActor final class VpnManager: ObservableObject {
    static let shared = VpnManager()
    enum State: Equatable { case idle, starting, running, missingCore }
    @Published var state: State = .running
    var isRunning: Bool { state == .running }
    var liveLeafName: String? { "日本 A01" }
    func resolvedDelay(_ name: String?) -> Int? { 42 }
}

@MainActor final class CursorUsageStore: ObservableObject {
    static let shared = CursorUsageStore()
    @Published var plan: CursorUsageFetcher.PlanUsage?
    @Published var grok: CursorUsageFetcher.GrokUsage?
    @Published var loading = false
    @Published var note: String? = nil
    func refresh(manual: Bool = false) {}
}

/// `ProcessSampler`/`FanMonitor` are SMC readers; `SessionLoadChip` asks only for
/// a per-key CPU/memory label, so the stub answers that and nothing else.
final class ProcessSampler {
    static let shared = ProcessSampler()
    @MainActor var host = HostStats()
    @MainActor var cells = CellLoad()
    @MainActor var byKey: [Key: Snapshot] = [:]
    struct Snapshot: Equatable {
        var cpu: Double = 0
        var memoryBytes: UInt64 = 0
        var loadLabel: String { String(format: "%.1f%% · %.0fMB", cpu, Double(memoryBytes) / 1_048_576) }
    }
    struct CellLoad: Equatable { var cores: [Double] = []; var gpuRenderers: [Double] = [] }
    struct HostStats: Equatable {
        var cpu: Double = 48; var gpu: Double = 44; var memoryUsed: UInt64 = 16_300_000_000
        var memoryTotal: UInt64 = 34_400_000_000; var coreCount: Int = 10
    }
    enum MonitorScope: Hashable { case popup, dashboard, sessions }
    enum Key: Hashable {
        case pid(Int)
        case cursor
        case cwd(String)
        static func standardizedCwd(_ path: String) -> Key { .cwd(path) }
    }
    enum Family: String, CaseIterable { case claudeBar, claude, cursor, codex }
    func setScope(_ scope: MonitorScope, active: Bool) {}
}

/// `AppPage` is the main window's own enum; only its raw values are posted.
enum AppPage: String, CaseIterable, Identifiable {
    case dashboard, sessions, providers, connectors, usage, traffic, vpn, settings, help
    var id: String { rawValue }
}

extension Notification.Name {
    static let showMainWindow = Notification.Name("com.claudebar.showMainWindow")
}
extension Notification {
    static func showMainWindow(page: AppPage, editor: Bool = false) -> Notification {
        Notification(name: .showMainWindow, object: nil,
                     userInfo: ["page": page.rawValue, "editor": editor])
    }
}
/// The real `FilePaths` enum, sliced above the stand-ins: the Codex scanner
/// reads `FilePaths.codexDir`, and a stub that dropped it is exactly how this
/// probe stopped compiling. The real file resolves its roots under the app's
/// own support dir on the dev channel, so nothing here touches `~/.claude`.
enum TerminalLauncher {
    static func resumeClaudeSession(cwd: String, sessionId: String, pid: Int?) {}
    static func resumeCodexSession(cwd: String, sessionId: String, pid: Int?, inDesktop: Bool) {}
    static func openInCursor(cwd: String) {}
}
'''

# --- Synthetic data ----------------------------------------------------------
source += '''
// MARK: - Synthetic data

@MainActor func fixtureProviderStore() -> ProviderStore {
    let store = ProviderStore()
    let flash = ModelConfig(name: "deepseek-v4.1-flash", contextTokens: "128000")
    let pro = ModelConfig(name: "deepseek-v4-pro", contextTokens: "128000")
    let glm = ModelConfig(name: "glm-5.3-flash", contextTokens: "128000")
    let aibox = Provider(name: "Aibox", baseURL: "https://api.aibox.example/v1",
                         models: [flash, pro, glm], activeModelID: flash.id)
    let anthropicModels = [ModelConfig(name: "claude-opus-4-6", contextTokens: "200000")]
    let anthropic = Provider(name: "Anthropic", baseURL: "https://api.anthropic.com",
                             models: anthropicModels, activeModelID: anthropicModels[0].id)
    store.providers = [aibox, anthropic]
    store.activeProviderID = aibox.id
    store.currentEnv = EnvConfig(ANTHROPIC_MODEL: "deepseek-v4.1-flash")

    store.sessions = [
        SessionInfo(pid: 15721, sessionId: "4f3a-1", cwd: "/Users/x/Project/ClaudeBar",
                    startedAt: 0, name: "ClaudeBar", status: .busy,
                    updatedAt: Date().timeIntervalSince1970 * 1000 - 4_000, isAlive: true,
                    contextTokens: 135_000, contextLimit: 500_000, model: "deepseek-v4.1-flash",
                    messageCount: 42, currentActivity: "Bash · build.sh",
                    firstPrompt: "修 CI 红", turnCount: 12, subagents: [], workflows: []),
    ]
    store.cursorSessions = [
        CursorSessionInfo(composerId: "composer-1", name: "AgentLoop 追踪",
                          cwd: "/Users/x/Project/Neo",
                          lastUpdatedAt: Date().timeIntervalSince1970 * 1000 - 8_000,
                          contextPercent: 68, status: .active, isAlive: true,
                          currentActivity: "编辑 routes.ts",
                          title: "AgentLoop 追踪", subtitle: "Edited routes.ts"),
    ]
    store.externalSessions = [
        ExternalSessionInfo(kind: .codex, sessionId: "9c1d", cwd: "/Users/x/Project/api",
                            updatedAt: Date().timeIntervalSince1970 * 1000 - 12_000,
                            model: "gpt-6-astra", isAlive: true, isActive: true,
                            contextTokens: 60_000, contextLimit: 400_000, title: "给我一个 hello"),
    ]
    store.heartbeats = [15721: [true, true, false, true, true, true, false, false, true, true]]
    store.usageStats = [
        ModelUsage(model: "deepseek-v4.1-flash", calls: 51_948, inputTokens: 3_200_000_000,
                   outputTokens: 420_000_000, cacheReadTokens: 6_900_000_000, cacheCreationTokens: 70_000_000),
        ModelUsage(model: "claude-opus-4-6", calls: 12_400, inputTokens: 900_000_000,
                   outputTokens: 180_000_000, cacheReadTokens: 1_600_000_000, cacheCreationTokens: 30_000_000),
        ModelUsage(model: "gpt-6-astra", calls: 6_120, inputTokens: 700_000_000,
                   outputTokens: 120_000_000, cacheReadTokens: 800_000_000, cacheCreationTokens: 20_000_000),
    ]
    store.usageEstimate = ModelPricing.estimate(store.usageStats)
    store.usageCostLines = Dictionary(uniqueKeysWithValues: store.usageEstimate.lines.map { ($0.model, $0) })
    // A month of days for the heatmap.
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    store.usageDays = (0..<30).reversed().map { offset in
        let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
        let key = String(format: "%04d-%02d-%02d", calendar.component(.year, from: date),
                         calendar.component(.month, from: date), calendar.component(.day, from: date))
        let base = [1_600_000_000, 2_900_000_000, 4_100_000_000, 900_000_000][offset % 4]
        return DayUsage(day: key, inputTokens: base / 3, outputTokens: base / 8,
                        cacheReadTokens: base / 2, cacheCreationTokens: base / 20)
    }
    if let week = calendar.dateInterval(of: .weekOfYear, for: today) {
        let keys = Set((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
            .map { date in
                String(format: "%04d-%02d-%02d", calendar.component(.year, from: date),
                       calendar.component(.month, from: date), calendar.component(.day, from: date))
            })
        store.usageWeekDays = store.usageDays.filter { keys.contains($0.day) }
    }
    return store
}

@MainActor func fixtureCodexStore() -> CodexProviderStore {
    let store = CodexProviderStore()
    let models = [CodexModelConfig(name: "gpt-6-astra"), CodexModelConfig(name: "gpt-5.4")]
    let provider = CodexProvider(name: "Aibox Codex", baseURL: "https://api.aibox.example/v1",
                                 models: models, activeModelID: models[0].id)
    store.providers = [provider]
    store.activeProviderID = provider.id
    store.configuredModel = "gpt-6-astra"
    let now = Date()
    store.quotaWindows = [
        CodexQuotaWindow(label: "5 小时", usedPercent: 18, resetsAt: now.addingTimeInterval(8_360), durationMinutes: 300),
        CodexQuotaWindow(label: "7 天", usedPercent: 41, resetsAt: now.addingTimeInterval(2 * 86_400), durationMinutes: 10_080),
    ]
    return store
}

@MainActor func fixtureCursorStore() -> CursorUsageStore {
    let store = CursorUsageStore()
    var plan = CursorUsageFetcher.PlanUsage(usedPercent: 46, apiPercentUsed: 52,
                                            autoPercentUsed: 43, totalSpendCents: 920,
                                            limitCents: 2000, includedSpendCents: 920,
                                            bonusSpendCents: 0)
    plan.billingCycleEnd = Calendar.current.date(byAdding: .day, value: 12, to: Date())
    store.plan = plan
    store.grok = CursorUsageFetcher.GrokUsage(usedPercent: 12.4, planName: "Pro",
                                              hasAvailableUsage: true,
                                              nextReset: Calendar.current.date(byAdding: .day, value: 4, to: Date()))
    return store
}
'''

# --- Probe -------------------------------------------------------------------
source += r'''
// MARK: - The popup, composed

/// The real `MenuBarView` shell, minus the two hardware-coupled subviews (see
/// the module doc): the KPI strip is drawn by `FixtureKpiStrip` to the same
/// geometry, and the energy card is omitted.
struct PopupFixture: View {
    @State private var panel = PanelState()
    let providerStore: ProviderStore
    let codexStore: CodexProviderStore
    let cursorStore: CursorUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(panel: panel)
                .fixedSize(horizontal: false, vertical: true)
            FixtureKpiStrip()
                .fixedSize(horizontal: false, vertical: true)
            SessionsPanelView()
                .frame(maxHeight: .infinity, alignment: .top)
                .panelCard()
            UsagePanel()
                .fixedSize(horizontal: false, vertical: true)
                .panelCard()
            FixtureActionBar()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(width: 460)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgPrimary)
        .environmentObject(codexStore)
        .environment(\.providerSource, providerStore)
        .onAppear {
            // The header observes `CursorUsageStore.shared`; point the shared
            // instance at the fixture's readings.
            CursorUsageStore.shared.plan = cursorStore.plan
            CursorUsageStore.shared.grok = cursorStore.grok
        }
    }
}

/// The four-cell KPI strip at `MachineKpiStrip`'s own geometry — see the module
/// doc for why the production view is not on screen. Synthetic figures, the
/// promo film's own (`§4 · 第 8 场`): `CPU 48% · GPU 44% · 内存 15.2G · 风扇 2977`.
struct FixtureKpiStrip: View {
    private let cells: [(icon: String, label: String, value: String, tint: Color)] = [
        ("cpu", "CPU", "48%", Theme.claude),
        ("gpu", "GPU", "44%", Theme.chartBlue),
        ("memory", "内存", "15.2G", Theme.chartAmber),
        ("fan", "风扇", "2977", Theme.claude),
    ]

    var body: some View {
        EqualRowGrid(spacing: 1, minColumnWidth: 0, fixedColumns: 4) {
            ForEach(cells.indices, id: \.self) { index in
                let cell = cells[index]
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        SignatureGlyph(name: cell.icon, tint: cell.tint, size: 15)
                        Text(cell.label)
                            .font(Theme.Font.kpi)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    RollingNumberText(cell.value)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 62, maxHeight: .infinity, alignment: .leading)
                .background(Theme.cardSurface)
            }
        }
        .background(Theme.hairline)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// The popup's action bar: the same `IconChipRow` the production `MenuBarView`
/// builds, and the same nine items production shows when no battery is
/// installed. Production prepends the conditional `CompactBatteryChargeControl`
/// when `ProcessSampler.shared.host.batteryInstalled` — a still cannot read
/// that, so the fixture draws the no-battery set.
///
/// The two state-dependent faces (bell, theme) come from the *production*
/// `ActionBarFaces` sliced above, and the state is drawn from the fixture's
/// own `AppPreferences` — the same `idleNotifyEnabled` / `appearance` values
/// the probe writes per theme. Nothing here restates an icon, a tooltip or a
/// tint by hand (finding 571).
struct FixtureActionBar: View {
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some View {
        let bell = ActionBarFaces.idleNotify(enabled: prefs.idleNotifyEnabled)
        let theme = ActionBarFaces.appearance(prefs.appearance)
        IconChipRow(spacing: Theme.Space.s2) {
            iconButton("arrow.clockwise", help: "刷新", color: Theme.textSecondary)
            iconButton("macwindow", help: "打开主窗口", color: Theme.accent)
            iconButton("questionmark.circle", help: "帮助", color: Theme.textSecondary)
            iconButton("arrow.uturn.backward", help: "还原官方配置", color: Theme.textSecondary)
            iconButton("pencil.line", help: "管理模型", color: Theme.cursorAccent)
            iconButton("gearshape", help: "打开 settings.json", color: Theme.textSecondary)
            iconButton(bell.icon, help: bell.help, color: bell.tint)
            iconButton(theme.icon, help: theme.help, color: theme.tint)
            Spacer(minLength: Theme.Space.s4)
            VerticalHairline().frame(height: 18).padding(.horizontal, Theme.Space.s2)
            iconButton("power", help: "退出", color: Theme.statusError)
        }
        .padding(.top, 2)
    }

    private func iconButton(_ icon: String, help: String, color: Color) -> some View {
        IconChip(systemImage: icon, tint: color)
            .help(help)
            .accessibilityLabel(help)
    }
}

@main struct Probe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        ProductBrandMark.resourceRoot = brandMarkRoot
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let providerStore = fixtureProviderStore()
        let codexStore = fixtureCodexStore()
        let cursorStore = fixtureCursorStore()
        for dark in [false, true] {
            AppPreferences.shared.isDark = dark
            AppPreferences.shared.appearance = dark ? .dark : .light
            let view = PopupFixture(providerStore: providerStore, codexStore: codexStore,
                                    cursorStore: cursorStore)
                .environment(\.colorScheme, dark ? .dark : .light)
            // `NSHostingView`, not `ImageRenderer`: the sessions panel is a real
            // `ScrollView` and `ImageRenderer` lays none of its content out.
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 460, height: 720)
            host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            host.frame = NSRect(x: 0, y: 0, width: 460, height: max(fitting.height, 480))
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                fatalError("render failed")
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                fatalError("PNG encode failed")
            }
            try png.write(to: out.appendingPathComponent("popup-\(dark ? "dark" : "light").png"))
            window.orderOut(nil)
        }
        print("Rendered popup preview to \(out.path)")
    }
}
'''

path = out / 'Probe.swift'
path.write_text(source)
binary = out / 'probe'
subprocess.run(['/usr/bin/swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                str(path), '-o', str(binary)], check=True)
if CHECK:
    # `--check` has to be the flag a maintainer can trust after touching
    # `Sources/`: the declaration lookups above raise when a name has moved, and
    # this compile proves the slices still form the program. What it skips is
    # the *launch*, the only part that needs a window server. The old shape
    # returned before any source was read at all, so it passed on a tree where
    # the probe could not compile.
    print('render-popup-preview: --check: declarations present and the probe compiles')
else:
    subprocess.run([str(binary), str(out)], check=True)
