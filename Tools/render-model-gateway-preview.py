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
for path in ['Sources/ClaudeBar/Views/Shared/SettingsControls.swift',
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
struct CodexModelConfig: Identifiable { var id = UUID(); var name: String }
struct CodexProvider: Identifiable {
    var id: UUID; var name: String; var baseURL: String; var apiKey = "preview-key"; var models: [CodexModelConfig]
    var activeModel: CodexModelConfig? { models.first }
}
enum PreviewCounts { static var rows = 0 }
@MainActor final class FreeModelGatewayStore: ObservableObject {
    static let shared = FreeModelGatewayStore()
    @Published var pool = FreeModelPool()
    @Published var loading = false
    @Published var saving = false
    @Published var discovering = false
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
    func change(_ edit:(inout FreeModelPool)->Void) { edit(&pool) }
    func discover() {}
    func add(_ model:FreeModelPool.CatalogModel) {}
    func refreshStatus() async {}
    func observeStatus() async {}
    func resetHealth() {}
}
'''
for path in ['Sources/ClaudeBar/Views/Shared/GatewayTopologyView.swift',
             'Sources/ClaudeBar/Views/Shared/GatewayInventoryRow.swift',
             'Sources/ClaudeBar/Views/Shared/FreeModelGatewayView.swift']:
    text = read(path)
    if 'GatewayInventoryRow.swift' in path:
        text = text.replace('    var body: some View {\n        VStack', '    var body: some View {\n        PreviewCounts.rows += 1\n        return VStack')
    source += '\n' + text
source += r'''
@main struct Preview {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath:CommandLine.arguments[1])
        if CommandLine.arguments.contains("--check") { print("PASS: native topology, inventory and full gateway compile"); return }
        let store = FreeModelGatewayStore.shared
        for (name,width,height,dark,count,live,long) in [
            ("light",900.0,1400.0,false,5,true,false),
            ("dark",900.0,1400.0,true,5,true,false),
            ("compact",640.0,1100.0,false,5,false,true),
            ("empty",640.0,640.0,false,0,false,false),
            ("large",900.0,900.0,false,200,true,false)] {
            AppPreferences.shared.isDark = dark
            store.seed(count:count,live:live,long:long)
            PreviewCounts.rows = 0
            let view = VStack(spacing:12) {
                Text("模型池布局预览 · 示例数据").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                FreeModelGatewayView(onAddOpenRouter:{})
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
        print("Rendered current native gateway to \(out.path)")
    }
}
'''
path = out / 'Probe.swift'; path.write_text(source)
binary = out / 'probe'
subprocess.run(['swiftc','-O','-parse-as-library','-target','arm64-apple-macos15.0',str(path),'-o',str(binary)],check=True)
subprocess.run([str(binary),str(out),*sys.argv[1:]],check=True)
