#!/usr/bin/env python3
"""Page presentation and native container probes; synthetic data, no app stores or controls."""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline-dir', type=Path)
p.add_argument('--keep-fixture', type=Path)
p.add_argument('--output-json', type=Path)
p.add_argument('--profile', action='store_true')
p.add_argument('--compile-only', action='store_true')
a = p.parse_args()
if a.compile_only and not a.keep_fixture:
    p.error('--compile-only requires --keep-fixture')

def read(name, folder):
    path = a.baseline_dir / name if a.baseline_dir and (a.baseline_dir / name).exists() else root / folder / name
    return path.read_text()

def decl(s, marker):
    start = s.index(marker); opening = s.index('{', start); i = opening + 1; depth = 1
    while depth:
        depth += (s[i] == '{') - (s[i] == '}'); i += 1
    return s[start:i]

connect = read('ConnectorsView.swift', 'Sources/ClaudeBar/Views/Pages')
sessions = read('SessionsView.swift', 'Sources/ClaudeBar/Views/Pages')
domain = (root / 'Sources/ClaudeBar/Models/ConnectorManager.swift').read_text()
domain = domain[:domain.index('/// Reads local connector metadata only.')]
cache = decl(connect, '@MainActor private final class ConnectorInventoryCache') if 'final class ConnectorInventoryCache' in connect else ''
methods = '\n'.join(decl(connect, marker).replace('private ', '') for marker in [
    'private var visibleRecords:', 'private var visibleCLIs:', 'private func relatedCount(', 'private func kind(of', 'private func matches('])
# Count work at the real filter closures, not merely the computed accessors.
methods = methods.replace('record.kind == kind &&', 'Counter.recordChecks += 1\n                return record.kind == kind &&')
methods = methods.replace('search.isEmpty || cli.name.', 'Counter.cliChecks += 1\n                return search.isEmpty || cli.name.')
methods = methods.replace('manager.records.reduce(0) { $0 + ($1.sharedOwner == name ? 1 : 0) }', 'manager.records.reduce(0) { Counter.ownerVisits += 1; return $0 + ($1.sharedOwner == name ? 1 : 0) }')
cache = cache.replace('for record in records {', 'for record in records {\n                Counter.ownerVisits += 1')
source = r'''
import SwiftUI
import AppKit
import Observation
import CryptoKit
enum Theme {
    static let claude = Color.blue
    static func textTertiary() -> Color { .secondary }
    static func djb2(_ s: String) -> Int { 0 }
    enum Ink { static let claude = Color.blue, success = Color.green }
    enum Space { static let s8: CGFloat = 8, s12: CGFloat = 12, gridGapPage: CGFloat = 16, gridGap: CGFloat = 12 }
    enum Font { static let body = SwiftUI.Font.body }
    enum GridLayout {
        enum Preset { case pageSession, pageUsage, pageMetric, pageProvider, pageSetting, pageSettingDense, popupSession, popupProvider, popupUsage }
        static func equalRow(_ p: Preset) -> (fixed: Int?, minWidth: CGFloat) { (nil, 280) }
    }
}
enum ProductBrandMark { enum Brand { case claude, codex, cursor } }
struct SectionHeader: View {
    let icon: String, title: String
    var brand: Bool?; var mark: ProductBrandMark.Brand?
    let tint: Color, ink: Color, count: Int, activeCount: Int
    var note: String?; var noteTint: Color
    var body: some View { Text(title + " \(count)").frame(height: 24) }
}
enum Counter {
    static var bodies = 0, recordChecks = 0, cliChecks = 0, ownerVisits = 0, providerVisits = 0, urlNormalizations = 0
    static var ids = Set<Int>(), appeared = Set<Int>()
    static var imagePath = ""
}
struct Agent { enum Status { case running, done }; let status: Status }
struct SessionInfo: Identifiable {
    let id: Int; var subagents: [Agent] = []; var workflows: [String] = []; var isAlive = true
    var title = "Synthetic session"
}
@Observable @MainActor final class SessionStore {
    var sessions: [SessionInfo]
    init(_ s: [SessionInfo]) { sessions = s }
    var aliveSessions: [SessionInfo] { sessions.filter(\.isAlive) }
    var busySessionCount: Int { 0 }
}
@Observable @MainActor final class ScrollState { var target: Int? }
struct SessionTileFull: View {
    let session: SessionInfo
    var body: some View {
        Counter.bodies += 1; Counter.ids.insert(session.id)
        return VStack { Text("\(session.title) \(session.id)"); Text("Synthetic content").lineLimit(2) }
            .frame(maxWidth: .infinity).frame(height: 160).background(Color.blue.opacity(0.1))
            .onAppear { Counter.appeared.insert(session.id) }
    }
}
struct SessionPage: View {
    let providerStore: SessionStore
    let scroll: ScrollState
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) { Text("Sessions"); claudeSection }.padding(24).id(-1)
            }.onChange(of: scroll.target) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
        }
    }
'''
source += '\n' + '\n'.join(decl(sessions, marker) for marker in ['private var claudeSection:', 'private static func claudeHasLiveWork', 'private func sectionContainer', 'private func emptyHint']) + '\n}\n'
tile = (root / 'Sources/ClaudeBar/Views/Shared/Tile.swift').read_text()
source += tile[tile.index('struct TileGrid<'):]
source += '\n' + domain + '\n' + cache + '\n' + decl(connect, 'private enum ConnectorFocus').replace('private enum', 'enum')
source += '''
@MainActor final class Inventory {
    var records: [ConnectorRecord] = []
    var pluginContents: [String: PluginBundleContents] = [:]
    var localCLIs: [LocalCLIRecord] = []
}
@MainActor final class ConnectorPage {
    let manager: Inventory
    var focus: ConnectorFocus = .plugin
    var platform: ConnectorPlatform?
    var search = ""
''' + ('    private let inventoryCache = ConnectorInventoryCache()\n' if cache else '') + '    init(_ manager: Inventory) { self.manager = manager }\n' + methods + '\n}\n'
# Frozen filter semantics, independent of the cache and gitignored artifacts.
oracle_methods = r'''
    var visibleRecords: [ConnectorRecord] {
        guard focus != .local else { return [] }
        let k = kind(of: focus), needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return manager.records.filter { r in
            r.kind == k && (platform.map { r.platforms.contains($0) } ?? true) &&
            (needle.isEmpty || r.name.localizedStandardContains(needle) || r.scope.localizedStandardContains(needle) ||
             r.platforms.contains { $0.title.localizedStandardContains(needle) } || r.sharedOwner?.localizedStandardContains(needle) == true ||
             manager.pluginContents[r.id]?.items.contains { $0.name.localizedStandardContains(needle) } == true)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var visibleCLIs: [LocalCLIRecord] { manager.localCLIs.filter {
        search.isEmpty || $0.name.localizedStandardContains(search) || $0.summary.localizedStandardContains(search) || $0.category.localizedStandardContains(search)
    } }
'''
source += '@MainActor struct OriginalConnectorPage { let manager: Inventory; let focus: ConnectorFocus; let platform: ConnectorPlatform?; let search: String\n' + decl(connect, 'private func kind(of').replace('private ', '') + oracle_methods + '\n}\n'
catalog = read('ProviderCatalog.swift', 'Sources/ClaudeBar/Models')
directory = read('ProviderDirectory.swift', 'Sources/ClaudeBar/Views/Shared')
entry = decl(catalog, 'struct ProviderCatalogEntry:').replace('static func identityURL(_ raw: String) -> String {', 'static func identityURL(_ raw: String) -> String {\n        Counter.urlNormalizations += 1')
source += '\n' + (root / 'Sources/ClaudeBar/Models/Provider.swift').read_text() + '\n' + decl(catalog, 'enum ProviderClient:') + '\n' + entry
partition = decl(directory, 'private var partition:').replace('private ', '').replace('for provider in providers {', 'for provider in providers {\n                Counter.providerVisits += 1')
partition_type = decl(directory, 'private struct Partition {').replace('private ', '')
partition_cache = decl(directory, '@MainActor private final class PartitionCache').replace('private ', '') if 'final class PartitionCache' in directory else ''
source += '\n@MainActor final class ProviderPage { var providers: [Provider]; init(_ providers: [Provider]) { self.providers = providers }\n' + partition_type + '\n' + partition_cache + '\n'
if partition_cache:
    source += 'let partitionCache = PartitionCache()\n'
source += partition + '\n}\n'
# Production catalog and URL identity; freeze the prior linear lookup.
source += r'''
func originalCatalogHits(_ raw: String) -> [ProviderCatalogEntry] {
    let value = ProviderCatalogEntry.identityURL(raw)
    guard !value.isEmpty else { return [] }
    return ProviderCatalogEntry.all.filter { $0.identityURLs.contains(value) }
}
func originalCatalogMatch(_ raw: String) -> ProviderCatalogEntry? {
    let hits = originalCatalogHits(raw)
    if hits.count <= 1 { return hits.first }
    return hits.first { $0.category == .coding } ?? hits.first
}
@MainActor func originalPartition(_ providers: [Provider]) -> ProviderPage.Partition {
    var buckets: [String: [Provider]] = [:], custom: [Provider] = []
    for p in providers {
        if let id = p.catalogID ?? originalCatalogMatch(p.baseURL)?.id { buckets[id, default: []].append(p) }
        else { custom.append(p) }
    }
    return .init(buckets: buckets, custom: custom)
}
'''
source += r'''
func require(_ ok: @autoclosure () -> Bool, _ message: String) { if !ok() { FileHandle.standardError.write(Data(("FAIL " + message + "\n").utf8)); exit(1) } }
func ms(_ body: () -> Void) -> Double { let s = ContinuousClock.now; body(); let d = s.duration(to: .now).components; return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15 }
@MainActor func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
@MainActor func digest<V: View>(_ h: NSHostingView<V>) -> String {
    h.layoutSubtreeIfNeeded(); let bitmap = h.bitmapImageRepForCachingDisplay(in: h.bounds)!
    h.cacheDisplay(in: h.bounds, to: bitmap)
    let png = bitmap.representation(using: .png, properties: [:])!
    if !Counter.imagePath.isEmpty { try! png.write(to: URL(fileURLWithPath: Counter.imagePath)) }
    return SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
}
@main struct Regression {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        if PROFILE { Thread.sleep(forTimeInterval: 1) }
        var metrics: [String: Any] = [:]
        for scenario in ["resting", "live", "mixed"] {
            let store = SessionStore((0..<1000).map { SessionInfo(id: $0, workflows: scenario == "live" || (scenario == "mixed" && $0 % 2 == 0) ? ["live"] : []) })
            let scroll = ScrollState()
            Counter.bodies = 0; Counter.ids = []; Counter.appeared = []
            let started = ContinuousClock.now
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: SessionPage(providerStore: store, scroll: scroll)); host.sizingOptions = []
            window.contentView = host; host.frame = window.contentLayoutRect
            host.layoutSubtreeIfNeeded(); settle(); _ = digest(host)
            let d = started.duration(to: .now).components
            let elapsed = Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
            metrics["\(scenario)_initial_cards"] = Counter.ids.count
            metrics["\(scenario)_initial_ms"] = elapsed
            metrics["\(scenario)_top_sha256"] = digest(host)
            if MODERN { require(Counter.ids.count < 50, "Session container must materialize only a viewport: " + scenario) }
            require(Counter.appeared.contains(0), "first card appears")
            scroll.target = 500; settle(); _ = digest(host)
            require(Counter.appeared.contains(500), "middle card appears")
            metrics["\(scenario)_middle_sha256"] = digest(host)
            scroll.target = 998; settle(); _ = digest(host)
            require(Counter.appeared.contains(998), "target 998 appears, including the mixed-list boundary")
            Counter.imagePath = IMAGE_FOLDER.isEmpty ? "" : IMAGE_FOLDER + "/" + scenario + "-tail.png"
            metrics["\(scenario)_tail_sha256"] = digest(host)
            Counter.imagePath = ""
            scroll.target = -1; settle(); _ = digest(host)
            require(metrics["\(scenario)_top_sha256"] as! String == digest(host), "scroll back preserves top")
            store.sessions[0].title = "Changed title"; settle()
            require(metrics["\(scenario)_top_sha256"] as! String != digest(host), "visible session changes redraw")
            window.orderOut(nil)
        }
        let inventory = Inventory()
        inventory.records = (0..<2000).map { i in
            ConnectorRecord(id: "r\(i)", name: "插件 \(2000-i)", summary: "fixture", kind: ConnectorKind.allCases[(i + 2) % 3],
                            platforms: i % 2 == 0 ? [.claude, .cursor] : [.codex], scope: "项目 \(i % 5)", source: URL(fileURLWithPath: "/synthetic/\(i)"), enabled: true, method: .native, sharedOwner: "cli\(i % 200)")
        }
        inventory.localCLIs = (0..<200).map { LocalCLIRecord(name: "cli\($0)", category: "Tools", summary: "命令 \($0)", source: URL(fileURLWithPath: "/synthetic/cli\($0)")) }
        inventory.pluginContents = ["r0": .init(items: [.init(kind: "Skill", name: "hidden skill unique")])]
        let page = ConnectorPage(inventory)
        func parity() {
            let oracle = OriginalConnectorPage(manager: inventory, focus: page.focus, platform: page.platform, search: page.search)
            require(page.visibleRecords == oracle.visibleRecords, "record filter/order/content parity")
            let expected = page.focus == .local ? oracle.visibleCLIs : []
            require(page.visibleCLIs == (MODERN ? expected : oracle.visibleCLIs), "CLI filter parity")
        }
        for f in ConnectorFocus.allCases { for platform in [nil] + ConnectorPlatform.allCases.map(Optional.some) {
            for search in ["", "  ", "CLAUDE", "项目 3", "插件 19", "hidden skill unique", "cli17", "命令", "missing", "插件"] {
                page.focus = f; page.platform = platform; page.search = search; parity()
            }
        } }
        page.focus = .plugin; page.platform = nil; page.search = ""; parity()
        Counter.recordChecks = 0; Counter.cliChecks = 0; Counter.ownerVisits = 0
        let repeats = PROFILE ? 240 : 30
        var sink = 0
        metrics["connector_repeated_filter_ms"] = ms {
            for _ in 0..<repeats { sink += page.visibleRecords.count + page.visibleCLIs.count }
        }
        metrics["connector_repeat_record_checks"] = Counter.recordChecks
        metrics["connector_repeat_cli_checks"] = Counter.cliChecks
        page.focus = .local; page.search = ""; parity()
        for cli in inventory.localCLIs { _ = page.relatedCount(cli.name) }
        Counter.ownerVisits = 0
        metrics["connector_repeated_owner_counts_ms"] = ms {
            for _ in 0..<repeats { for cli in inventory.localCLIs { sink += page.relatedCount(cli.name) } }
        }
        metrics["connector_repeat_owner_visits"] = Counter.ownerVisits
        if MODERN {
            require(metrics["connector_repeat_record_checks"] as! Int == 0 && metrics["connector_repeat_cli_checks"] as! Int == 0, "unchanged state must reuse filters")
            require(Counter.ownerVisits == 0, "unchanged local cards must reuse shared-owner counts")
        }
        let first = inventory.records[0]
        inventory.records[0] = .init(id: first.id, name: first.name, summary: first.summary, kind: first.kind,
                                    platforms: first.platforms, scope: first.scope, source: first.source,
                                    enabled: false, method: first.method, sharedOwner: first.sharedOwner)
        page.focus = .plugin; parity()
        require(page.visibleRecords.first { $0.id == "r0" }?.enabled == false, "state copy must update")
        inventory.records[0].sharedOwner = "new-owner"
        require(page.relatedCount("new-owner") == 1 && page.relatedCount("cli0") == 9, "owner changes invalidate counts")
        inventory.records[0] = .init(id: first.id, name: "Renamed", summary: first.summary, kind: first.kind,
                                    platforms: [.codex], scope: first.scope, source: first.source,
                                    enabled: false, method: first.method, sharedOwner: "new-owner")
        parity()
        page.search = "hidden skill unique"; parity()
        inventory.pluginContents["r0"] = .init(items: []); parity(); require(page.visibleRecords.isEmpty, "contents changes invalidate search")
        inventory.records.removeFirst(); parity()
        page.focus = .local; page.search = "new-cli"; parity()
        inventory.localCLIs.append(.init(name: "new-cli", category: "Tools", summary: "new", source: URL(fileURLWithPath: "/synthetic/new"))); parity()
        require(page.visibleCLIs.count == 1, "CLI changes invalidate search")
        inventory.records = []; inventory.localCLIs = []; inventory.pluginContents = [:]; parity()
        require(page.relatedCount("cli1") == 0 && sink > 0, "empty inventory invalidation")
        var urls = ["", "bad URL", "https://unknown.example.test/v1", "http://localhost:11434/v1", "https://api.openai.com:444/v1"]
        for entry in ProviderCatalogEntry.all {
            for endpoint in [entry.claude?.baseURL, entry.codex?.baseURL, entry.codex?.chatBaseURL].compactMap({ $0 }) {
                urls += [endpoint, endpoint + "/", endpoint + "/v1/messages", endpoint + "/responses", endpoint + "/models?query=synthetic#fixture", "  " + endpoint + "  ", endpoint.uppercased()]
            }
        }
        for url in urls {
            require(ProviderCatalogEntry.matchingAll(baseURL: url).map(\.id) == originalCatalogHits(url).map(\.id), "endpoint order/deduplication")
            require(ProviderCatalogEntry.matching(baseURL: url)?.id == originalCatalogMatch(url)?.id, "coding-plan priority")
        }
        let listedURL = ProviderCatalogEntry.all.first { $0.claude != nil }!.claude!.baseURL
        let providerPage = ProviderPage((0..<300).map { i in
            Provider(name: "Synthetic provider \(i)", baseURL: i % 3 == 0 ? "https://unknown.example.test/v1" : listedURL,
                     models: [.init(name: "model-\(i)")], catalogID: i % 7 == 0 ? "synthetic-explicit" : nil)
        })
        func providerParity() {
            let actual = providerPage.partition, expected = originalPartition(providerPage.providers)
            require(actual.buckets == expected.buckets && actual.custom == expected.custom, "provider partition and full values")
        }
        providerParity()
        Counter.providerVisits = 0; Counter.urlNormalizations = 0
        metrics["provider_repeated_partition_ms"] = ms {
            for _ in 0..<repeats { let p = providerPage.partition; sink += p.custom.count + p.buckets.count }
        }
        metrics["provider_repeat_row_visits"] = Counter.providerVisits
        metrics["provider_repeat_url_normalizations"] = Counter.urlNormalizations
        if MODERN { require(Counter.providerVisits == 0, "unchanged provider presentation must reuse partition") }
        Counter.urlNormalizations = 0
        metrics["provider_index_lookups_ms"] = ms {
            for i in 0..<2000 { sink += ProviderCatalogEntry.matchingAll(baseURL: urls[i % urls.count]).count }
        }
        metrics["provider_index_url_normalizations"] = Counter.urlNormalizations
        if MODERN { require(Counter.urlNormalizations == 2000, "warm endpoint lookups must normalize only their input") }
        providerPage.providers[1].name = "Renamed"; providerParity()
        providerPage.providers[1].baseURL = "https://unknown.example.test/v1"; providerParity()
        providerPage.providers[1].catalogID = "changed-explicit"; providerParity()
        providerPage.providers[1].authToken = "synthetic-value"; providerParity()
        providerPage.providers[1].models[0].name = "changed-model"; providerParity()
        providerPage.providers[1].activeModelID = providerPage.providers[1].models[0].id; providerParity()
        providerPage.providers[1].captureEnabled = true; providerParity()
        providerPage.providers.removeFirst(); providerParity()
        providerPage.providers.reverse(); providerParity()
        providerPage.providers = []; providerParity()
        metrics["provider_url_parity_cases"] = urls.count
        metrics["cycles"] = repeats
        print("METRICS " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
        print("PASS production session containers, connector filters/counts and provider index/partition, scrolling, source changes and cache invalidation")
    }
}
'''
source = source.replace('IMAGE_FOLDER', json.dumps(str(a.keep_fixture.resolve()) if a.keep_fixture else ''))
# Only an explicitly requested prior-source comparison may relax work-count
# gates. Removing a production cache must not silently disable its regression.
source = source.replace('PROFILE', 'true' if a.profile else 'false').replace('MODERN', 'false' if a.baseline_dir else 'true')
with tempfile.TemporaryDirectory(prefix='claudebar-page-frontend-') as tmp:
    folder = a.keep_fixture or Path(tmp); folder.mkdir(parents=True, exist_ok=True)
    path = folder / 'probe.swift'; path.write_text(source); binary = folder / 'probe'
    subprocess.run(['swiftc', '-O', '-g', '-parse-as-library', '-module-name', 'ClaudeBar', '-target', 'arm64-apple-macos15.0', str(path), '-o', str(binary)], check=True)
    if not a.compile_only:
        result = subprocess.run([str(binary)], text=True, capture_output=True)
        print(result.stdout, end='', flush=True)
        if result.returncode:
            print(result.stderr, end='', flush=True); result.check_returncode()
        if a.output_json:
            a.output_json.write_text(json.dumps(next(json.loads(x[8:]) for x in result.stdout.splitlines() if x.startswith('METRICS ')), indent=2) + '\n')
