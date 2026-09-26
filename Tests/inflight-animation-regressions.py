#!/usr/bin/env python3
"""No implicit `.animation(_:value:)` keyed on a value that ticks.

`.animation(_:value:)` opens an animated transaction every time `value`
changes. While any transaction is in flight, *every* display cycle makes
AppKit run the whole hosting view's layout and display list — not only the
cycles where the interpolated property moves. So a modifier keyed on a value
the sampler publishes once a second is not a cheap animation: it is a
permanently in-flight transaction.

Evidence: a `sample` of the idle dashboard. With the modifier, one such
`.animation(.snappy(duration: 0.38), value: value)` on `RollingNumberText` put
`+[NSAnimationContext runAnimationGroup:]` inside `@objc NSHostingView.layout()`
for 31 % of main-thread samples, `NSHostingView.layout()` at 31 %, and
`stepIdle` (the display-cycle observer re-laying out the window every frame) at
56 %. Without it: 13 % / 13 % / 3 %.

The `ps -p PID -o time=` delta is a noisy metric on the machine this was found
on (a Chrome renderer holds half a core, and the app's own idle figure swings
10–27 % between 20 s windows with no interaction), so treat the sample
attribution as the evidence and the CPU delta as corroboration only.

This test is a *source* assertion, not a behavioural one: no compiled slice can
run the SwiftUI animation machinery, and "a transaction is in flight" has no
observable API. What it can do is hold the two components whose inputs change
on every poll to the rule, so the fix cannot be silently reverted by a later
"let's animate that number" edit.

The rule, for whoever hits this next: before adding `value:`, ask how often
that value changes. If the answer is "every poll", key on something coarse (a
mode, a phase, a status) and let `.contentTransition(.numericText())` carry the
digits — that transition *is* the animation.

See docs/technical/08-performance.md and docs/technical/17-ui-audit-backlog.md.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]

# (file, symbol) — the symbol's body must not carry an implicit value-keyed
# animation.
GUARDED = [
    ('Sources/ClaudeBar/Views/Shared/Interaction.swift', 'struct RollingNumberText: View'),
    ('Sources/ClaudeBar/Views/Shared/SectionHeader.swift', 'private var trailingView: some View'),
]

failures = []


def body_of(source: str, signature: str) -> str:
    """The braces-balanced body of `signature`, signature line included."""
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    index = brace + 1
    while depth:
        depth += (source[index] == '{') - (source[index] == '}')
        index += 1
    return source[start:index]


def without_comments(code: str) -> str:
    """Drop `//` and `/* … */` comments.

    The doc comments on these components *quote* the forbidden modifier — that
    is the point of them, they tell the next reader why it is gone — so
    matching raw source would flag every explanation of the rule.
    """
    code = re.sub(r'/\*.*?\*/', '', code, flags=re.S)
    return re.sub(r'//[^\n]*', '', code)


def top_level_characters(text: str) -> str:
    """`text` with every nested parenthesised group replaced by `()`.

    Used to tell a `value:` that belongs to the `.animation` call from one
    belonging to a nested call. Done by scanning depth rather than by regex:
    `re.sub(r'\\([^()]*\\)', '()', …)` collapses the *whole* argument list when
    the arguments contain no parens of their own
    (`.animation(Theme.Animation.smooth, value: count)`), which silently
    dropped the label the caller was looking for — a plugin that a
    reintroduction of the bug slipped past.
    """
    out = []
    depth = 0
    for character in text:
        if character == '(':
            depth += 1
            if depth == 1:
                out.append('(')
        elif character == ')':
            if depth == 1:
                out.append(')')
            depth -= 1
        elif depth <= 1:
            out.append(character)
    return ''.join(out)


def value_keyed_animations(code: str) -> list[str]:
    """Every `.animation(...)` call whose argument list carries a `value:` label.

    Scans to the call's *matching* close paren, not the first one: the argument
    list routinely nests parens (`.snappy(duration: 0.38)`), and a match that
    stops at the first `)` accepts the very modifier this test exists to catch.
    """
    found = []
    cursor = 0
    while True:
        start = code.find('.animation(', cursor)
        if start < 0:
            return found
        index = start + len('.animation(')
        depth = 1
        while index < len(code) and depth:
            if code[index] == '(':
                depth += 1
            elif code[index] == ')':
                depth -= 1
            index += 1
        arguments = code[start:index]
        if re.search(r'(^|[(,\s])value\s*:', top_level_characters(arguments)):
            found.append(' '.join(arguments.split()))
        cursor = index


for path, signature in GUARDED:
    source = (root / path).read_text()
    try:
        body = body_of(source, signature)
    except ValueError:
        failures.append(f'{path}: {signature!r} not found — the guard is stale')
        continue
    hits = value_keyed_animations(without_comments(body))
    if hits:
        failures.append(
            f'{path}: {signature} carries an implicit animation keyed on a '
            f'value — {hits[0]}. Values on these components change every poll, '
            f'so this keeps an animated transaction permanently in flight: '
            f'every display cycle then re-lays out the whole hosting view. '
            f'Drop it and let `.contentTransition(.numericText())` animate the '
            f'digits.')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}', file=sys.stderr)
    sys.exit(1)

print('PASS: no implicit value-keyed animation on the per-poll digit '
      'components (RollingNumberText, SectionHeader.trailingView)')
