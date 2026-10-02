#!/usr/bin/env python3
"""The widget's model tint must equal the main app's, for every bundled model.

`WidgetViews.WidgetBars.color(for:)` is a private copy of `Theme.barColor` —
the widget target cannot see the app's code — and the copy had drifted: it
ended `h % palette.count` while `Theme.djb2` ends `Int(h % UInt64(Int.max))`.
Because `2^63−1 ≡ 2 (mod 5)`, that is not a rounding detail: every hash at or
above `Int.max` lands two palette slots away. Of the 56 slugs in the bundled
price table, 19 came out a different colour in the widget than in the popup.

This suite compiles both real hash functions — sliced from `Theme.swift` and
`WidgetViews.swift`, not retyped — and compares their index over every slug the
bundled table ships, plus the whole 56-slug fixture from the price table, so a
future edit to either copy fails here rather than in a screenshot.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
theme = (root / 'Sources/ClaudeBar/Theme/Theme.swift').read_text()
widget = (root / 'Sources/Widget/WidgetViews.swift').read_text()


def slice_body(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth, index = 1, opening + 1
    while depth:
        depth += (text[index] == '{') - (text[index] == '}')
        index += 1
    return text[opening + 1:index - 1]


theme_djb2 = slice_body(theme, 'static func djb2(')
widget_color = slice_body(widget, 'static func color(for model: String) -> Color')

# The table's own slugs: the fixture list is generated from the model names the
# bundled price table actually ships, so a slug added there is covered here.
slugs = sorted(set(re.findall(r'slug: "([a-z0-9.\-]+)"', (root / 'Sources/ClaudeBar/Utils/ModelPriceTable.swift').read_text())))
if len(slugs) < 30:
    raise SystemExit(
        f'widget-tint-regressions.py: found only {len(slugs)} slugs in ModelPriceTable.swift — '
        'the table\'s shape changed and this suite is no longer reading it')
names = '\n'.join(f'        "{slug}",' for slug in slugs)

harness = f'''
import Foundation

enum Theme {{
    static func djb2(_ s: String) -> Int {{
        {theme_djb2}
    }}
}}

enum WidgetBars {{
    static let palette = [0, 1, 2, 3, 4]
    /// `WidgetBars.color`'s body verbatim — including its `return`, so what runs
    /// here is the shipped index arithmetic, not a restatement of it.
    static func index(for model: String) -> Int {{
        {widget_color}
    }}
}}

let slugs: [String] = [
{names}
]

var failures = 0
for slug in slugs {{
    let app = Theme.djb2(slug) % 5
    let widget = WidgetBars.index(for: slug)
    if app != widget {{
        print("FAIL: \\(slug): app index \\(app), widget index \\(widget)")
        failures += 1
    }}
}}
if failures > 0 {{
    print("\\(failures)/\\(slugs.count) slugs disagree between the app and the widget")
    exit(1)
}}
print("PASS: all \\(slugs.count) bundled model slugs hash to the same palette slot in Theme and the widget")
'''

with tempfile.TemporaryDirectory(prefix='claudebar-widget-tint-') as folder:
    folder = Path(folder)
    source = folder / 'WidgetTint.swift'
    source.write_text(harness)
    subprocess.run(['swiftc', '-O', str(source), '-o', str(folder / 'widget-tint')], check=True)
    subprocess.run([str(folder / 'widget-tint')], check=True)
