#!/usr/bin/env python3
"""Render production session overview cards with synthetic, idle/busy fixtures.

Reads current models and card bodies; no app, client history or process sampler
is started. Agent-only workspaces are outside these compact-card captures.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / '.build/session-overview-preview'
out.mkdir(parents=True, exist_ok=True)

def declaration(path, start):
    text = (root / path).read_text()
    pos = text.index(start)
    opening = text.index('{', pos)
    level = 1
    end = opening + 1
    while level:
        level += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[pos:end] + "\n"

source = ''

source += '''
import SwiftUI
import AppKit
'''
# The shared scalars: the theme, and the surface the preview sits on.
source += declaration('Sources/ClaudeBar/Theme/Theme.swift', 'extension Color {')
source += declaration('Sources/ClaudeBar/Theme/Theme.swift', 'enum Theme {')
_support = (root / 'Tools/control-preview-support.swift').read_text()
_support = _support.replace('final class Preferences: @unchecked Sendable {',
                           'final class Preferences: ObservableObject, @unchecked Sendable {\n        @Published var costDisplay: CostDisplay = .split\n        @Published var tokenUnitStyle: TokenUnitStyle = .metric')
source += _support + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/LucideHardwareGeometry.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/LucideHardwarePaths.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/InstrumentGlyph.swift').read_text() + '\n'

source += (root / 'Sources/ClaudeBar/Views/Shared/SignatureGlyph.swift').read_text() + '\n'
source += (root / 'Tools/control-preview-sheet.swift').read_text().split('struct PreviewSheet: View')[0] + '\n'

source += (root / 'Sources/ClaudeBar/Views/Shared/ProductBrandMark.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/UiverseSurfaces.swift').read_text().replace('private struct SegmentedItem', 'struct SegmentedItem') + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/DecorativeMotion.swift').read_text() + '\n'
_tile = (root / 'Sources/ClaudeBar/Views/Shared/Tile.swift').read_text()
_tile = _tile.replace("""                .background {
                    LayerShadow(radius: hovered ? 9 : 5,
                                y: hovered ? 4 : 1,
                                opacity: hovered ? 0.07 : 0.04,
                                cornerRadius: radius,
                                surface: Theme.cardSurface)
                }""", '')
assert 'LayerShadow(radius: hovered ? 9' not in _tile, 'Tile shadow fixture anchor moved'
source += _tile[: _tile.index('// MARK: - Tile grid')] + '\n' 



# `Interaction.swift` carries the historical `adaptiveGlassButton` alias, which
# `InstrumentControls.swift` (taken whole below) now also defines. Take the two
# pieces the sheet actually builds, and drop the alias — `CodexModelMark`'s lane
# and `IconChip` come from it in the app, not in this sheet.
_interaction = (root / 'Sources/ClaudeBar/Views/Shared/Interaction.swift').read_text()
_lo = _interaction.index('// MARK: - Action buttons')
_hi = _interaction.index('// MARK: - HoverState')
source += _interaction[: _lo] + '\n' + _interaction[_hi:] + '\n'
source += declaration('Sources/ClaudeBar/Utils/CodexQuotaFetcher.swift', 'struct CodexQuotaWindow: Equatable, Identifiable {')
source += (root / 'Sources/ClaudeBar/Views/Shared/CodexQuotaGauges.swift').read_text() + '\n'
# `AppGlyph` → `StatusPill` are contiguous in `Theme.swift`; one slice keeps
# their private helpers (`IconChip`'s drawing, `PillMark`) inside the cut.
_theme = (root / 'Sources/ClaudeBar/Theme/Theme.swift').read_text()
source += _theme[_theme.index('struct PanelCardModifier: ViewModifier {'):] + '\n'

# The control language under test, whole file.
_controls = (root / 'Sources/ClaudeBar/Views/Shared/InstrumentControls.swift').read_text()
# The page-band shim is app-side glue, not part of the control language; the
# sheet builds no band. Dropping it avoids a second `View` extension here.
source += _controls[: _controls.index("// MARK: - The page band's own control")] + '\n'



source += (root / 'Sources/ClaudeBar/Models/SessionMigration.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Utils/SessionTitle.swift').read_text() + '\n'
for path, markers in [
    ('Sources/ClaudeBar/Utils/SessionMonitor.swift', ['struct SessionInfo:', 'enum SessionStatus:',
        'enum SubagentStatus:', 'struct SubagentInfo:', 'struct WorkflowInfo:']),
    ('Sources/ClaudeBar/Utils/WorkflowMonitor.swift', ['enum WorkflowStatus:']),
    ('Sources/ClaudeBar/Utils/CursorSessionMonitor.swift', ['struct CursorSessionInfo:', 'enum CursorStatus:',
        'struct CursorSubagentInfo:', 'enum CursorSubagentStatus:']),
    ('Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift', ['struct ExternalSessionInfo:', 'enum ExternalAgentKind:']),
    ('Sources/ClaudeBar/Views/Shared/SessionCardView.swift', ['struct SessionTitleLine:']),
    ('Sources/ClaudeBar/Views/Shared/ResourceStrip.swift', ['struct SessionLoadChip:'])
]:
    for marker in markers:
        source += declaration(path, marker)
source += (root / 'Sources/ClaudeBar/Views/Shared/SectionHeader.swift').read_text() + '\n'
source += 'enum UsageStats {\n' + declaration('Sources/ClaudeBar/Utils/UsageStats.swift', '    static func formatContext(') + '}\n'
source += declaration('Sources/ClaudeBar/Views/Pages/SessionMigrationView.swift', 'extension MigrationClient {')
source += declaration('Sources/ClaudeBar/Views/Shared/SessionMigrationDialog.swift', 'extension MigrationSource {')
source += declaration('Sources/ClaudeBar/Views/Shared/SessionMigrationDialog.swift', 'struct SessionMigrationButton:')
source += (root / 'Sources/ClaudeBar/Models/ModelUsage.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Utils/ModelPricing.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Utils/ModelPriceTable.swift').read_text() + '\n'
source += declaration('Sources/ClaudeBar/Models/AppPreferences.swift', 'enum TokenUnitStyle:')
source += (root / 'Sources/ClaudeBar/Utils/TokenMagnitude.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Models/SessionUsageSummary.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/SessionUsageReadout.swift').read_text() + '\n'
source += '''
enum BuildChannel { static let allowsSystemIntegration = false }
enum UsageIndex {
    static func fetchSessionDailyFamilies(source: UsageSource, sessionIds: [String]) -> [String: [String: [ModelUsage]]] { [:] }
}
final class ExchangeRate: ObservableObject {
    static let shared = ExchangeRate()
    let effectiveRate: Double? = nil
}
enum FilePaths { static let codexDir = URL(fileURLWithPath: "/synthetic/codex") }
@MainActor final class SessionMigrationModel: ObservableObject {
    func requestMigration(_ source: MigrationSource) {}
}
@MainActor enum TerminalLauncher {
    static func revealInFinder(cwd: String) {}
    static func resumeClaudeSession(cwd: String, sessionId: String, pid: Int?) {}
    static func openInCursor(cwd: String) {}
    static func resumeCodexSession(cwd: String, sessionId: String, pid: Int?, inDesktop: Bool) {}
}
final class ProcessSampler {
    static let shared = ProcessSampler()
    enum Key: Hashable { case pid(Int), cursor, cwd(String)
        static func standardizedCwd(_ path: String) -> Key { .cwd(path) }
    }
    struct Snapshot { let loadLabel: String }
    let byKey: [Key: Snapshot] = [.pid(101): .init(loadLabel: "12% · 271 MB"),
        .pid(102): .init(loadLabel: "0% · 164 MB"), .cursor: .init(loadLabel: "8% · 1.2 GB"),
        .cwd("/Projects/ClaudeBar"): .init(loadLabel: "4% · 356 MB")]
}
struct ProviderStore {
    struct ExternalSessionNode {
        let session: ExternalSessionInfo
        var activeDescendantCount = 0
        var descendants: [ExternalSessionInfo] = []
    }
}
// No agent UI is drawn: all fixture cards have no agents. The real swarm's
// packing and interactions remain covered by the registered swarm regressions.
struct AgentSwarmView: View {
    let root: ExternalSessionInfo
    let children: [ExternalSessionInfo]
    var compact = false
    let onOpen: (ExternalSessionInfo) -> Void
    var body: some View { EmptyView() }
    enum SwarmGrid {
        static func strip(count: Int, width: CGFloat, maxRows: Int, compact: Bool) -> (visible: Int, height: CGFloat) { (0, 0) }
    }
}
struct ExternalSessionTile {
    static func swarmAgents(of node: ProviderStore.ExternalSessionNode) -> [ExternalSessionInfo] { node.descendants }
}
'''
for marker in ['private struct SessionActionChips', 'private struct SessionClientBadge',
               'private struct SessionContextReadout', 'private struct SessionCardHeading', 'private struct SessionMetadataLine',
               'private struct ActivityLine', 'private struct SessionTileFull',
               'private struct CursorTileFull', 'private struct SessionAgentDetailRow',
               'private struct ExternalSessionGridCard']:
    source += declaration('Sources/ClaudeBar/Views/Pages/SessionsView.swift', marker)
# The dashboard shares the cumulative readout but keeps its compact card body.
source += (root / 'Sources/ClaudeBar/Views/Shared/SessionStatusViews.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/ContextBar.swift').read_text() + '\n'
source += 'struct DashboardView {\n' + declaration('Sources/ClaudeBar/Views/Pages/DashboardView.swift', '    struct OverviewRow:') + '}\n'
source += declaration('Sources/ClaudeBar/Views/Pages/DashboardView.swift', 'private struct OverviewTile:')
source += r'''
@main struct Probe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        ProductBrandMark.resourceRoot = URL(fileURLWithPath: CommandLine.arguments[2])
        let now = Date().timeIntervalSince1970 * 1000
        let claude = [
            SessionInfo(pid: 101, sessionId: UUID().uuidString, cwd: "/Projects/ClaudeBar", startedAt: now,
                name: "claudebar-18", status: .busy, updatedAt: now - 18 * 60_000, isAlive: true,
                contextTokens: 94000, contextLimit: 500000, model: "deepseek-v4-flash",
                messageCount: 20, currentActivity: "Bash · swift test", firstPrompt: "完善会话工作台"),
            SessionInfo(pid: 102, sessionId: UUID().uuidString, cwd: "/Projects/Analytics", startedAt: now,
                name: "analytics", status: .idle, updatedAt: now - 4 * 3600_000, isAlive: true,
                contextTokens: 165000, contextLimit: 200000, model: "claude-opus-4-6",
                messageCount: 32, currentActivity: "Read · index.swift", firstPrompt: "梳理索引与查询流程，验证超长标题在窄卡片中始终只占一行")
        ]
        let cursor = [
            CursorSessionInfo(composerId: UUID().uuidString, name: "OpenClaw session debugging",
                cwd: "/Projects/OpenClaw", lastUpdatedAt: now - 4 * 3600_000, contextPercent: 44,
                status: .idle, isAlive: true, currentActivity: "Shell · git", title: "调试会话连接"),
            CursorSessionInfo(composerId: UUID().uuidString, name: "Code authentication path",
                cwd: "/Projects/Notes", lastUpdatedAt: now - 24 * 3600_000, contextPercent: 92,
                status: .idle, isAlive: true, currentActivity: "Grep · authentication", title: "完善登录与认证流程")
        ]
        let codex = ExternalSessionInfo(kind: .codex, sessionId: UUID().uuidString,
            cwd: "/Projects/ClaudeBar", updatedAt: now - 45 * 60_000, model: "gpt-6.1-sol",
            isAlive: true, isActive: false, contextTokens: 48000, contextLimit: 256000,
            title: "验证迁移记录和重试行为，并确认长标题不会推动其他读数向下移动")
        let summaries: [SessionUsageSummary.Request: SessionUsageSummary] = [
            .init(source: .claude, sessionId: claude[0].sessionId): .init(days: ["2026-10-10": [
                ModelUsage(model: claude[0].model, calls: 20, inputTokens: 480000000,
                           outputTokens: 38000000, cacheReadTokens: 2200000000, cacheCreationTokens: 90000000)]]),
            .init(source: .claude, sessionId: claude[1].sessionId): .init(days: ["2026-10-10": [
                ModelUsage(model: claude[1].model, calls: 32, inputTokens: 810000,
                           outputTokens: 64000, cacheReadTokens: 3400000, cacheCreationTokens: 120000)]]),
            .init(source: .codex, sessionId: codex.sessionId): .init(days: ["2026-10-10": [
                ModelUsage(model: codex.model, calls: 12, inputTokens: 250000,
                           outputTokens: 12000, cacheReadTokens: 180000)]])
        ]
        for width in [640, 900, 1440] {
            for dark in [false, true] {
                AppPreferences.shared.isDark = dark
                AppPreferences.shared.tokenUnitStyle = .chinese
                let sheet = VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        PageTitle(title: "会话")
                        Spacer()
                        SegmentedCapsule(items: [false, true], selection: false,
                            title: { $0 ? "迁移会话" : "会话总览" },
                            symbol: { $0 ? "arrow.triangle.branch" : "rectangle.grid.2x2" }, onSelect: { _ in })
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(icon: "rectangle.connected.to.line.below", title: "Claude Code",
                                      tint: Theme.claude, ink: Theme.Ink.claude, count: 2, activeCount: 1)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], spacing: 16) {
                            ForEach(claude) { SessionTileFull(session: $0).frame(maxWidth: .infinity) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(icon: "", title: "Cursor", mark: .cursor,
                                      tint: Theme.cursor, ink: Theme.Ink.cursor, count: 2, activeCount: 0)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], spacing: 16) {
                            ForEach(cursor) { CursorTileFull(session: $0).frame(maxWidth: .infinity) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(icon: "", title: "Codex", brand: true,
                                      tint: Theme.external, ink: Theme.Ink.success, count: 1, activeCount: 0)
                        ExternalSessionGridCard(node: .init(session: codex)).frame(width: width == 900 ? 418 : 336)
                    }
                    Text("合成数据 · 原生会话卡片预览").font(.caption).foregroundColor(Theme.textSecondary)
                }
                .padding(24).frame(width: CGFloat(width))
                .environmentObject(SessionMigrationModel())
                .environment(\.sessionUsageSummaries, summaries)
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Theme.bgPrimary)
                let dashboardRows: [DashboardView.OverviewRow] = [
                    .init(id: "cc", platform: "CC", mark: .claude, tint: Theme.claude,
                          pillInk: Theme.Ink.claude, busy: true, project: "完善会话工作台",
                          activity: "Bash · swift test", contextRatio: 0.188, contextLabel: "94K / 500K",
                          updated: "18m", load: .pid(101), usageRequest: .init(source: .claude, sessionId: claude[0].sessionId)),
                    .init(id: "cc2", platform: "CC", mark: .claude, tint: Theme.claude,
                          pillInk: Theme.Ink.claude, busy: false, project: "梳理索引与查询流程",
                          activity: "Read · index.swift", contextRatio: 0.825, contextLabel: "165K / 200K",
                          updated: "4h", load: .pid(102), usageRequest: .init(source: .claude, sessionId: claude[1].sessionId)),
                    .init(id: "cursor", platform: "Cursor", mark: .cursor, tint: Theme.cursor,
                          pillInk: Theme.Ink.cursor, busy: false, project: "OpenClaw session debugging",
                          activity: "Shell · git", contextRatio: 0.44, contextLabel: "44%", updated: "4h", load: .cursor),
                    .init(id: "codex", platform: "Codex", mark: .codex, tint: Theme.external,
                          pillInk: Theme.Ink.success, busy: true, project: "验证迁移记录和重试行为",
                          activity: "exec", contextRatio: 0.1875, contextLabel: "48K / 256K", updated: "45m",
                          load: .standardizedCwd("/Projects/ClaudeBar"), usageRequest: .init(source: .codex, sessionId: codex.sessionId))
                ]
                let overview = VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(icon: "rectangle.stack", title: "活跃会话",
                                  tint: Theme.claude, ink: Theme.Ink.claude, count: 4)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], spacing: 16) {
                        ForEach(dashboardRows) { row in OverviewTile(row: row, action: {}) }
                    }
                }
                .padding(16).panelCard(tint: Theme.claude)
                .padding(24).frame(width: CGFloat(width))
                .environment(\.sessionUsageSummaries, summaries)
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Theme.bgPrimary)
                let overviewRenderer = ImageRenderer(content: overview)
                overviewRenderer.scale = 2
                guard let overviewImage = overviewRenderer.cgImage,
                      let overviewPNG = NSBitmapImageRep(cgImage: overviewImage).representation(using: .png, properties: [:])
                else { fatalError("Dashboard render failed") }
                try overviewPNG.write(to: out.appendingPathComponent("dashboard-\(width)-\(dark ? "dark" : "light").png"))
                let renderer = ImageRenderer(content: sheet)
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                else { fatalError("Render failed") }
                try png.write(to: out.appendingPathComponent("overview-\(width)-\(dark ? "dark" : "light").png"))
            }
        }
        print("Rendered synthetic session cards to \(out.path)")
    }
}
'''
path = out / 'Probe.swift'
path.write_text(source)
binary = out / 'probe'
subprocess.run(['swiftc', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                str(path), '-o', str(binary)], check=True)
subprocess.run([str(binary), str(out), str(root / 'Sources/BrandAssets')], check=True)
