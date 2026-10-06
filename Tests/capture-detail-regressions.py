#!/usr/bin/env python3
"""The capture store's detail path against a real SQLite file.

Four things here are invisible from every other suite:

- `makeDetail` used to parse the same request/response four times (once for
  turns, once for the reply, once each for tool calls). The derivation is
  asserted equal to the per-derivation composition, so the single-parse
  refactor cannot change what a detail contains.
- `detail()` must finish its SQLite read — statement finalized, lock released
  — *before* the multi-megabyte derivation runs; the fixture locks assert the
  ordering, so a future edit cannot quietly re-introduce parsing under the
  store lock.
- `rowToSummary` read the token columns through `sqlite3_column_int` (32-bit),
  silently truncating anything past 2^31, and turned an unparseable
  `started_at` into "now" while `ended_at` stayed put — two clocks in one row.
- `CaptureTranscript.clip` now folds one growing window instead of the whole
  body (the live preview calls it at 10 Hz per streaming capture); the
  differential fixture pins it to the old whole-string fold across random and
  handcrafted strings.
- `evictStaleLiveBuffers` republished `streams.live` / `previews.map` on every
  finishing proxied call (health checks included) even when the filter removed
  nothing, re-evaluating the whole traffic page for no change.

Slices production `detail()`, `makeDetail`, `rowToSummary`, `optInt` and
`evictStaleLiveBuffers`; no app, no network, no real user data.
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
store = (root / 'Sources/ClaudeBar/Utils/ProxyCaptureStore.swift').read_text()
transcript = (root / 'Sources/ClaudeBar/Utils/CaptureTranscript.swift').read_text()


def method(signature):
    """One production method, verbatim, with `private` dropped."""
    try:
        start = store.index('    private func ' + signature)
    except ValueError:
        start = store.index('    func ' + signature)
    end = store.index('\n    }', start) + len('\n    }')
    return store[start:end].replace('    private func', '    func', 1)


def static_method(signature):
    return method(signature).replace('    func ', '    static func ', 1)


# `detail()` keeps its production SQL and its lock/unlock points verbatim; the
# fixture supplies the lock and resolves the connection handle. The count of
# those calls is load-bearing: the derivation must run *after* the statement is
# finalized and the lock released, which `makeDetail` itself asserts below.
detail = method('detail(id: Int64, includeRaw: Bool = false,\n                includePayloads: Bool = true, includeTools: Bool = true)')
detail = detail.replace('openConnectionLocked()', 'connection()')
detail = detail.replace('sqlite3_prepare_v2(db, sql, -1, &stmt, nil)', 'prepareStatement(db, sql, &stmt)')
detail = detail.replace('sqlite3_finalize(stmt)', 'closeStatement(stmt)')
detail = detail.replace('    func detail(', '    static func detail(', 1)

make_detail = static_method('makeDetail(id: Int64, summary: CaptureSummary,')
make_detail = make_detail.replace(
    '        let dir = CaptureMedia.mediaDir(captureID: id)',
    '''        require(lock.depth == 0, "makeDetail ran while detail() still held the store lock")
        require(!stmtOpen, "makeDetail ran with detail()'s statement still open")
        let dir = CaptureMedia.mediaDir(captureID: id)''',
    1)
row_to_summary = static_method('rowToSummary(_ stmt: OpaquePointer?)')
opt_int = static_method('optInt(_ stmt: OpaquePointer?, _ i: Int32)')
text_col = static_method('text(_ stmt: OpaquePointer?, _ i: Int32)')
parse_iso = static_method('parseISO(_ s: String)')

# `isoFormatter` is an instance property; the fixture owns a static one.
row_to_summary = row_to_summary.replace('self.', '')
parse_iso = parse_iso.replace('isoFormatter', 'StoreFixture.isoFormatter')
make_detail = make_detail.replace('self.', '')

evict = method('evictStaleLiveBuffers(keeping id: Int64)')

transcript_body = transcript[transcript.index('enum CaptureTranscript {'):]

harness = r'''
import Foundation
import Combine
import SQLite3

enum CaptureMedia {
    static let payloadCapBytes = 16 * 1024 * 1024
    static let payloadCapLabel = "16 MB"
    struct EmbeddedImage: Equatable { var data: Data? = nil }
    static func image(from part: [String: Any], mediaDir: URL?) -> EmbeddedImage? { nil }
    static func mediaDir(captureID: Int64) -> URL { URL(fileURLWithPath: "/nonexistent/\(captureID)") }
}

enum CaptureKind: String { case anthropic, openaiChat = "openai-chat", openaiResponses = "openai-responses" }
enum CaptureSource: String { case claude, codex, other }
enum CaptureState: String { case pending, streaming, done, error, aborted }

struct CaptureSummary {
    var id: Int64
    var startedAt: Date
    var endedAt: Date?
    var firstTokenAt: Date?
    var kind: CaptureKind
    var source: CaptureSource
    var providerName: String
    var model: String
    var path: String
    var isStream: Bool
    var state: CaptureState
    var httpStatus: Int
    var promptTokens: Int?
    var completionTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var error: String?
    var preview: String
}

struct CaptureDetail {
    var summary: CaptureSummary
    var requestJSON: String
    var rewrittenJSON: String
    var responseJSON: String
    var rawSSE: String
    var requestHeadersJSON: String
    var turns: [CaptureTranscript.Turn]
    var toolCalls: [CaptureTranscript.ToolCall]
    var requestTruncated: Bool
    var payloadsLoaded: Bool
}

enum CaptureAssembler {
    struct Tool: Equatable { var id: String; var name: String; var arguments: String }
}

struct CaptureLive: Equatable {
    var content = ""
    var reasoning = ""
    var tools: [CaptureAssembler.Tool] = []
}

TRANSCRIPT

/// The per-derivation composition `makeDetail` must match: each public entry
/// point parses its payload independently, exactly as the store used to.
enum Oracle {
    static func detail(summary: CaptureSummary, request: String, rewritten: String,
                       response: String, sse: String, requestHeadersJSON: String,
                       includePayloads: Bool, includeTools: Bool) -> CaptureDetail {
        let dir = CaptureMedia.mediaDir(captureID: summary.id)
        var turns = CaptureTranscript.turns(from: request, mediaDir: dir)
        if !response.isEmpty {
            turns += CaptureTranscript.replyTurns(
                responseJSON: response, live: nil, streaming: false, mode: .conversation)
        }
        return CaptureDetail(
            summary: summary,
            requestJSON: includePayloads ? request : "",
            rewrittenJSON: includePayloads ? rewritten : "",
            responseJSON: includePayloads ? response : "",
            rawSSE: includePayloads ? sse : "",
            requestHeadersJSON: includePayloads ? requestHeadersJSON : "",
            turns: turns,
            toolCalls: includeTools ? CaptureTranscript.toolCalls(request: request, response: response) : [],
            requestTruncated: request.contains("[truncated]"),
            payloadsLoaded: includePayloads)
    }
}

/// `detail()`'s dead JSON branch still has to type-check.
final class JSONStoreStub {
    func summary(id: Int64) -> CaptureSummary? { nil }
    func readPayload(_ id: Int64) -> (request: String, rewritten: String, response: String,
                                      sse: String, headers: String) {
        ("", "", "", "", "")
    }
}

enum StoreFixture {
    static let isoFormatter = ISO8601DateFormatter()
    static var db: OpaquePointer?
    static let jsonStore = JSONStoreStub()
    static let useDatabase = true

    /// Stands in for the store's `NSRecursiveLock`. `detail()` must release
    /// it before `makeDetail` runs, and must have closed its statement first
    /// (`pruneLocked`'s VACUUM cannot run with one open).
    final class ProbeLock {
        var depth = 0
        func lock() { depth += 1 }
        func unlock() { depth -= 1 }
    }
    static let lock = ProbeLock()
    static var stmtOpen = false

    static func connection() -> OpaquePointer? { db }

    static func prepareStatement(_ db: OpaquePointer?, _ sql: String,
                                 _ stmt: inout OpaquePointer?) -> Int32 {
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc == SQLITE_OK { stmtOpen = true }
        return rc
    }

    static func closeStatement(_ stmt: OpaquePointer?) {
        stmtOpen = false
        sqlite3_finalize(stmt)
    }

DETAIL

MAKE_DETAIL

ROW_TO_SUMMARY

OPT_INT

TEXT_COL

PARSE_ISO
}

/// A store-shaped fixture for the eviction rule; only the members the sliced
/// production method touches exist here.
final class EvictionFixture {
    final class Catalog: ObservableObject { @Published var records: [CaptureSummary] = [] }
    final class Streams: ObservableObject { @Published var live: [Int64: CaptureLive] = [:] }
    final class Previews: ObservableObject { @Published var map: [Int64: String] = [:] }

    let catalog = Catalog()
    let streams = Streams()
    let previews = Previews()

EVICT
}

func row(_ id: Int64, state: CaptureState = .done) -> CaptureSummary {
    CaptureSummary(id: id, startedAt: Date(), endedAt: nil, firstTokenAt: nil,
                   kind: .anthropic, source: .claude, providerName: "fixture", model: "m",
                   path: "/v1/messages", isStream: false, state: state, httpStatus: 200,
                   promptTokens: nil, completionTokens: nil, cacheReadTokens: nil,
                   cacheWriteTokens: nil, error: nil, preview: "p")
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@main struct Regression {
    @MainActor static func main() async throws {
        try sqlite3_open(":memory:", &StoreFixture.db)
        sqlite3_exec(StoreFixture.db, """
            CREATE TABLE captures (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT NOT NULL,
                ended_at TEXT, first_token_at TEXT, kind TEXT NOT NULL, source TEXT NOT NULL,
                provider_name TEXT, model TEXT, path TEXT, is_stream INTEGER, state TEXT,
                http_status INTEGER, prompt_tokens INTEGER, completion_tokens INTEGER,
                cache_read_tokens INTEGER, cache_write_tokens INTEGER, error TEXT, preview TEXT);
            CREATE TABLE payloads (capture_id INTEGER PRIMARY KEY, request_json TEXT,
                rewritten_json TEXT, response_json TEXT, raw_sse TEXT, request_headers TEXT);
            """, nil, nil, nil)

        // --- The derivation is unchanged by the single-parse refactor.
        let summary = row(1)
        let samples: [(request: String, response: String)] = [
            ("", ""),
            (#"{"messages":[{"role":"user","content":"hi"}]}"#,
             #"{"message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}"#),
            (#"{"messages":[{"role":"user","content":[{"type":"tool_use","id":"a","name":"Read","input":{"file":"x"}}]},{"role":"tool","tool_call_id":"a","content":"out"}]}"#,
             #"{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"a","function":{"name":"Read","arguments":"{}"}}]}}]}"#),
            (#"{"input":[{"type":"function_call","call_id":"c1","name":"Bash","arguments":"{}"},{"type":"function_call_output","call_id":"c1","output":"ok"}]}"#,
             #"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}"#),
            (#"{"system":"sys","instructions":"ins","messages":[{"role":"user","content":"<system-reminder>noise</system-reminder>real"}]}"#,
             #"{"message":{"content":""}}"#),
            ("{\"messages\":[{\"role\":\"user\",\"content\":\"cut [truncated]\"}]}", ""),
            // Tool calls in *both* payloads with different ids: the order of
            // the derivations (and which parsed body each one receives) is
            // observable, so wiring them to the wrong payload cannot pass.
            // The response uses the `message` shape `collectTools` walks —
            // `choices` is only understood by the turns path.
            (#"{"messages":[{"role":"user","content":[{"type":"tool_use","id":"req-1","name":"Read","input":{}}]}]}"#,
             #"{"message":{"tool_calls":[{"id":"res-1","function":{"name":"Bash","arguments":"{}"}}]}}"#),
        ]
        for (index, sample) in samples.enumerated() {
            for includePayloads in [true, false] {
                for includeTools in [true, false] {
                    let current = StoreFixture.makeDetail(
                        id: 1, summary: summary, request: sample.request, rewritten: "rw",
                        response: sample.response, sse: "sse-data", requestHeadersJSON: "{}",
                        includePayloads: includePayloads, includeTools: includeTools)
                    let oracle = Oracle.detail(
                        summary: summary, request: sample.request, rewritten: "rw",
                        response: sample.response, sse: "sse-data", requestHeadersJSON: "{}",
                        includePayloads: includePayloads, includeTools: includeTools)
                    require(current.turns == oracle.turns,
                            "turns drifted on sample \(index) payloads=\(includePayloads) tools=\(includeTools)")
                    require(current.toolCalls == oracle.toolCalls, "toolCalls drifted on sample \(index)")
                    require(current.requestJSON == oracle.requestJSON
                            && current.rewrittenJSON == oracle.rewrittenJSON
                            && current.responseJSON == oracle.responseJSON
                            && current.rawSSE == oracle.rawSSE
                            && current.requestHeadersJSON == oracle.requestHeadersJSON
                            && current.requestTruncated == oracle.requestTruncated
                            && current.payloadsLoaded == oracle.payloadsLoaded,
                            "detail fields drifted on sample \(index)")
                }
            }
        }

        // --- Rows round-trip through the production SELECT, including values
        // the old 32-bit reader truncated and timestamps that do not parse.
        let huge = Int64(5_000_000_000)     // past Int32.max, still a sane token count
        var insert: OpaquePointer?
        sqlite3_prepare_v2(StoreFixture.db, """
            INSERT INTO captures (id, started_at, ended_at, kind, source, provider_name, model,
                path, is_stream, state, http_status, prompt_tokens, cache_write_tokens, preview)
            VALUES (?, ?, ?, 'anthropic', 'claude', 'p', 'm', '/v1/messages', 0, 'done', 200, ?, ?, 'p')
            """, -1, &insert, nil)
        sqlite3_bind_int64(insert, 1, 1)
        sqlite3_bind_text(insert, 2, "2026-10-05T00:00:00Z", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_null(insert, 3)
        sqlite3_bind_int64(insert, 4, huge)
        sqlite3_bind_int64(insert, 5, huge + 1)
        sqlite3_step(insert)
        sqlite3_reset(insert)
        sqlite3_bind_int64(insert, 1, 2)
        sqlite3_bind_text(insert, 2, "not-a-date", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(insert, 3, "2026-10-05T01:00:00Z", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(insert, 4, 3)
        sqlite3_bind_int64(insert, 5, 4)
        sqlite3_step(insert)
        sqlite3_finalize(insert)
        var payload: OpaquePointer?
        sqlite3_prepare_v2(StoreFixture.db,
            "INSERT INTO payloads (capture_id, request_json, response_json, request_headers) VALUES (?, ?, ?, ?)",
            -1, &payload, nil)
        let request = #"{"messages":[{"role":"user","content":"hi"}]}"#
        sqlite3_bind_int64(payload, 1, 1)
        sqlite3_bind_text(payload, 2, request, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(payload, 3, "", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(payload, 4, "{}", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(payload)
        sqlite3_finalize(payload)

        let loaded = StoreFixture.detail(id: 1)
        require(loaded != nil, "a row with a payload must load")
        require(loaded?.summary.promptTokens == Int(huge),
                "prompt tokens must survive the 64-bit column, got \(String(describing: loaded?.summary.promptTokens))")
        require(loaded?.summary.cacheWriteTokens == Int(huge + 1), "cache write tokens must survive too")
        require(loaded?.turns.count == 1 && loaded?.turns.first?.text == "hi", "turns must load from the payload")

        let fallback = StoreFixture.detail(id: 2)
        require(fallback != nil, "a row without a payload still lists")
        let start = fallback!.summary.startedAt
        let end = fallback!.summary.endedAt
        require(start == end, "an unparseable started_at must fall back to this row's ended_at, not now")
        require(abs(start.timeIntervalSinceNow) > 3600,
                "the fallback must not read as the current instant")

        // --- Eviction republishes only when it actually drops something.
        let store = EvictionFixture()
        var streamNotifications = 0, previewNotifications = 0
        let streamToken = store.streams.objectWillChange.sink { streamNotifications += 1 }
        let previewToken = store.previews.objectWillChange.sink { previewNotifications += 1 }
        store.catalog.records = [row(1), row(2)]
        store.streams.live = [1: CaptureLive(content: "a"), 2: CaptureLive(content: "b")]
        store.previews.map = [1: "a", 2: "b"]
        try await Task.sleep(for: .milliseconds(30))
        streamNotifications = 0; previewNotifications = 0   // the setup writes above
        store.evictStaleLiveBuffers(keeping: 1)
        try await Task.sleep(for: .milliseconds(30))
        require(streamNotifications == 0 && previewNotifications == 0,
                "eviction that removes nothing must not republish (streams \(streamNotifications), previews \(previewNotifications))")
        require(store.streams.live.count == 2 && store.previews.map.count == 2, "nothing should have been dropped")

        store.catalog.records = [row(1)]
        store.evictStaleLiveBuffers(keeping: 1)
        try await Task.sleep(for: .milliseconds(30))
        require(streamNotifications == 1 && previewNotifications == 1,
                "a real eviction must republish once (streams \(streamNotifications), previews \(previewNotifications))")
        require(store.streams.live.keys.sorted() == [1] && store.previews.map.keys.sorted() == [1],
                "the stale buffers must be gone")
        _ = (streamToken, previewToken)

        // --- `clip` is now a windowed fold; it must agree with the old
        // whole-string fold everywhere, including the degenerate shapes
        // (newline runs longer than the window, whitespace-only bodies).
        func oldClip(_ text: String, cap: Int = 160) -> String {
            let folded = text
                .split(whereSeparator: { $0.isNewline || $0 == "\r" })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if folded.count <= cap { return folded }
            return String(folded.prefix(cap)) + "…"
        }
        var seed: UInt64 = 0x5eed
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 33) % UInt64(n)) }
        func randomText(_ length: Int) -> String {
            // Characters chosen to straddle the fold's edges: newlines, CR,
            // leading/trailing whitespace, wide scalars and plain letters.
            let alphabet = Array("ab \n\r\t\u{00A0}\u{3000}😀한글。")
            return String((0..<length).map { _ in alphabet[random(alphabet.count)] })
        }
        var clipCases: [String] = ["", " ", "\n", "\r\n", "\n\n\n\n", "   \n  ", String(repeating: "\n", count: 500),
                                   String(repeating: "x", count: 10_000), String(repeating: "\n", count: 4_000) + "real text"]
        clipCases += (0..<400).map { _ in randomText(random(300)) }
        for (index, text) in clipCases.enumerated() {
            for cap in [1, 2, 64, 160, 159, 1600] {
                let current = CaptureTranscript.clip(text, cap: cap)
                let expected = oldClip(text, cap: cap)
                require(current == expected, "clip drifted on case \(index) cap \(cap): \(current.prefix(40)) vs \(expected.prefix(40))")
            }
        }
        // The measured hazard: a multi-megabyte body must not be walked per
        // call. The window fold touches at most a few multiples of `cap`.
        let big = randomText(2_000_000)
        func milliseconds(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now; body()
            let d = start.duration(to: .now)
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        let clipMs = milliseconds { _ = CaptureTranscript.clip(big) }
        require(clipMs < 5, "clip on 2 MB took \(clipMs) ms — the whole-string fold is back")

        print("PASS: detail derivation, 64-bit token columns, timestamp fallback, eviction publishing and clip folding")
    }
}
'''

source = ('import Foundation\nimport Combine\nimport SQLite3\n' + harness
          .replace('TRANSCRIPT', transcript_body)
          # 'MAKE_DETAIL' contains 'DETAIL' — replace the longer placeholder
          # first or the shorter rule mangles it.
          .replace('MAKE_DETAIL', make_detail)
          .replace('DETAIL', detail)
          .replace('ROW_TO_SUMMARY', row_to_summary)
          .replace('OPT_INT', opt_int)
          .replace('TEXT_COL', text_col)
          .replace('PARSE_ISO', parse_iso)
          .replace('EVICT', evict))

with tempfile.TemporaryDirectory(prefix='claudebar-capture-detail-') as tmp:
    path = Path(tmp) / 'Regression.swift'
    path.write_text(source)
    binary = Path(tmp) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                    str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
