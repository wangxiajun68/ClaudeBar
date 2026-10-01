#!/usr/bin/env python3
"""Cursor's actual-charge decoder must survive the two shapes that are not like
any other payload in this app, and the money must never be able to pass for an
estimate.

Four things here produce a confidently wrong number if left to review, and none
is visible by reading the Swift:

1. **The aggregation sends every token count as a string.** `"inputTokens":
   "914"` alongside a *numeric* `totalCents`. A parser written with `as? Int`
   reads the whole payload as zero — which renders as an empty month, not as an
   error. The shared `CursorUsageFetcher.number` accepts both forms; this locks
   that it is the helper being used.

2. **`tokenUsage` is absent entirely on non-token calls.** `isTokenBasedCall:
   false`, `chargedCents: 0`, and no `tokenUsage` key — a real zero-value row
   (a `grok-bot-*` sub-agent dispatch), not a parse failure. A parser that
   requires the key drops the page.

3. **A window Cursor will not answer for comes back as an error envelope**
   (`{"code":"internal"}`) with no `aggregations` key, and a too-large
   `pageSize` comes back as a body with *neither* count nor rows. Both must be
   nil, never an empty result — an empty result sums to $0.00 and reads as a
   free month.

4. **Cursor names a model by its effort tier** (`claude-opus-5-5-medium`) where
   the local clients record it bare, so the fold has to canonicalise or the
   charge lands on a row that does not exist on the page. `grok-4.7-medium`
   must NOT be folded to `grok-4.7-medium` … it must fold to `grok-4.7`, and
   `claude-4.6-sonnet-medium-thinking` must fold all the way down.

Drives the production parsers and the window planner with payloads captured
from the live endpoints. No network, no app launch, no credentials.
"""

from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
utils = root / 'Sources/ClaudeBar/Utils'
models = root / 'Sources/ClaudeBar/Models'
views = root / 'Sources/ClaudeBar/Views/Shared'

fetcher = (utils / 'CursorUsageFetcher.swift').read_text()
ledger = (utils / 'CursorLedger.swift').read_text()
pricing = (utils / 'ModelPricing.swift').read_text()
table = (utils / 'ModelPriceTable.swift').read_text()
usage_model = (models / 'ModelUsage.swift').read_text()
card = (views / 'UsageModelCard.swift').read_text()

def indent(text, by=12):
    """Indent every non-empty line, so an injected block sits inside the
    Swift multi-line string literal that carries it."""
    pad = ' ' * by
    return ''.join((pad + line if line.strip() else line) + '\n'
                   for line in text.splitlines())

def slice_between(text, start_marker, end_marker):
    a = text.index(start_marker)
    b = text.index(end_marker, a)
    return text[a:b]

# Only the pieces this harness drives: the pure ledger, the string-or-number
# coercion it shares with the allowance fetcher, the price module it must never
# feed, and — as *text* — the two sources whose shape the rules depend on.
number_helper = slice_between(
    fetcher,
    '    /// A finite `Double` from a JSON value that may be a number **or a string**.',
    '    /// Cursor returns the billing cycle as an **epoch-millisecond string**')
ledger_enum = slice_between(ledger, 'enum CursorLedger {', '\n}\n') + '\n}'
# `enum ModelPricing` is one top-level declaration with no other top-level brace
# inside it, so the run from its opening brace to the file's last `\n}\n` is the
# whole type — including the longest-match helpers `rate(for:)` needs.
pricing_enum = pricing[pricing.index('enum ModelPricing {'):pricing.rindex('\n}\n')] + '\n}'
# `ModelPricing.present` takes the display preference as a parameter, so the enum
# that names the three modes comes along.
cost_display = slice_between(pricing, 'enum CostDisplay', '\n}\n') + '\n}'
table_enum = slice_between(table, 'enum ModelPriceTable {', '\n}\n') + '\n}'
usage_source = slice_between(usage_model, 'struct ModelUsage', '\n/// Today')
card_source = card

# The Swift template lives in its own file because it carries `"""` string
# literals of its own — a Python triple-quoted template would end at the first
# of them. Same split as `Tests/machine-mark-regressions.py`.
template = (Path(__file__).resolve().parent / 'fixtures/cursor-ledger-probe.swift').read_text()
SWIFT = template
SWIFT = (SWIFT
         .replace('COSTDISPLAY', cost_display)
         .replace('NUMBER', number_helper)
         .replace('LEDGER', ledger_enum)
         .replace('PRICING', pricing_enum + '\n\n' + table_enum)
         .replace('USAGE_SOURCE', indent(usage_source))
         )

# --- The tile must word the two figures differently -----------------------
# Source-level rather than compiled: `UsageModelCard` is a SwiftUI view and
# dragging its body into a harness would mean stubbing SwiftUI. What matters
# here is only that the two figures carry *different words*, and that the actual
# never inherits the estimate's label.
assert 'Cursor 实扣' in card_source, "the tile must name Cursor's figure as an actual charge"
assert '估算 ' in card_source, "the estimate keeps its own word"
assert 'settlementWindow' in card_source, "the actual's row is where the window caption lives"
# Each figure is formatted through the same presenter, so a converted / 分列
# setting cannot make one of them a raw number.
assert card_source.count('ModelPricing.format(primary.amount') >= 2, \
    "both figures must go through the shared formatter"

# Model cards must stay static and reserve independent space for long names
# and source quantities. These checks do not render or benchmark SwiftUI.
assert 'SourceStack(' not in card_source and '.hoverState(' not in card_source
assert 'RollingNumberText(' not in card_source
assert 'DepthLensSpec(' not in card_source
assert 'CacheHitBadge(stat: stat, rolls: false)' in card_source
assert 'TokenMixStrip(stats: [stat], compact: true, rolls: false)' in card_source
assert '.lineLimit(2)' in card_source and '.help(stat.model)' in card_source
assert '.frame(width: 46' not in card_source
assert 'minHeight:' not in card_source, "model card height must follow its content"
usage_view = (views.parent / 'Pages/UsageView.swift').read_text()
assert 'TileGrid(.pageUsage, minColumnWidth: 320)' in usage_view

with tempfile.TemporaryDirectory(prefix='claudebar-cursor-ledger-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(SWIFT)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
