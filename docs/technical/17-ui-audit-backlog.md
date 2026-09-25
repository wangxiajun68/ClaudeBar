# UI / interaction audit backlog

Findings from the "审查每个页面（桌面 UI / 灵动岛 / popup）" pass that were
**verified in code but not fixed in that pass**, because each one either changes
visible behaviour beyond a defect fix or needs a decision only the product owner
can make. Every entry records what was verified, not what was suspected.

Rule for closing an entry: fix it, or add a line here saying why it is
intentionally behaviour we keep. Closed entries are deleted, not struck through —
git history holds the reasoning for anything that was fixed.

---

## 1. `nonisolated(unsafe)` on `ExternalSessionInfo` mirrors

- `Utils/ExternalSessionMonitor.swift` — `indexRows` / `codexFileCache`
- These concern the concurrent-poll path the file is written to support. The
  `nonisolated(unsafe)` annotations are load-bearing and correct as written
  today; flagged only because the `codex-session-regressions` test does not
  exercise concurrent `fetchActive()` calls, so an invariant change there would
  not be caught.

## 2. Codex swarm tree is structurally empty (behaviour decision)

- `Models/ProviderStore+Derived.swift:69-93`
- `externalSessionTree` builds `childrenOf` from `externalSessions` rows where
  `isSubagent` — but every producer in `ExternalSessionMonitor` filters sub-agents
  out before returning:
  - `fetchCodex`'s rollout path requires `parsed.parentThreadId == nil` and
    `parsed.spawnDepth == 0` (`:252`);
  - the `state_*.sqlite` path has the same two conditions (`:357`).

  So no returned row ever satisfies `isSubagent`, no node ever has children, and
  the "⋯N 子 agent" / swarm surfaces can never light up. **Verified by reading
  both producer paths**, not inferred.
- Closing this means widening the monitor's fetch set (or adding a separate
  children feed) — a **collection-scope decision**, not a fix: the filters exist
  because a sub-agent rollout is indistinguishable from a main thread once it
  reaches the UI, and `roots()` deliberately drops helpers so an orphaned child
  never becomes a main card. Written up so the empty swarm is not mistaken for a
  rendering bug.

## 3. Unmounted provider-editor views (mount-or-delete decision)

- `Views/ProviderEditorView.swift`, `Views/CodexProviderEditorView.swift`,
  `Views/Shared/ProviderEditorSidebar.swift`, `Models/ProviderEditorModel.swift`,
  `Models/CodexEditorModel.swift` — 1,357 lines with **no call site anywhere**
  (verified by grepping every reference outside their own file cluster; the last
  use was in 2fd24f7).
- The shipped editing surface is `Views/Shared/ProviderConnectionEditor.swift`,
  plus `ProviderQuickSetup` for catalog entries — sheets over the directory
  (`ProvidersView`), each owning its own draft.
- **The part that makes this a real question rather than a cleanup:** those five
  files hold the *only* UI for four per-model fields. `ProviderConnectionEditor`
  renders name / key / URL / model list / (Codex) wire API and reasoning effort,
  and nothing else; verified by grepping every editor for the field names:
  - Claude `contextTokens`, `disableCompact`, `disableExperimentalBetas`
    (`Views/ProviderEditorView.swift:290-300`)
  - Codex `contextWindow`, `autoCompactTokenLimit`
    (`Views/CodexProviderEditorView.swift:303-307`)

  `ProvidersView.connectionDraft` seeds these into the shipped sheet's draft and
  `saveConnection` writes them back, so existing values survive an edit — but a
  user can no longer *set* them, and `docs/technical/10-extension-guide.md:10`
  still tells new fields to go through `ProviderEditorModel`.
- **Needs a decision**, three ways: (a) delete the five files and accept that
  those four fields are bridge-/import-managed only, updating the docs and the
  extension guide; (b) mount them (two editors for one job); or (c) fold the four
  fields into `ProviderConnectionEditor` and then delete them. (c) is the only one
  that leaves no capability behind, and it is also the most work.
- **Docs corrected** in this pass: `docs/technical/05-view-layer.md`,
  `docs/technical/10-extension-guide.md`, `docs/design/05-main-window-and-theme.md`
  and `docs/design/06-interactions.md` now say plainly that this editor has no
  mount point, and `.openProvidersEditor` (a name that no longer exists — the
  destination rides on `.showMainWindow`'s `userInfo`) is gone from all of them.

## 4. `IslandGlanceReel` (mount-or-delete decision)

- `Views/Island/IslandComponents.swift:302-700` — a finished, documented
  auto-advancing status reel that nothing instantiates; the island's expanded
  content is header + session strip + `IslandUsageCard` only.
- It is not one file: mounting or deleting it also decides the fate of
  `NetworkGlancePage`, `IslandGlanceCard`, the `glance*` / `mark*` / `pager*`
  constants in `IslandStyle`, `ProcessSampler.MonitorScope.island`, the island
  tier of `FanMonitor`, and `Tests/island-reel-regressions.py` (which locks the
  reel's fixed sizes and would be deleted with it).
- Written up in-file and in `docs/technical/09-file-index.md` so the dead code is
  not mistaken for an oversight.

## 5. Unmounted tiles

- `Views/Shared/ModelCostCard.swift` and `Views/Shared/VpnPowerCard.swift` have no
  call sites. Each says so in-file and in `docs/technical/09-file-index.md` /
  `11-vpn.md` / `15-model-cost.md`. Mount or delete; neither is a defect.

## 6. `UsagePanel`'s date-picker popover anchor (unreproduced)

- `Views/Popup/UsagePanel.swift:11-17` — the `.popover(isPresented:)` is attached
  to `header`, and the period chips (`PeriodTabs`) and 重新统计 live *inside*
  `header`. The concern is the standard SwiftUI anchor rule: a click anywhere in
  the anchor's subtree dismisses the popover, so while the picker is open those
  controls would be dead on their first click and would leave `usagePeriod` on
  `.custom` — the exact state `selectPeriod` was rewritten to prevent.
- **Not reproduced.** Four harnesses were built to test it — a synthetic
  `NSPopover` over a container, and three SwiftUI probes driven by `sendEvent`,
  `NSApp.sendEvent` and posted `CGEvent`s, the last one inside a signed app
  bundle with the Accessibility API. Every one failed to drive a SwiftUI control
  at all (the synthetic `NSButton` inside the same container *did* receive its
  click, and its sibling kept working while the popover was up — which is the
  opposite of the reported symptom). So this is recorded as an unverified
  concern, not fixed on the strength of a hypothesis.
- If it does reproduce in the running app, the fix is to hang the popover off a
  zero-size anchor that is a sibling of the chip row rather than off `header`.

## 7. The collapsed island repaints a 640×386 panel at 10 Hz (perf, needs a visual check)

- `NotchIslandController.swift:404` (`tickTimer`, 0.1 s) +
  `IslandStyle.panelSize` (640 × `expandedMaxHeight + 48`).
- **Measured, not inferred.** `sample` of the idle app, main-thread sample
  shares, island ON vs OFF (A/B on `notchIslandEnabled`, preference restored
  afterwards):

  | frame under the main thread | island ON | island OFF |
  |---|---|---|
  | `NSHostingView.layout()` | 13.9 % | 0.8 % |
  | `stepIdle` (display-cycle observer re-laying out every frame) | 9.7 % | 0.0 % |
  | `CALayer _display` (backing-store rasterization) | 10.7 % | 0.06 % |

  The whole hosting view is laid out and rasterized on **every commit**, at
  ~10 Hz, while the island is collapsed — and a collapsed island draws only the
  notch strip (`wings`, `IslandStyle.wingWidth` × `state.notch.height`). The
  panel *window* is still the full expanded box: `position()` sizes it from
  `IslandStyle.panelSize` unconditionally, and the content is
  `.frame(panelSize, alignment: .top)` + `.clipShape(shape)`, so the backing
  store is 640 × 386 regardless of what is visible. `winlist` confirms the
  window at 640 × 386 in collapsed mode.
- **Why it is not fixed here:** the fix is to size the panel to what is
  actually drawn (the island's own size, re-applied when a morph settles), and
  the island's frames are centred by `.frame(…, alignment: .top)`, so a narrower
  panel keeps the geometry — but a wrong frame clips the island mid-morph, which
  needs a visual check of the collapse/expand/alert transitions, not just a
  green build. Shipping it unverified would risk the app's most visible surface.
- First cheap step for whoever picks this up: halve the tick to 0.2 s and
  re-run the same A/B. If the three shares roughly halve, the redraw is
  timer-driven and the panel size is the whole story; if they do not, something
  else is opening a commit per frame and the timer is innocent.
- Related, same class: `IslandComponents.swift:874` (`IslandUsageCard.hero`)
  carries `.animation(.snappy(duration: 0.18), value: value)` where `value` is
  the usage-card hero figure — a per-poll value, so the same permanently-in-flight
  shape as the `RollingNumberText` bug in `docs/technical/08-performance.md`.
  It is not free to delete, though: that modifier is what fires the scrub
  crossfade (`Text(…dayLabel…)` beside it carries `.contentTransition(.opacity)`,
  and a transition needs an animation to run), and the scrub is user-driven.
  The correct edit is therefore the *coarse key* — `.animation(…, value:
  scrubIndex)` — leaving the digits to `RollingNumberText`'s `.numericText`.
  Left alone here rather than bundled into an already-large change, and because
  the card only exists while the island is expanded (the collapsed path above is
  the bigger cost).
