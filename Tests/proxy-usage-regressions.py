#!/usr/bin/env python3
"""The proxy's token buckets must be disjoint, whichever protocol reported them.

`ModelUsage` stores fresh input, cache read, cache write and output as
*disjoint* buckets, and `ModelPricing` multiplies each by its own rate and adds
them. That arithmetic is only correct if no token is in two buckets. The
upstreams do not agree on the shape:

  * Anthropic reports `cache_read_input_tokens` / `cache_creation_input_tokens`
    beside `input_tokens`, which excludes both.
  * Chat and Responses report the cache hit *inside* the prompt count. DeepSeek
    documents `prompt_tokens == prompt_cache_hit_tokens +
    prompt_cache_miss_tokens`; OpenAI nests `cached_tokens` in `input_tokens`.

Storing the Chat/Responses numbers raw billed the cached part twice (miss rate
+ hit rate) and counted it twice in `total`. Nothing in review shows it — both
numbers are individually correct, and the sum is a plausible-looking figure.
So: feed the production parser the exact usage shapes the real vendors emit and
assert the buckets come out disjoint.

Also locks the SQL side of the same invariant: the third-party rollup's
migration must subtract the hit from rows written before the fix, and the
`input` column must never be smaller than zero.

No app launch, no network.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
assembler = (root / 'Sources/ClaudeBar/Utils/StreamAssembler.swift').read_text()
usage_store = (root / 'Sources/ClaudeBar/Utils/ProxyUsageStore.swift').read_text()

start = assembler.index('/// Token usage as one upstream call reported it.')
end = assembler.index('/// Assembled assistant payload used by the Traffic page')
tokens_source = assembler[start:end]

swift = r'''
import Foundation

TOKENS

@main struct Regression {
    static func main() {
        // 1. Anthropic: the cache fields sit BESIDE `input_tokens`, which is
        //    fresh input already. Nothing may be folded out of it.
        var anthropic = TokenTotals()
        anthropic.applyAnthropic(event: "message_start", json: ["message": ["usage": [
            "input_tokens": 1_000, "output_tokens": 200,
            "cache_read_input_tokens": 9_000, "cache_creation_input_tokens": 500,
        ]]])
        precondition(anthropic.input == 1_000, "Anthropic input_tokens is fresh input: \(anthropic.input!)")
        precondition(anthropic.cacheRead == 9_000)
        precondition(anthropic.cacheWrite == 500)
        precondition(anthropic.output == 200)
        precondition(anthropic.total == 1_000 + 200 + 9_000 + 500,
                     "total must sum the disjoint buckets, not the upstream's prompt count")

        // 2. DeepSeek Chat: `prompt_tokens` INCLUDES the hit, and the hit is
        //    also reported at the top level of `usage`. This is the shape that
        //    was billed twice.
        var deepseek = TokenTotals()
        deepseek.applyChat(["usage": [
            "prompt_tokens": 10_000, "completion_tokens": 200,
            "prompt_cache_hit_tokens": 9_000, "prompt_cache_miss_tokens": 1_000,
        ]])
        precondition(deepseek.input == 1_000,
                     "the hit must be folded out of prompt_tokens: got \(deepseek.input!)")
        precondition(deepseek.cacheRead == 9_000)
        precondition(deepseek.total == 10_200,
                     "in + hit + out must equal the upstream's own total: \(deepseek.total!)")

        // 3. OpenAI-shaped Chat: the hit arrives nested instead, and the
        //    upstream's own total_tokens is reproduces exactly once the hit is
        //    not counted twice.
        var nested = TokenTotals()
        nested.applyChat(["usage": [
            "prompt_tokens": 10_339, "completion_tokens": 60, "total_tokens": 10_399,
            "prompt_tokens_details": ["cached_tokens": 10_318],
        ]])
        precondition(nested.input == 21, "got \(nested.input!)")
        precondition(nested.cacheRead == 10_318)
        precondition(nested.total == 10_399,
                     "in + hit + out must reproduce the upstream's total_tokens: \(nested.total!)")

        // 3b. A separate write bucket: it is a third disjoint bucket, so it
        //     adds to `total` on top of prompt+completion rather than being
        //     part of the prompt count.
        var writes = TokenTotals()
        writes.applyChat(["usage": [
            "prompt_tokens": 10_339, "completion_tokens": 60,
            "prompt_tokens_details": ["cached_tokens": 10_318, "cache_write_tokens": 21],
        ]])
        precondition(writes.input == 21)
        precondition(writes.cacheWrite == 21)
        precondition(writes.total == 21 + 60 + 10_318 + 21)

        // 4. Responses API, streamed and non-streamed, `cached_tokens` nested
        //    in `input_tokens_details` — and only on the event that carries it.
        //    An earlier event's input count must not be double-subtracted.
        var responses = TokenTotals()
        responses.applyResponses(["type": "response.in_progress",
                                  "response": ["usage": ["input_tokens": 5_000, "output_tokens": 0]]])
        precondition(responses.input == 5_000)
        responses.applyResponses(["type": "response.completed",
                                  "response": ["usage": [
                                      "input_tokens": 5_000, "output_tokens": 300,
                                      "input_tokens_details": ["cached_tokens": 4_000]]]])
        precondition(responses.input == 1_000, "got \(responses.input!)")
        precondition(responses.cacheRead == 4_000)
        precondition(responses.total == 5_300)

        // 5. An identical re-statement must not move the numbers — streams
        //    repeat their usage block, and re-deriving from the raw prompt
        //    count is what keeps that idempotent.
        let before = responses
        responses.applyResponses(["type": "response.completed",
                                  "response": ["usage": [
                                      "input_tokens": 5_000, "output_tokens": 300,
                                      "input_tokens_details": ["cached_tokens": 4_000]]]])
        precondition(responses == before, "a repeated usage block must be idempotent")

        // 6. A relay echoing Anthropic-named fields on the OpenAI route: that
        //    `input_tokens` excludes the cache buckets, so nothing is folded
        //    out. Reading the field and subtracting anyway would under-count.
        var relay = TokenTotals()
        relay.applyResponses(["usage": [
            "input_tokens": 1_000, "output_tokens": 100,
            "cache_read_input_tokens": 9_000, "cache_creation_input_tokens": 2_000,
        ]])
        precondition(relay.input == 1_000, "got \(relay.input!)")
        precondition(relay.cacheRead == 9_000)
        precondition(relay.cacheWrite == 2_000)

        // 6b. Same relay, but after `normalizeUsage` ran: it fills a
        //     `cached_tokens: 0` placeholder when there was no detail block to
        //     read. A zero placeholder must not be mistaken for the hit, or the
        //     Anthropic-shaped field beside it is ignored and the prompt count
        //     gets folded by a hit it does not contain.
        var normalized = TokenTotals()
        normalized.applyResponses(["usage": [
            "input_tokens": 1_000, "output_tokens": 100,
            "cache_read_input_tokens": 9_000, "cache_creation_input_tokens": 2_000,
            "input_tokens_details": ["cached_tokens": 0],
        ]])
        precondition(normalized.input == 1_000, "got \(normalized.input!)")
        precondition(normalized.cacheRead == 9_000)

        // 6c. Both shapes present and agreeing: the subset read is taken, and
        //     the prompt count — which then does contain it — is folded. This
        //     is the OpenAI-compatible case, not the relay one.
        var both = TokenTotals()
        both.applyResponses(["usage": [
            "input_tokens": 5_000, "output_tokens": 100,
            "input_tokens_details": ["cached_tokens": 4_000],
            "cache_read_input_tokens": 4_000,
        ]])
        precondition(both.input == 1_000, "got \(both.input!)")
        precondition(both.cacheRead == 4_000)

        // 7. No usage at all stays nil rather than becoming a confident zero.
        var empty = TokenTotals()
        empty.applyChat(["choices": [["delta": ["content": "hi"]]]])
        precondition(empty.isEmpty, "a delta with no usage must not report zeros")
        precondition(empty.total == nil)

        // 8. A gateway that reports the hit but never the prompt total still
        //    gets a bucket, and it cannot go negative.
        var hitOnly = TokenTotals()
        hitOnly.applyChat(["usage": ["completion_tokens": 5,
                                     "prompt_cache_hit_tokens": 4_000]])
        precondition(hitOnly.input == nil, "no prompt count was reported")
        precondition(hitOnly.cacheRead == 4_000)
        precondition(hitOnly.total == 4_005)

        // 9. A pathological upstream whose hit exceeds its prompt count must
        //    clamp at zero, not go negative.
        var impossible = TokenTotals()
        impossible.applyChat(["usage": ["prompt_tokens": 100, "completion_tokens": 1,
                                        "prompt_cache_hit_tokens": 9_000]])
        precondition(impossible.input == 0, "a negative bucket must clamp: \(impossible.input!)")

        print("PASS: proxy token buckets are disjoint across Anthropic, Chat and Responses shapes")
    }
}
'''.replace('TOKENS', tokens_source)

# The rollup migration, asserted on the SQL text rather than by opening a DB:
# this test compiles the parser standalone, which has no SQLite store behind it.
for needed, why in [
    ('ALTER TABLE usage ADD COLUMN cache_write', 'the cache-write bucket needs a column'),
    ('UPDATE usage SET input = MAX(0, input - cache_read)', 'old rows must fold the hit out of input'),
    ('PRAGMA user_version = 1', 'the repair must be recorded so it runs once'),
]:
    assert needed in usage_store, f'missing migration step: {why}'
assert 'func record(model: String, at date: Date, input: Int, output: Int,\n                cacheRead: Int, cacheWrite: Int = 0)' in usage_store, \
    'the rollup must accept the cache-write bucket'

with tempfile.TemporaryDirectory(prefix='claudebar-proxy-usage-tests-') as folder:
    temporary = Path(folder)
    source = temporary / 'Regression.swift'
    source.write_text(swift)
    binary = temporary / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

print("PASS: third-party rollup repairs pre-fix rows and stores all four buckets")
