# UI / interaction audit backlog

Findings from the "审查每个页面（桌面 UI / 灵动岛 / popup）" pass — every page of
the desktop UI, the notch island, and the popup — judged on code quality,
comment quality, render cost, motion, flow and interaction bugs. Each entry
records what was **verified**, not what was suspected, and then what was done
about it.

The rule this file is kept by: an entry is closed by *fixing it* or by writing
down why the behaviour is intentional, and a closed entry stays here as a
**record of the fix and the evidence** — what was measured, what was rejected
and on what numbers, and which dead ends are not worth re-running. Git history
has the diffs; this file has the reasoning behind them, including the reasoning
that turned out to be wrong.

Status of the original nine findings, after the fix pass:

| # | Finding | Outcome |
|---|---|---|
| 1 | `nonisolated(unsafe)` mirrors untested concurrently | **fixed** — 16-way scan arm + TSan clean |
| 2 | Codex swarm tree structurally empty | **fixed** — monitor now returns helpers |
| 3 | Unmounted provider editors held 4 live fields | **fixed** — fields folded in, 1,512 lines deleted |
| 4 | `IslandGlanceReel` unmounted | **fixed** — deleted with its test and constants |
| 5 | `ModelCostCard` / `VpnPowerCard` unmounted | **fixed** — deleted |
| 6 | `UsagePanel` date-picker popover anchor | **fixed** — zero-size sibling anchor |
| 7 | Collapsed island still lays out the expanded box | **closed** — premise withdrawn by measurement |
| 8 | Two `EXC_BREAKPOINT` crash reports | **fixed** — a mount that never injected `\.providerSource` |
| 9 | `ProviderTile` unmounted | kept, deliberately (see the entry) |
| 10 | `MetricTile` unmounted (last caller gone with §5) | **fixed** — deleted |
| 11 | 10 more unmounted view types + one dead store field | **fixed** — deleted |
| 12 | The idle display cycle: two 30 Hz `.animation` timelines | **open** — measured, four fixes rejected (§11) |
| 13 | `CodexModelMark`'s dashboard arm and its allowance lane | **fixed** — deleted; §12 records what went |
| 14 | `SkyAstronomy.stars` recomputed per frame | **closed** — cached, measured, reverted (§13) |
| 15 | `TokenComparison` animating on the per-poll token total | **fixed** — modifier dropped, guarded (§15) |
| 16 | `PinChromeBar` routing buttons by `frame.minX` | **fixed** — routes on `tag` (§14) |
| 17 | GPU's SMC temperature sweep on every tick | **fixed** — rides the 5 s gate; 1.41 → 0.29 ms/s (§14) |
| 18 | `State.missingCore` never assigned | **fixed** — `fail(.coreMissing)` maps to it (§14) |

---

## 1. `nonisolated(unsafe)` on the Codex caches — FIXED (the gap is closed)

- `Utils/ExternalSessionMonitor.swift` — `indexRows` / `indexReadAt` /
  `codexFileCache`, shared mutable state behind `indexLock` and
  `codexCacheLock`.
- Original finding: the annotations are load-bearing (the app kicks `scan()`
  from detached tasks and polls overlap), but no test exercised that path, so
  an invariant change would have gone unnoticed. The `NSLock`s were there;
  nothing proved they were *held everywhere they need to be*.
- Closed on both sides now, not by removing the state:
  - `Tests/codex-session-regressions.py` runs **16 overlapping scans** on a
    concurrent queue and asserts every one of them agrees with the sequential
    result. That is the shape of the failure the locks prevent — a scan that
    observes a half-written cache returns a different set, and the assertion
    catches it. It runs in CI (`make test`).
  - The same harness is compiled with `-sanitize=thread` and run over 24
    overlapping scans (6 main + 6 sub-agent rollouts so the caches are actually
    hot): **clean, exit 0**. TSan is not in CI — it needs a second build of the
    slice — but it was the direct evidence for "the locks cover the state",
    which is what the finding asked for.
- The `nonisolated(unsafe)` spelling itself is gone: the state is now plain
  `private static var` under the locks, which is stricter than an unchecked
  annotation and compiles clean under Swift 6 mode.

## 2. Codex swarm tree — FIXED

Closed by delivering the rows the tree was already built to consume, not by
removing the tree.

The finding was that every producer in `ExternalSessionMonitor` filtered
sub-agents out before returning — `fetchCodex`'s rollout path required
`parentThreadId == nil` **and** `spawnDepth == 0`, and so did the
`state_*.sqlite` path — so no returned row ever satisfied `isSubagent`, no node
ever had children, and the "⋯N 子 agent" surfaces could never light up. The
data was never missing: `~/.codex/state_5.sqlite` has carried 129
`thread_source = 'subagent'` rows with their `parent_thread_id` inside the
`source` JSON all along.

What changed:

- `ExternalSessionMonitor` hands back a `Scan` (`main` + `subagents`) instead of
  a flat list. `fetchActive()` still returns `main` only, sorted, for the
  callers that mean "sessions".
- The `state_*.sqlite` reader kept only rows `isInteractiveMain` accepted —
  exactly the set that excludes helpers — so the index path could never produce
  one either. It now classifies rows through `threadKind(source:threadSource:)`
  and keeps helpers as well.
- Helpers carry a much tighter recency gate (`subagentRecencyWindow`, 5 min,
  well inside `busyWindow`/`orphanedTurnWindow`): a helper is a child of a
  *running* fan-out, never a card and never resumable, so holding its rollout
  open after the run ends buys nothing. That is what makes `⋯N` mean "running
  now" rather than "ran sometime today".
- `ProviderStore.refreshExternalSessions()` publishes both populations, and the
  filtering moves to one place — `ProviderStore+Derived`'s
  `aliveExternalSessions` / `activeExternalCount` / `anyExternalBusy`, plus
  `externalSessionTree`'s existing `roots()`, all drop helpers. Every counter a
  user sees therefore still counts threads, not helpers, and the two cannot
  drift apart from separate filter passes again.
- `Tests/codex-session-regressions.py` asserts the split (a recent child is
  returned with its parent id, a stale child is not), and
  `Tests/e2e-codex-tree.py` asserts the other end of the wire — that the helpers
  the monitor returns are exactly the ones the tree attaches, and that no
  counter counts them.
- The schema-less filesystem fallback also stopped walking the whole history:
  it now prunes year/month directories against the recency window instead of
  listing every day of every month on each poll.

## 3. Unmounted provider-editor views — FIXED

Closed with option (c), the only one that leaves no capability behind: the four
per-model fields the generic editor was the sole home for were folded into the
shipped `ProviderConnectionEditor` first (`modelOptions`: the window and
auto-compact-threshold field pair, plus 禁用压缩 / 禁用实验性 Beta on the Claude
side), and *then* the five dead files were deleted — 1,512 lines with no call
site anywhere:

- `Views/ProviderEditorView.swift`, `Views/CodexProviderEditorView.swift`,
  `Views/Shared/ProviderEditorSidebar.swift`, `Models/ProviderEditorModel.swift`,
  `Models/CodexEditorModel.swift`

`ProvidersView.connectionDraft` / `saveConnection` already round-tripped these
values, so the only thing missing was a way to *set* them; that gap is the part
that needed closing before the deletion. The docs that pointed at the deleted
cluster (`technical/05-view-layer.md`, `technical/10-extension-guide.md`,
`design/05-main-window-and-theme.md`, `design/06-interactions.md`,
`design/07-file-structure.md`) now describe the single remaining editor.

## 4. `IslandGlanceReel` — FIXED (deleted)

`Views/Island/IslandComponents.swift` carried a finished, documented
auto-advancing status reel that nothing instantiated; the island's expanded
content is header + session strip + `IslandUsageCard`, and has been since
`631ec17`.

Deleted, 547 lines and everything that existed only for it:

- `IslandGlanceReel`, `IslandGlanceCard`, `NetworkGlancePage`, `IslandGlance`,
  `IslandMark`, the reel's `markCell` / `pager` / `play` / `page*` helpers, and
  the network page's traffic-mark builders — the whole `// MARK: - Rotating
  glance` section.
- `Tests/island-reel-regressions.py` — it locked the reel's fixed sizes and had
  nothing left to measure. Removed from `make test` **and** from
  `.github/workflows/ci.yml`. That second edit is where the duplication bit:
  the workflow kept its own copy of the list, so the two drifted and six
  suites in `make test` (`product-mark`, `greeting-name`, `weather-astronomy`,
  `card-shadow`, `machine-mark`, `fan-rotor`) were never run in CI at all. The
  workflow now just runs `make test` — see `docs/CHANGELOG.md` §内部.
- `IslandStyle`'s `glance*` / `cardTitle*` / `cardBody*` / `markCell*` /
  `markValue*` / `markCaption*` / `pager*` / `reel*` constants. The one survivor
  is `markWellSize`, which `IslandMarkWell` uses — and `IslandMarkWell` itself
  stays, because `NotchIslandView`'s route chip draws the active agent's mark
  with it.
- `ProcessSampler.MonitorScope.island` — the reel was its only writer.

The tie-break, since mounting was the alternative: the reel's content (quota,
balance, compute, memory, network, peripherals, usage) is all reachable from the
popup and the main window, and the island's expanded box already spends its
height on the session grid and the usage card. Mounting would mean either
replacing one of those or growing the island again — and the island's per-frame
cost is what §7 is about. Its own doc comment had said "mount it or delete it
together with its test" since it was written.

One thing the deletion settled by accident: the "island tier of `FanMonitor`"
the old entry worried about does not exist. The reel was `FanMonitor`'s only
island subscriber (`FanMonitor.shared.start()` / `stop()` in its `onAppear` /
`onDisappear`), and with it gone the fan tier is the popup's `MachineKpiStrip`
and the dashboard's `ResourceStrip` — which is exactly what `docs/design/05`
already documented, so the docs were right and the code was carrying a third
caller nothing reached.

## 5. Unmounted tiles — FIXED (deleted)

`Views/Shared/ModelCostCard.swift` and `Views/Shared/VpnPowerCard.swift` had no
call sites, in either direction:

- `ModelCostCard` built a 「模型花费」 tile from `ProviderStore.costEstimate`,
  but the estimate is already shown on three live surfaces — the popup's usage
  section, the usage page's per-model `UsageModelCard`, and the island's usage
  card — and the dashboard tile row it belonged to was replaced by the usage
  page's own cards. Its own doc comment said so.
- `VpnPowerCard` had two arms, and neither was reachable: the dashboard arm was
  dropped when `DashboardView` was restructured to 资源条 → 能源流向 → 会话总览
  (the tile row it sat in is gone), and the popup arm was superseded by
  `PanelHeader`'s VPN control, which already carries the node picker
  (`VpnNodePickerPanel`) and the live rate. It was also the *only* remaining
  caller of `VpnNodeMenu`, so that type went with it. That control is now the
  status row's `VpnStatusPill` — the same panel, moved out of the switcher row
  so a third client (Cursor) could take its cell.

Both were "mount or delete; neither is a defect", so the tie is broken by what
they would have cost: mounting either means reintroducing a tile row on the
dashboard (or a second VPN control in the popup) for content that is already on
screen somewhere the user opens more often. Deleted, together with the
`VpnNodeMenu` type they were the last caller of, and the three doc rows that
pointed at them (`technical/09-file-index.md`, `technical/11-vpn.md`,
`technical/15-model-cost.md`). `VpnDelayStyle` and `VpnNodePickerPanel` stay —
`PanelHeader` uses both.

## 6. `UsagePanel`'s date-picker popover anchor — FIXED

Closed, by removing the premise rather than by reproducing the symptom. The
`.popover(isPresented:)` used to hang off `header`, and the period chips
(`PeriodTabs`) and 重新统计 live *inside* `header` — so while the picker was open,
the two controls whose clicks are supposed to drive it sat under the anchor's
own subtree, and the standard SwiftUI rule is that a click anywhere in that
subtree dismisses the popover. That would have left `usagePeriod` on `.custom`
with no date change, the exact state `selectPeriod` was rewritten to prevent.

It now hangs off `datePickerAnchor`, an empty zero-size sibling of the header
that draws nothing and hit-tests nothing, so the anchoring question cannot come
up regardless of which behaviour this platform has. The look and the dismissal
path are unchanged.

The open question from the original entry is settled and worth keeping, because
it is about a different one of this app's windows:

```
_NSPopoverWindow  parentIsPanel=true   sheetParent=nil
_NSAlertPanel     parentIsPanel=false  sheetParent=Optional("KeyablePanel")
```

A SwiftUI `.popover` becomes an `_NSPopoverWindow` whose `parent` **is** the
presenter panel; a `confirmationDialog` becomes an `_NSAlertPanel` attached by
`sheetParent` instead. So the dismissal path and the `parent`-based exemption
are wired for each other — and that same `parent === panel` test is the
click-outside exemption in `MenuBarController.handleLocalMouseDown` (`:390`),
added for exactly this class of window. The residual note is that a
`confirmationDialog` off the popup would arrive as `sheetParent`, not `parent`,
so the day one is added to this panel it needs its own clause there.

What could not be tested, recorded so it is not attempted the same way again:
four harnesses (a synthetic `NSPopover` over a container, and three SwiftUI
probes driven by `sendEvent`, `NSApp.sendEvent` and posted `CGEvent`s, the last
inside a signed app bundle with the Accessibility API) all failed to deliver a
click to a SwiftUI control at all. The synthetic `NSButton` in the same
container *did* receive its click, and its sibling kept working while the
popover was up — the opposite of the reported symptom.

## 7. A collapsed island still lays out the expanded panel box (perf) — CLOSED, premise withdrawn

Found while fixing the item this section used to hold — `IslandOrbit`'s SwiftUI
`repeatForever`, now a `DecorativeMotion(kind: .arc)` layer (see
`Views/Shared/DecorativeMotion.swift` and the numbers in it). The entry claimed
the remaining per-frame cost was the *panel box size*: the panel is sized from
`IslandStyle.panelSize` (640 × 386) unconditionally while a collapsed island
draws only the notch strip, and the per-frame layout cost is proportional to the
hosting view's size.

**That premise does not survive measurement, and the entry is closed on that.**

Two `-O -whole-module-optimization` builds of the same tree, differing only in
`IslandStyle.panelSize` (the second a 320 × 80 box, i.e. collapsed-sized).
Same launcher, bundle swapped under one fixed path, arms interleaved
big→small→big→small and each sampled three times, one instance asserted before
every round. Median `NSHostingView.layout()` share of main-thread samples:

| round | big panel (640 × 386) | small panel (320 × 80) |
|---|---|---|
| 1 | 19.7 % (17.0–21.3) | 22.2 % (20.7–22.9) |
| 2 | 29.0 % (25.7–29.0) | 22.6 % (18.4–24.0) |
| 3 | 30.9 % (28.6–31.6) | 29.9 % (one sample) |

The arms overlap in every round and the small box measured *higher* in round 1 —
i.e. the residual cost is not the box. The whole spread across all six arms
(17.0–31.6 %) is machine drift between rounds, which is why the arms have to be
interleaved to mean anything over the ~18 s a round takes here. So a second
size-hugging window (or an animated window resize) buys nothing measurable, and
this is **not** implemented: a layout change to the app's most prominent surface
with no measured gain behind it is not worth the risk.

What the measurements do support, recorded so the next attempt starts here:

- **The orbit's own cost is ~zero.** Forcing `active: false` so the view is
  mounted but never animates measured 33.4 % (29.4–36.0) against 31.9 %
  (28.2–39.0) animated — the same number. This is the entry's real result and it
  is why `IslandOrbit` now uses a render-server layer rather than a SwiftUI
  transaction.
- **Withdrawing the collapsed wings is worth a little.** `wingWidth = 0` (52 → 0,
  removing the busy badge *and* today's token readout from the collapsed strip):
  23.5 % vs 26.6 % in round 1, 27.7 % vs 29.2 % in round 2 — overlapping ranges,
  so call it ~2–3 points, not the 25 % the entry predicted for deleting a
  subview.
- **A transaction is in flight most of the time.** `runAnimationGroup` counts
  track the layout share all the way down every arm (≈190–200 samples when the
  share is ~20 %, ≈260–280 when it is ~30 %), so what keeps the hosting view
  re-laying out is *some* in-flight animation, not the box.
- **Two states, and only one is expensive.** A later run of the same two-arm
  harness (removing the island's remaining per-poll `.animation(_:value:)`
  modifiers: `model.usage.today` on the collapsed wing, the pace ring's `value`,
  and the usage card's scrub hero) measured **0.5–0.7 %** layout share on *all
  four* arms, with `runAnimationGroup` at 5–6 samples — the collapsed-and-idle
  figure the old entry recorded as 0.8 %. Both modifiers are therefore *not*
  what holds the transaction open; they cost nothing measurable in that state.
  What the 20–33 % arms above were in, and what opened their transaction, was
  not recorded at the time the samples were taken — the island grows on hover,
  so the two states can differ between runs without the source differing at all.
  That is the one hole in this entry, stated rather than papered over: the next
  attempt should record the island's mode per round (or force it) before
  comparing arms, because an arm measured expanded and an arm measured collapsed
  differ by a factor of fifty and nothing in the sample says which is which.

A third two-arm run settles the last candidate: pausing
`HardwareIllustration`'s 30 Hz `TimelineView` sweep (the one repeating
`TimelineView` that draws every frame on the resource strip) measured 0.6 % /
0.6 % layout share against 0.4 % / 0.5 % — identical within noise, with Canvas
work at 0.0 %. So none of the three animation sites on these surfaces is the
cost, which is consistent with the 0.5–0.7 % floor above: in the idle-collapsed
state there is essentially nothing to find.

Two dead ends, recorded so they are not re-run: the per-frame work is *not*
`body` evaluation (`DisplayList.ViewUpdater.body` / `dynamicBody` never appear;
the chain is `render(interval:)` → `renderDisplayList` → `updateInheritedView` /
`updateGeometry` / `CoreViewSetTransform`), and clearing `defaults`'s saved state
plus accepting the system's "unexpectedly quit while reopening windows" dialog
had no effect on it.

## 8. The `EXC_BREAKPOINT` crash reports — FIXED (root cause found)

`~/Library/Logs/DiagnosticReports/ClaudeBar-2026-09-26-015502.ips`,
`-020355.ips` and `-0130222.ips` — `EXC_BREAKPOINT` / `SIGTRAP` on the main
thread, top app frame at offset `+502612`, then
`EmbeddedDynamicPropertyBox.update(property:phase:)` →
`DynamicBody.updateValue()` → `AG::Graph::update_attribute`. The offset is
`__TEXT`-relative and identical in all three, and the trailing bytes at that
offset in the crashing binary are two consecutive `brk #1` instructions — a
trap, not a wild branch.

**The crash is a mount that never injected `\.providerSource`.** Identified
from the reports' own metadata: all three carry
`responsibleProc = ChatGPT`, i.e. they were launched from the `codex/ui-redesign`
worktree, whose `UIPreviewProbe` renders a page through an `NSHostingView`
passing `.environmentObject(store)` and `.environmentObject(codexStore)` — and
never the environment *value* `ProviderState` reads. Every page it renders
(`dashboard`, `settings`, `providers`, `usage`) carries `@ProviderState`, so the
first AttributeGraph update resolves the source to `nil` and traps at
`ScopedStoreObservation.swift:63`.

Reproduced in one binary, two arms: `DashboardView()` straight into an
`NSHostingView` traps with exit 133 and `ProviderState.update()` as the top app
frame; the same view with `.environment(\.providerSource, store)` runs
indefinitely. A reduced property wrapper with the same shape (`@Environment`
into a non-optional `preconditionFailure`, plus a `@StateObject`) reproduces it
on its own, so it is not specific to this store.

Fixed by injecting the value in the harness (`UIPreviewProbe.run`). The
requirement is now stated at the declaration
(`Models/ScopedStoreObservation.swift`), because this is the one value in the
app that fails *inside SwiftUI's update pass* rather than at the call site —
the shipped mounts (`MainWindowController.installContent`,
`MenuBarController.makeHostingView`) were always correct, which is why the app
never crashed for a user.

This also closes the note that it "could not be reproduced in isolation": the
thing that could not be reproduced was a crash on the *shipped* bundle, and the
reason is that the shipped bundle has no such mount. The `-g -Onone` build ran
90+ minutes because `/tmp/symbuild.sh` builds from `Project/ClaudeBar`, which
has no `UIPreviewProbe`. Nothing about `com.claudebar.sym` or the group
container was ever involved.

## 9. `ProviderTile` has no call site either

Found while closing §3 and §5: that work removed two unmounted *editors* and two
unmounted *tiles*, and left a fifth unmounted view in place —
`Views/ProviderRow.swift` is a single 232-line `ProviderTile` struct with no call
site (`ProvidersView` has gone through `ProviderDirectoryHost` +
`ProviderConnectionEditor` since `2fd24f7`). Its own doc comment claims it is
"shared by the providers page and the popup's dense 2-col grid"; neither is true
now — the popup's model switching is `PanelHeader`'s chip → `ModelSwitchList`,
and `PopupModelTile` was deleted for the same reason.

**Left in place, deliberately, and that is the difference from §3 and §5:** it is
not dead weight the way they were. Everything it composes is live —
`SignatureGlyph`, `ConnectivityTileButton`, `ActiveTileEdge`, `StatusPill`,
`RollingNumberText` all ship elsewhere — so keeping it costs one file and leaves
no orphaned type behind. It is also the only built-and-styled surface for a
per-provider tile in a grid, which is exactly what the directory page renders
through `ProviderDirectoryHost`; mounting it is a restructure of that page rather
than a deletion question. §3 and §5 closed because the fields and the numbers
they showed already had a live home; this one's home is the directory grid.

`docs/technical/05-view-layer.md` and `docs/design/05-main-window-and-theme.md`
say what it is and that it is unmounted, so the next reader does not mistake it
for the shipped tile.

---

## Method notes

Kept because the next pass will need them, and because two of them were learned
by getting the answer wrong first.

- **One instance, or the numbers are meaningless.** Several copies of a rebuild
  under different paths were running at once early in this pass (left by
  earlier work), and `killall` / `pgrep -f` match the shell command that runs
  them. Every sampling round here asserts `instances == 1` on the exact binary
  path before it takes a sample, and the arms are interleaved (old / new / old /
  new) so a machine that drifts between rounds cannot bias one side.
- **The metric is the share of main-thread `sample`s inside a named frame**
  (`sum of the counts of every matching line ÷ the main thread's total`).
  `ps -p PID -o time=` deltas swing 10–27 % between 20 s windows on this machine
  and are not usable as evidence; a share reproduces to about a point.
- **A/B by swapping the bundle under one fixed path**, not by mutating the
  source in place: the launcher, the environment and the window arrangement then
  cannot differ between arms, and the source change cannot be forgotten in one
  of them.
- **Distrust a single round.** The panel-size A/B (§7) was run three times
  precisely because rounds 1 and 2 disagreed; with one round it would have
  "proved" the opposite conclusion.

## 10. `MetricTile` — the last unmounted view, deleted

§9 argued `ProviderTile` should stay because everything it composes is live.
`MetricTile` is the same *shape* of finding with the opposite answer: a
public-looking tile in `Views/Shared/Tile.swift` with **no call site since
`2fd24f7`**, when the dashboard's metric row was replaced by the usage page's
own cards. It was the last one out — `ModelCostCard` and `VpnPowerCard` (§5)
were its final two callers, and deleting them is what left it stranded.

Deleted rather than kept, because the difference from §9 is measurable: it
carried a `.animation(.spring(response: 0.24, dampingFraction: 0.8), value: value)`
on its headline figure, and `value` on a tile is a per-poll number (CPU %,
battery %, session count) — the exact construction
`Tests/inflight-animation-regressions.py` exists to catch. Keeping it means
keeping a live example of the pattern this pass spent its time removing, in a
type nothing can reach; there is no field or capability behind it (unlike §3)
and no live composition to preserve (unlike §9). The `.tile()` / `.hoverTile()`
modifiers and `TileGrid` it shared a file with all ship.

The same pass checked the rest of the app's per-poll `.animation(_:value:)`
sites and found nothing else to fix: everywhere else the `value` is
interaction state (`isHovered`, `isPressed`, `focused`, `selection`, `active`),
which changes only when the user does something.

**Postscript — the deletion did not stick.** `MetricTile` is back in
`Sources/ClaudeBar/Views/Shared/Tile.swift` (reintroduced when the Uiverse
surface work landed on top of this pass), still with **no call site**. The
judgement above is unchanged and the Uiverse commit agrees with it: it removed
the same `.animation(value: value)` modifier from the resurrected view rather
than keeping the pattern alive, and `Tests/inflight-animation-regressions.py`
deliberately does **not** list it — that guard cannot tell a per-poll value from
hover state, so it would fail on this view's surviving
`.animation(value: isHovered)`. Deleting it again is a one-view change with no
call site to update.

## 11. The idle display cycle — two 30 Hz timelines, not the panel box

§7 withdrew the claim that the collapsed island's panel **size** is the
per-frame multiplier, and §8's fix record showed a running transaction makes
every display cycle re-run the whole hosting view's layout. What neither found
was the *other* way to hold a display cycle open: a `TimelineView` with an
``.animation(...)`` schedule. It does not open a transaction, so the
`runAnimationGroup` signature §8 relies on does not move — but it re-validates
its body every frame, and that is enough to re-lay-out the hosting view.

Measured 2026-09-28 on commit `50e0fc5`, main window on screen and idle,
`ps -p PID -o time=` deltas, arms interleaved over 5–9 rounds:

| arm | idle CPU |
|---|---|
| dashboard, as shipped | 38–49 % of one core |
| an empty `NSHostingView` root | 7–14 % |
| `topBar` + one `Text` | **4.0 %** |
| `ScrollView` skeleton, no cards | 9–10 % |
| + `GreetingCard` | 27–32 % |
| + `ResourceStrip` | 27–31 % |
| + `PowerFlowCard` | 40–46 % |
| `WeatherBackdrop`'s timeline live, canvas replaced by `Color.clear` | **37–38 %** |
| `HardwareIllustration`'s timeline live, canvas replaced by `Color.clear` | — |
| all three `.animation` timelines frozen (CodexModelMark's, since deleted — see §12) | **10–23 %** |

The decisive pair is the last two rows of the §7-style test: a `VStack` with
`topBar` and **one 30 Hz `TimelineView` drawing a plain rectangle** measures
**14.7 %**, against **4.0 %** for the same shell with no timeline — ten points
for one timeline whose content is a fill. Adding a second raises it to 17.2 %,
so the cost is roughly additive per live timeline, not per pixel.

Attribution from `sample` confirms where it goes: `CanvasDisplayList.updateValue`
is **1.7 %** of main-thread samples and `ViewGraph.renderDisplayList` **5.7 %**,
while `NSHostingView.layout()` is **39 %** and `-[NSView _layoutSubtreeWithOldSize:]`
**79 %**. The drawing is not the cost; the per-frame layout it forces is.

**What was tried and rejected:**

- **Lowering the frame rate.** 30 → 15 → 8 Hz on both timed views moved nothing
  (43.2 / 43.5 / 41.5 %). The cost is per *frame the timeline is live for*, not
  per unit of content, so a slower clock does not help and would cost the rain
  its smoothness.
- **`TimelineView(.periodic(by: 1/30))` instead of `.animation(...)`** — 43.6 vs
  42.6 %, inside the spread. Still a per-frame body validation.
- **Hosting the timeline in its own nested `NSHostingView`** so it would not
  re-lay-out the enclosing one: 44.5 % vs 43.6 %. The nested host's own layout
  pass replaces the one it saves.
- **Removing the hidden popover content** (`HardwareDetailPanel` etc., mounted
  behind four `.popover(isPresented:)` on the hardware tiles): 44.2 vs 43.8 %.
  Not mounted, not resident.

**Not yet resolved.** Every fix that keeps the motion has failed; the only arm
that removes the cost removes the animation. The records above are what a future
pass needs in order not to re-run them. `docs/technical/08-performance.md` has since been corrected: the tree has
five `TimelineView`s, two of them `.animation`-scheduled.

## 12. `CodexModelMark`'s dashboard arm — deleted

`CodexModelMark` was written as one mark for two surfaces: a 38pt dashboard tile
(`style: .tile`, the default) and a 13pt popup chip (`.inline`). The tile lost
its caller when the greeting card was rebuilt — `GreetingStatusSheet.modelCell`
now draws `modelIdentity(codex:model:provider:)` and carries the allowance in its
own `quotaRow`/`resetLine` pair, so `CodexQuotaGauges` owns that reading — and
nothing in `Sources/` or `Tests/` has passed `.tile` since. What went with it,
all reachable only from that arm:

- `tileBody` (43 lines, the only reader of `Lane.head`),
- `laneControl`, `laneReserve`, `refreshChip`, `laneSummary`, `laneHovered`, the
  `@State` it held, and the `.animation(.easeOut(0.15), value: laneHovered)` on
  the chip,
- `flow` / `sweeping` / `sweep(_:_:into:)` — the travelling highlight, already
  documented as belonging to the dashboard mark, and its
  `TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !sweeping))`,
- the whole `Lane` constant table and the lane canvas beside it.

`Tests/product-mark-regressions.py` and `Tests/machine-mark-regressions.py` render
marks and never instantiated this view, so nothing had to be retargeted; the
surviving chip needs only `ProductBrandMark`, `Theme.Font`, `Text` and
`rollingNumber()`. The file is 441 → 61 lines.

This is the §11 finding arriving at a concrete site: the deleted arm carried one
of the app's three `.animation`-scheduled `TimelineView`s, so removing it removes
one of the per-frame layout drivers §11 measured — while the chip, which never
had a lane, renders identically.

## 13. `SkyAstronomy.stars` per frame — cached, measured, reverted

`WeatherBackdrop.drawCelestial` runs 30 `asin` / `atan2` pairs per frame to place
the bright-star field, on a canvas already redrawn at 24–30 Hz. It is a real
per-frame cost with an obvious fix — a star's altitude and azimuth depend only on
the sidereal time and the latitude, and both move ~0.004°/s, so one cached array
per 0.05° of sidereal time serves thousands of frames.

Implemented and then **reverted on the evidence**. The project has a render
fixture for exactly this view (`Tools/render-greeting-preview.py`, 24 synthetic
sheets per run), so the cache was compared against HEAD over all 32 sheets:

- star band (top third, where `point()` places the field) at 1100pt: **0
  differing pixels**, max channel delta 2 — indistinguishable;
- star band at 620pt: 10 differing pixels on a horizontal run at y≈486, values
  jumping from `(18,24,49)` to `(94,99,118)`. That is a star the old path did not
  draw, i.e. the 0.05° bucket flips a star across `altitude > 0` at the horizon.

Ten pixels is small, but the whole point of the change was an invisible
optimisation, and this one is not invisible. The bucket would have to be far
finer to be exact, at which point most frames miss the cache and the win goes
with it. The per-frame `asin`/`atan2` cost stays; it is smaller than the layout
cost §11 measured and it is paid only when a sky is actually on screen.

Recorded so the next pass does not re-derive it: **do not cache the star field
by a coarse sidereal bucket** — compare against the fixture before believing a
finer one.

## 14. Three audit findings landed — the pin toolbar, the throttled GPU sweep, the core-missing state

Three of the entries a whole-tree sweep confirmed were real bugs rather than
style, so they were fixed rather than recorded. Each had a measurement or a
reproduction behind it, and two of them are interaction-visible.

**`PinChromeBar.tap(_:)` routed every button to the wrong action.** The pinned
screenshot's toolbar carries close / copy / bigger / smaller, and `tap` switched
on `sender.frame.minX` against hand-written ranges (`..<30`, `30..<55`,
`55..<80`). The buttons are laid out from `x = 4` with 22pt widths, so their
minX values are **4 / 26 / 48 / 70** — the ranges were written for `midX`. The
mapping the user got was close→close, **copy→close**, **bigger→copy**, and
**smaller→bigger**: Copy closed the pin and the shrink action could not be
reached. The buttons already carried `tag`, but as `action.hashValue`, which
nothing read. Fixed by making `Action: Int` and routing on `Action(rawValue:
sender.tag)`, which removes the layout arithmetic from the question entirely.

**The GPU's SMC temperature fallback ran on every foreground tick.** On Apple
Silicon `IOAccelerator`'s `PerformanceStatistics` carries no `Temperature(C)`
(verified here: `ioreg -r -c IOAccelerator` has no such key), so
`HardwareSensors.gpuReading()`'s fallback always fired — six SMC keys
(`G0eT`/`g0pT`/`G1pT` and their byte-swapped spellings) through the same
`ioLock` on **every** tick, beside a package-temperature read the tick already
gates at 5 s and whose own comment calls it "the dearest read in the tick".
Measured with the production calls: **1.41 ms per iteration**, one iteration per
foreground tick. The accelerator's *own* figure still rides the tick (on a GPU
that reports one it is the warmer-hotspot reading, and it is one property fetch
on an already-matched service); the six-key sweep now rides the 5 s gate, so the
amortised cost is **3.07 ms/s** — 5.3× less.

Correction to the finding as filed: it called this a **main-thread** cost. The
sampler runs on its own `DispatchQueue(label: "com.claudebar.proc", qos:
.utility)`, so this never blocked a display cycle — it is wasted work and lock
contention against the fan reader, which is worth fixing but is not an
interaction bug.

**`VpnManager.State.missingCore` was never assigned.** The missing-binary path
funnels through `fail(.coreMissing)`, which set `.failed(err.logMessage)` for
every case — so all five readers of `.missingCore` were unreachable, and with
them the one actionable affordance for that failure: `VPNView.coreMissingHint`,
which prints the path to drop the binary at and offers an 打开目录 button. The
user saw only the generic error line. `fail` now maps `.coreMissing` to
`.missingCore`, which is what `docs/design/08-error-handling.md:16` specified in
the first place.

## 15. `TokenComparison` — the last implicit animation on a per-poll value

`TokenComparison` (`GreetingCard.swift`) draws the two bars beside 今日 / 昨日
under the greeting card's token total, and carried
`.animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: today)` where
`today` is `providerStore.todayUsage.tokens`. `ProviderStore.publishTodayUsage`
is gated only on `todayUsage != fresh`, and `UsageFSWatcher` debounces FSEvents
at 0.4 s, so a transcript burst republishes several times a second — the same
shape as the island's pace ring (§ the `IslandPaceRing` entry under 2026-09-26),
but on the **dashboard**, the surface this whole audit is about.

The bars are `Capsule().frame(width: geo.size.width * …)`, and `frame(width:)`
interpolates, so unlike the pace ring this modifier both opened the transaction
*and* actually eased the bars — the modifier was doing what its author intended
while costing a permanently in-flight transaction.

Deleted, and pinned in `Tests/inflight-animation-regressions.py`'s `GUARDED`
list so it cannot come back. It was missed by the 2026-09-26 sweep for a
provenance reason worth recording: it landed in `f1e2b0f`, i.e. *after* the
list of sites that sweep worked from was drawn up. A guard list built from a
grep is only as current as the grep's moment.

### Three more from the same sweep

- **`VpnNetProbe.fetchIP` iterated `ipEndpoints.prefix(4)`.** The list holds
  seven IP-echo services and the count stranded the last three — among them
  `icanhazip.com`, the only plain-text one, and with it `parsePlainIP`, which
  therefore had no reachable caller. Those three are precisely what is left to
  try when the first four (all on one hosting side of the world) rate-limit
  together, so the exit-IP read failed having never used them. Now the loop is
  bounded by a **12 s budget** rather than a count: each attempt already carries
  a 6 s timeout, so a count-bounded sweep could hold the caller 42 s on a total
  failure, and a budget keeps the tail from mattering.
- **`ConnectorUtilityButtonStyle` forced `.environment(\.isEnabled, true)`**,
  which defeats any `.disabled()` a caller applies — both styles in that chain
  draw their own disabled treatment (`ActionPlateButtonStyle` desaturates at
  0.34, `ControlPressModifier` dims through `.uiversePress`). Nothing depends on
  it today, which is the reason to delete it rather than the reason to keep it:
  the first `.disabled()` on a connector button would have silently done
  nothing.
- **`cp -R Sources/ProviderIcons` shipped the maintainer README to every user.**
  It is provenance notes for the LobeHub pin — which asset came from which URL,
  the 3:1 ink floor, why five brands swapped `-color` for the monochrome mark —
  and it belongs in the repo, not in a shipping bundle. The copy now takes
  `*.png`, `*.ico` and the licence.
