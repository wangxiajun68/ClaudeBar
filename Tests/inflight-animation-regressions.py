#!/usr/bin/env python3
"""No implicit `.animation(_:value:)` keyed on a value that ticks — and the
transaction that actually makes the digit roll run.

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

The `.transaction(value:)` half of this file guards a second, opposite failure.
`.contentTransition(.numericText())` only says what happens to the glyphs
*during* a transition; it does not create one. Removing the `.animation(value:)`
left every figure in a non-animated transaction, so the digits swapped with no
roll — the numbers stopped moving even though the transition was still declared.
A `RollingNumberModifier` without its `.transaction(value:)` is that bug, so it
is asserted here rather than trusted to survive the next "these numbers are
expensive" pass.

(Measured with the island harness: with `.transaction(value:)` the figure is
caught mid-flight, the new value sliding up over the old one; without it the
frame after the change already shows the final value, and no frame ever shows
two digits at once.)

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
    # The common method the whole app routes its digits through. The wrapper
    # above no longer carries the transition itself, so the guard has to sit on
    # the definition that does — otherwise a `.animation(value:)` added to
    # `RollingNumberModifier` would reopen the cost on every rolling figure in
    # the app and this test would still pass.
    ('Sources/ClaudeBar/Views/Shared/Interaction.swift', 'struct RollingNumberModifier: ViewModifier'),
    ('Sources/ClaudeBar/Views/Shared/SectionHeader.swift', 'private var trailingView: some View'),
    # Two more leaves that carried the identical modifier on a per-poll value
    # and were cleared in the same sweep: the island's collapsed token total
    # and the island usage card's hero. They are not the obvious hot leaves —
    # that is exactly why they are pinned here.
    #
    # `MetricTile` in `Tile.swift` had the same modifier and lost it in the
    # same pass, but it is *not* listed: its view also animates hover/press
    # state, which this guard cannot tell apart from a per-poll value, and the
    # view has no caller left (docs/technical/17-ui-audit-backlog.md §10).
    ('Sources/ClaudeBar/Views/Island/NotchIslandView.swift', 'private var wings: some View'),
    ('Sources/ClaudeBar/Views/Island/IslandComponents.swift', 'private var hero: some View'),
    # Three more found in the 2026-09-26 pass, each keyed on a value a *poller*
    # owns rather than on a pointer or a mode. None of them is a figure — they
    # are a gauge arc, a pace ring and a pill label — so `.numericText` cannot
    # take over for them; the right answer was to drop the modifier (or, for
    # `LucideRotor`, to key it on a quantised value that only changes when the
    # drawing visibly does).
    #
    # `SessionCardView`: `agentTotals.running` is derived from `subagents` +
    # `workflows`, i.e. a `ProviderStore.$sessions` output republished every
    # 2.5 s busy / 5 s idle. Nothing in that card interpolates on the count.
    ('Sources/ClaudeBar/Views/Shared/SessionCardView.swift', 'var body: some View'),
    # `IslandPaceRing`: `pace` is today's total against yesterday's, so it moves
    # on *every* usage-index pass — an FSEvents transcript burst can move it
    # several times a second. It is drawn only in the collapsed wings, on the
    # one surface `UIWakePolicy` deliberately does not count as visible.
    ('Sources/ClaudeBar/Views/Island/NotchIslandView.swift', 'struct IslandPaceRing: View'),
    # `LucideRotor`: the rim gauge used to animate on `rpm` directly, and SMC
    # reports a slightly different RPM most 2 s polls, so a fan at a steady
    # speed still opened a transaction every tick. It is now keyed on `gauge`,
    # a 1.5 % quantisation of the same reading — so a `value:` is correct here
    # and only a `value: rpm` would be the bug. Asserted separately below
    # rather than with the blanket rule.
]

# `value:` is allowed here, but only on the quantised key. Keeping the rule in
# the same file means a later "let's animate the rpm" edit is caught with the
# same message the other components give.
ROTOR_BODY = ('Sources/ClaudeBar/Views/Shared/LucideRotor.swift', 'var body: some View')

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


def tile_calls(code: str) -> list[str]:
    """Every `.tile(...)` call's argument list, paren-balanced.

    A `[^)]*` scan stops inside the nested `DepthLensSpec(...)`, so it would
    miss a flag that comes after it — which is where `lift: false` sits.
    """
    found = []
    for match in re.finditer(r'\.tile\(', code):
        index = match.end()
        depth = 1
        while index < len(code) and depth:
            if code[index] == '(':
                depth += 1
            elif code[index] == ')':
                depth -= 1
            index += 1
        found.append(code[match.end():index - 1])
    return found


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

# --- The roll must actually run --------------------------------------------
#
# The mirror image of the rule above: the digits need a transaction to move in,
# and the one place that may open it is the shared modifier, keyed on the
# rendered value. Assert both halves — the call, and that it is keyed on the
# value rather than sitting on a per-poll input.
roll_source = without_comments(
    (root / 'Sources/ClaudeBar/Views/Shared/Interaction.swift').read_text())
roll_body = body_of(roll_source, 'struct RollingNumberModifier: ViewModifier')
if '.transaction(value:' not in roll_body:
    failures.append(
        'Interaction.swift: RollingNumberModifier no longer opens a '
        '`.transaction(value:)`. `.numericText` needs an animated transaction to '
        'run in, and a figure fed by the sampler arrives in a plain one, so '
        'without this the digits swap instantly and the roll is invisible in the '
        'running app — which is exactly the regression this guards.')
elif not re.search(r'\.transaction\(value:\s*transition', roll_body):
    failures.append(
        'Interaction.swift: RollingNumberModifier opens a transaction keyed on '
        'something other than the rendered value. A key that does not change with '
        'the figure is a fresh transaction per poll (the cost this file exists '
        'to prevent); one keyed on the value animates only the change being '
        'drawn.')

# --- The fan gauge may animate, but not on the raw reading -------------------
#
# The one component where a `value:` is correct: the rotor's rim gauge. It has
# to be keyed on the *quantised* fraction, because SMC reports a slightly
# different RPM most polls and a key on `rpm` would therefore open a transaction
# on every one of them, for a change of a fraction of a point of arc.
#
# Asserted on the *write* rather than on the presence of `gaugeValue`: the
# property is named in `.onAppear` and in the Reduce Motion branch as well, so
# "the file mentions it" passes even when the animated write reads `rpm`
# straight (confirmed with a negative control — that reintroduction first
# slipped past a check written that way).
rotor_source = without_comments(
    (root / 'Sources/ClaudeBar/Views/Shared/LucideRotor.swift').read_text())
rotor_body = body_of(rotor_source, ROTOR_BODY[1])
if 'withAnimation' in rotor_body and not re.search(
        r'let\s+next\s*=\s*gaugeValue', rotor_body):
    failures.append(
        'LucideRotor.swift: the rim gauge is animated from something other than '
        '`gaugeValue`. Keyed on the raw reading it opens a transaction on every '
        'fan poll — SMC wobbles the RPM most ticks — for a change too small to '
        'see. Route the write through `gaugeValue`, which quantises to the '
        'smallest step worth interpolating.')

# --- The page band must not lift -------------------------------------------
#
# `TileSurface`'s 2pt hover rise moves the card's own frame, and the hover
# region moves with it: a pointer parked within 2pt of the card's bottom edge
# is carried out of the card by the rise, re-enters as it drops back, and
# oscillates once per pointer update — which reads as the header shaking. Two
# structural properties keep that from coming back:
#
#   1. the hit shape is pinned *before* the offset, so the pointer region never
#      travels with the rise — this is what makes any lifting card safe;
#   2. the page band opts out (`lift: false`), because it is full-width with its
#      controls in the lower half and one-per-page, so the rise buys nothing and
#      only widens the strip that can oscillate.
tile_source = (root / 'Sources/ClaudeBar/Views/Shared/Tile.swift').read_text()
tile_surface = without_comments(body_of(tile_source, 'struct TileSurface<Content: View>: View'))
shape = tile_surface.find('.contentShape(')
offset = tile_surface.find('.offset(y: lift')
if shape < 0:
    failures.append(
        'Tile.swift: TileSurface has no pinned `.contentShape` — the hit shape '
        'must be fixed before the hover lift, or the pointer region rides the '
        'card out of itself and back.')
elif offset >= 0 and shape > offset:
    failures.append(
        'Tile.swift: TileSurface pins `.contentShape` *after* the hover lift; '
        'it must be applied to the unlifted frame.')

band_source = (root / 'Sources/ClaudeBar/Views/Shared/UiverseSurfaces.swift').read_text()
band = without_comments(body_of(band_source, 'struct PageHeaderCard<Content: View>: View'))
if not any(re.search(r'lift:\s*false', call) for call in tile_calls(band)):
    failures.append(
        'UiverseSurfaces.swift: PageHeaderCard no longer passes `lift: false`. '
        'A full-width band that rises on hover carries a pointer parked on its '
        'bottom edge out of its own hover region and back, which reads as the '
        'header shaking.')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}', file=sys.stderr)
    sys.exit(1)

print('PASS: no implicit value-keyed animation on the per-poll digit '
      'components (RollingNumberText, RollingNumberModifier, '
      'SectionHeader.trailingView, Island wings / usage hero), and the shared '
      'roll opens its own transaction')
