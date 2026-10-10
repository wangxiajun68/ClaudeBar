#!/usr/bin/env python3
"""Native gateway preview + bounded rendering checks. Only synthetic stores.
Uses current production views and controls, an offscreen NSHostingView and
private fixture token; never starts the app, network, VPN or permission APIs.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = root / '.build/gateway-topology-preview'
out.mkdir(parents=True, exist_ok=True)
# Reuse the control sheet's existing production-source assembly, not a copy of
# its styles. Stop before its @main/write/compile steps.
control = root / 'Tools/render-control-preview.py'
namespace = {'__file__': str(control)}
exec(control.read_text().split("source += '''\n@main struct Probe {", 1)[0], namespace)
source = namespace['source']

def decl(text, marker):
    start = text.index(marker); pos = text.index('{', start) + 1; level = 1
    while level:
        level += (text[pos] == '{') - (text[pos] == '}'); pos += 1
    return text[start:pos]

def read(path):
    return (root / path).read_text()

source = source.replace(decl(source, 'enum AppPreferences: Sendable {'), r'''
final class AppPreferences: ObservableObject, @unchecked Sendable {
    static let shared = AppPreferences()
    @Published var isDark = false
    @Published var proxyThirdPartyTrafficEnabled = false
    var codexRoutingEnabled = true
    var codexProxyPort = 15721
}
''')
theme = read('Sources/ClaudeBar/Theme/Theme.swift')
source += theme[theme.index('struct PanelCardModifier:'):theme.index('// MARK: - Hairline sectioning')]
source += decl(theme, 'struct HairlineDivider: View {')
source += '\n' + decl(read('Sources/ClaudeBar/Views/Shared/InstrumentControls.swift'), 'struct InstrumentMenuLabel: View {')
source += '\n' + decl(read('Sources/ClaudeBar/Views/Shared/InstrumentControls.swift'), 'struct InstrumentChoiceControl<Value: Hashable>: View {')
for path in ['Sources/ClaudeBar/Views/Shared/SettingsControls.swift',
             'Sources/ClaudeBar/Views/Shared/GatewaySettingsControls.swift',
             'Sources/ClaudeBar/Utils/GatewayProviderImport.swift',
             'Sources/ClaudeBar/Views/Shared/InstrumentSearchField.swift',
             'Sources/ClaudeBar/Views/Shared/CodeBlock.swift',
             'Sources/ClaudeBar/Models/FreeModelPool.swift',
             'Sources/ClaudeBar/Utils/GatewayTaskRouter.swift',
             'Sources/ClaudeBar/Utils/FreeModelGateway.swift',
             'Sources/ClaudeBar/Utils/PrivateFileWriter.swift',
             'Sources/ClaudeBar/Utils/GatewayTopologyLayout.swift',
             'Sources/ClaudeBar/Views/Shared/ProxyCurlExample.swift']:
    source += '\n' + read(path)
source += decl(read('Sources/ClaudeBar/Models/CodexProxyState.swift'), 'enum LocalProxyAddress {')
source += r'''
enum FilePaths { static let proxyTokenFile = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("fixture-token") }
enum CodexProxyServer { static var configuredToken: String { "preview-token" } }
struct CodexModelConfig: Identifiable, Equatable { var id = UUID(); var name: String; var contextWindow = "64000" }
struct CodexProvider: Identifiable, Equatable {
    var id: UUID; var name: String; var baseURL: String; var apiKey = "preview-key"; var models: [CodexModelConfig]
    var activeModel: CodexModelConfig? { models.first }
}
enum PreviewScreen { static var discovery = false; static var editor = false; static var settings = false; static var admission = false; static var importSelected = false; static var routes = false }
enum PreviewMotion { static var reduce = false }
enum PreviewCounts { static var rows = 0 }
@MainActor final class FreeModelGatewayStore: ObservableObject {
    static let shared = FreeModelGatewayStore()
    @Published var pool = FreeModelPool()
    @Published var loading = false
    @Published var saving = false
    @Published var discovering = false
    @Published var testingMemberID: String?
    @Published var testResults: [String:String] = [:]
    @Published var error: String?
    @Published var snapshot = FreeModelGateway.Snapshot()
    var connections: [CodexProvider] = []
    let first = UUID(uuidString:"11111111-1111-1111-1111-111111111111")!
    let second = UUID(uuidString:"22222222-2222-2222-2222-222222222222")!
    func seed(count: Int, live: Bool, long: Bool = false) {
        pool = FreeModelPool(); pool.enabled = true
        connections = [.init(id:first,name:"示例供应商 A",baseURL:"https://example.test/v1",models:[]),
                       .init(id:second,name:"示例供应商 B",baseURL:"https://example.test/v1",models:[])]
        let names = ["Swift Light", "Atlas Tools", "Reasoning Pro", "Vision Free", "Standby Model"]
        pool.members = (0..<count).map { i in
            .init(providerID:i % 2 == 0 ? first : second,model:"example/\(i)-free",name:names[i % 5] + (i >= 5 ? " \(i)" : ""),
                enabled:i % 5 != 4,contextLength:[32768,65536,128000][i % 3],supportsTools:i % 3 != 0,
                supportsImages:i % 5 == 3,supportsJSON:true,difficulties:i % 3 == 0 ? [.low] : (i % 3 == 1 ? [.medium,.high] : [.high]))
        }
        if long, count > 0 {
            pool.members[0].name = String(repeating:"完整模型名称与多语言能力标识", count:12)
            pool.members[0].model = "example/" + String(repeating:"very-long-model-identifier-",count:6)
        }
        snapshot = .init()
        for (i, member) in pool.members.enumerated() where i < 5 {
            snapshot.health[member.id] = .init(successes:i % 2, failures:i == 2 ? 1 : 0,
                cooldownUntil:i == 2 ? Date().addingTimeInterval(90) : nil)
        }
        if live, count > 1 {
            snapshot.active = 1; snapshot.requests = 3
            snapshot.flights = [.init(requestID:UUID(),memberID:pool.members[1].id,
                routing:.init(kind:.coding,difficulty:.medium,source:.automatic,reason:"需要工具执行，保留执行能力"),
                phase:.streaming,attempt:1,startedAt:Date(),updatedAt:Date(),outputPulses:1)]
        }
        pool.catalog = [.init(id:"fixture/free",name:"示例发现模型",contextLength:64000,supportsTools:true,supportsImages:false,supportsJSON:true)]
    }
    var canEdit: Bool { !loading && !saving }
    @discardableResult func importModels(_ members:[FreeModelPool.Member],confirmedFree:Bool,completion:((Bool)->Void)? = nil)->Bool { completion?(false); return false }
    func change(completion:((Bool)->Void)? = nil,_ edit:(inout FreeModelPool)->Void) { edit(&pool); completion?(true) }
    func discover() {}
    func add(_ model:FreeModelPool.CatalogModel) {}
    func refreshStatus() async {}
    func observeStatus() async {}
    func resetHealth() {}
    func test(_ member:FreeModelPool.Member) {}
    func cancelTest() {}
}
'''
for path in ['Sources/ClaudeBar/Views/Shared/GatewayTopologyView.swift',
             'Sources/ClaudeBar/Views/Shared/GatewayInventoryRow.swift',
             'Sources/ClaudeBar/Views/Shared/GatewayCatalogCard.swift',
             'Sources/ClaudeBar/Views/Shared/GatewayProviderImportView.swift',
             'Sources/ClaudeBar/Views/Shared/FreeModelGatewayView.swift']:
    text = read(path)
    if 'GatewayTopologyView.swift' in path:
        text = text.replace('@Environment(\\.accessibilityReduceMotion) private var reduceMotion', 'private var reduceMotion: Bool { PreviewMotion.reduce }')
    if 'FreeModelGatewayView.swift' in path:
        text = text.replace('@State private var workspace = Workspace.pool', '@State private var workspace = PreviewScreen.discovery ? Workspace.discovery : (PreviewScreen.routes ? Workspace.routes : Workspace.pool)')
        text = text.replace('var body: some View {\n        ScrollViewReader', 'var body: some View {\n        if PreviewScreen.admission { ScrollView { admissionControls.padding(16) } } else if PreviewScreen.editor { modelEditor } else if PreviewScreen.settings { ScrollView { VStack(spacing:16) { controls; admissionControls; discoveryControls }.padding(16) } } else {\n        ScrollViewReader')
        text = text.replace('.sheet(isPresented: $showAdd) { modelEditor }\n    }', '.sheet(isPresented: $showAdd) { modelEditor }\n        }\n    }')
    if 'GatewayProviderImportView.swift' in path:
        text = text.replace('@State private var selected: Set<String> = []', '@State private var selected: Set<String> = PreviewScreen.importSelected ? ["11111111-1111-1111-1111-111111111111:example/1-free", "11111111-1111-1111-1111-111111111111:example/2-free"] : []')
        text = text.replace('@State private var confirmedFree = false', '@State private var confirmedFree = PreviewScreen.importSelected')
    if 'GatewayInventoryRow.swift' in path:
        text = text.replace('    var body: some View {\n        VStack', '    var body: some View {\n        PreviewCounts.rows += 1\n        return VStack')
    source += '\n' + text
source += "\n" + read('Sources/ClaudeBar/Models/Provider.swift')
catalog = read('Sources/ClaudeBar/Models/ProviderCatalog.swift')
source += "\n" + decl(catalog, 'enum ProviderClient:') + "\n" + decl(catalog, 'struct ProviderCatalogEntry:')
source += "\n" + read('Sources/ClaudeBar/Views/Shared/StandbyEmptyState.swift')
source += "\n" + read('Sources/ClaudeBar/Views/Shared/ProviderControls.swift')
directory = read('Sources/ClaudeBar/Views/Shared/ProviderDirectory.swift')
for marker in ['struct ProviderCategoryFilter:', 'struct ProviderDirectorySearch:', 'private struct ProviderCardSurface<', 'private struct ProviderBalanceReadout:', 'private struct ProviderDirectoryCard:', 'private struct CustomProviderDirectoryCard:']:
    source += "\n" + decl(directory, marker)
providers_page = read('Sources/ClaudeBar/Views/Pages/ProvidersView.swift')
source += r'''
private struct FixtureImportSummary { var summary = "示例导入" }
private struct FixtureProviderStore { func importFromCodex() -> FixtureImportSummary { .init() }; func importFromClaude() -> FixtureImportSummary { .init() } }
private struct ProviderConnectionRoute { var id:UUID; var isNew:Bool }
private struct ProviderHeadingPreview: View {
    @State var surfaceRaw = "gateway"
    @State private var clientRaw = "codex"
    @State private var query = ""
    @State private var category: ProviderCatalogEntry.Category?
    @State private var configuredOnly = false
    @State private var selectedID: UUID?
    @State private var importNote: String?
    @State private var connectionEdit: ProviderConnectionRoute?
    private let reduceMotion = true
    private var client: ProviderClient { ProviderClient(rawValue:clientRaw) ?? .codex }
    private let providerStore = FixtureProviderStore(), codexStore = FixtureProviderStore()
    private struct Facts { var providers:[Provider] = []; var activeID:UUID? }
    private func currentModel(_ p:Provider,activeID:UUID?) -> String? { p.activeModel?.name }
    var body: some View {
        VStack(spacing:0) {
            header
            if surfaceRaw == "providers" {
                VStack(spacing:12) { directoryToolbar; HairlineDivider(); connectionStrip(Facts()) }
                    .padding(14).panelCard(radius:Theme.Radius.md).padding(.horizontal,24)
            }
        }
    }
'''
for header_marker in ['private var header:', 'private var surfaceTabs:', 'private var providerActions:', 'private var clientSwitcher:', 'private var directoryToolbar:', 'private func connectionStrip(']:
    source += '\n' + decl(providers_page, header_marker)
source += '\n}\n'
source += r'''
// Synthetic occlusion for exercising compositor lifecycle without showing UI.
private final class VisibleFixtureWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}
@main struct Preview {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath:CommandLine.arguments[1])
        if CommandLine.arguments.contains("--check") { print("PASS: native topology, inventory and full gateway compile"); return }
        let lines = GatewayLinesView(frame: CGRect(x:0,y:0,width:500,height:300))
        let visible = VisibleFixtureWindow(contentRect:lines.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        visible.contentView = lines
        var flight = FreeModelGateway.Flight(requestID:UUID(),memberID:"fixture",routing:.init(kind:.coding,difficulty:.medium,source:.automatic,reason:"fixture"),phase:.connecting,attempt:1,startedAt:Date(),updatedAt:Date(),outputPulses:0)
        func paint(_ current: FreeModelGateway.Flight?, moving: Bool = true) {
            lines.update(links:[.init(id:"fixture",points:[CGPoint(x:10,y:20),CGPoint(x:400,y:200)],vertical:false,selected:false,enabled:true,flight:current,node:CGRect(x:400,y:180,width:90,height:60))],moving:moving)
        }
        func animations() -> Int { (lines.layer?.sublayers ?? []).reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) } }
        paint(nil); precondition(animations() == 0, "idle must have no animations")
        paint(flight); precondition(lines.layer?.sublayers?[1].animation(forKey:"travel") != nil)
        flight.phase = .streaming; flight.updatedAt = Date(); paint(flight)
        precondition((lines.layer?.sublayers?[1].animation(forKey:"travel") as? CABasicAnimation)?.toValue as? Double == 28)
        paint(flight,moving:false); precondition(animations() == 0, "reduce-motion/offscreen must stop")
        flight.phase = .succeeded; flight.updatedAt = Date(); paint(flight)
        precondition(lines.layer?.sublayers?[1].animation(forKey:"travel") == nil)
        precondition(lines.layer?.sublayers?[1].animation(forKey:"complete") != nil)
        flight.phase = .failed; flight.updatedAt = Date(); paint(flight)
        precondition(lines.layer?.sublayers?[2].animation(forKey:"pulse") != nil)
        lines.stop(); precondition(animations() == 0)
        visible.contentView = nil
        paint(flight); precondition(animations() == 0, "detached must have no animation")
        print("PASS: native idle, active travel, streaming direction, terminal pulse, reduce-motion and detach lifecycle")
        let store = FreeModelGatewayStore.shared
        for (name,width,height,dark,count,live,long) in [
            ("editor",600.0,680.0,false,1,false,false),
            ("editor-dark",600.0,680.0,true,1,false,false),
            ("settings",520.0,1300.0,false,1,false,false),
            ("settings-dark",520.0,1300.0,true,1,false,false),
            ("header",900.0,240.0,false,0,false,false),
            ("header-dark",900.0,240.0,true,0,false,false),
            ("admission",500.0,1000.0,false,5,false,false),
            ("admission-dark",500.0,1000.0,true,5,false,false),
            ("routes",900.0,1200.0,false,5,true,false),
            ("discovery",900.0,1250.0,false,0,false,false),
            ("discovery-compact",640.0,1250.0,false,0,false,false),
            ("discovery-dark",900.0,1250.0,true,0,false,false),
            ("minimum",900.0,600.0,false,5,true,false),
            ("reduced",900.0,900.0,false,5,true,false),
            ("light",900.0,1400.0,false,5,true,false),
            ("dark",900.0,1400.0,true,5,true,false),
            ("compact",640.0,1100.0,false,5,false,true),
            ("empty",640.0,640.0,false,0,false,false),
            ("large",900.0,900.0,false,200,true,false)] {
            PreviewScreen.editor = name.hasPrefix("editor")
            PreviewScreen.settings = name.hasPrefix("settings")
            PreviewScreen.admission = name.hasPrefix("admission")
            PreviewScreen.routes = name == "routes"
            PreviewScreen.discovery = name.hasPrefix("discovery")
            PreviewMotion.reduce = name == "reduced"
            AppPreferences.shared.isDark = dark
            store.seed(count:count,live:live,long:long)
            if PreviewScreen.admission {
                store.pool.maxConcurrent = 2; store.pool.defaultProviderConcurrent = 1
                store.pool.providerConcurrent[store.first.uuidString] = 1
                store.snapshot.active = 2; store.snapshot.queued = 2; store.snapshot.requests = 5
                store.snapshot.providers = [store.first:.init(active:1,queued:1,limit:1), store.second:.init(active:1,queued:1,limit:1)]
            }
            if PreviewScreen.discovery {
                store.connections[0].baseURL = "https://openrouter.ai/api/v1"
                store.pool.openRouterProviderID = store.first
                store.pool.discoveredAt = Date()
                store.pool.catalog = (0..<24).map { i in .init(id:"example/\(i)-free",name:i == 0 ? String(repeating:"多语言推理模型名称",count:8) : "Example Model \(i)",contextLength:128000,supportsTools:i%2==0,supportsImages:i%3==0,supportsJSON:true) }
            }
            PreviewCounts.rows = 0
            let view = VStack(spacing:12) {
                Text("模型池布局预览 · 示例数据").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                if !PreviewScreen.editor && !PreviewScreen.settings && !PreviewScreen.admission {
                    ProviderHeadingPreview(surfaceRaw:name.hasPrefix("header") ? "providers" : "gateway")
                }
                if !name.hasPrefix("header") { FreeModelGatewayView(onAddOpenRouter:{}) }
            }.padding(.top,16).background(Theme.bgPrimary)
             .environment(\.colorScheme,dark ? .dark : .light)

            let host = NSHostingView(rootView:view)
            host.frame = CGRect(x:0,y:0,width:width,height:height)
            host.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until:Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { fatalError("No bitmap") }
            host.cacheDisplay(in:host.bounds,to:bitmap)
            guard let png = bitmap.representation(using:.png,properties:[:]) else { fatalError("No PNG") }
            try png.write(to:out.appendingPathComponent("gateway-\(name).png"))
            if name == "large" {
                let mounted = PreviewCounts.rows
                let before = PreviewCounts.rows
                for _ in 0..<12 {
                    store.snapshot.flights[0].updatedAt = Date()
                    store.snapshot.flights[0].outputPulses += 1
                    RunLoop.current.run(until:Date().addingTimeInterval(0.01))
                }
                let refreshed = PreviewCounts.rows - before
                precondition(mounted < 100,"200-model inventory must be lazy")
                precondition(refreshed == 0,"output pulses must not redraw unchanged inventory rows")
                print("PASS: 200-model viewport mounts \(mounted) row bodies; 12 output updates redraw \(refreshed) row bodies")
            }
            window.contentView = nil
        }
        PreviewScreen.discovery = false; PreviewScreen.editor = false; PreviewScreen.settings = false; PreviewScreen.routes = false; PreviewScreen.admission = false
        store.seed(count:1,live:false)
        store.connections[0].models = (0..<8).map { .init(name:"example/\($0)-free") }
        for (name,dark,selection) in [("import",false,false),("import-selected",false,true),("import-dark",true,true),("import-blocked",false,true)] {
            AppPreferences.shared.isDark = dark; PreviewScreen.importSelected = selection
            store.connections[0].baseURL = name == "import-blocked" ? "http://example.test/v1" : "https://example.test/v1"
            let importHost = NSHostingView(rootView:GatewayProviderImportView(providerIDs:[store.first]).environment(\.colorScheme,dark ? .dark : .light))
            importHost.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
            importHost.frame = CGRect(x:0,y:0,width:620,height:680)
            let importWindow = NSWindow(contentRect:importHost.frame,styleMask:[.borderless],backing:.buffered,defer:false)
            importWindow.contentView = importHost
            RunLoop.current.run(until:Date().addingTimeInterval(0.3)); importHost.layoutSubtreeIfNeeded()
            let bitmap = importHost.bitmapImageRepForCachingDisplay(in:importHost.bounds)!
            importHost.cacheDisplay(in:importHost.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("gateway-\(name).png"))
            importWindow.contentView = nil
        }
        for dark in [false,true] {
            AppPreferences.shared.isDark = dark
            let preset = Provider(name:"示例预设配置",authToken:"fixture",baseURL:"https://example.test/v1",models:[.init(name:"example/primary-free")])
            let custom = Provider(name:String(repeating:"自定义长名称",count:8),authToken:"fixture",baseURL:"https://example.test/v1",models:[.init(name:"example/long-model-id-free")])
            let cards = VStack(spacing:16) {
                Text("供应商卡片预览 · 示例数据").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing:12) {
                    ProviderDirectoryCard(entry:ProviderCatalogEntry.entry(id:"deepseek")!,client:.codex,connections:[preset],activeID:nil,selectedID:nil,onAdd:{},onOpen:{_ in},onActivate:{_,_ in},onToggleCapture:{_,_ in})
                    CustomProviderDirectoryCard(provider:custom,active:false,selected:false,onOpen:{},onActivate:{_ in},onToggleCapture:{_ in})
                }
            }.padding(24).background(Theme.bgPrimary).environment(\.colorScheme,dark ? .dark : .light)
            let host = NSHostingView(rootView:cards);host.frame = CGRect(x:0,y:0,width:610,height:300)
            let window = NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false);window.contentView = host
            RunLoop.current.run(until:Date().addingTimeInterval(0.3));host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
            host.cacheDisplay(in:host.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("gateway-provider-\(dark ? "dark" : "light").png"))
            window.contentView = nil
        }
        print("Rendered current native gateway to \(out.path)")
    }
}
'''
path = out / 'Probe.swift'; path.write_text(source)
binary = out / 'probe'
subprocess.run(['swiftc','-O','-parse-as-library','-target','arm64-apple-macos15.0',str(path),'-o',str(binary)],check=True)
subprocess.run([str(binary),str(out),*sys.argv[1:]],check=True)
