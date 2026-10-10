#!/usr/bin/env python3
"""Render the production migration workspace with synthetic data only.

Does not start the app, read client histories, or perform a migration. Native
fields and scroll containers use still-image equivalents for ImageRenderer.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / '.build/session-migration-preview'
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
source += (root / 'Tools/control-preview-support.swift').read_text() + '\n'
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
source += '''
enum BuildChannel { static let allowsSystemIntegration = true }
@MainActor final class SessionMigrationModel: ObservableObject {
    @Published var records: [MigrationRecord] = []
    @Published var selectedSource: MigrationSource?
    func requestMigration(_ source: MigrationSource) { selectedSource = source }
    @Published var opening: UUID?
    @Published var error: String?
    func refresh() async {}
    func open(_ record: MigrationRecord, codexStore: CodexProviderStore) async throws {}
}
@MainActor final class CodexProviderStore: ObservableObject {
    struct Provider: Identifiable {
        struct Model: Identifiable { var id: String { name }; let name: String }
        let id: UUID; let name: String; let apiKey: String; let models: [Model]
    }
    let providers: [Provider] = []
}
func fixtureField(_ prompt: String, text: Binding<String>) -> some View {
    Text(text.wrappedValue.isEmpty ? prompt : text.wrappedValue)
        .foregroundColor(text.wrappedValue.isEmpty ? Theme.textSecondary : Theme.textPrimary)
}
'''
shared = (root / 'Sources/ClaudeBar/Views/Shared/SessionMigrationDialog.swift').read_text()
source += shared[shared.index('struct SessionMigrationButton:'):]
search = (root / 'Sources/ClaudeBar/Views/Shared/InstrumentSearchField.swift').read_text()
import re
search = re.sub(r'TextField\(prompt, text: \$text\)', 'fixtureField(prompt, text: $text)', search)
search = re.sub(r'\n\s*\.focused\(\$focused\)', '', search)
source += search + '\n'
workspace = (root / 'Sources/ClaudeBar/Views/Pages/SessionMigrationView.swift').read_text()
# State and bodies are production; the actor is a fixture with no external IO.
source += workspace[workspace.index('@MainActor'):workspace.index('extension MigrationClient')].replace(
    '    private var work: Task<Void, Never>?', '''    init(source: MigrationSource?, preview: MigrationPreview?, target: MigrationTarget = .codexCurrent) {
        self.source = source; self.preview = preview; self.target = target
    }
    private var work: Task<Void, Never>?''')
source += '''
actor SessionMigrationService {
    static let shared = SessionMigrationService()
    func preview(_ source: MigrationSource, includeCompletedTools: Bool, includeImages: Bool) throws -> MigrationPreview {
        throw MigrationFailure.restricted
    }
    func prepare(source: MigrationSource, target: MigrationTarget, fingerprint: String,
                 officialModel: String, includeCompletedTools: Bool, includeImages: Bool,
                 bridgeProviderID: UUID?, bridgeModel: String) throws -> MigrationRecord {
        throw MigrationFailure.restricted
    }
}
'''
views = workspace[workspace.index('extension MigrationClient'):]
# ImageRenderer has no AppKit input bridge or scroll viewport. Flatten only
# native containers, retaining the exact production content and spacing.
views = views.replace('.buttonStyle(.link)', '.buttonStyle(.plain)')
views = views.replace('ScrollView {', 'VStack(alignment: .leading, spacing: 0) {')
views = views.replace('LazyVStack(', 'VStack(').replace('LazyVGrid(', 'LazyVGrid(')
views = views.replace('TextField("官方账号可用的模型名称", text: $draft.officialModel)',
                      'fixtureField("官方账号可用的模型名称", text: $draft.officialModel)')
source += views
source += r'''
@main struct Probe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        ProductBrandMark.resourceRoot = URL(fileURLWithPath: CommandLine.arguments[2])
        let sample = [
            MigrationSource(client: .claude, sessionID: UUID().uuidString,
                cwd: "/Projects/ClaudeBar", title: "优化会话工作台的交互"),
            MigrationSource(client: .cursorDesktop, sessionID: UUID().uuidString,
                cwd: "/Projects/Website", title: "完善首页的响应式布局"),
            MigrationSource(client: .codex, sessionID: UUID().uuidString,
                cwd: "/Projects/Analytics", title: "分析索引性能与缓存", isBusy: true)
        ]
        let preview = MigrationPreview(source: sample[0], messages: [
            .init(role: .user, text: "请完善迁移会话页面的交互，保留项目目录与原会话。"),
            .init(role: .assistant, text: "已梳理会话来源与目标选择，接下来验证历史预览。"),
            .init(role: .user, text: "同时适配明暗外观。"),
            .init(role: .assistant, text: "界面继续使用现有 Theme 和原生组件。")
        ], fingerprint: "synthetic", omissions: ["思考过程与账号信息不迁移。"])
        for width in [900, 1440] {
            for dark in [false, true] {
                for empty in [false, true] {
                    // Empty state needs only one size; captures remain labelled.
                    if empty && width != 900 { continue }
                    AppPreferences.shared.isDark = dark
                    let migrations = SessionMigrationModel()
                    migrations.selectedSource = empty ? nil : sample[0]
                    if !empty {
                        migrations.records = [
                            MigrationRecord(id: UUID(), logicalConversationID: UUID(),
                                createdAt: Date(timeIntervalSince1970: 1791648000), source: sample[1],
                                sourceFingerprint: "synthetic", target: .codexCurrent,
                                targetSessionID: UUID().uuidString, nativePath: "/synthetic/history.jsonl",
                                messageCount: 17, omissions: [], model: "gpt-6.1-sol", providerKey: "",
                                configurationFingerprint: nil, executablePath: "/synthetic/codex"),
                            MigrationRecord(id: UUID(), logicalConversationID: UUID(),
                                createdAt: Date(timeIntervalSince1970: 1791561600), source: sample[0],
                                sourceFingerprint: "synthetic", target: .cursorDesktop,
                                targetSessionID: UUID().uuidString, nativePath: "/synthetic/history.sqlite",
                                messageCount: 15, omissions: [], model: "项目模型", providerKey: "",
                                configurationFingerprint: nil, executablePath: "/synthetic/Cursor")
                        ]
                    }
                    let draft = SessionMigrationDraft(source: empty ? nil : sample[0], preview: empty ? nil : preview)
                    let sheet = VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            PageTitle(title: "会话")
                            Spacer()
                            SegmentedCapsule(items: [false, true], selection: true,
                                title: { $0 ? "迁移会话" : "会话总览" },
                                symbol: { $0 ? "arrow.triangle.branch" : "rectangle.grid.2x2" }, onSelect: { _ in })
                        }.padding(.horizontal, 24).padding(.top, 24)
                        SessionMigrationView(sources: empty ? [] : sample, draft: draft)
                        Text("合成数据 · 原生界面预览").font(.caption).foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 24).padding(.bottom, 16)
                    }
                    .frame(width: CGFloat(width))
                    .environmentObject(migrations).environmentObject(CodexProviderStore())
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Theme.bgPrimary)
                    let renderer = ImageRenderer(content: sheet)
                    renderer.scale = 2
                    guard let image = renderer.cgImage,
                          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    else { fatalError("Render failed") }
                    let name = "migration-\(width)-\(dark ? "dark" : "light")\(empty ? "-empty" : "").png"
                    try png.write(to: out.appendingPathComponent(name))
                }
            }
        }
        print("Rendered synthetic migration workspace to \(out.path)")
    }
}
'''
path = out / 'Probe.swift'
path.write_text(source)
binary = out / 'probe'
subprocess.run(['swiftc', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                str(path), '-o', str(binary)], check=True)
subprocess.run([str(binary), str(out), str(root / 'Sources/BrandAssets')], check=True)
