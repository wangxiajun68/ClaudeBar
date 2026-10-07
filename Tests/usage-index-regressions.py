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
source = 'import Foundation\nimport SQLite3\nimport Combine\nimport os\nstruct Color {}\nenum Theme { static let claude = Color(); static let codex = Color(); static let cursor = Color(); enum Ink { static let claude = Color(); static let codex = Color(); static let cursor = Color() } }\n'
source += '\n'.join(declaration(models, m) for m in [
    'enum UsageSource', 'struct ModelUsage', 'struct DayUsage', 'enum UsageProviderAttribution'])
source += r'''
enum FilePaths {
    static var root = URL(fileURLWithPath: CommandLine.arguments[1])
    static var claudeDir: URL { root.appendingPathComponent("claude") }
    static var logsDir: URL { root }
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
source += declaration((utils / 'UsageClaims.swift').read_text(), 'enum UsageClaims') + '\n'
for filename, marker, name in [
    ('UsageIndex.swift', 'struct UsageIndex', 'index.db'),
    ('ProxyUsageStore.swift', 'final class ProxyUsageStore', 'proxy.db')]:
    text = declaration((utils / filename).read_text(), marker)
    # The production URL is `FilePaths.appSupportDir.appendingPathComponent(...)`
    # (the fourth copy of the root derivation is gone — findings 91/400); only
    # the support root is redirected here. All production parsing, SQL and
    # migration run unchanged.
    db_name = 'usage-index.db' if name == 'index.db' else 'proxy-usage.db'
    old = 'private static let dbURL = FilePaths.appSupportDir.appendingPathComponent("%s")' % db_name
    assert old in text, f'{filename}: the storage URL moved — update the fixture redirect'
    text = text.replace(
        old, f'private static var dbURL: URL {{ FilePaths.root.appendingPathComponent("{name}") }}')
    source += text + "\n"
source += (utils / 'ModelPricing.swift').read_text()
source += (utils / 'ModelPriceTable.swift').read_text()
source += (utils / 'UsageModelInventory.swift').read_text()
provider = (root / 'Sources/ClaudeBar/Models/ProviderStore.swift').read_text()
source += r'''
extension UsageIndex {
    /// Same-file extensions may see the production `private` statics.
    static func testFastStamp(_ s: String) -> Date? { fastStamp(s) }
    static func testCurrentStamp(_ s: String) -> Date? {
        isoFormatter.date(from: s) ?? isoFormatterNoFrac.date(from: s)
    }
}
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
        do {
            FilePaths.root = base.appendingPathComponent("index")
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
            require(total() == 110, "initial total \(total()) rows \(UsageIndex.fetchBySource(in: interval))")
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
                    "a shrunk rewrite must not keep stale rows: \(shrunk)")
            // …and the next append is counted as its own delta, not as a
            // rebuild of everything the rewritten file used to hold.
            try append(event(100, 10, 60), to: archivedRollout)
            UsageIndex.updateIndex()
            require(total() == 110, "post-rewrite append \(total()) rows \(UsageIndex.fetchBySource(in: interval))")
            // Put the original transcript back so the rest of the scenario
            // keeps its baseline. It returns as a *new* path (vanished files
            // are pruned with their rows), which is how a restored transcript
            // re-indexes in full.
            try fm.removeItem(at: archivedRollout)
            UsageIndex.updateIndex()
            try fullBody.write(to: archivedRollout)
            UsageIndex.updateIndex()
            require(total() == 190, "restored transcript \(total()) rows \(UsageIndex.fetchBySource(in: interval))")

            // A rewrite that preserves mtime *and* byte count — `cp -p`,
            // `rsync -a`, an unarchive — must still be re-read. The skip is
            // normally decided on (mtime, size) alone and never opens the
            // file, so without the head hash this file kept its first body's
            // rollup rows on every later pass, forever: each pass took the
            // same early return and no FSEvents burst could reach the new
            // bytes. Its own day keeps the assertion off the scenario totals.
            let preserved = sessions.appendingPathComponent("rollout-preserved.jsonl")
            let preservedDay = period("2026-09-25", "2026-09-26")
            func preservedTotal() -> Int {
                UsageIndex.fetch(in: preservedDay).reduce(0) { $0 + $1.totalTokens }
            }
            let preservedHeader = line(["type": "turn_context", "payload": ["model": "preserved-model"]])
            let firstBody = preservedHeader + event(100, 10, 60, day: "2026-09-25")
            try Data(firstBody.utf8).write(to: preserved)
            UsageIndex.updateIndex()
            require(preservedTotal() == 110, "preserved-first-body \(preservedTotal())")
            // Exact nanosecond stamp, read and restored through `stat` /
            // `utimensat` rather than `FileManager.attributesOfItem`, whose
            // Date round-trip lands one ULP off and would make the next pass
            // re-read the file for the wrong reason (an mtime mismatch).
            func statStamp(_ path: String) -> timespec {
                var info = stat(); stat(path, &info); return info.st_mtimespec
            }
            let stamp = statStamp(preserved.path)
            // Same number of bytes, different digits: the metadata is
            // indistinguishable and only the bytes can tell the two apart.
            let secondBody = preservedHeader + event(200, 20, 80, day: "2026-09-25")
            require(secondBody.utf8.count == firstBody.utf8.count,
                    "the rewrite fixture must keep the byte count")
            try Data(secondBody.utf8).write(to: preserved)
            var restored = [stamp, stamp]
            require(utimensat(AT_FDCWD, preserved.path, &restored, 0) == 0,
                    "the fixture must restore the exact mtime")
            let check = statStamp(preserved.path)
            require(check.tv_sec == stamp.tv_sec && check.tv_nsec == stamp.tv_nsec,
                    "the restored mtime must compare equal to the stored one")
            UsageIndex.updateIndex()
            require(preservedTotal() == 220,
                    "a same-mtime same-size rewrite must be re-read, got \(preservedTotal())")
            try fm.removeItem(at: preserved)
            UsageIndex.updateIndex()
            func assistant(_ output: Int, id: String = "message-id") -> String {
                line(["type": "assistant", "timestamp": "2026-10-01T12:00:00Z",
                    "message": ["id": id, "model": "audit-model",
                        "usage": ["input_tokens": 20, "output_tokens": output,
                                  "cache_read_input_tokens": 30, "cache_creation_input_tokens": 40]]])
            }
            let sessionURL = claude.appendingPathComponent("session.jsonl")
            try Data((assistant(1) + assistant(10)).utf8).write(to: sessionURL)
            UsageIndex.updateIndex(); require(total() == 290) // last-wins message ID
            // The Claude append fast path. A pure append — new bytes whose ids
            // are all unseen — folds additively from the chunk alone, O(new
            // bytes). Its last-wins obligation only arises when the chunk
            // reprints an id this file books (measured on the live corpus:
            // 64% of assistant lines are reprints, almost always of the line
            // right before), and that case must still fall back to the full
            // reparse: the reprint's final numbers replace the partial's,
            // they are never added on top.
            try append(assistant(7, id: "append-new"), to: sessionURL)
            UsageIndex.updateIndex()
            require(total() == 387, "a pure append books its new id additively: \(total())")
            // A reprint of the last line rewrites, not adds: the file still
            // holds two messages, the total does not grow.
            try append(assistant(10), to: sessionURL)
            UsageIndex.updateIndex()
            require(total() == 387, "a reprint must replace the partial, not add: \(total())")
            // Sandwich: a fresh id, then a reprint inside one append chunk —
            // the reprint forces the full reparse, and the fresh id keeps its
            // once-only booking through it.
            try append(assistant(3, id: "sandwich") + assistant(10), to: sessionURL)
            UsageIndex.updateIndex()
            require(total() == 480, "a reprint anywhere in the chunk must reparse the file: \(total())")
            // Back to the two-line original so the scenario below keeps its
            // baseline. The rewrite shrinks the file (full reparse); the ids
            // the file no longer prints are released like any other reparse.
            try Data((assistant(1) + assistant(10)).utf8).write(to: sessionURL)
            UsageIndex.updateIndex()
            require(total() == 290, "restoring the transcript must drop the appended ids: \(total())")
            require(UsageClaims.owner(of: "append-new") == nil && UsageClaims.owner(of: "sandwich") == nil,
                    "a reparse that no longer prints an id must release it")
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
            // Official attribution reads each rollout's first line once and
            // memoizes the verdict on (mtime, size) — the same shape
            // fetchSessionFamilies uses for rollout headers. A month window
            // with a few hundred rollouts made a republish-per-FSEvents-fire
            // re-open and re-read all of them: measured 200 opens + 12.8 MB of
            // header reads per pass at ~2.5 passes/s during an active session.
            let officialRollout = archive.appendingPathComponent("official-model.jsonl")
            let officialHeader = line(["type": "session_meta", "payload": ["id": "official-1", "model_provider": "openai"]])
                + line(["type": "turn_context", "payload": ["model": "gpt-official"]])
            try Data((officialHeader + event(120, 12, 90, day: "2026-10-04")).utf8).write(to: officialRollout)
            UsageIndex.updateIndex()
            let officialDay = period("2026-10-04", "2026-10-05")
            let official = UsageIndex.fetchOfficialCodex(in: officialDay)
            require(official.contains { $0.model == "gpt-official" && $0.totalTokens == 132 },
                    "an openai-provider rollout books to official: \(official.map(\.model))")
            // A verdict memoized on the old (mtime, size) must be re-read —
            // not trusted — when the file changes: rewriting the header from
            // openai to a relay flips the attribution on the next pass.
            try Data((line(["type": "session_meta", "payload": ["id": "official-1", "model_provider": "custom-relay"]])
                      + line(["type": "turn_context", "payload": ["model": "gpt-official"]])
                      + event(120, 12, 90, day: "2026-10-04")).utf8).write(to: officialRollout)
            UsageIndex.updateIndex()
            require(UsageIndex.fetchOfficialCodex(in: officialDay).isEmpty,
                    "a rewritten provider must invalidate the memoized official verdict")
            // Deleting the file must drop the verdict with the rollout.
            try fm.removeItem(at: officialRollout)
            UsageIndex.updateIndex()
            require(UsageIndex.fetchOfficialCodex(in: officialDay).isEmpty,
                    "a deleted rollout must not leave a stale verdict")
            // Restore the openai shape for the remaining scenario state.
            try Data((officialHeader + event(120, 12, 90, day: "2026-10-04")).utf8).write(to: officialRollout)
            UsageIndex.updateIndex()
            require(!UsageIndex.fetchOfficialCodex(in: officialDay).isEmpty,
                    "the restored official rollout must book again")
            // Upgrade an inflated legacy cache without touching either transcript.
            UsageIndex.reloadPersistence()
            var db: OpaquePointer?
            require(sqlite3_open(FilePaths.root.appendingPathComponent("index.db").path, &db) == SQLITE_OK)
            require(sqlite3_exec(db, "UPDATE rollup SET input=input+10000 WHERE path LIKE 'codex:%'; PRAGMA user_version=9", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)
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

            // The claims ledger appends only what changed and rewrites itself
            // only when dead lines outnumber live ones. The inverted comparison
            // (`lines * 2 > count + 4096`) rewrote the file on every flush once
            // the corpus passed ~4,096 ids; assert the two behaviours the
            // corrected test encodes, through the real flush path. A fresh root
            // keeps this phase's ledger away from the scenario's own claims.
            FilePaths.root = base.appendingPathComponent("claims")
            try fm.createDirectory(at: FilePaths.root, withIntermediateDirectories: true)
            let claimsURL = FilePaths.usageClaimsJSONL
            UsageClaims.reset()
            let steady = (0..<5000).map { "steady-\($0)" }
            for id in steady { UsageClaims.record(id, owner: "claude:steady") }
            UsageClaims.flush()
            let afterFirst = try String(contentsOf: claimsURL, encoding: .utf8)
            require(afterFirst.split(separator: "\n").count == 5000, "first flush must write every claim")
            // One changed id: the file gains a line, and is not rewritten.
            UsageClaims.record("steady-0", owner: "claude:other")
            UsageClaims.flush()
            let afterAppend = try String(contentsOf: claimsURL, encoding: .utf8)
            require(afterAppend.split(separator: "\n").count == 5001,
                    "a single change must append one line, not rewrite \(afterAppend.count) bytes")
            require(afterAppend.hasPrefix(afterFirst), "an append must not disturb the prefix")
            // Now bury the live set. With dead lines dominating, the flush
            // compacts back to one line per live id.
            FilePaths.root = base.appendingPathComponent("claims-compact")
            try fm.createDirectory(at: FilePaths.root, withIntermediateDirectories: true)
            UsageClaims.reset()
            for id in 0..<20000 { UsageClaims.record("dead-\(id)", owner: "claude:dead") }
            UsageClaims.flush()
            for id in 0..<19000 { UsageClaims.release("dead-\(id)") }
            UsageClaims.record("live-1", owner: "claude:live")
            UsageClaims.flush()
            let compacted = try String(contentsOf: FilePaths.usageClaimsJSONL, encoding: .utf8)
            require(compacted.split(separator: "\n").count == 1001,
                    "a dead-dominated ledger must compact to its live ids, got \(compacted.split(separator: "\n").count)")
            require(UsageClaims.owner(of: "live-1") == "claude:live"
                    && UsageClaims.owner(of: "dead-3") == nil
                    && UsageClaims.owner(of: "dead-19000") == "claude:dead",
                    "compaction lost the live set or kept a freed id")

            // The claims file's load is a byte scanner with a JSONDecoder
            // fallback (UsageClaims.fastClaim). Differential: whatever the
            // scanner accepts must equal what a decoder-only reference load
            // produces, and every shape the scanner refuses must still come
            // back through the fallback with the same answer. The ledger here
            // is written by the production flush path first (exactly the
            // escaping Foundation writes), then adversarial lines are appended:
            // swapped keys, whitespace, unknown trailing keys, \uXXXX and \"
            // escapes, multibyte owners, tombstones and a truncated line.
            FilePaths.root = base.appendingPathComponent("claims-diff")
            try fm.createDirectory(at: FilePaths.root, withIntermediateDirectories: true)
            UsageClaims.reset()
            for id in 0..<20_000 where id % 3 != 1 {
                UsageClaims.record("msg-\(id)", owner: "claude:/Users/corpus/project-\(id % 7)/session-\(id).jsonl")
            }
            for id in stride(from: 1, to: 20_000, by: 3) { UsageClaims.record("msg-\(id)", owner: "codex:/rollouts/\(id).jsonl") }
            UsageClaims.flush()
            var adversarial = try String(contentsOf: FilePaths.usageClaimsJSONL, encoding: .utf8).split(separator: "\n").map(String.init)
            adversarial += [
                #"{"owner":"claude:\/swapped.jsonl","id":"swapped"}"#,                      // key order the scanner refuses
                #"{ "id" : "spaced" , "owner" : "claude:\/spaced.jsonl" }"#,               // whitespace
                #"{"id":"trailing","owner":"claude:\/t.jsonl","extra":true}"#,             // unknown trailing key
                #"{"id":"unicode","owner":"claude:\u0041.jsonl"}"#,             // \uXXXX escape the scanner refuses (decodes to "claude:A.jsonl")
                #"{"id":"quoted","owner":"claude:\/a\"b.jsonl"}"#,                         // literal-quote escape
                #"{"id":"multi","owner":"claude:\/项目\/会话😀.jsonl"}"#,                    // multibyte UTF-8, unescaped
                #"{"id":"tombstone-me","owner":"claude:\/gone.jsonl"}"#,
                #"{"id":"tombstone-me","owner":""}"#,
                #"{"id":"msg-0","owner":"codex:\/moved.jsonl"}"#,                          // later line wins
                #"{"id":"broken","owner":"claude:\/unterminated.jsonl""#,                  // truncated
                #"{"id":"junk-tail","owner":"claude:\/j.jsonl"}junk"#,                     // trailing bytes the decoder rejects
                "not json at all",
                #"{"id":"","owner":""}"#,
            ]
            try Data((adversarial.joined(separator: "\n") + "\n").utf8)
                .write(to: FilePaths.usageClaimsJSONL)
            UsageClaims.reset()
            // Force the load through the production entry point, then answer
            // every id from production. A missing id is tracked in its own set:
            // a `[String: String?]` subscript cannot express "present but nil"
            // readably.
            let decoderReference = JSONDecoder()
            var reference: [String: String] = [:]
            var queried: Set<String> = ["junk-tail"]   // decoded by neither: both routes must drop it
            for line in adversarial {
                guard let claim = try? decoderReference.decode(UsageClaims.Claim.self, from: Data(line.utf8)) else { continue }
                queried.insert(claim.id)
                if claim.owner.isEmpty { reference.removeValue(forKey: claim.id) }
                else { reference[claim.id] = claim.owner }
            }
            var production: [String: String] = [:]
            var missing: Set<String> = []
            for key in queried {
                if let owner = UsageClaims.owner(of: key) { production[key] = owner }
                else { missing.insert(key) }
            }
            for (key, owner) in reference where production[key] != owner {
                require(false, "the scanner and the decoder disagree on \(key): production=\(production[key] ?? "nil") reference=\(owner)")
            }
            for (key, owner) in production where reference[key] != owner {
                require(false, "production booked \(key) that the reference dropped: \(key) → \(owner)")
            }
            for key in missing where reference[key] != nil {
                require(false, "production dropped \(key) that the reference booked: \(reference[key]!)")
            }
            require(production["junk-tail"] == nil && missing.contains("junk-tail"),
                    "trailing junk must be dropped by the scanner and by the decoder alike")
            require(production["swapped"] == "claude:/swapped.jsonl", "a swapped-key line must fall back to the decoder")
            require(production["spaced"] == "claude:/spaced.jsonl", "a spaced line must fall back to the decoder")
            require(production["unicode"] == "claude:A.jsonl", "a \\uXXXX escape must fall back to the decoder")
            require(production["quoted"] == "claude:/a\"b.jsonl", "a quote escape must fall back to the decoder")
            require(production["multi"] == "claude:/项目/会话😀.jsonl", "multibyte owners must survive both routes")
            require(missing.contains("tombstone-me"), "the last tombstone must win")
            require(production.filter { $0.value != "claude:/gone.jsonl" }.count == production.count - 0
                    || production["tombstone-me"] == nil,
                    "the tombstone must not leave the earlier owner")
            require(reference.count == production.count,
                    "the two routes must book the same number of ids")

            // fastStamp vs ISO8601DateFormatter. Differential on random stamps
            // plus adversarial shapes: the fast path must agree with the
            // formatter wherever it accepts (within float noise — the two
            // differ by ~30 ns at ULP level, which no day bucket can see), and
            // fall back to it wherever it refuses, so the two routes can never
            // book a stamp on different days.
            func currentStamp(_ s: String) -> Date? {
                UsageIndex.testCurrentStamp(s)
            }
            var stampChecked = 0
            for _ in 0..<20_000 {
                let y = Int.random(in: 2000...2035), m = Int.random(in: 1...12), d = Int.random(in: 1...28)
                let h = Int.random(in: 0...23), mi = Int.random(in: 0...59), se = Int.random(in: 0...59)
                let frac = Int.random(in: 0...999)
                for s in [String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, m, d, h, mi, se, frac),
                          String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, h, mi, se)] {
                    let a = currentStamp(s), f = UsageIndex.testFastStamp(s)
                    switch (a, f) {
                    case let (x?, y?):
                        require(abs(x.timeIntervalSince(y)) <= 1e-6, "fastStamp disagrees on \(s)")
                    default:
                        require(false, "fastStamp presence disagrees on \(s)")
                    }
                    stampChecked += 1
                }
            }
            require(stampChecked == 40_000)
            var refused = 0
            for s in ["2026-02-30T12:00:00Z", "2026-13-01T00:00:00Z", "2026-01-00T00:00:00Z",
                      "2026-01-01T24:00:00Z", "2026-01-01T00:00:60Z", "2026-01-01T00:00:00.Z",
                      "2026-01-01T00:00:00", "2026-01-01T00:00:00+08:00", "2026-1-01T00:00:00Z",
                      "20260101T000000Z", "2026-01-01t00:00:00z", "2026-01-01T00:00:00.123456789Z",
                      "2026-01-01T00:00:00.1Z", "2026-01-01T00:00:00.123456Z",
                      "2026-01-01T00:00:00.123Z ", " 2026-01-01T00:00:00Z", "2026/01/01T00:00:00Z"] {
                let a = currentStamp(s), f = UsageIndex.testFastStamp(s)
                if f == nil { refused += 1; continue }
                require(a != nil && abs(a!.timeIntervalSince(f!)) <= 1e-6,
                        "fastStamp accepted \(s) with a different value than the formatter")
            }
            require(refused >= 16, "the fast path must refuse every non-canonical shape, refused \(refused)")
        }

        // The two flags that drive the usage page's spinner and first-query
        // gate, asserted directly — nothing else in the suite reads either, so
        // a lifecycle regression (cached before the first build, never reset,
        // or the DB probe turning a hit into a miss) would leave the page
        // spinning (or empty) with no failing test. The contract, in the order
        // the app exercises it:
        //   1. A fresh process needs its first build and has no rows to show.
        //   2. Any completed pass ends the build *and* sets the in-memory flag —
        //      `hasCachedData` is not asked of SQLite once a pass has run, so
        //      even an empty corpus reports "cached" (the spinner's condition
        //      is `!hasCachedData && needsInitialBuild`, so this is what lets
        //      the period chips query immediately after launch).
        //   3. Against a *database* with rows, the first `hasCachedData` of a
        //      process probes SQLite (no pass yet) and must find them.
        do {
            FilePaths.root = base.appendingPathComponent("flags")
            try fm.createDirectory(at: FilePaths.root, withIntermediateDirectories: true)
            UsageIndex.reloadPersistence(); ProxyUsageStore.shared.reset()
            require(UsageIndex.needsInitialBuild, "a fresh process must need its first build")
            require(!UsageIndex.hasCachedData, "an empty index cannot report cached rollup rows")
            UsageIndex.updateIndex()
            require(!UsageIndex.needsInitialBuild, "the first pass must end the initial build")
            require(UsageIndex.hasCachedData, "a completed pass must report cached data")
            // With no corpus the database holds no rows, so the SQL probe a
            // reloaded process runs answers false — the other side of the
            // asymmetry above.
            UsageIndex.reloadPersistence()
            require(UsageIndex.needsInitialBuild, "a reload must need a fresh build")
            require(!UsageIndex.hasCachedData, "the DB probe must find the empty rollup empty")
            // A rollout makes the probe hit, and the flag must stay per-process:
            // a reload still needs the build while the rows are on disk.
            let flagRollout = FilePaths.root.appendingPathComponent("codex/sessions/rollout-flag.jsonl")
            try fm.createDirectory(at: flagRollout.deletingLastPathComponent(), withIntermediateDirectories: true)
            func flagLine(_ obj: [String: Any]) -> String {
                String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self) + "\n"
            }
            let flagBody = flagLine(["type": "turn_context", "payload": ["model": "flag-model"]])
                + flagLine(["type": "event_msg", "timestamp": "2026-10-01T12:00:00Z",
                            "payload": ["type": "token_count",
                                        "info": ["total_token_usage": ["input_tokens": 40, "output_tokens": 4,
                                                                       "cached_input_tokens": 10, "total_tokens": 44]]]])
            try Data(flagBody.utf8).write(to: flagRollout)
            UsageIndex.updateIndex()
            require(UsageIndex.hasCachedData, "a booked rollout must report cached rows")
            UsageIndex.reloadPersistence()
            require(UsageIndex.needsInitialBuild && UsageIndex.hasCachedData,
                    "a reload must need the build while still seeing the rows on disk")
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
        print("PASS: SQLite production indexing, cumulative deltas, dedupe, archives and aggregate conservation")
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
