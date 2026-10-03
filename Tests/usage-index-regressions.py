#!/usr/bin/env python3
"""Production index, parser, migration and proxy rollups in temporary files only."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
utils = root / 'Sources/ClaudeBar/Utils'


def declaration(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


models = (root / 'Sources/ClaudeBar/Models/ModelUsage.swift').read_text()
source = 'import Foundation\nimport SQLite3\nimport Combine\nstruct Color {}\nenum Theme { static let claude = Color(); static let codex = Color(); static let cursor = Color(); enum Ink { static let claude = Color(); static let codex = Color(); static let cursor = Color() } }\n'
source += '\n'.join(declaration(models, m) for m in [
    'enum UsageSource', 'struct ModelUsage', 'struct DayUsage', 'enum UsageProviderAttribution'])
source += r'''
enum DiskPersistence { static var useDatabase = true }
enum FilePaths {
    static var root = URL(fileURLWithPath: CommandLine.arguments[1])
    static var claudeDir: URL { root.appendingPathComponent("claude") }
    static var logsDir: URL { root }
    static var usageFilesJSON: URL { root.appendingPathComponent("files.json") }
    static var usageRollupJSONL: URL { root.appendingPathComponent("rollup.jsonl") }
    static var usageClaimsJSONL: URL { root.appendingPathComponent("usage-claims.jsonl") }
}
enum ExternalAgentKind {
    case codex
    var rawValue: String { "codex" }
    var rootDir: String { FilePaths.root.appendingPathComponent("codex/sessions").path }
}
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
'''
source += (utils / 'JSONCoerce.swift').read_text()
source += declaration((utils / 'UsageJSONStore.swift').read_text(), 'final class UsageJSONStore') + '\n'
source += declaration((utils / 'UsageClaims.swift').read_text(), 'enum UsageClaims') + '\n'
for filename, marker, name in [
    ('UsageIndex.swift', 'struct UsageIndex', 'index.db'),
    ('ProxyUsageStore.swift', 'final class ProxyUsageStore', 'proxy.db')]:
    text = declaration((utils / filename).read_text(), marker)
    start = text.index('    private static let dbURL: URL = {')
    end = text.index('    }()', start) + len('    }()')
    # Inject only the storage URL. All production parsing, SQL and migration run unchanged.
    text = text[:start] + f'    private static var dbURL: URL {{ FilePaths.root.appendingPathComponent("{name}") }}' + text[end:]
    source += text + "\n"
source += (utils / 'ModelPricing.swift').read_text()
source += (utils / 'ModelPriceTable.swift').read_text()
source += (utils / 'UsageModelInventory.swift').read_text()
provider = (root / 'Sources/ClaudeBar/Models/ProviderStore.swift').read_text()
source += r'''
final class PublicationFixture {
    var usageStats: [ModelUsage] = []
    var usageBySource: [UsageSource: [ModelUsage]] = [:]
    var usageTokensByModel: [UsageSource: [String: Int]] = [:]
    var usageDays: [DayUsage] = []
    var usagePublishedInterval: DateInterval?
    var usageLoading = false
    var usageCostLines: [String: ModelPricing.Estimate.Line] = [:]
    PRICE_PUBLICATION
    func apply(_ stats: [ModelUsage], daily: [String: [ModelUsage]], interval: DateInterval) {
        publishUsage(stats, [:], [], dailyModels: daily, interval: interval)
    }
'''
publication = next(line.strip() for line in provider.splitlines() if 'var usageEstimate = ' in line)
source = source.replace('PRICE_PUBLICATION', publication)
observation = (root / 'Sources/ClaudeBar/Models/ScopedStoreObservation.swift').read_text()
assert 'changes($usageEstimate)' in observation, 'price-only updates must invalidate usage views'
for marker in ['private func publishUsage(', 'private func publishPrices(']:
    source += declaration(provider, marker) + '\n'
source += '}\n'
source += r'''
func require(_ condition: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL at fixture line \(line): \(message)\n".utf8)); exit(1)
    }
}
@main struct Regression {
    static func main() throws {
        let fm = FileManager.default
        let base = FilePaths.root
        for sqlite in [true, false] {
            DiskPersistence.useDatabase = sqlite
            FilePaths.root = base.appendingPathComponent(sqlite ? "sqlite" : "json")
            UsageIndex.reloadPersistence(); ProxyUsageStore.shared.reset()
            let sessions = FilePaths.root.appendingPathComponent("codex/sessions")
            let archive = FilePaths.root.appendingPathComponent("codex/archived_sessions")
            let claude = FilePaths.claudeDir.appendingPathComponent("projects/project")
            for url in [sessions, archive, claude] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            let rollout = sessions.appendingPathComponent("rollout-session.jsonl")
            func line(_ obj: [String: Any]) -> String {
                String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self) + "\n"
            }
            func event(_ input: Int, _ output: Int, _ cached: Int, day: String = "2026-10-01",
                       turn: [String: Int]? = nil) -> String {
                var info: [String: Any] = ["total_token_usage": ["input_tokens": input,
                    "output_tokens": output, "cached_input_tokens": cached, "total_tokens": input + output]]
                if let turn { info["last_token_usage"] = turn }
                return line(["type": "event_msg", "timestamp": day + "T12:00:00Z",
                    "payload": ["type": "token_count", "info": info]])
            }
            func append(_ text: String) throws { try append(text, to: rollout) }
            func append(_ text: String, to url: URL) throws {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); try handle.close()
            }
            let header = line(["type": "turn_context", "payload": ["model": "audit-model"]])
            try Data((header + event(100, 10, 60)).utf8).write(to: rollout)
            UsageIndex.updateIndex()
            func period(_ start: String, _ end: String) -> DateInterval {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                return DateInterval(start: f.date(from: start)!, end: f.date(from: end)!)
            }
            let interval = period("2026-10-01", "2026-10-03")
            func total() -> Int { UsageIndex.fetch(in: interval).reduce(0) { $0 + $1.totalTokens } }
            require(total() == 110, "backend \(sqlite) initial total \(total()) rows \(UsageIndex.fetchBySource(in: interval))")
            try append(event(100, 10, 60)) // duplicate across append boundary
            UsageIndex.updateIndex(); require(total() == 110)
            try append(event(140, 15, 80, day: "2026-10-02")) // cumulative-only delta
            UsageIndex.updateIndex(); require(total() == 155)
            require(UsageIndex.fetchDaily(in: interval).map(\.totalTokens) == [110, 45])
            let last = ["input_tokens": 30, "output_tokens": 5, "cached_input_tokens": 20]
            try append(event(170, 20, 100, day: "2026-10-02", turn: last))
            UsageIndex.updateIndex(); require(total() == 190)
            try append(event(170, 20, 100, day: "2026-10-02", turn: last))
            UsageIndex.updateIndex(); require(total() == 190)
            let duplicate = event(170, 20, 100, day: "2026-10-02", turn: last)
            try append(String(duplicate.dropLast(12)))
            UsageIndex.updateIndex(); require(total() == 190, "partial trailing line must wait")
            try append(String(duplicate.suffix(12)))
            UsageIndex.updateIndex(); require(total() == 190)
            // Archive moves preserve all historical rows; repeated rescans are idempotent.
            try fm.moveItem(at: rollout, to: archive.appendingPathComponent(rollout.lastPathComponent))
            UsageIndex.updateIndex(); UsageIndex.updateIndex(); require(total() == 190)
            // A shrink/rewrite replaces the path's rollup rows, so a rollout
            // whose body is rewritten down to its header must lose every token
            // it used to account for — under both backends. This is the only
            // shape that reaches the full-reparse path's empty branch; the
            // archive move above re-parses under a new key and would pass even
            // if a shrunk file kept its stale rows forever. Claude's transcript
            // is rewritten to empty in the same pass, so one call covers both
            // parsers.
            let archivedRollout = archive.appendingPathComponent(rollout.lastPathComponent)
            let fullBody = try Data(contentsOf: archivedRollout)
            try Data(header.utf8).write(to: archivedRollout)
            try Data().write(to: claude.appendingPathComponent("session.jsonl"))
            UsageIndex.reloadPersistence(); ProxyUsageStore.shared.reset()
            UsageIndex.updateIndex()
            let shrunk = UsageIndex.fetchBySource(in: interval)
            require(shrunk.values.flatMap { $0 }.reduce(0) { $0 + $1.totalTokens } == 0,
                    "a shrunk rewrite must not keep stale rows on backend \(sqlite): \(shrunk)")
            // …and the next append is counted as its own delta, not as a
            // rebuild of everything the rewritten file used to hold.
            try append(event(100, 10, 60), to: archivedRollout)
            UsageIndex.updateIndex()
            require(total() == 110, "backend \(sqlite) post-rewrite append \(total()) rows \(UsageIndex.fetchBySource(in: interval))")
            // Put the original transcript back so the rest of the scenario
            // keeps its baseline. It returns as a *new* path (vanished files
            // are pruned with their rows), which is how a restored transcript
            // re-indexes in full.
            try fm.removeItem(at: archivedRollout)
            UsageIndex.updateIndex()
            try fullBody.write(to: archivedRollout)
            UsageIndex.updateIndex()
            require(total() == 190, "backend \(sqlite) restored transcript \(total()) rows \(UsageIndex.fetchBySource(in: interval))")
            func assistant(_ output: Int) -> String {
                line(["type": "assistant", "timestamp": "2026-10-01T12:00:00Z",
                    "message": ["id": "message-id", "model": "audit-model",
                        "usage": ["input_tokens": 20, "output_tokens": output,
                                  "cache_read_input_tokens": 30, "cache_creation_input_tokens": 40]]])
            }
            try Data((assistant(1) + assistant(10)).utf8).write(to: claude.appendingPathComponent("session.jsonl"))
            UsageIndex.updateIndex(); require(total() == 290) // last-wins message ID
            // A resumed session copies the parent's assistant records verbatim
            // into a new transcript: same `message.id`, same usage, second
            // path. The id is one API call, so whichever file is indexed first
            // books it and the copy books nothing — a per-file dedupe cannot
            // see this, which is why 103M tokens were counted twice on this
            // machine's own corpus. The reverse order must give the same total.
            let fork = claude.appendingPathComponent("fork.jsonl")
            try Data(assistant(10).utf8).write(to: fork)
            UsageIndex.updateIndex()
            require(total() == 290, "a resumed transcript re-booked its parent's message id: \(total())")
            try fm.removeItem(at: fork)
            UsageIndex.updateIndex()
            require(total() == 290, "releasing a fork's claim changed the total: \(total())")
            let date = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
            ProxyUsageStore.shared.record(model: "audit-model", at: date, input: 30, output: 10,
                                          cacheRead: 40, cacheWrite: 10)
            require(total() == 380)
            let sources = UsageIndex.fetchBySource(in: interval)
            require(sources.values.flatMap { $0 }.reduce(0) { $0 + $1.totalTokens } == total())
            require(UsageIndex.fetchDaily(in: interval).reduce(0) { $0 + $1.totalTokens } == total())
            require(UsageIndex.fetchDailyModels(in: interval).values.flatMap { $0 }
                .reduce(0) { $0 + $1.totalTokens } == total())
            require(UsageIndex.fetchDailyBySource(in: interval).values.flatMap { $0 }
                .reduce(0) { $0 + $1.totalTokens } == total())
            // Persisted JSON parser state must reload without triggering a stale rebuild.
            UsageIndex.reloadPersistence(); ProxyUsageStore.shared.reset()
            require(total() == 380)
            UsageIndex.updateIndex(); require(total() == 380)
            require(UsageIndex.fetch(in: period("2026-10-03", "2026-10-04")).isEmpty)
            let publish = PublicationFixture()
            var priceSignals = 0
            let subscription = publish.$usageEstimate.dropFirst().sink { _ in priceSignals += 1 }
            defer { subscription.cancel() }
            let model = ModelUsage(model: "audit-priced", inputTokens: 1_000_000)
            func price(_ amount: Double, from: String) -> ModelPricing.PriceOverride {
                .init(slug: "audit-priced", rate: .init(currency: .usd, input: amount, output: 4,
                    cacheRead: 0.2, cacheWrite: 2), unpriced: nil, effectiveFrom: from, source: .manual)
            }
            ModelPricing.replaceOverrides(["audit-priced": [price(2, from: "2026-10-01")]])
            publish.apply([model], daily: ["2026-10-01": [model]], interval: interval)
            require(publish.usageEstimate.cost.usd == 2)
            ModelPricing.replaceOverrides(["audit-priced": [price(3, from: "2026-10-01")]])
            publish.apply([model], daily: ["2026-10-01": [model]], interval: interval)
            require(publish.usageEstimate.cost.usd == 3, "price-only changes must refresh money")
            require(priceSignals == 2, "price-only changes must publish a UI update")
            ModelPricing.replaceOverrides(["audit-priced": [price(2, from: "2026-10-01"), price(4, from: "2026-10-02")]])
            publish.apply([model], daily: ["2026-10-02": [model]], interval: interval)
            require(publish.usageEstimate.cost.usd == 4, "equal totals with different usage days must be repriced")
            ModelPricing.replaceOverrides([:])
            try Data(event(50, 5, 30, day: "2026-10-04").utf8)
                .write(to: archive.appendingPathComponent("unknown-model.jsonl"))
            UsageIndex.updateIndex()
            let unknown = UsageIndex.fetch(in: period("2026-10-04", "2026-10-05"))
            require(unknown.count == 1 && unknown[0].model == "unknown" && unknown[0].totalTokens == 55,
                    "Missing model metadata cannot erase measured tokens")
            let customHeader = line(["type": "session_meta", "payload": ["model_provider": "custom-relay"]])
                + line(["type": "turn_context", "payload": ["model": "custom-model"]])
            try Data((customHeader + event(80, 8, 50, day: "2026-10-04")).utf8)
                .write(to: archive.appendingPathComponent("custom-model.jsonl"))
            UsageIndex.updateIndex()
            let customDay = period("2026-10-04", "2026-10-05")
            let codexModels = UsageIndex.fetchBySource(in: customDay)[.codex] ?? []
            require(codexModels.contains { $0.model == "custom-model" && $0.totalTokens == 88 },
                    "Codex custom models belong to Codex regardless of provider")
            require(UsageIndex.fetchOfficialCodex(in: customDay).isEmpty,
                    "official attribution is separate from the Codex platform total")
            // Upgrade an inflated legacy cache without touching either transcript.
            UsageIndex.reloadPersistence()
            if sqlite {
                var db: OpaquePointer?
                require(sqlite3_open(FilePaths.root.appendingPathComponent("index.db").path, &db) == SQLITE_OK)
                require(sqlite3_exec(db, "UPDATE rollup SET input=input+10000 WHERE path LIKE 'codex:%'; PRAGMA user_version=9", nil, nil, nil) == SQLITE_OK)
                sqlite3_close(db)
            } else {
                var files = try JSONSerialization.jsonObject(with: Data(contentsOf: FilePaths.usageFilesJSON)) as! [String: [String: Any]]
                for key in files.keys { files[key]?.removeValue(forKey: "parserVersion") }
                try JSONSerialization.data(withJSONObject: files).write(to: FilePaths.usageFilesJSON)
            }
            UsageIndex.updateIndex(); require(total() == 380, "legacy parser caches must be rebuilt")

            // Lifetime family costs include completed children and workflow
            // transcripts, but never siblings or proxy copies of those calls.
            let children = claude.appendingPathComponent("family/subagents")
            let workflow = children.appendingPathComponent("workflows/done-workflow")
            try fm.createDirectory(at: workflow, withIntermediateDirectories: true)
            func familyCall(_ id: String, _ input: Int, model: String = "family-model") -> String {
                line(["type":"assistant","timestamp":"2026-09-30T12:00:00Z",
                    "message":["id":id,"model":model,"usage":["input_tokens":input,"output_tokens":1,
                        "cache_read_input_tokens":2,"cache_creation_input_tokens":3]]])
            }
            let parentCall = familyCall("family-parent",10)
            try Data(parentCall.utf8).write(to:claude.appendingPathComponent("family.jsonl"))
            try Data((parentCall + familyCall("family-agent",20)).utf8).write(to:children.appendingPathComponent("agent-one.jsonl"))
            let workerURL = workflow.appendingPathComponent("agent-two.jsonl")
            try Data(familyCall("family-worker",30,model:"workflow-model").utf8).write(to:workerURL)
            try Data(familyCall("unrelated-family",100).utf8).write(to:claude.appendingPathComponent("family-other.jsonl"))
            UsageIndex.updateIndex()
            func familyTokens(_ id: String, source: UsageSource) -> Int {
                UsageIndex.fetchSession(source:source,sessionId:id).reduce(0){$0+$1.totalTokens}
            }
            require(familyTokens("family",source:.claude) == 78,"Claude root + agent + workflow, deduped")
            require(UsageIndex.fetchSession(source:.claude,sessionId:"family").count == 2,"mixed workflow models retained")
            try append(familyCall("family-worker-next",40,model:"workflow-model"),to:workerURL)
            UsageIndex.updateIndex()
            require(familyTokens("family",source:.claude) == 124,"finished workflow append refreshes lifetime cost")
            UsageIndex.reloadPersistence(); UsageIndex.updateIndex()
            require(familyTokens("family",source:.claude) == 124,"family query survives persistence reload")
            let batch = UsageIndex.fetchSessionFamilies(source:.claude,sessionIds:["family","family","family-other","missing"])
            require(batch["family"]!.reduce(0){$0+$1.totalTokens} == 124 && batch["missing"]!.isEmpty)
            require(batch["family-other"]!.reduce(0){$0+$1.totalTokens} == 106,"neighbor sessions stay separate")

            func codexFamily(_ id: String, parent: String?, tokens: Int, nested: Bool = false, archived: Bool = false) throws -> URL {
                var meta: [String:Any] = ["id":id]
                if let parent {
                    if nested { meta["source"] = ["subagent":["thread_spawn":["parent_thread_id":parent]]] }
                    else { meta["parent_thread_id"] = parent }
                }
                let body = line(["type":"session_meta","payload":meta]) + header
                    + (tokens > 0 ? event(tokens,tokens/10,tokens/3,day:"2026-09-30") : "")
                let url = (archived ? archive : sessions).appendingPathComponent("rollout-"+id+".jsonl")
                try Data(body.utf8).write(to:url)
                return url
            }
            _ = try codexFamily("cx-family",parent:nil,tokens:0)
            _ = try codexFamily("cx-middle",parent:"cx-family",tokens:0)
            let childURL = try codexFamily("cx-child",parent:"cx-middle",tokens:10,nested:true,archived:true)
            _ = try codexFamily("cx-grandchild",parent:"cx-child",tokens:20)
            _ = try codexFamily("cx-unrelated",parent:nil,tokens:100)
            _ = try codexFamily("cycle-a",parent:"cycle-b",tokens:10)
            _ = try codexFamily("cycle-b",parent:"cycle-a",tokens:20)
            UsageIndex.updateIndex()
            require(familyTokens("cx-family",source:.codex) == 33,"Codex archived descendants through zero-usage parent")
            require(familyTokens("cx-child",source:.codex) == 33,"child rows show their own subtree")
            require(familyTokens("cycle-a",source:.codex) == 33,"cyclic metadata terminates without double counting")
            try append(event(30,3,10,day:"2026-09-30"),to:childURL)
            UsageIndex.updateIndex()
            require(familyTokens("cx-family",source:.codex) == 55,"descendant growth invalidates cached header")
            let rootBatch = UsageIndex.fetchSessionFamilies(source:.codex,sessionIds:["cx-family","cx-unrelated"])
            require(rootBatch["cx-unrelated"]!.reduce(0){$0+$1.totalTokens} == 110)
            // A rewritten child's parent must change attribution, not reuse a stale header.
            _ = try codexFamily("cx-child",parent:"cx-unrelated",tokens:30,archived:true)
            UsageIndex.updateIndex()
            require(familyTokens("cx-family",source:.codex) == 0)
            require(familyTokens("cx-unrelated",source:.codex) == 165)
            require(UsageIndex.fetchSessionFamilies(source:.thirdParty,sessionIds:["family"]).isEmpty)
        }
        let a = ModelUsage(model: "shared-medium", inputTokens: 10)
        let b = ModelUsage(model: "shared", inputTokens: 100)
        let other = ModelUsage(model: "local-only", inputTokens: 20)
        let cursor = [ModelUsage(model: "shared-high", inputTokens: 9000)]
            + (1...5).map { ModelUsage(model: "cursor-model-\($0)", inputTokens: $0) }
            + [ModelUsage(model: "cursor-zero")]
        let inventory = UsageModelInventory.rows(local: [a, b, other], sources: [.claude: [a], .codex: [b, other]],
            cursor: cursor, costs: [
                a.model: .init(model: a.model, cost: .init(usd: 2), unpriced: nil),
                b.model: .init(model: b.model, cost: .init(usd: 3), unpriced: nil)])
        require(inventory.count == 8, "all recorded models must appear, including Cursor-only/zero-token rows")
        let shared = inventory.first { $0.id == "shared" }!
        require(shared.local.totalTokens == 110 && shared.cursor?.totalTokens == 9000)
        require(shared.displayed.totalTokens == 110, "different coverage cannot be added together")
        require(shared.sourceTokens[.codex] == 100 && shared.costLine?.cost.usd == 5,
                "aliases merge without losing Codex source tokens or cost")
        let localOnly = inventory.first { $0.id == "local-only" }!
        require(localOnly.costLine?.unpricedTokens == 20)
        require(inventory.first { $0.id == "cursor-model-1" }?.hasLocal == false)
        print("PASS: SQLite/JSON production indexing, cumulative deltas, dedupe, archives and aggregate conservation")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='claudebar-usage-index-') as tmp:
    directory = Path(tmp)
    swift = directory / 'Regression.swift'
    swift.write_text(source)
    binary = directory / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(directory / 'fixtures')], check=True,
                   env={**os.environ, 'TZ': 'Asia/Shanghai'})
