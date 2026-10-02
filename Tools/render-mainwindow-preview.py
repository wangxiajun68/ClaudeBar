#!/usr/bin/env python3
"""Render the app's **main-window pages** from the CURRENT production source.

Slides type declarations out of `Sources/ClaudeBar` (the same `declaration()`
slicing `render-greeting-preview.py` and `render-control-preview.py` use) and
re-assembles them into one `Probe.swift`, compiled head-less with
`/usr/bin/swiftc -O -parse-as-library -target arm64-apple-macos15.0` and drawn
with `ImageRenderer` at scale 2 — so a PNG cannot drift onto a layout the app
has moved on from.

Writes `.build/mainwindow-preview/{page}-{light,dark}.png`, ten files:

    overview  DashboardView    greeting/status sheet · title row · resource strip
                              (CPU/GPU/内存/硬盘/连接/风扇) · energy-flow card
                              · active-session grid
    sessions  SessionsView     CLAUDE CODE / CURSOR / CODEX sections
    usage     UsageView        period chips · heatmap · 来源/节奏/构成 · model tiles
    vpn       VPNView          enable switch · live rates · node mosaic with
                              latencies · subscription area · log
    traffic   TrafficView      request list + conversation inspector

Pages reached, and the one omission
-----------------------------------
All five render. The greeting card is the **real** `GreetingStatusSheet` — sky,
script greeting, instruments and all — because the sky has a shipped still path
(`AtmosphereSurface.stills`, the same shader drawn once into an image, exactly
as `render-greeting-preview.py` does it). Its *store plumbing* is replaced: the
six stores `GreetingCard` reads are handed fixed readings by
`FixtureGreetingSheet`, which is the only part of that card a still cannot use.

What a still cannot carry, and what the fixture does about it
------------------------------------------------------------
`ImageRenderer` never runs view-graph lifecycle and never bridges AppKit, so
three production idioms render as a yellow "unsupported" placeholder or as
nothing at all. Each is replaced by its own drawing, never by different content:

  * `ScrollView` (+ the `LazyVStack` inside it) has no viewport in a still, so
    `page_without_scroll` / `unwrap_scroll_views` / `unwrap_scroll_readers` turn
    each one into a `Group` over the same children;
  * `NSViewRepresentable` — the tile shadow, the rotor layers, the hardware
    sweep (via the production `\.rendersHardwareSweep` flag), the Sankey wave
    layer, the raw-JSON `NSTextView` — is replaced by a SwiftUI equivalent or
    dropped where only the animation is lost;
  * `TextField` and `.buttonStyle(.borderless)` are placeholders outright, so the
    fields become the same string as `Text` and the fan tile's borderless
    buttons become `.plain` (identical chrome, and a still has no press state).

Two page states are seeded that only `onAppear` would otherwise set, because a
still never fires it: the traffic list (`TrafficView.init(fixtureRecords:)`) and
the VPN disclosures (`VPNView(fixtureNodesOpen:fixtureLogsOpen:)`). Both are
additive initialisers; no production body is rewritten.

Fixtures are **synthetic**: no `~/.claude`, `~/.codex` or `~/.cursor` read, no
network, no preference writes (`UserDefaults.volatileDomain` only, which is
dropped with the process). `Sources/` is read-only — the fixture asserts it
below, before slicing anything, so a run that would edit a source fails loudly
rather than silently drifting the PNGs.
"""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / '.build/mainwindow-preview'
out.mkdir(parents=True, exist_ok=True)


def sources_are_read_only():
    """Fail loudly if `Sources/` is not the read-only input this tool assumes.

    Everything here slices *from* the app's source and writes only under
    `.build/`. A writable tree is not itself a problem, but a run that leaves a
    modification behind would mean the renderer had edited the thing it is
    supposed to be reporting on, and the PNG would no longer describe the app.
    """
    import subprocess as _sp
    status = _sp.run(['git', 'status', '--porcelain', '--', 'Sources'],
                     cwd=root, capture_output=True, text=True)
    assert status.returncode == 0, 'git status failed — cannot verify Sources/ is clean'
    dirty = [line for line in status.stdout.splitlines() if line.strip()]
    assert not dirty, ('Sources/ has uncommitted changes before the run:\n  '
                       + '\n  '.join(dirty)
                       + '\nThe renderer must not be the author of a source edit.')


sources_are_read_only()


def declaration(path, start):
    """The balanced-brace declaration beginning at `start` in `path`.

    Same shape as the sibling renderers': `require()` in front of every call
    site is what makes a moved declaration fail loudly, so this stays bare.
    """
    text = (root / path).read_text()
    pos = text.index(start)
    opening = text.index('{', pos)
    level = 1
    end = opening + 1
    while level:
        level += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[pos:end] + "\n"


def whole(path):
    return (root / path).read_text() + '\n'


def after(path, marker):
    text = (root / path).read_text()
    return text[text.index(marker):]


def require(path, start):
    """`declaration()` that fails loudly when the production shape moved."""
    assert start in (root / path).read_text(), \
        f'{path}: required declaration {start!r} is missing — the renderer would drift'
    return declaration(path, start)


# ---------------------------------------------------------------------------
# Text fields
# ---------------------------------------------------------------------------
# `ImageRenderer` draws `TextField` (and therefore every `InstrumentSearchField`)
# as the AppKit "unsupported" placeholder, because the field is bridged to a
# live `NSTextField` that a one-shot snapshot has no window for. The app has no
# custom `TextFieldStyle` that would draw the field on its own — `InstrumentFieldStyle`
# only supplies the well *behind* an AppKit field — so the fixture swaps the
# field for the same string as a `Text`.
#
# The textual content is identical (a draft port, a search prompt, a blank
# query), the field's frame and alignment are the page's own, and what is lost
# is the caret and the text selection — neither of which a still can show.
fixtureTextFields = [
    'Sources/ClaudeBar/Views/Pages/VPNView.swift',
    'Sources/ClaudeBar/Views/Pages/TrafficView.swift',
    'Sources/ClaudeBar/Views/Shared/InstrumentSearchField.swift',
    'Sources/ClaudeBar/Views/Pages/VPNSubscriptionSection.swift',
]


def fixture_text_field(text, expr, path):
    """A `TextField(_:text:)` replaced by a `Text` of the same string.

    The prompt argument is passed straight through: a string literal stays a
    literal, and a `String` property (`InstrumentSearchField`'s `prompt`) stays
    that property. Only the field itself changes — `fixtureField` takes the same
    `Binding<String>` the field did.
    """
    return 'fixtureField(' + text + ', text: ' + expr + ')'

def rewrite_text_fields(text, path):
    """Replace every `TextField(_:text:)` in a page slice with `fixtureField`.

    The two argument shapes the app uses:

      * a string literal prompt — `TextField("7890", text: $portDraft)`
      * a `String` property      — `TextField(prompt, text: $text)`

    Both become `fixtureField(<prompt>, text: <binding>)`, which is declared in
    the preamble and draws the same string and colour without AppKit.
    """
    out, count = re.subn(
        r'TextField\(\s*("(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_.]*)\s*,\s*text:\s*([^)\n]+)\)',
        lambda m: fixture_text_field(m.group(1), m.group(2).strip(), path),
        text)
    # `.focused(_:)` attaches to a real field; a `Text` has no focus to take.
    out = re.sub(r'\n(\s*)\.focused\([^)]*\)', '', out)
    return out, count



def inject_member(text, struct_name, marker, insertion, path):
    """Insert a member into an existing type, right before `marker`.

    The traffic page derives its list in `onAppear` (`recomputeFiltered`), and
    `ImageRenderer` runs no lifecycle callbacks — the page would render its
    empty state against a store that is full of rows. Its cache is a private
    `@State`, so the fixture adds one initialiser that seeds it from the same
    values the page's own pass computes. Nothing in the body changes.
    """
    start = text.index('struct ' + struct_name + ': View {')
    at = text.index(marker, start)
    return text[:at] + insertion + text[at:]



# The row list's own trailing modifiers, as they are written in TrafficView.swift:
# the two paddings and the scroll gate the fixture cannot keep.
SCROLL_LIST_TAIL = """                    .padding(.vertical, Theme.Space.s6)
                    .padding(.horizontal, Theme.Space.s8)
                }
                .scrollHoverGate()"""
SCROLL_LIST_FILL = """                    .padding(.vertical, Theme.Space.s6)
                    .padding(.horizontal, Theme.Space.s8)
                }
                .frame(maxHeight: .infinity, alignment: .top)"""


# The conversation body's own trailing frame, as it is written in
# TrafficView.swift. Under a `VStack` the flex used to push the body to the top;
# a `Group` needs the alignment stated.
CONVERSATION_TAIL = """                    .padding(Theme.Space.s16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)"""
CONVERSATION_TOP = """                    .padding(Theme.Space.s16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"""

def unwrap_scroll_readers(text, path):
    """Replace `ScrollViewReader { proxy in BODY }` with its `BODY`.

    A reader exists only to hand a `proxy` to `ScrollViewReader.scrollTo` — the
    log console's auto-follow, in these pages. A still does not scroll, and the
    closure is not a view the renderer can place, so the reader goes and the
    body it wrapped stays. Every `proxy.scrollTo(…)` line inside it is dropped.
    """
    count = 0
    while True:
        index = text.find('ScrollViewReader')
        if index == -1:
            break
        brace = text.index('{', index)
        stop = _guard_depth(text, brace)
        inner = text[brace + 1:stop - 1]
        assert ' in' in inner, f'{path}: ScrollViewReader no longer takes a proxy'
        _, _, body = inner.partition(' in')
        # The calls appear in two shapes: a statement of their own, and inlined
        # in a one-line closure (`if let id = … { proxy.scrollTo(…) }`). Both
        # carry their own balanced braces, so the whole line goes; a dropped
        # line whose braces did *not* balance would silently unbalance the view
        # body, so that case is a failure here rather than a compile error
        # inside the generated probe.
        kept = []
        for line in body.split('\n'):
            if 'proxy.' not in line:
                kept.append(line)
                continue
            assert line.count('{') == line.count('}'), \
                f'{path}: a proxy call spans lines — the fixture cannot drop it safely'
        body = '\n'.join(kept)
        assert 'proxy.' not in body, f'{path}: a ScrollViewReader proxy use survived'
        text = text[:index] + 'Group {' + body + '}' + text[stop:]
        count += 1
    return text


def _guard_depth(text, brace):
    depth, index = 1, brace + 1
    while depth:
        depth += (text[index] == '{') - (text[index] == '}')
        index += 1
    return index


def unwrap_scroll_views(text, path, expect):
    """Replace every code `ScrollView { … }` in a slice with a `Group { … }`.

    Only real call sites are matched. The word also appears inside doc comments
    in these files ("the `ScrollView` that takes the remaining width"), and a
    rewrite that walked a comment would swallow the declaration under it.

    `ImageRenderer` gives a scroll view no viewport, so its content draws
    nothing — the traffic page is mostly two of them (the request list and the
    conversation body), and the VPN page's node / log sections are two more.
    A `Group` keeps the same children and the same modifiers that hang off the
    scroll view (`.frame`, `.background`), so the page lays out as the content
    it holds. No lazy stack is involved in these, so nothing else changes.
    """
    count = 0
    search = 0
    while True:
        index = text.find('ScrollView', search)
        if index == -1:
            break
        # Leave doc / line comments alone: a `ScrollView` in prose is not a view,
        # and treating one as a view would consume the code beneath it.
        line_start = text.rfind('\n', 0, index) + 1
        prefix = text[line_start:index]
        if '//' in prefix:
            search = index + 1
            continue
        # `ScrollViewReader` is a different container and is handled by name —
        # matching its prefix here would swap the wrong view.
        if text.startswith('ScrollViewReader', index):
            search = index + len('ScrollViewReader')
            continue
        brace = text.index('{', index)
        stop = _guard_depth(text, brace)
        text = text[:index] + 'Group ' + text[brace:stop] + text[stop:]
        count += 1
    assert count == expect, f'{path}: expected {expect} ScrollViews, replaced {count}'
    return text


def page_without_scroll(path, struct_name, marker='    var body: some View {\n'):
    """The page, with its outer `ScrollView` replaced by a plain `VStack`.

    `ImageRenderer` draws the view graph at its measured size; a `ScrollView`
    proposes an unbounded height to its child and then clips to a scroll
    viewport a one-shot render never sizes. So the fixture keeps the page
    *type* — its stored properties and every member the body reads — and
    substitutes the container only: `ScrollView { … }` becomes `Group { … }`,
    with the body's own stack left exactly as it is. `Dashboard` / `Sessions` /
    `Usage` are this shape.

    `VPNView` is not: its body opens on a `GeometryReader` whose `geometry.size`
    *is* the sizing input, so a still with no reader has nothing to measure.
    That branch therefore goes further — it removes the reader, rewrites every
    `geometry.size` to the fixed `fixturePageSize`, and swaps the `ScrollView`
    inside it for a `Group` too — which is a materially larger substitution than
    the container swap above, and the reason this docstring names it.
    """
    text = (root / path).read_text()
    # Anchor on the *page* type, not the first `var body` in the file: these
    # pages carry private helper structs above them that also have a body.
    type_start = text.index('struct ' + struct_name + ': View {')
    body_start = text.index(marker, type_start) + len(marker)
    # Two body shapes ship in the app, and both need the same treatment because
    # a still has one size and a `ScrollView` has none:
    #
    #   * `ScrollView { LazyVStack { … } }` — Dashboard / Sessions / Usage. The
    #     container is the body's first view; swap it for a `Group`.
    #   * `GeometryReader { … ScrollView … }` — VPN. The `GeometryReader` is
    #     the first view and it *is* the sizing container here (`contentWidth`
    #     is derived from its `geometry`). Its flexible axis would measure to 0
    #     in a still, so replace only the reader — taking its `geometry` name
    #     out of the members below — and let the `ScrollView` inside lay out
    #     against the width the fixture host pins.
    reader = text.find('GeometryReader', body_start)
    if reader != -1 and reader - body_start < 400:
        open_brace = text.index('{', reader)
        depth, index = 1, open_brace + 1
        while depth:
            depth += (text[index] == '{') - (text[index] == '}')
            index += 1
        inner = text[open_brace + 1:index - 1]
        # `GeometryReader { geometry in … }`: the closure's parameter is named
        # whatever the page calls it, so read the name off the first line rather
        # than assuming `geometry`.
        assert ' in' in inner, f'{path}: GeometryReader no longer takes a named proxy'
        first, _, rest = inner.partition(' in')
        geometry = first.strip().split()[-1]
        inner = rest
        assert geometry + '.size' in inner, \
            f'{path}: GeometryReader body no longer reads {geometry}.size'
        inner = inner.replace(geometry + '.size', 'fixturePageSize')
        # The reader's child is itself the scroll container
        # (`ScrollView([.horizontal, .vertical]) { … }`). With a concrete width
        # in hand, dropping that container is what lets the page lay out at all:
        # `ImageRenderer` never sizes a scroll viewport, so leaving it in yields
        # a blank canvas even at a fixed width. Same swap as the pages above.
        dot = inner.find('ScrollView')
        assert dot != -1, f'{path}: GeometryReader no longer wraps a ScrollView'
        brace = inner.index('{', dot)
        depth, stop = 1, brace + 1
        while depth:
            depth += (inner[stop] == '{') - (inner[stop] == '}')
            stop += 1
        inner = inner[:dot] + 'Group ' + inner[brace:stop] + inner[stop:]
        text = text[:reader] + 'Group {' + inner + '}' + text[index:]
        # The reader's own trailing modifiers (`.scrollHoverGate()`, the
        # `onChange` plumbing) stay attached to the `Group`, which is right —
        # they are the page's, not the scroll container's.
        return text
    scroll = text.index('ScrollView', body_start)
    assert scroll - body_start < 1200, f'{path}: body no longer opens with a ScrollView'
    open_brace = text.index('{', scroll)
    depth, index = 1, open_brace + 1
    while depth:
        depth += (text[index] == '{') - (text[index] == '}')
        index += 1
    # Everything from `ScrollView` to its matching `}` becomes the page's own
    # non-scrolling content, and the page keeps its remaining body modifiers.
    text = (text[:scroll] + 'Group ' + text[open_brace:index]
            + text[index:])
    # `ScrollView`'s own trailing modifiers are the scroll behaviour, not the
    # page's; drop the two the fixture cannot use (a `View`'s `.onScroll*` needs
    # a real scroll container).
    text = text.replace('.scrollHoverGate()\n', '')
    text = re.sub(r'\.onScrollPhaseChange \{ _, phase in.*?\n        \}\n', '', text, count=1, flags=re.S)
    text = re.sub(r'\.onScrollVisibilityChange\(threshold: [^)]*\) \{ [^}]*\}\n', '', text)
    return text

def require_file(path):
    assert (root / path).is_file(), f'{path} is missing'
    return whole(path)


# The brand artwork `ProductBrandMark` decodes; a slice with no app bundle would
# otherwise draw its missing-asset fallback and a blank mark would pass.
brand_marks = root / 'Sources/BrandAssets'
for mark in ('anthropic', 'openai', 'cursor', 'claudebar'):
    for variant in ('light', 'dark'):
        assert (brand_marks / f'{mark}-{variant}.png').is_file(), \
            f'{mark}-{variant}.png missing — ProductBrandMark would draw its fallback'


# ---------------------------------------------------------------------------
# The assembled probe
# ---------------------------------------------------------------------------
# A plain concatenation, not an f-string: the Swift below is full of braces.
source = 'import AppKit\nimport SwiftUI\nimport Combine\nimport simd\n'
source += '\n'
source += 'let brandMarks = "' + str(brand_marks) + '"\n'
source += 'let greetingScripts = "' + str(root / 'Sources/Fonts') + '"\n'
source += 'let fanArtworkPath = "' + str(root / 'Sources/ClaudeBar/Resources/macbook-internals-illustration.png') + '"\n'
# `VPNView` measures its content width off a `GeometryReader`. A still has one
# size and no reader, so `page_without_scroll` swaps the reader for a fixed
# page box and every `geometry.size` in that body reads this instead. 1120pt is
# the app's default window width (`Fixture.pageWidth`); the page then subtracts
# its own 16pt padding, exactly as it does live.
source += 'let fixturePageSize = CGSize(width: 1120, height: 1180)\n'
# `GreetingCard` and the terminal launchers are referenced by pages above the
# stand-in block's own body, so they are declared here, before everything.
source += '''
enum AppPage: String, CaseIterable, Identifiable {
    case dashboard, sessions, providers, connectors, usage, traffic, vpn, settings, help
    var id: String { rawValue }
    static var tabs: [AppPage] { allCases.filter { $0 != .help } }
    var label: String { rawValue }
    var icon: String { "square.grid.2x2" }
}
struct GreetingCard: View {
    var onNavigate: (AppPage) -> Void = { _ in }
    var body: some View { EmptyView() }
}
enum TerminalLauncher {
    static func resumeClaudeSession(cwd: String, sessionId: String, pid: Int?) {}
    static func resumeCodexSession(cwd: String, sessionId: String, pid: Int?, inDesktop: Bool) {}
    static func revealInFinder(cwd: String) {}
    static func openInCursor(cwd: String) {}
}
struct ProxyLogView: View { var body: some View { EmptyView() } }
/// Which hosts each provider actually talks to, pinned in front of the
/// profile's rules. The fixture reads no preset file, so the list is empty —
/// the strip's tiles draw from the sampler anyway.
enum VpnProviderDirect {
    @discardableResult
    static func hosts(claudeFile: URL? = nil, codexFile: URL? = nil) -> [String] { [] }
}

// MARK: - Traffic capture store (synthetic)

enum ProxyAccessLog {
    static let clockShort: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}

final class JSONFoldControl: ObservableObject {
    @Published private(set) var expanded = false
    @Published var openIDs: Set<String> = []
    func expandAll() { expanded = true }
    func collapseAll() { expanded = false }
    func toggle(_ id: String) { if openIDs.contains(id) { openIDs.remove(id) } else { openIDs.insert(id) } }
    var isExpanded: Bool { expanded }
}
struct JSONTreeView: View {
    let source: String
    var empty: String = "(empty)"
    var parseID: String = ""
    @ObservedObject var fold: JSONFoldControl
    var body: some View { EmptyView() }
}
struct PlainDumpView: View { var text: String; var body: some View { EmptyView() } }
enum JSONTree { static func pretty(_ raw: String) -> String { raw } }
final class ProxyInflight {
    static let shared = ProxyInflight()
    func cancel(captureID: Int64) {}
}

/// Cursor's monthly allowance. Its real `init` reads Cursor's SQLite; the
/// fixture only needs the published shape the usage tile reads.
final class CursorUsageStore: ObservableObject {
    @MainActor static let shared = CursorUsageStore()
    var plan: CursorUsageFetcher.PlanUsage? { nil }
    var loading = false
    var note: String?
    func refresh(manual: Bool = false) {}
}

/// Cursor's charged-amount store. Its real `init` reads a disk cache and opens
/// Cursor's SQLite; the fixture only needs the published shape the usage tile
/// and the provider derivation read.
final class CursorLedgerStore: ObservableObject {
    @MainActor static let shared = CursorLedgerStore()
    @Published private(set) var rows: [String: CursorLedger.Row] = [:]
    @Published private(set) var window: DateInterval?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var loading = false
    @Published private(set) var note: String?
    private(set) var truncated = false
    var windowLabel: String? { Self.windowLabel(window) }
    static func windowLabel(_ window: DateInterval?) -> String? { nil }
    func snapshot(for window: DateInterval) -> CursorLedger.Snapshot? { nil }
    func isStale(for window: DateInterval) -> Bool { true }
    func refresh(window: DateInterval, billingCycle: DateInterval?, force: Bool = false) {}
}

'''


source += r'''
// MARK: - Text fields (fixture)

/// A `TextField` drawn as text.
///
/// `ImageRenderer` renders a live `NSTextField` bridge as the AppKit
/// "unsupported" placeholder, so every field on the captured pages is swapped
/// for its own string. The frame, font and alignment stay the page's; only the
/// caret and the selection are gone, and a still cannot show either.
func fixtureField(_ prompt: String, text: Binding<String>) -> some View {
    let value = text.wrappedValue
    return Text(value.isEmpty ? prompt : value)
        .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
}
'''

# ---------------------------------------------------------------------------
# The greeting / status sheet
# ---------------------------------------------------------------------------
# The dashboard's first card. It is a production `View` whose only two hard
# inputs are the Metal sky and the hand-written greeting face, and both have
# shipped still paths:
#
#   * `ImageRenderer` cannot capture an `MTKView`, so the sky goes through
#     `AtmosphereSurface.stills` — the production one-shot path that runs the
#     same shader into an image (the choice `render-greeting-preview.py` makes);
#   * `GreetingScript` loads its face from the repo's brand resources rather
#     than an app bundle.
#
# Everything else the sheet needs is a value type or a store stand-in, so the
# dashboard's top card is the real one — not a placeholder.
for _atmosphere in ('SkyScene', 'AtmosphereShader', 'AtmosphereRenderer', 'AtmosphereView', 'GreetingScript'):
    source += (root / f'Sources/ClaudeBar/Views/Shared/Atmosphere/{_atmosphere}.swift').read_text() + '\n'
source += require_file('Sources/ClaudeBar/Views/Shared/WeatherBackdrop.swift')
source += require('Sources/ClaudeBar/Utils/WeatherForecastFetcher.swift', 'struct WeatherDay: Equatable, Identifiable {')
source += require_file('Sources/ClaudeBar/Views/Shared/WeatherReadingSky.swift')
source += require_file('Sources/ClaudeBar/Utils/GreetingPhrase.swift')
source += require('Sources/ClaudeBar/Utils/WeatherFetcher.swift', 'struct WeatherReading: Equatable {')
# `SkyAstronomy` comes in with the rest of the value types below; it is only
# named here so the sheet's `WeatherBackdrop` has its sun path.
source += require_file('Sources/ClaudeBar/Views/Shared/GreetingInstruments.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/CodexModelMark.swift')
# `GreetingStatusSheet` is the presentation half of `GreetingCard`; the card
# around it reads six stores, which is the half the fixture does not need.
_greeting = require_file('Sources/ClaudeBar/Views/Shared/GreetingCard.swift')
_greeting = _greeting[_greeting.index('struct GreetingStatusSheet: View {'):]
# The sheet's `@AppStorage` keys are only ever read; the tweak here keeps the
# sky on its automatic mode so the still shows the live reading's weather.
_greeting = _greeting.replace('@State private var metalReady = AtmosphereGPU.shared != nil',
                              '@State private var metalReady = true')
source += _greeting

source += r'''
/// The dashboard's first card: the production `GreetingStatusSheet`, handed the
/// readings the dashboard's own stores would supply.
///
/// The sky is production (`AtmosphereSurface` in its still mode — see `main`),
/// the instruments and the hand-written greeting are production, and the sheet
/// type itself is production. What this stands in for is only the six stores
/// `GreetingCard` reads to fill those arguments: the two model names, today's
/// tokens, the Codex window, the Cursor allowance and the weather reading. The
/// figures match the rest of the fixture, so the card and the session grid below
/// it agree the way they do in the app.
struct FixtureGreetingSheet: View {
    var body: some View {
        GreetingStatusSheet(
            name: "Xiajun Wang",
            ccModel: "deepseek-v4.1-flash",
            ccProvider: "Aibox",
            codexModel: "gpt-6-astra",
            codexProvider: "OpenAI",
            tokens: 12_840_000,
            yesterdayTokens: 9_640_000,
            calls: 286,
            spend: "¥404.70",
            windows: [CodexQuotaWindow(label: "5 小时", usedPercent: 82.0,
                                       resetsAt: Fixture.now.addingTimeInterval(8360))],
            quotaLoading: false, quotaNote: nil,
            cursorPlan: nil, cursorLoading: false,
            cursorNote: "请先在主登录 Cursor，再刷新用量。",
            reading: Fixture.weather,
            city: "广州",
            weatherLoading: false, weatherNote: nil,
            refreshWeather: {}, refreshQuota: {}, refreshCursor: {},
            showModels: {}, showUsage: {})
            .frame(width: 1072)
    }
}
'''


# ---------------------------------------------------------------------------
# Production slices — the drawings themselves
# ---------------------------------------------------------------------------
source += require('Sources/ClaudeBar/Theme/Theme.swift', 'extension Color {')
source += require('Sources/ClaudeBar/Theme/Theme.swift', 'enum Theme {')
# -- Inert stand-ins --------------------------------------------------------
# Every `@ProviderState` / `@EnvironmentObject` the pages read resolves to a
# value built here. The *data* is synthetic; the views are production.
source += r'''
// MARK: - Preferences (inert)

final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    private init() {}
    @Published var isDark = false
    @Published var appearance: AppearanceMode = .light
    @Published var tokenUnitStyle: TokenUnitStyle = .chinese
    @Published var costDisplay: CostDisplay = .split
    @Published var greetingWeatherRendering = true
    @Published var weatherCity = "广州"
    @Published var vpnEnabled = true
    @Published var vpnSystemProxyEnabled = true
    @Published var vpnTunEnabled = false
    @Published var vpnMixedPort = 7890
    @Published var vpnAllowLan = false
    @Published var vpnGuardEnabled = true
    @Published var manualUSDToCNY: Double? = nil
    var whatIf: Void { () }
}

enum AppearanceMode: String { case light, dark }
enum TokenUnitStyle: String { case chinese, metric
    var label: String { self == .chinese ? "万 / 亿" : "K / M / B" } }

// MARK: - Environment

struct SurfaceKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var surfaceIsVisible: Bool {
        get { self[SurfaceKey.self] }
        set { self[SurfaceKey.self] = newValue }
    }
}
struct ProviderSourceKey: EnvironmentKey { static let defaultValue: ProviderStore? = nil }
extension EnvironmentValues {
    var providerSource: ProviderStore? {
        get { self[ProviderSourceKey.self] }
        set { self[ProviderSourceKey.self] = newValue }
    }
}

// MARK: - Scroll gates
//
// `PageScrollActivity` and its environment key are **not** stubbed here: the
// greeting sheet's sky (`AtmosphereView.swift`, sliced with the atmosphere
// above) declares both, and a second copy is a redeclaration. Nothing else in
// the fixture reads them.

// MARK: - Sampler / monitors (static readings)

final class ProcessSampler {
    static let shared = ProcessSampler()
    enum MonitorScope: Hashable { case popup, dashboard, sessions }
    enum Key: Hashable {
        case pid(Int), cursor, cwd(String)
        static func standardizedCwd(_ path: String) -> Key { .cwd(path) }
    }
    enum Family: String { case claudeBar, claude, cursor, codex
        var label: String { rawValue } }
    struct Snapshot: Equatable {
        var cpu: Double = 0
        var memoryBytes: UInt64 = 0
    }
    struct CellLoad: Equatable { var cores: [Double] = []; var gpuRenderers: [Double] = [] }
    struct Point: Equatable { var cpu: Double; var gpu: Double; var mem: Double }
    struct Share: Equatable, Identifiable {
        var id: String; var label: String; var memoryBytes: UInt64
        var cpuShare: Double; var memShare: Double
    }
    struct HostStats: Equatable {
        var cpu: Double = 0
        var gpu: Double = 0
        var memoryUsed: UInt64 = 0
        var memoryTotal: UInt64 = 0
        var coreCount: Int = 1
        var memoryActive: UInt64 = 0
        var memoryWired: UInt64 = 0
        var memoryCompressed: UInt64 = 0
        var cpuTemperatureCelsius: Double?
        var gpuTemperatureCelsius: Double?
        var memoryPressureLevel: Int = 0
        var diskUsed: UInt64 = 0
        var diskTotal: UInt64 = 1
        var wifiOn: Bool = false
        var wifiName: String = ""
        var wifiRSSI: Int = 0
        var bluetoothOn: Bool = false
        var wiredOn: Bool = false
        var batteryPercent: Int = 0
        var batteryInstalled: Bool = false
        var batteryCharging: Bool = false
        var batteryExternalPower: Bool = false
        var batteryChargingWatts: Double?
        var powerInputWatts: Double?
        var powerSystemWatts: Double?
        var powerBatteryWatts: Double?
        var powerIsEstimated = false
        var adapterRatedWatts: Int?
        var diskPercent: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) * 100 : 0 }
        var diskLabel: String { "412.6 GB / 512.0 GB" }
        var memoryLabel: String { "13.4 GB / 16.0 GB" }
        func temperatureLabel(celsius: Double?) -> String? {
            guard let celsius, celsius > 0 else { return nil }
            return String(format: "%.0f°C", celsius.rounded())
        }
        /// The stub carries fixed readings, so the line is spelled out rather
        /// than assembled from them; production's own `summaryLine` sits in the
        /// struct the fixture replaces.
        var summaryLine: String { "本机  CPU 18%  GPU 7%  13.4 GB / 16.0 GB" }
        var memoryWells: [Double] { memoryTotal > 0 ? [0.42, 0.28, 0.12] : [] }
        var diskWells: [Double] { diskTotal > 0 ? [0.81, 0.19] : [] }
    }
    var host = HostStats()
    var cells = CellLoad()
    var byKey: [Key: Snapshot] = [:]
    var shares: [Share] = []
    var trail: [Point] = []
    func start() {}
    func stop() {}
    func setScope(_ scope: MonitorScope, active: Bool) {}
    func setLive(_ on: Bool) {}
    func setAgentPIDs(_ pids: [Int]) {}
}

final class FanMonitor {
    @MainActor static let shared = FanMonitor()
    var fans: [FanInfo] = [
        FanInfo(id: 0, name: "左侧", rpm: 1463, minRPM: 1200, maxRPM: 6800, mode: .automatic),
        FanInfo(id: 1, name: "右侧", rpm: 1580, minRPM: 1200, maxRPM: 6800, mode: .automatic),
    ]
    var smcAvailable = true
    var lastError: String?
    var helperInstalled = true
    func start() {}
    func stop() {}
    func refresh() {}
    func setAutomatic(_ fanID: Int) {}
    func setManual(_ fanID: Int, rpm: Int) {}
    func setMaxSpeed(_ fanID: Int) {}
    func resetAllToAutomatic() {}
    /// Mirrors `FanMonitor.toggleMode(of:)` in the app, so the fixture's fan
    /// tile drives the same shape the production one does.
    func toggleMode(of fan: FanInfo) {
        if fan.mode.isAutomatic { setMaxSpeed(fan.id) }
        else { setAutomatic(fan.id) }
    }
    /// Mirrors the fleet-wide pair the tile and the KPI chip both read.
    var allAtMax: Bool {
        guard !fans.isEmpty else { return false }
        return fans.allSatisfy { !$0.mode.isAutomatic }
    }
    func setAllMax(_ max: Bool) {}
}

struct FanMode: Equatable {
    var isAutomatic: Bool { true }
    var label: String { "自动" }
    static let automatic = FanMode()
}
struct FanInfo: Identifiable, Equatable {
    let id: Int
    var name: String
    var rpm: Int
    var minRPM: Int
    var maxRPM: Int
    var mode: FanMode
}

// The left/right parse the fan tile's caption reads now lives with its owner
// (`FanInfo.side` in `SMCController.swift`); the stand-in below mirrors it.
enum FanSide {
    case left, right
}

extension FanInfo {
    var side: FanSide? {
        if name.localizedCaseInsensitiveContains("left") || name.contains("左") { return .left }
        if name.localizedCaseInsensitiveContains("right") || name.contains("右") { return .right }
        return nil
    }
}

final class AudioAccessoryMonitor {
    @MainActor static let shared = AudioAccessoryMonitor()
    struct Reading: Equatable { var percent: Int; var charging: Bool? }
    struct Accessory: Identifiable, Equatable {
        var id: String
        var name: String
        var category: String = ""
        var combined: Reading?
        var left: Reading?
        var right: Reading?
        var caseLevel: Reading?
        var observedAt: Date = Date()
        var source: Source = .bluetoothLog
        var nameIsCaseName = false
        enum Source: String { case bluetoothLog, batteryCenter, profiler, audioRoute }
        enum Connection: Equatable { case inUse, nearby, absent
            var label: String { self == .inUse ? "已连接" : (self == .nearby ? "未连接" : "已离开") } }
        var headline: Int? { left?.percent }
        var isCharging: Bool? { nil }
        var isStale: Bool { false }
        var connection: Connection = .inUse
        var hasAnyReading: Bool { false }
    }
    var accessories: [Accessory] = []
    var unavailableReason: String?
    func start() {}
    func stop() {}
}

final class UIWakePolicy {
    static var hasVisibleWindow = true
    static var hasVisibleMainWindow = true
}


'''.lstrip('\n')

# -- Stores -----------------------------------------------------------------
source += r'''
// MARK: - Provider store (synthetic)

final class ProviderStore: ObservableObject {
    struct NavigationRequest: Equatable { let id: Int }
    struct ExternalSessionNode: Identifiable {
        var id: String { session.id }
        let session: ExternalSessionInfo
        let depth: Int
        let children: [ExternalSessionNode]
        let flattened: [ExternalSessionInfo]
        let activeDescendantCount: Int
        init(session: ExternalSessionInfo, depth: Int, children: [ExternalSessionNode]) {
            self.session = session
            self.depth = depth
            self.children = children
            self.flattened = [session] + children.flatMap(\.flattened)
            self.activeDescendantCount = children.reduce(0) { $0 + $1.activeDescendantCount + ($1.session.isActive ? 1 : 0) }
        }
        var descendantCount: Int { flattened.count - 1 }
    }

    @Published var sessions: [SessionInfo] = []
    @Published var cursorSessions: [CursorSessionInfo] = []
    @Published var externalSessions: [ExternalSessionInfo] = []
    @Published var expandedSessionPIDs: Set<Int> = []
    @Published var usageStats: [ModelUsage] = []
    @Published var usageDays: [DayUsage] = []
    @Published var usageBySource: [UsageSource: [ModelUsage]] = [:]
    @Published var usageLoading = false
    @Published var usagePeriod: UsagePeriod = .month
    @Published var usageReferenceDate: Date = Date()
    /// The interval the store has finished publishing. `UsageView` gates its
    /// analytics section on it (`if usagePublishedInterval == interval`), and
    /// the fixture host seeds it in `populate()` — a still has no computation
    /// to wait for, so gating on a nil here would draw the placeholder.
    var usagePublishedInterval: DateInterval?
    @Published var providers: [Provider] = []
    @Published var todayUsage = TodayUsage()
    @Published var usageEstimate = ModelPricing.Estimate()
    @Published var navigationRequest: NavigationRequest?

    var aliveSessions: [SessionInfo] { sessions.filter(\.isAlive) }
    var aliveExternalSessions: [ExternalSessionInfo] { externalSessions.filter(\.isAlive) }
    var busySessionCount: Int { aliveSessions.filter { $0.status == .busy }.count }
    var activeCursorCount: Int { cursorSessions.filter { $0.status == .active }.count }
    var activeExternalCount: Int { externalSessions.filter(\.isActive).count }
    var anyClaudeBusy: Bool { busySessionCount > 0 }
    var anyExternalBusy: Bool { activeExternalCount > 0 }
    var usageTotalBySource: [(source: UsageSource, tokens: Int)] {
        UsageSource.allCases.map { ($0, (usageBySource[$0] ?? []).reduce(0) { $0 + $1.totalTokens }) }
    }
    /// The estimate's per-model lines, keyed as the local inventory reads them
    /// (`UsageModelInventory.rows(costs:)`). Seeded from the fixture estimate so
    /// a rendered cost column cannot disagree with the totals beside it.
    var usageCostLines: [String: ModelPricing.Estimate.Line] = [:]
    /// The session cards' 清理 action. This still never presses it; the member
    /// has to exist for `SessionsPanel` to compile against the stand-in.
    func cleanUpExternalSession(_ session: ExternalSessionInfo) {}
    var totalUsageTokens: Int { usageStats.reduce(0) { $0 + $1.totalTokens } }
    var totalUsageLabel: String { UsageStats.formatTokens(totalUsageTokens) }
    var maxUsageTokens: Int { max(usageStats.first?.totalTokens ?? 1, 1) }
    func externalSessionTree(kind: ExternalAgentKind) -> [ExternalSessionNode] { externalTree[kind] ?? [] }
    func costLine(for model: String) -> ModelPricing.Estimate.Line? {
        usageEstimate.lines.first { $0.model == model }
    }
    func requestNavigation(_ request: NavigationRequest) {}
    func clearNavigation(_ request: NavigationRequest) {}
    func refresh() {}
    func refreshUsage(rescan: Bool) {}
    func requestSettlement(force: Bool = false) {}
    var externalTree: [ExternalAgentKind: [ExternalSessionNode]] = [:]
}

final class CodexProviderStore: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var proxyRunning = true
    @Published var usesOfficialAccount = true
    @Published var quotaLoading = false
    @Published var quotaNote: String?
    @Published var quotaWindows: [CodexQuotaWindow] = []
    var configuredModel: String? { "gpt-6-astra" }
    var configuredProviderID: UUID? { nil }
    var activeProvider: Provider? { providers.first }
    var activeProviderID: UUID? { providers.first?.id }
    func resolvedThirdPartyOpenAI() -> Provider? { nil }
    func refreshConfiguredModel() {}
}

struct Provider: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var models: [ModelInfo] = []
    var profileID: String = ""
    var asDisplayProvider: Provider { self }
}
struct ModelInfo: Identifiable, Equatable {
    var id = UUID()
    var name: String
}

struct CodexQuotaWindow: Equatable, Identifiable {
    var id: String { label }
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    var durationMinutes: Int = 0

    var usedText: String {
        let rounded = usedPercent.rounded()
        if abs(usedPercent - rounded) < 0.05 { return "\(Int(rounded))%" }
        return String(format: "%.1f%%", usedPercent)
    }
    var resetClock: String { "" }
    var resetWait: String { "" }
}

final class ExchangeRate: ObservableObject {
    @MainActor static let shared = ExchangeRate()
    private init() {}
    var usdToCny: Double? { 7.12 }
    var effectiveRate: Double? { 7.12 }
    var providerDate: Date?
    var isFetching = false
    var lastError: String?
    func refreshIfStale() {}
}
'''.lstrip('\n')

source += r'''
// MARK: - VPN (synthetic)

struct VpnProxy: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let type: String
    let server: String
    let port: Int
    var delay: Int?
    var isCurrent: Bool = false
}
struct VpnGroup: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let type: String
    var nodes: [String]
    var current: String
}
struct VpnTrafficSnapshot: Equatable {
    var up: Int64 = 0, down: Int64 = 0, totalUp: Int64 = 0, totalDown: Int64 = 0
    var activeConnections: Int = 0
}
enum VpnFormat {
    static func rate(_ b: Int64) -> String { bytes(b) + "/s" }
    static func bytes(_ b: Int64) -> String {
        String(format: "%6.1f %@", Double(b) / 1_048_576.0, "MB")
    }
    static func compact(_ b: Int64) -> String { String(format: "%6.1f%@", Double(b) / 1_048_576.0, "M") }
    static func connections(_ n: Int) -> String { String(format: "%4d", n) }
}

final class VpnManager: ObservableObject {
    @MainActor static let shared = VpnManager()
    enum State: Equatable { case idle, missingCore, starting, running, failed(String) }
    struct PortConflict: Equatable { var port: Int; var owner: String?; var isOurOwnCore = false }
    @Published var state: State = .running
    @Published var portConflict: PortConflict?
    @Published var proxies: [VpnProxy] = []
    @Published var groups: [VpnGroup] = []
    @Published var coreVersion: String? = "1.19.4"
    @Published var testingNodes: Set<String> = []
    var isRunning: Bool { state == .running }
    static let primaryGroupNames = ["主代理", "GLOBAL", "PROXY"]
    static func conflictMessage(_ conflict: PortConflict) -> String {
        "端口 \(conflict.port) 被占用，内核未启动"
    }
    var primaryGroup: VpnGroup? { groups.first }
    var livePath: [String] { ["主代理", "香港 · HKG-01"] }
    var liveLeafName: String? { "香港 · HKG-01" }
    var activeNodeName: String? { liveLeafName }
    var mixedPortIfRunning: Int? { 7890 }
    func resolvedDelay(_ name: String?) -> Int? { 42 }
    func testGroupDelay(group: String) async {}
    func testDelay(node: String) async -> Int? { 42 }
    func selectNode(group: String, node: String) async -> Bool { true }
    func reloadConfig() {}
    func syncRuntime() {}
    func retryStart() {}
    func log(_ line: String) {}
    static func isPortFree(_ port: Int) -> Bool { true }
    var isPortFree: Bool { true }
}

final class VpnSubscriptionStore: ObservableObject {
    @MainActor static let shared = VpnSubscriptionStore()
    @Published var subscriptions: [VpnSubscription] = []
    @Published var activeID: UUID? = nil
    @Published var browsingID: UUID? = nil
    @Published var errorMessage: String?
    @Published var isUpdating = false
    func queryAll() async {}
    func removeSubscription(_ id: UUID) {}
    func previewAsync(for id: UUID) async -> VpnProfilePreview { VpnProfilePreview() }

    func addSubscription(name: String, url: String) {}
    func rename(_ id: UUID, name: String) {}
    func refresh(_ id: UUID) async -> Bool { true }
    func replaceURL(_ id: UUID, url: String) async -> Bool { true }
    func queryInfo(_ id: UUID) async -> Bool { true }
    func copyURL(_ id: UUID) {}
    func browse(_ id: UUID) { browsingID = id }
    func setActive(_ id: UUID) { activeID = id }
}

struct VpnSubscription: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 = 0
    var expires: Date?
    var lastUpdated: Date?
    var nodeCount: Int = 0
    var homeURL: String?
    var usedBytes: Int64 { upload + download }
    var remainingBytes: Int64 { max(0, total - usedBytes) }
    var usedRatio: Double { total > 0 ? min(1, Double(usedBytes) / Double(total)) : 0 }
}

struct VpnProfilePreview: Equatable {
    struct Group: Identifiable, Equatable { var id: String { name }; var name: String; var nodes: [String] }
    var groups: [Group] = []
    var proxyNames: [String] = []
}

final class VpnLiveRates: ObservableObject {
    @MainActor static let shared = VpnLiveRates()
    var speedHistory: [(down: Int64, up: Int64)] = []
    var speedDown: Int64 = 3_140_000
    var speedUp: Int64 = 412_000
    var traffic = VpnTrafficSnapshot(up: 0, down: 0, totalUp: 4_820_000_000, totalDown: 31_600_000_000, activeConnections: 128)
}

final class VpnNetProbe: ObservableObject {
    @MainActor static let shared = VpnNetProbe()
    struct IPInfo: Equatable { var ip = ""; var country = ""; var countryCode = ""; var region = ""; var city = ""; var isp = ""; var asn = 0 }
    @Published var sites: [VpnSiteProbe] = []
    @Published var ipInfo: IPInfo?
    @Published var ipError: String?
    @Published var ipLoading = false
    @Published var testingAll = false
    func testAll() async {}
    func test(id: String) async {}
    func refreshIP(afterNodeSwitch: Bool = false) async {}
    func reset() {}
}
struct VpnSiteProbe: Identifiable, Equatable {
    let id: String
    let name: String
    let url: String
    var delay: Int?
}

final class VpnLogStore: ObservableObject {
    @MainActor static let shared = VpnLogStore()
    var lines: [String] = []
}

final class VpnDomainLog: ObservableObject {
    @MainActor static let shared = VpnDomainLog()
    /// The real ring's bound, quoted so the retention caption on the log page
    /// reads the same number the app writes.
    static let limit = 10_000
    @Published var connections: [VpnDomainConnection] = []
    @Published var entries: [VpnDomainEntry] = []
    @Published var received = 0
    @Published var revision = 0
    func clear() {}
}
'''.lstrip('\n')
# The per-domain rollup the log page's summary lists. Static and pure in the app
# too — which is why the regression suite drives it without a main actor — so
# the real body is grafted onto this stand-in rather than stubbed: the summary
# rows the still draws cannot drift from the ones the app computes.
_domain_stat = require('Sources/ClaudeBar/Utils/VpnDomainLog.swift', 'nonisolated static func stat(')
source += 'extension VpnDomainLog {\n' \
    + _domain_stat.replace('nonisolated static func', 'static func', 1) + '}\n'

source += r'''
// MARK: - Session title helpers used by the tiles

''' .lstrip('\n')

# The energy card, whole — Sankey plus `BatteryChargeControls`, since the fixture
# host has a battery (see `populate`).
_power = require_file('Sources/ClaudeBar/Views/Shared/PowerFlowCard.swift')
# The Sankey's travelling highlight is a Core Animation gradient masked to each
# ribbon (`SankeyWaveLayer: NSViewRepresentable`) — the placeholder in a still,
# and the card is otherwise finished. The fixture draws the *same* band: same
# ribbon mask, same destination hue, same soft stops, at a frozen phase instead
# of one sliding along `position.x`. A still can only hold one phase of a sweep,
# so nothing is lost but the motion.
_power = _power.replace(
    """                SankeyWaveLayer(waves: waves(layout), animating: animating,
                                travel: (layout.ribbonLeft, layout.ribbonRight),
                                pace: pace, dark: scheme == .dark)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)""",
    """                FixtureSankeyWaves(waves: waves(layout),
                                   travel: (layout.ribbonLeft, layout.ribbonRight),
                                   dark: scheme == .dark)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)""")
assert 'SankeyWaveLayer(waves:' not in _power, 'PowerFlowCard.swift: the Sankey layer survived'
source += _power
source += '''
/// The Sankey's ribbon highlight, drawn as SwiftUI instead of a `CALayer`
/// gradient (see the fixture note where `PowerFlowCard.swift` is sliced).
///
/// Same geometry as the layer it replaces: each band is masked to its ribbon's
/// `CGPath`, filled with the destination node's hue through the same
/// `[0.02, 0.05, 0.16, 0.05]` (dark) / `[0.01, 0.03, 0.11, 0.03]` (light)
/// opacity ramp, repeating over a `wavePeriod`-long stride. The phase is fixed
/// at the start of a pass — the live version animates `position.x` across one
/// period, which is the one thing a snapshot cannot carry.
private struct FixturePathShape: Shape {
    let path: CGPath
    func path(in rect: CGRect) -> Path { Path(path) }
}

private struct FixtureSankeyWaves: View {
    let waves: [SankeyWave]
    let travel: (from: CGFloat, to: CGFloat)
    let dark: Bool

    private var opacity: [Double] { dark ? [0.02, 0.05, 0.16, 0.05] : [0.01, 0.03, 0.11, 0.03] }

    var body: some View {
        let period = max(240, min(480, (travel.to - travel.from) * 0.65))
        ForEach(Array(waves.enumerated()), id: \.element.id) { index, wave in
            let color = PowerFlow.color(wave.destination)
            let stops = (0..<16).map { step in
                Gradient.Stop(color: color.opacity(opacity[step % opacity.count]),
                              location: Double(step) / 15.0)
            }
            let offset = CGFloat(index) * period * 0.37
            LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
                .frame(width: period * 2)
                .offset(x: offset - period * 0.5)
                .mask(FixturePathShape(path: wave.path))
        }
    }
}
'''.strip('\n') + '\n\n'

source += require_file('Sources/ClaudeBar/Utils/VpnSystemProxyController.swift')




# The pages themselves.
_dashboard = page_without_scroll('Sources/ClaudeBar/Views/Pages/DashboardView.swift', 'DashboardView')
# The page opens with `GreetingCard`, which reads six live stores and starts a
# weather poll. The sheet underneath it is the same production view with the
# same production sky — see the greeting block above — so the fixture calls
# `GreetingStatusSheet` directly with the readings the dashboard's stores would
# have handed it. Only the store *plumbing* is replaced.
_dashboard = _dashboard.replace(
    'GreetingCard(onNavigate: onNavigate)', 'FixtureGreetingSheet()')
assert 'FixtureGreetingSheet()' in _dashboard, 'DashboardView.swift: GreetingCard call moved'
source += _dashboard
_sessions = page_without_scroll('Sources/ClaudeBar/Views/Pages/SessionsView.swift', 'SessionsView')
source += _sessions
source += page_without_scroll('Sources/ClaudeBar/Views/Pages/UsageView.swift', 'UsageView')
_vpn = page_without_scroll('Sources/ClaudeBar/Views/Pages/VPNView.swift', 'VPNView')
_vpn, _n = rewrite_text_fields(_vpn, 'VPNView.swift')
assert _n == 1, f'VPNView.swift: expected 1 TextField, rewrote {_n}'
assert 'TextField(' not in _vpn, 'VPNView.swift: a TextField survived the rewrite'
# Two scroll views live *inside* the page (the page-level one is already gone
# above): the compact-page picker's owns and the log console's. The horizontal
# strips that used to sit here moved into `VpnDomainLogSection` with the traffic
# workspace; this count is what catches a container being added back.
_vpn = unwrap_scroll_views(_vpn, 'VPNView.swift', 2)
# `ScrollViewReader { proxy in … }` unwraps to the same content minus the
# reader: the proxy only ever drove `.scrollTo` (which a still never needs) and
# any remaining call to it is dropped with the reader.
_vpn = unwrap_scroll_readers(_vpn, 'VPNView.swift')
# The node mosaic and the log list both start collapsed (`nodesOpen` / `logsOpen`
# are per-visit `@State`, and `onAppear` — which the renderer never runs — is the
# only thing that ever flips them). That leaves the page's whole point, the node
# list with its latencies, behind a "展开" row. The fixture seeds them open, so
# the PNG shows what a user sees after one click.
_vpn = inject_member(_vpn, 'VPNView', '    var body: some View {',
    '''    /// Fixture-only: the two disclosures the page starts with closed.
    init(fixtureNodesOpen: Bool = true, fixtureLogsOpen: Bool = true) {
        _nodesOpen = State(initialValue: fixtureNodesOpen)
        _logsOpen = State(initialValue: fixtureLogsOpen)
    }

''', 'VPNView.swift')
# This page's body is `GeometryReader { ScrollView([.horizontal, .vertical]) { … } }`
# rather than the other pages' `ScrollView { LazyVStack { … } }`. `ImageRenderer`
# needs a concrete height, so the fixture replaces the *GeometryReader* with a
# fixed-width container — the vertical `ScrollView` inside it then lays out
# normally against that width. Same helper as the pages above; see its docstring.
source += _vpn
_domainlog = require_file('Sources/ClaudeBar/Views/Pages/VpnDomainLogSection.swift')
_domainlog = unwrap_scroll_views(_domainlog, 'VpnDomainLogSection.swift', 4)
_domainlog = unwrap_scroll_readers(_domainlog, 'VpnDomainLogSection.swift')
source += _domainlog
_sub, _n = rewrite_text_fields(require_file('Sources/ClaudeBar/Views/Pages/VPNSubscriptionSection.swift'),
                               'VPNSubscriptionSection.swift')
assert _n == 2, f'VPNSubscriptionSection.swift: expected 2 TextFields, rewrote {_n}'
assert 'TextField(' not in _sub, 'VPNSubscriptionSection.swift: a TextField survived the rewrite'
source += _sub
_traffic = require_file('Sources/ClaudeBar/Views/Pages/TrafficView.swift')
_traffic, _n = rewrite_text_fields(_traffic, 'TrafficView.swift')
assert _n >= 1, f'TrafficView.swift: expected at least 1 TextField, rewrote {_n}'
assert 'TextField(' not in _traffic, 'TrafficView.swift: a TextField survived the rewrite'
# The request list and the conversation body are both `ScrollView { LazyVStack }`
# pairs nested in the page (the page itself is not one). The list is what makes
# the traffic page readable, so both are unwrapped; the `LazyVStack`s inside
# collapse to plain stacks on their own at a fixed height.
_traffic = unwrap_scroll_views(_traffic, 'TrafficView.swift', 3)
# A `Group` is only as tall as its content, so the list pane — `Spacer`-terminated,
# and pinned to the top by the scroll viewport it used to hold — needs that axis
# back. The fixture restores the fill at the two call sites and drops the
# scroll-only modifiers that came with the container.
_traffic = _traffic.replace(SCROLL_LIST_TAIL, SCROLL_LIST_FILL)
assert '.scrollHoverGate()' not in _traffic, 'TrafficView.swift: a scrollHoverGate survived'
# The conversation body used to be the flexible child of a `VStack`, so its
# content sat at the top under the search well; a same-sized `Group` is centred
# by the stack instead. Pin it back to the top.
_traffic = _traffic.replace(CONVERSATION_TAIL, CONVERSATION_TOP)
assert CONVERSATION_TOP.strip() in _traffic, 'TrafficView.swift: the conversation body lost its top alignment'
assert '.frame(maxHeight: .infinity, alignment: .top)' in _traffic, \
    'TrafficView.swift: the row list lost its fill'
# Seed the list cache the page would otherwise fill in `onAppear`. See
# `inject_member` for why a still needs this and why nothing else does.
_traffic = inject_member(
    _traffic, 'TrafficView', '    /// Filtering is O(rows × 3 `lowercased()`)',
    '''    /// Fixture-only: the rows the page's own `onAppear` pass would compute.
    ///
    /// `ImageRenderer` never calls `onAppear`, so the fixture takes the page's
    /// published state and its records and fills both cached values here.
    init(fixtureRecords: [CaptureSummary]) {
        _filteredCache = State(initialValue: fixtureRecords)
        _recordsStamp = State(initialValue: Self.stamp(fixtureRecords))
    }

''', 'TrafficView.swift')
# The raw pane's frame dump is an `NSTextView` bridge — `ImageRenderer` draws it
# as the "unsupported" placeholder and it is only reachable from the 原始 tab,
# which is not the tab this fixture selects.
_traffic = _traffic.replace('PlainDumpView(text: text)', 'Text(text).font(Theme.Font.captionMono)')
assert 'PlainDumpView(' not in _traffic, 'TrafficView.swift: PlainDumpView survived the rewrite'
# A still has no live capture lifecycle. Read the immutable seeded detail and
# blocks directly; mounting/onChange must not replace them with an empty result
# from the inert capture store. The production conversation drawing is unchanged.
assert 'get { state.displayBlocks }' in _traffic
_traffic = _traffic.replace('get { state.displayBlocks }', 'get { Fixture.trafficBlocks }')
_traffic = _traffic.replace('get { state.detail }', 'get { Fixture.trafficDetail() }')
source += _traffic
source += require_file('Sources/ClaudeBar/Views/Pages/CursorTokenUsageCard.swift')

# `AppPage` is declared in the stand-in preamble (a whole-file slice of
# `MainWindowView.swift` would drag the shell in with it). `docs/design/05` §9
# pins the nine destinations, and `Tests/ui-regressions.py` guards the labels.


# The whole theme tail: `PanelCardModifier` → `PageTitle` are contiguous, and
# one slice keeps their private helpers (`PillMark`, `GlyphWell`'s ring, the
# `panelCard()` extension) inside the cut — exactly the trick
# `render-control-preview.py` uses.
source += after('Sources/ClaudeBar/Theme/Theme.swift', 'struct PanelCardModifier: ViewModifier {')

source += require_file('Sources/ClaudeBar/Utils/SessionTitle.swift')
source += require_file('Sources/ClaudeBar/Utils/UsageStats.swift')
# The build's own identity (`FilePaths` reads `BuildChannel.appName` and
# `allowsSystemIntegration`). It is compiled into the probe as the dev channel,
# exactly as in the greeting fixture: `-D CLAUDEBAR_DEV`, no `CLAUDEBAR_RELEASE`.
source += require_file('Sources/Shared/BuildChannel.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/VPNSurface.swift')
source += require('Sources/ClaudeBar/Utils/FilePaths.swift', 'enum FilePaths {')
source += require_file('Sources/ClaudeBar/Utils/ModelPricing.swift')
source += require_file('Sources/ClaudeBar/Utils/ModelPriceTable.swift')
source += require('Sources/ClaudeBar/Utils/SkyAstronomy.swift', 'enum SkyAstronomy {') \
    if 'enum SkyAstronomy {' in (root / 'Sources/ClaudeBar/Utils/SkyAstronomy.swift').read_text() else ''
source += require_file('Sources/ClaudeBar/Models/ModelUsage.swift')
# The usage report: the analysis is pure arithmetic over the seeded days, and
# the section is the page's own drawing — both are sliced whole. The report's
# cross-source attribution reads `UsageIndex`, whose real body opens the
# rollup database; the stand-in below answers with the fixture's own codex rows.
source += require_file('Sources/ClaudeBar/Utils/UsageAnalysis.swift')
source += require_file('Sources/ClaudeBar/Utils/UsageModelInventory.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/UsageAnalytics.swift')
source += '''
/// Stand-in for the rollup reader. The real `fetchOfficialCodex` opens the
/// store database; the preview's attribution card only needs the same rows the
/// fixture already seeded, so it returns those instead of querying disk.
enum UsageIndex {
    static func fetchOfficialCodex(in interval: DateInterval) -> [ModelUsage] {
        Fixture.store.usageBySource[.codex] ?? []
    }
}
'''
source += require('Sources/ClaudeBar/Utils/SessionMonitor.swift', 'struct SessionInfo: Identifiable, Equatable {')
source += require('Sources/ClaudeBar/Utils/SessionMonitor.swift', 'enum SessionStatus: String {')
source += require('Sources/ClaudeBar/Utils/SessionMonitor.swift', 'enum SubagentStatus: String {')
source += require('Sources/ClaudeBar/Utils/SessionMonitor.swift', 'struct SubagentInfo: Identifiable, Equatable {')
source += require('Sources/ClaudeBar/Utils/SessionMonitor.swift', 'struct WorkflowInfo: Identifiable, Equatable {')
source += require('Sources/ClaudeBar/Utils/CursorSessionMonitor.swift', 'struct CursorSessionInfo: Identifiable, Equatable {')
source += require('Sources/ClaudeBar/Utils/CursorSessionMonitor.swift', 'enum CursorStatus: String {')
source += require('Sources/ClaudeBar/Utils/CursorSessionMonitor.swift', 'struct CursorSubagentInfo: Identifiable, Equatable {')
source += require('Sources/ClaudeBar/Utils/CursorSessionMonitor.swift', 'enum CursorSubagentStatus: String, Equatable {')
source += require('Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift', 'struct ExternalSessionInfo: Identifiable, Equatable {')
source += require('Sources/ClaudeBar/Utils/ExternalSessionMonitor.swift', 'enum ExternalAgentKind: String, CaseIterable {')

# The VPN domain log's value types + the watchlist are pure (no socket, no
# store): slice them so the traffic-log rows cannot drift.
source += require('Sources/ClaudeBar/Utils/VpnDomainLog.swift', 'enum VpnDomainRoute: String, CaseIterable, Identifiable {')
source += require('Sources/ClaudeBar/Utils/VpnDomainLog.swift', 'struct VpnDomainEntry: Identifiable, Equatable {')
source += require('Sources/ClaudeBar/Utils/VpnDomainLog.swift', 'struct VpnDomainConnection: Identifiable, Equatable {')
source += require('Sources/ClaudeBar/Utils/VpnDomainLog.swift', 'struct VpnDomainLogStat: Identifiable, Equatable {')
source += require_file('Sources/ClaudeBar/Utils/VpnDomainQuery.swift')
source += require('Sources/ClaudeBar/Utils/VpnDomainLog.swift', 'enum VpnWatchlist {')
source += require_file('Sources/ClaudeBar/Utils/CaptureTranscript.swift')
# The capture store's own value types, sliced whole (the store itself is a
# fixture stand-in: its real `init` opens SQLite).
source += require('Sources/ClaudeBar/Utils/ProxyCaptureStore.swift', 'enum CaptureKind: String {')
source += require('Sources/ClaudeBar/Utils/ProxyCaptureStore.swift', 'enum CaptureSource: String {')
source += require('Sources/ClaudeBar/Utils/ProxyCaptureStore.swift', 'enum CaptureState: String {')
source += require('Sources/ClaudeBar/Utils/ProxyCaptureStore.swift', 'struct CaptureLive: Equatable {')
source += require('Sources/ClaudeBar/Utils/ProxyCaptureStore.swift', 'struct CaptureSummary: Identifiable, Equatable {')
source += require('Sources/ClaudeBar/Utils/ProxyCaptureStore.swift', 'extension CaptureSummary {')
source += '''
final class CaptureCatalog: ObservableObject { @Published var records: [CaptureSummary] = [] }
final class CaptureLivePreview: ObservableObject { @Published var map: [Int64: String] = [:] }
final class CaptureStreams: ObservableObject { @Published var live: [Int64: CaptureLive] = [:] }

final class ProxyCaptureStore {
    static let shared = ProxyCaptureStore()
    let catalog = CaptureCatalog()
    let streams = CaptureStreams()
    let previews = CaptureLivePreview()
    var detail: CaptureDetail?
    func loadListIfNeeded(force: Bool = false) {}
    func clearAll() {}
    func interrupt(_ id: Int64) {}
    func detail(id: Int64?, includeRaw: Bool, includePayloads: Bool, includeTools: Bool) -> CaptureDetail? { detail }
}
'''
source += require_file('Sources/ClaudeBar/Utils/StreamAssembler.swift')
_fetcher = require_file('Sources/ClaudeBar/Utils/CursorUsageFetcher.swift')
_fetcher = _fetcher.replace('CursorDB.readCredentials()', 'nil as CursorCredentials?')
source += _fetcher
source += require('Sources/ClaudeBar/Utils/CursorDB.swift', 'struct CursorCredentials: Equatable {')
source += require_file('Sources/ClaudeBar/Utils/CaptureMedia.swift')
source += require('Sources/ClaudeBar/Utils/ProxyCaptureStore.swift', 'struct CaptureDetail: Equatable {')
source += require_file('Sources/ClaudeBar/Views/Shared/Interaction.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/ProductBrandMark.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/GlassCard.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/SignatureGlyph.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/InstrumentGlyph.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/LucideHardwareGeometry.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/LucideHardwarePaths.swift')
_rotor = require_file('Sources/ClaudeBar/Views/Shared/LucideRotor.swift')
# `ImageRenderer` snapshots an `NSViewRepresentable` as the "unsupported"
# placeholder, so the fixture drops the Core Animation rotor layer and draws
# the same `fanblades.fill` glyph as a `View`. Same symbol, same tint, same
# frame — only the spin is missing, which a still cannot show anyway.
# The rotor artwork is a bundled PNG; a slice with no app bundle would draw the
# symbol fallback instead, so the fixture points `FanArtwork` at the repo copy.
_rotor = _rotor.replace(
    'Bundle.main.url(forResource: "macbook-internals-illustration", withExtension: "png")',
    'Optional(URL(fileURLWithPath: fanArtworkPath))')
_rotor = _rotor.replace(
    'RotorLayer(tint: NSColor(tint), degreesPerSecond: degreesPerSecond, artwork: artwork)',
    'FixtureRotorGlyph(artwork: artwork, tint: tint)')
assert 'FixtureRotorGlyph' in _rotor, 'LucideRotor body moved — update the renderer'
source += _rotor
source += '''
/// The rotor's artwork, drawn as a `View` instead of a `CALayer`.
///
/// The production rotor puts its bitmap (or the `fanblades.fill` symbol when
/// there is none) into a `CALayer`'s `contents` and spins it with Core
/// Animation. A still has no spin to show, so the same artwork is drawn as a
/// SwiftUI `Image` — same frame, same aspect, same tint.
struct FixtureRotorGlyph: View {
    var artwork: CGImage?
    let tint: Color
    var body: some View {
        if let artwork {
            Image(decorative: artwork, scale: 2)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "fanblades.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
        }
    }
}
'''
source += require_file('Sources/ClaudeBar/Views/Shared/HardwareIllustration.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/UiverseKit.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/UiverseSurfaces.swift')
_tile = require_file('Sources/ClaudeBar/Views/Shared/Tile.swift')
# Every tile hangs its drop shadow off a Core Animation layer
# (`LayerShadow: NSViewRepresentable`) so SwiftUI's display-list pass does not
# re-run it once per cycle. `ImageRenderer` draws an `NSViewRepresentable` as
# the "unsupported" placeholder, so the fixture keeps the tile surface — base
# fill, wash, depth lens, inner ring, hairline — and drops only the shadow
# layer. A still cannot show a `CALayer` shadow's cost-driven design anyway.
_tile = _tile.replace('''                .background {
                    LayerShadow(radius: hovered ? 9 : 5,
                                y: hovered ? 4 : 1,
                                opacity: hovered ? 0.07 : 0.04,
                                cornerRadius: radius,
                                surface: Theme.cardSurface)
                }''', '')
assert 'LayerShadow(radius: hovered' not in _tile, 'TileSurface shadow moved — update the renderer'
source += _tile
_widgets = require_file('Sources/ClaudeBar/Views/Shared/InstrumentWidgets.swift')
# `CompactFanPair` is the fan tile: two 64pt rotors, each inside a
# `Button { … }.buttonStyle(.borderless)`. `ImageRenderer` draws *any*
# `.borderless` button as the AppKit "unsupported" placeholder — verified in
# isolation, and not a property of the label, since the same button with a plain
# `Text` label is a placeholder too. `.plain` is the substitute, not nothing:
# both styles draw the label with no chrome, so the tile reads as it does live,
# while the default style would add a grey macOS button plate behind each rotor.
# Only the press/rollover feedback is gone, and a still shows none of it.
_widgets = _widgets.replace('.buttonStyle(.borderless)', '.buttonStyle(.plain)')
assert '.borderless' not in _widgets, 'InstrumentWidgets.swift: a borderless button survived'
source += _widgets
source += require_file('Sources/ClaudeBar/Views/Shared/DecorativeMotion.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/SectionHeader.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/ContextBar.swift')
_controls = require_file('Sources/ClaudeBar/Views/Shared/InstrumentControls.swift')
# Destructive buttons have the same AppKit shadow bridge as TileSurface.
# Keep the actual control plate and label, omit only its animated shadow.
# The destructive plate's shadow is one shared view now
# (`DestructivePlateShadow`), so a still render empties that one type instead of
# rewriting a copy of its six literals — the literals live in exactly one place
# in the app, and the renderer no longer has to track them.
_shadow_struct = '''struct DestructivePlateShadow: View {
    var hovered: Bool
    var pressed: Bool
    var height: CGFloat

    var body: some View {
        LayerShadow(radius: pressed ? 1 : (hovered ? 6 : 3),
                    y: pressed ? 0 : (hovered ? 3 : 1.5),
                    opacity: hovered ? 0.20 : 0.13,
                    cornerRadius: height / 2,
                    surface: .clear,
                    color: .black)
    }
}'''
assert _shadow_struct in _controls, 'ActionButton shadow moved — update renderer'
_controls = _controls.replace(_shadow_struct, '''struct DestructivePlateShadow: View {
    var hovered: Bool
    var pressed: Bool
    var height: CGFloat
    var body: some View { Color.clear }
}''')
source += _controls
_search = require_file('Sources/ClaudeBar/Views/Shared/InstrumentSearchField.swift')
_search, _n = rewrite_text_fields(_search, 'InstrumentSearchField.swift')
assert _n == 1, f'InstrumentSearchField.swift: expected 1 TextField, rewrote {_n}'
assert 'TextField(' not in _search, 'InstrumentSearchField.swift: a TextField survived the rewrite'
source += _search
source += require('Sources/ClaudeBar/Views/Shared/HeartbeatSparkline.swift', 'struct HeartbeatSparkline: View {')
source += require_file('Sources/ClaudeBar/Views/Shared/SessionStatusViews.swift')
# The Codex 清理 dialog both session surfaces attach; the renderer owns neither
# page's copy, so the shared modifier comes in with the cards.
source += require_file('Sources/ClaudeBar/Views/Shared/CodexCleanupDialog.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/SessionCardView.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/AgentSwarmView.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/SourceRing.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/UsageModelCard.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/UsageViz.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/UsageHeatmap.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/ConnectionCard.swift')
source += require_file('Sources/ClaudeBar/Views/Shared/StandbyEmptyState.swift')

# The `@ProviderState` wrapper resolves through the environment (see its own
# crash note). A page built directly in a fixture has no environment at the
# *call* site, so the wrapper gains an explicit-store initialiser — the same
# value the live mount injects through `\.providerSource`.
source += '''
@propertyWrapper struct ProviderState: DynamicProperty {
    private let fields: ProviderFields
    private var explicitStore: ProviderStore?
    init(_ fields: ProviderFields, store: ProviderStore? = nil) {
        self.fields = fields
        self.explicitStore = store
    }
    var wrappedValue: ProviderStore { explicitStore ?? Fixture.store }
    var projectedValue: StoreBindings<ProviderStore> { StoreBindings(store: wrappedValue) }
    mutating func update() {}
}
struct ProviderFields: OptionSet {
    let rawValue: Int
    static let usage = ProviderFields(rawValue: 1 << 0)
    static let configuration = ProviderFields(rawValue: 1 << 1)
    static let sessions = ProviderFields(rawValue: 1 << 2)
    static let heartbeats = ProviderFields(rawValue: 1 << 3)
    static let expansion = ProviderFields(rawValue: 1 << 4)
}
@dynamicMemberLookup struct StoreBindings<Store: AnyObject> {
    let store: Store
    subscript<Value>(dynamicMember path: ReferenceWritableKeyPath<Store, Value>) -> Binding<Value> {
        Binding(get: { store[keyPath: path] }, set: { store[keyPath: path] = $0 })
    }
}
'''

# Hardware marks live in the detail panel; the strip's tiles draw them.
# `ProcessSampler.Snapshot`'s own labels (`memoryLabel` / `loadLabel`) — pure
# formatting, sliced from the sampler so the strip's captions cannot drift.
source += require('Sources/ClaudeBar/Utils/ProcessSampler.swift', 'extension ProcessSampler.Snapshot {')

source += require('Sources/ClaudeBar/Views/Shared/HardwareDetailPanel.swift', 'enum HardwareIdentity {')
source += require('Sources/ClaudeBar/Views/Shared/HardwareDetailPanel.swift', 'struct HardwareSiliconMark: View {')
source += require('Sources/ClaudeBar/Views/Shared/HardwareDetailPanel.swift', 'struct CapacityHardwareMark: View {')
# The tile's signal mark shares the ruler's unfilled-cell ink
# (`ConnectionSignalScale.emptyCell`), and the panel itself is not in this
# fixture — only `ConnectionCard` is — so the declaration is sliced here.
source += require('Sources/ClaudeBar/Views/Shared/HardwareDetailPanel.swift', 'struct ConnectionSignalScale: View {')
source += require_file('Sources/ClaudeBar/Utils/CursorLedger.swift')

# The detail panels the strip's tiles open. Their bodies are page-scale and
# none is ever mounted in a render (the popover `if` is pinned false), so the
# fixture takes inert stand-ins rather than dragging the hardware-popover tree
# in behind a closed popover.
source += '''
struct BatteryChargeControls: View { var body: some View { EmptyView() } }
struct HardwareDetailPanel: View { var gpu: Bool; var body: some View { EmptyView() } }
struct MemoryDetailPanel: View { var body: some View { EmptyView() } }
struct DiskUsagePanel: View { var body: some View { EmptyView() } }
struct FanInternalsPanel: View { var body: some View { EmptyView() } }
struct ConnectionDetailPanel: View { var body: some View { EmptyView() } }
'''



# The resource strip: drop the five popovers (they rebuild the same mark at
# hero size and are never open in a render) by wrapping the tile's closure body
# in a dead `if false` arm.
_strip = require_file('Sources/ClaudeBar/Views/Shared/ResourceStrip.swift')
# The tile's `switch kind` lists its cases directly now, so the wrapper is
# placed by brace-matching rather than by a `if kind == .cpu` literal: the
# popovers' views are still *compiled* (the panels are stubbed above) but never
# mounted.
_anchor = '        return Group {\n            switch kind {\n'
_pos = _strip.index(_anchor)
_open = _strip.index('{', _pos)
_depth, _end = 1, _open + 1
while _depth:
    _depth += (_strip[_end] == '{') - (_strip[_end] == '}')
    _end += 1
_strip = (_strip[:_open + 1] + '\n            if false { EmptyView() } else {'
          + _strip[_open + 1:_end - 1] + '}' + _strip[_end - 1:])
assert 'if false { EmptyView() } else {' in _strip, 'ResourceStrip popover block moved — update the renderer'
source += _strip

# ---------------------------------------------------------------------------
# Fixtures + `main`
# ---------------------------------------------------------------------------
source += r'''
// MARK: - Fixtures

@MainActor enum Fixture {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-29

    /// The weather the greeting sheet draws: a clear 29 °C Guangzhou afternoon,
    /// the reading the fixture's own 2026-09-29 date implies.
    static var weather: WeatherReading = {
        var reading = WeatherReading(
            place: "广州 · 天河区", temperatureC: 29, feelsLikeC: 32,
            conditionCode: 113, conditionText: "晴", highC: 32, lowC: 25,
            humidity: 68, windKph: 8, windDirection: "东南", isDay: true,
            sunrise: "06:18", sunset: "18:22", rainChance: 20,
            observedAt: now, latitude: 23.13, longitude: 113.26,
            timezone: "Asia/Shanghai", source: "Open-Meteo")
        let day = Calendar.current.startOfDay(for: now)
        reading.forecast = (0..<6).map { offset in
            let date = Calendar.current.date(byAdding: .day, value: offset, to: day) ?? day
            return WeatherDay(date: date, code: offset == 2 ? 176 : 113,
                              high: 32 - Double(offset), low: 25 - Double(offset) / 2,
                              rainChance: offset == 2 ? 70 : 20)
        }
        return reading
    }()

    static let store = ProviderStore()
    static let codexStore = CodexProviderStore()

    static func claudeSessions() -> [SessionInfo] {
        let specs: [(Int, String, String, String, String, SessionStatus, Int, Int, Int, String)] = [
            (90124, "9f3a12", "/Users/x/Project/ClaudeBar", "把概览页的资源条换成宫格", "168K / 200K", .busy, 168_000, 200_000, 41, "Edit · ResourceStrip.swift"),
            (90188, "b7c240", "/Users/x/Project/aisle-mcp", "修一下 SSE 断流后的重连", "92K / 200K", .busy, 92_000, 200_000, 27, "Bash · swift test"),
            (90233, "4d1e77", "/Users/x/Project/agentscope", "给 subagent 加一个超时", "44K / 200K", .idle, 44_000, 200_000, 12, "Read · runner.py"),
        ]
        return specs.map { pid, sid, cwd, prompt, _, status, tokens, limit, msgs, activity in
            SessionInfo(pid: pid, sessionId: sid, cwd: cwd, startedAt: 1_789_990_000_000,
                        name: (cwd as NSString).lastPathComponent,
                        status: status, updatedAt: 1_789_999_400_000, isAlive: true,
                        contextTokens: tokens, contextLimit: limit, model: "claude-opus-5-5",
                        messageCount: msgs, currentActivity: activity, firstPrompt: prompt)
        }
    }

    static func cursorSessions() -> [CursorSessionInfo] {
        [
            CursorSessionInfo(composerId: "c-1", name: "cm cloud concurrency",
                              cwd: "/Users/x/Project/cmcc_skills",
                              lastUpdatedAt: 1_789_999_200_000, contextPercent: 68, status: .active,
                              isAlive: true,
                              currentActivity: "Edit · organize.py", title: "CM cloud organize concurrency",
                              subtitle: "Edited organize.py, schema.sql"),
            CursorSessionInfo(composerId: "c-2", name: "promo-film scrub",
                              cwd: "/Users/x/Project/ClaudeBar",
                              lastUpdatedAt: 1_789_996_000_000, contextPercent: 24, status: .idle,
                              isAlive: true,
                              currentActivity: "Read · prompt.md", title: "宣传片运镜 scrub",
                              subtitle: "Edited film.html"),
        ]
    }

    static func codexSession(id: String, cwd: String, title: String, active: Bool,
                             nickname: String = "", parent: String? = nil,
                             tokens: Int = 0, limit: Int = 0) -> ExternalSessionInfo {
        ExternalSessionInfo(kind: .codex, sessionId: id, cwd: cwd, startedAt: 1_789_990_000_000,
                            updatedAt: 1_789_999_000_000, model: "gpt-6-astra", isAlive: true,
                            isActive: active, contextTokens: tokens, contextLimit: limit,
                            parentThreadId: parent, threadSource: parent == nil ? "user" : "subagent",
                            agentNickname: nickname, holderPID: 51_200, title: title)
    }

    static func codexRoot() -> ProviderStore.ExternalSessionNode {
        let kids = [("Darwin", true), ("Curie", true), ("Hopper", false), ("Turing", true),
                    ("Lovelace", false), ("Ramanujan", true), ("Faraday", true), ("Mendel", false)]
            .map { codexSession(id: "a-\($0.0)", cwd: "/Users/x/Project/ClaudeBar",
                                title: $0.0, active: $0.1, nickname: $0.0, parent: "root",
                                tokens: 18_000, limit: 200_000) }
        let root = codexSession(id: "root", cwd: "/Users/x/Project/ClaudeBar",
                                title: "把 popup 的会话卡做成一格", active: true,
                                tokens: 138_000, limit: 200_000)
        return ProviderStore.ExternalSessionNode(session: root, depth: 0,
            children: kids.enumerated().map {
                ProviderStore.ExternalSessionNode(session: $0.element, depth: 1, children: [])
            })
    }

    static func usageModels() -> [ModelUsage] {
        [
            ModelUsage(model: "claude-opus-5-5", calls: 412, inputTokens: 1_240_000,
                       outputTokens: 386_000, cacheReadTokens: 8_420_000, cacheCreationTokens: 620_000),
            ModelUsage(model: "gpt-6-astra", calls: 286, inputTokens: 0,
                       outputTokens: 41_000, cacheReadTokens: 179_000, cacheCreationTokens: 0),
            ModelUsage(model: "glm-5.3-flash", calls: 1_284, inputTokens: 3_800_000,
                       outputTokens: 640_000, cacheReadTokens: 21_400_000, cacheCreationTokens: 1_100_000),
            ModelUsage(model: "deepseek-v4.1-flash", calls: 508, inputTokens: 940_000,
                       outputTokens: 224_000, cacheReadTokens: 5_260_000, cacheCreationTokens: 380_000),
            ModelUsage(model: "qwen3.8-max", calls: 96, inputTokens: 260_000,
                       outputTokens: 88_000, cacheReadTokens: 0, cacheCreationTokens: 0),
        ]
    }

    static func usageDays(days: Int) -> [DayUsage] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        return (0..<days).map { offset in
            let date = cal.date(byAdding: .day, value: -(days - 1 - offset), to: start) ?? start
            let wave = 0.35 + 0.65 * abs(sin(Double(offset) * 0.7))
            let total = Int(wave * 4_200_000)
            return DayUsage(day: UsageHeatmap.dayKey(date), inputTokens: total / 6,
                            outputTokens: total / 12, cacheReadTokens: total / 2,
                            cacheCreationTokens: total / 4)
        }
    }

    static func vpnNodes() -> [String] {
        ["香港 · HKG-01", "香港 · HKG-02", "日本 · NRT-01", "日本 · NRT-02", "新加坡 · SIN-01",
         "新加坡 · SIN-02", "台湾 · TPE-01", "韩国 · ICN-01", "美国 · LAX-01", "美国 · SJC-02",
         "德国 · FRA-01", "英国 · LHR-01"]
    }

    static func vpnProxies(_ names: [String]) -> [VpnProxy] {
        names.enumerated().map { index, name in
            VpnProxy(name: name, type: "ss", server: "203.0.113.\(index + 11)", port: 443,
                     delay: index == 0 ? 42 : 38 + index * 27, isCurrent: index == 0)
        }
    }

    static var trafficTurns: [CaptureTranscript.Turn] {
        [CaptureTranscript.Turn(role: "user", text: "把概览页的资源条换成宫格，风扇瓦片保留调速。"),
         CaptureTranscript.Turn(role: "tool", text: "读取 Sources/ClaudeBar/Views/Shared/ResourceStrip.swift", name: "Read"),
         CaptureTranscript.Turn(role: "assistant", text: "资源条包含 CPU、GPU、内存、硬盘、网络和风扇。将沿用现有控件，保留风扇的调速入口，并在概览中展示能源流向。")]
    }
    static var trafficBlocks: [ConvBlock] {
        ConversationBuilder.build(ConversationInput(
            id: 1, history: trafficTurns, live: nil, response: nil,
            headers: nil, full: false, streaming: false, query: ""))
    }

    static func trafficDetail() -> CaptureDetail {
        let rec = trafficRecords()[0]
        let response = """
        {"content":[{"type":"text","text":"概览页的资源条已经换成宫格：\n\n1. CPU / GPU / 内存 / 硬盘 / 连接 / 风扇 六格等宽；\n2. 风扇瓦片保留点击调速，其余区域打开详情面板；\n3. 能源流向卡在资源条下方，用 SMC 实时读数。"}]}

"""
        let request = """
        {"model":"claude-opus-5-5","max_tokens":4096,"system":"You are Claude Code.","messages":[{"role":"user","content":"把概览页的资源条换成宫格，风扇瓦片保留调速。"}]}

"""
        return CaptureDetail(summary: rec,
            requestJSON: request, rewrittenJSON: request,
            responseJSON: response, rawSSE: "",
            requestHeadersJSON: "{\"user-agent\":\"claude-cli/2.0.0\",\"accept\":\"text/event-stream\"}",
            turns: trafficTurns, toolCalls: [CaptureTranscript.ToolCall(
                id: "demo-read", name: "Read", arguments: "ResourceStrip.swift",
                output: "CPU / GPU / 内存 / 硬盘 / 网络 / 风扇")])
    }

    static func trafficRecords() -> [CaptureSummary] {
        let cal = Calendar.current
        func at(_ hour: Int, _ minute: Int) -> Date {
            cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        }
        return [
            CaptureSummary(id: 1, startedAt: at(18, 23), endedAt: at(18, 23),
                           kind: .anthropic, source: .claude, providerName: "Aibox",
                           model: "claude-opus-5-5", path: "/v1/messages", isStream: true,
                           state: .done, httpStatus: 200, promptTokens: 179_000,
                           completionTokens: 41, cacheReadTokens: 179_000, cacheWriteTokens: 0,
                           preview: "把概览页的资源条换成宫格，风扇瓦片保留调速"),
            CaptureSummary(id: 2, startedAt: at(18, 21), endedAt: at(18, 21),
                           kind: .openaiResponses, source: .codex, providerName: "OpenAI",
                           model: "gpt-6-astra", path: "/responses", isStream: true,
                           state: .done, httpStatus: 200, promptTokens: 12_400,
                           completionTokens: 210, cacheReadTokens: 0, cacheWriteTokens: 0,
                           preview: "hello"),
            CaptureSummary(id: 3, startedAt: at(18, 19), endedAt: at(18, 19),
                           kind: .openaiChat, source: .other, providerName: "Aibox",
                           model: "glm-5.3-flash", path: "/chat/completions", isStream: false,
                           state: .done, httpStatus: 200, promptTokens: 3_800,
                           completionTokens: 96, cacheReadTokens: 0, cacheWriteTokens: 0,
                           preview: "把这段 JSON 整理成 markdown 表格"),
        ]
    }
}
'''.lstrip('\n')

source += r'''
// MARK: - Probe

@main struct Probe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        // The dashboard's top card is the Metal sky. `ImageRenderer` cannot
        // capture an `MTKView`, so the sheet runs the production still path:
        // the same shader, drawn once into an image. Without a Metal device the
        // render is impossible, so this fails loudly rather than quietly
        // dropping the card (which would still look plausible).
        guard AtmosphereGPU.loadNow() != nil else { fatalError("Metal atmosphere unavailable") }
        AtmosphereSurface.stills = true
        GreetingScript.resourceRoot = URL(fileURLWithPath: greetingScripts)
        ProductBrandMark.resourceRoot = URL(fileURLWithPath: brandMarks)
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        populate()

        for dark in [false, true] {
            AppPreferences.shared.isDark = dark
            AppPreferences.shared.appearance = dark ? .dark : .light
            let scheme: ColorScheme = dark ? .dark : .light
            for (rawName, page) in pages() {
            let name = rawName
                let content = page
                    .environment(\.colorScheme, scheme)
                    .environment(\.surfaceIsVisible, true)
                    // The hardware mark's Core Animation sweep is an
                    // `NSViewRepresentable`; `ImageRenderer` would replace it
                    // with the "unsupported" placeholder. The production
                    // fixture flag turns those layers off and leaves the canvas
                    // drawing — the same choice `render-greeting-preview.py`
                    // makes for the metal atmosphere.
                    .environment(\.rendersHardwareSweep, false)
                    .environment(\.providerSource, Fixture.store)
                    .environmentObject(Fixture.codexStore)
                    .frame(width: pageWidth, alignment: .topLeading)
                    .background(Theme.bgPrimary)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                else { fatalError("Render failed for \(name)") }
                try png.write(to: out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                print("\(name)-\(dark ? "dark" : "light")  \(Int(image.width))×\(Int(image.height))")
            }
        }
    }

    /// Synthetic data for every store the pages read. Nothing here touches a
    /// real account file or the network.
    @MainActor static func populate() {
        let store = Fixture.store
        store.sessions = Fixture.claudeSessions()
        store.cursorSessions = Fixture.cursorSessions()
        store.externalSessions = Fixture.codexRoot().flattened
        store.externalTree = [.codex: [Fixture.codexRoot()]]

        let models = Fixture.usageModels()
        store.usageStats = models
        store.usageDays = Fixture.usageDays(days: 30)
        store.usageBySource = [
            .claude: models.filter { $0.model.hasPrefix("claude") },
            .codex: models.filter { $0.model.hasPrefix("gpt") },
            .thirdParty: models.filter { !$0.model.hasPrefix("claude") && !$0.model.hasPrefix("gpt") },
        ]
        store.usageEstimate = ModelPricing.estimate(models)
        store.usageCostLines = Dictionary(uniqueKeysWithValues: store.usageEstimate.lines.map { ($0.model, $0) })
        store.usagePublishedInterval = UsageStats.interval(for: store.usagePeriod,
                                                          reference: store.usageReferenceDate)
        store.providers = [
            Provider(name: "Aibox", models: [ModelInfo(name: "claude-opus-5-5"), ModelInfo(name: "glm-5.3-flash")], profileID: "aibox"),
            Provider(name: "OpenAI", models: [ModelInfo(name: "gpt-6-astra")], profileID: "openai"),
        ]
        store.todayUsage = TodayUsage(tokens: 12_840_000, calls: 286, yesterdayTokens: 9_640_000,
                                      cost: ModelPricing.estimate(models))

        Fixture.codexStore.providers = [Provider(name: "OpenAI", models: [ModelInfo(name: "gpt-6-astra")], profileID: "openai")]
        Fixture.codexStore.quotaWindows = [CodexQuotaWindow(label: "5 小时", usedPercent: 82, resetsAt: Fixture.now.addingTimeInterval(8360))]

        // Hardware readings — the strip's own numbers.
        var host = ProcessSampler.HostStats()
        host.cpu = 47; host.gpu = 35; host.coreCount = 12
        host.memoryUsed = 13_400_000_000; host.memoryTotal = 16_000_000_000
        host.memoryActive = 6_700_000_000; host.memoryWired = 4_400_000_000; host.memoryCompressed = 1_900_000_000
        host.diskUsed = 443_000_000_000; host.diskTotal = 512_000_000_000
        host.cpuTemperatureCelsius = 58; host.gpuTemperatureCelsius = 51
        host.wifiOn = true; host.wiredOn = false; host.wifiName = "CMCC-5G"; host.wifiRSSI = -47
        // A Mac with a battery: `PowerFlowCard` draws nothing at all without one
        // (`if host.batteryInstalled { … }` has no `else`), and the Sankey is one
        // of the four blocks the overview is about. The readings below put the
        // card in its `charging` topology — adapter covering the load and topping
        // the battery up — which is the one with all three nodes on screen.
        host.batteryInstalled = true
        host.batteryPercent = 82
        host.batteryExternalPower = true
        host.powerInputWatts = 96.4
        host.powerSystemWatts = 61.8
        host.powerBatteryWatts = 34.6
        host.adapterRatedWatts = 96
        ProcessSampler.shared.host = host
        var cells = ProcessSampler.CellLoad()
        cells.cores = (0..<12).map { 0.10 + Double(($0 * 37) % 60) / 100 }
        cells.gpuRenderers = (0..<10).map { 20 + Double(($0 * 29) % 55) }
        ProcessSampler.shared.cells = cells
        ProcessSampler.shared.shares = [
            ProcessSampler.Share(id: "claude", label: "CC", memoryBytes: 1_200_000_000, cpuShare: 0.31, memShare: 0.08),
            ProcessSampler.Share(id: "codex", label: "Codex", memoryBytes: 640_000_000, cpuShare: 0.12, memShare: 0.04),
        ]

        // VPN — a running core with a measured node list.
        let manager = VpnManager.shared
        let names = Fixture.vpnNodes()
        manager.proxies = Fixture.vpnProxies(names)
        manager.groups = [VpnGroup(name: "主代理", type: "Selector", nodes: names, current: names[0]),
                          VpnGroup(name: "♻️ 自动选择", type: "URLTest", nodes: Array(names.prefix(6)), current: names[2])]
        var history: [(down: Int64, up: Int64)] = []
        for i in 0..<60 {
            let down: Int64 = 1_200_000 + Int64(900_000 * abs(sin(Double(i) / 7)))
            let up: Int64 = 200_000 + Int64(260_000 * abs(cos(Double(i) / 11)))
            history.append((down: down, up: up))
        }
        VpnLiveRates.shared.speedHistory = history
        VpnNetProbe.shared.sites = [
            VpnSiteProbe(id: "apple", name: "Apple", url: "", delay: 38),
            VpnSiteProbe(id: "github", name: "GitHub", url: "", delay: 96),
            VpnSiteProbe(id: "google", name: "Google", url: "", delay: 142),
            VpnSiteProbe(id: "youtube", name: "YouTube", url: "", delay: 118),
            VpnSiteProbe(id: "chatgpt", name: "ChatGPT", url: "", delay: 164),
            VpnSiteProbe(id: "claude", name: "Claude", url: "", delay: 152),
            VpnSiteProbe(id: "gemini", name: "Gemini", url: "", delay: 171),
        ]
        VpnNetProbe.shared.ipInfo = .init(ip: "203.0.113.24", country: "日本", countryCode: "JP",
                                          region: "Tokyo", city: "东京", isp: "NTT Communications", asn: 4713)
        let sub = VpnSubscription(name: "Aibox · Premium", url: "https://example.invalid/sub",
                                  upload: 61_000_000_000, download: 214_000_000_000,
                                  total: 500_000_000_000,
                                  expires: Fixture.now.addingTimeInterval(24 * 86400),
                                  lastUpdated: Fixture.now, nodeCount: names.count,
                                  homeURL: "https://example.invalid")
        VpnSubscriptionStore.shared.subscriptions = [sub]
        VpnSubscriptionStore.shared.activeID = sub.id
        VpnSubscriptionStore.shared.browsingID = sub.id
        VpnLogStore.shared.lines = ["[2026-09-29 18:23:04] core started, version 1.19.4",
                                    "[2026-09-29 18:23:05] mixed-port listening on 127.0.0.1:7890",
                                    "[2026-09-29 18:23:07] 主代理 → 香港 · HKG-01  42ms"]

        // Traffic — three captured requests, the first one selected.
        ProxyCaptureStore.shared.catalog.records = Fixture.trafficRecords()
    }

    /// The page width: the default 1120pt window less its 24pt padding. One
    /// value for every page — `fixturePageSize.width` is the same box, and the
    /// name parameter the pages used to pass no longer selected anything.
    @MainActor static let pageWidth: CGFloat = 1120

    @MainActor static let trafficState: TrafficPageState = {
        let state = TrafficPageState()
        state.selectedID = 1
        state.detail = Fixture.trafficDetail()
        state.displayBlocks = ConversationBuilder.build(ConversationInput(
            id: 1,
            history: [CaptureTranscript.Turn(role: "user", text: "把概览页的资源条换成宫格，风扇瓦片保留调速。")],
            live: nil, response: nil, headers: nil,
            full: false, streaming: false, query: ""))
        state.historyCount = 1
        return state
    }()

    /// The five deliverables, in the order the report lists them.
    ///
    /// `overview` takes the dashboard's own navigation closure; `traffic` takes
    /// the seeded record list its `onAppear` would have computed (see
    /// `inject_member`); `vpn` opens the two disclosures the page starts with
    /// closed, so the node mosaic — the thing the page is about — is on screen.
    @MainActor static func pages() -> [(String, AnyView)] {
        return [
            ("overview", AnyView(DashboardView(onNavigate: { _ in })
                .environmentObject(Fixture.codexStore))),
            ("sessions", AnyView(SessionsView())),
            ("usage", AnyView(UsageView())),
            ("vpn", AnyView(VPNView(fixtureNodesOpen: true, fixtureLogsOpen: true)
                .frame(height: 1180))),
            ("traffic", AnyView(TrafficView(fixtureRecords: Fixture.trafficRecords())
                .environmentObject(trafficState)
                .frame(height: 720))),
        ]
    }
}
'''.lstrip('\n')

# ---------------------------------------------------------------------------
path = out / 'Probe.swift'
path.write_text(source)

swiftc = '/usr/bin/swiftc'
subprocess.run([swiftc, '-O', '-parse-as-library', '-D', 'CLAUDEBAR_DEV',
                '-target', 'arm64-apple-macos15.0',
                str(path), '-o', str(out / 'probe')], check=True)
subprocess.run([str(out / 'probe'), str(out)], check=True)
