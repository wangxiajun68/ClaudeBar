import SwiftUI

/// Compact popup HUD. ClaudeBar is opened to switch a model or a proxy —
/// not to read Mac specs (those already live in the meter cards).
///
/// Row 1: live facts (sessions · local proxy · VPN · rates) + refresh.
/// Row 2: three switchers — Claude Code, Codex, Cursor — each a popover.
///
/// **VPN moved up into row 1.** The switcher row used to spend its third cell
/// on a VPN control, which made the header answer "which proxy" three times and
/// never answer "how much allowance is left" for the third client. VPN is a
/// *connection state*, not a model to switch, so it now rides the fact strip as
/// a compact pill (still the trigger for `VpnNodePickerPanel`), and the freed
/// cell shows Cursor's allowance — the one family whose quota was otherwise
/// invisible in the popup.
struct PanelHeader: View {
    @ProviderState([.configuration, .sessions]) var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    /// The three preferences this header renders, subscribed individually.
    /// Observing `AppPreferences.shared` wholesale re-evaluated the whole
    /// header — including both popover switchers' labels — for any unrelated
    /// write (a notch flag, the token-unit toggle, `manualUSDToCNY`).
    @State private var codexProxyPort = AppPreferences.shared.codexProxyPort
    @State private var codexRoutingEnabled = AppPreferences.shared.codexRoutingEnabled
    @State private var vpnMixedPort = AppPreferences.shared.vpnMixedPort
    @ObservedObject private var vpn = VpnManager.shared
    /// Cursor's allowance reading. Observed here so a quota refresh repaints
    /// this header only — not the session grid, KPI strip or action bar.
    @ObservedObject private var cursorStore = CursorUsageStore.shared
    var panel: PanelState

    var body: some View {
        return VStack(alignment: .leading, spacing: 6) {
            statusRow
            EqualRowGrid(spacing: 1, minColumnWidth: 0, fixedColumns: 3) {
                HeaderSwitchChip(
                    eyebrow: "CC",
                    title: ccModel,
                    vendor: ccVendor,
                    subtitle: ccVendor,
                    mark: { AnyView(CodexModelMark(codex: false, value: "CC")) },
                    tint: Theme.claude, ink: Theme.Ink.claude
                ) { _ in
                    ModelSwitchList(kind: .claude, panel: panel)
                }
                HeaderSwitchChip(
                    eyebrow: "Codex",
                    title: codexModel,
                    vendor: codexVendor,
                    subtitle: codexSubtitle,
                    mark: { AnyView(CodexModelMark(codex: true, value: "Codex")) },
                    quotaWindows: codexStore.quotaWindows,
                    tint: Theme.codex, ink: Theme.Ink.codex,
                    quotaLoading: codexStore.quotaLoading,
                    refreshQuota: { codexStore.refreshQuota(manual: true) }
                ) { _ in
                    ModelSwitchList(kind: .codex, panel: panel)
                }
                HeaderSwitchChip(
                    eyebrow: "Cursor",
                    title: cursorTitle,
                    vendor: "Cursor",
                    subtitle: cursorSubtitle,
                    mark: { AnyView(CursorMark()) },
                    quotaWindows: cursorGaugeWindows,
                    tint: Theme.cursor, ink: Theme.Ink.cursor,
                    quotaLoading: cursorStore.loading,
                    quotaDetail: cursorDetail,
                    refreshQuota: { cursorStore.refresh(manual: true) }
                ) { _ in
                    CursorUsagePanel()
                }
            }
            // The 1pt divider between chips, and nothing else. The chips are
            // drawn edge-to-edge in their slots, so this fill is only ever a
            // hairline: a `visualPercentCap` that inset each chip would expose a
            // 13pt band either side of it, which is why there is no cap.
            .background(Theme.hairline)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
        }
        .onAppear { codexStore.refreshConfiguredModel() }
        .onReceive(AppPreferences.shared.$codexProxyPort.removeDuplicates()) { codexProxyPort = $0 }
        .onReceive(AppPreferences.shared.$codexRoutingEnabled.removeDuplicates()) { codexRoutingEnabled = $0 }
        .onReceive(AppPreferences.shared.$vpnMixedPort.removeDuplicates()) { vpnMixedPort = $0 }
    }

    // MARK: Status row

    /// Row 1: live facts + refresh.
    ///
    /// **Every text here is capped to a share of the row, and that is the fix
    /// for a real bug.** The row is one `HStack` of variable-length strings
    /// (sessions, the proxy port, the VPN node) and it used to be
    /// laid out by *ideal* widths alone: `VpnStatusPill` carried
    /// `layoutPriority(1)` and no cap, so a long node name
    /// (`加拿大 A05 电信+联通 BGP 高带宽优化 · 18 ms` measures **240pt**) took the
    /// room it wanted and left the fixed facts beside it fighting over the
    /// remainder — which is what rendered the proxy fact as `本地...`.
    ///
    /// Two rules instead of a priority:
    ///
    /// * **Fixed facts keep their space.** Sessions and the proxy port are the
    ///   row's reason to exist (`docs/design/04-popup-layout.md`); they are
    ///   `fixedSize()` so they are never the thing that gives way.
    /// * **The flexible fact is capped, so it shortens itself.** The node name
    ///   gets the width below, so a very long node truncates its own tail
    ///   (`加拿大 A05 电信+联通…`) instead of squeezing a neighbour to `本地...`.
    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(runningCount > 0 ? Theme.chartGreen : Theme.Ink.idle)
                .frame(width: 6, height: 6)
            Text(runningCount > 0 ? "\(runningCount) 会话" : "空闲")
                .rollingNumber()
                .font(Theme.Font.section)
                .foregroundColor(Theme.textPrimary)
                .fixedSize()
            statusDot
            Text(proxyFact)
                .rollingNumber()
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(codexStore.proxyRunning ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
            statusDot
            // The VPN readout lives here now — see the type doc. The floor is
            // the *dot + delay* the pill already has a compact form for, so the
            // node name shrinks toward that before anything beside it moves.
            //
            // The live rate pair (`↓1.8K ↑…`) used to sit after this and is gone.
            // It cost ~76pt of a 436pt row to say one thing — "there is
            // traffic" — that the pill's own green dot already says, and the
            // figures were unreadable at 11pt and in constant motion from the
            // 1 Hz sampler. What it bought was the node name, the one fact here
            // a person acts on ("which line am I on?"): the long
            // `加拿大 A05 电信+联通 BGP 高带宽优化 · 18 ms` label now has room to
            // run. The rates themselves still live on the menu-bar strip, the
            // VPN page and the traffic page — this row does not need a fourth
            // copy of them.
            VpnStatusPill()
                .layoutPriority(1)
                .frame(maxWidth: Self.vpnPillMaxWidth, alignment: .leading)
            Spacer(minLength: 4)
            Button {
                NotificationCenter.default.post(name: .showMainWindow, object: nil)
            } label: {
                GlyphWell(name: "macwindow", tint: Theme.textSecondary, size: 20)
            }
            .buttonStyle(.plain)
            .help("打开主窗口")
            .accessibilityLabel("打开主窗口")
            Button {
                providerStore.refresh()
                panel.showFeedback("已刷新")
            } label: {
                GlyphWell(name: "arrow.clockwise", tint: Theme.textSecondary, size: 20)
            }
            .buttonStyle(.plain)
            .help("刷新")
            .accessibilityLabel("刷新")
        }
    }

    /// How wide the VPN pill's label may grow before it truncates.
    ///
    /// 228pt. The row is 436pt of content (460pt shell − 24pt padding) and the
    /// fixed pieces around the pill — sessions ≈26, proxy ≈58, two 20pt buttons,
    /// four dots, five 6pt gaps and the trailing 4pt spacer — come to ≈208pt, so
    /// this is what is left. It was 168 while the live rate pair also lived here;
    /// dropping that bought the 60pt back.
    ///
    /// It is a *cap*, not a reservation: a shorter label draws shorter and the
    /// surplus goes to the spacer. A node name longer than this truncates at the
    /// **end**, keeping the region (`加拿大 A05 …`) and dropping the least
    /// distinctive words. Nothing is lost — the full name is in the pill's
    /// tooltip and on the VPN page it opens.
    static let vpnPillMaxWidth: CGFloat = 228

    private var statusDot: some View {
        Text("·")
            .font(.system(size: 11))
            .foregroundColor(Theme.textTertiary())
    }

    // MARK: Facts

    private var runningCount: Int {
        providerStore.busySessionCount
            + providerStore.activeCursorCount
            + providerStore.activeExternalCount
    }

    private var proxyFact: String {
        if codexStore.proxyRunning { return "本地 \(codexProxyPort)" }
        if codexRoutingEnabled { return "本地 未监听" }
        return "本地 关"
    }

    private var ccModel: String {
        providerStore.activeProvider?.activeModel?.name ?? "未配置"
    }

    private var ccVendor: String {
        providerStore.activeProvider?.name ?? "添加供应商"
    }

    private var codexModel: String {
        // The active custom provider is optional when Codex uses OpenAI.
        // Read the actual selection instead of treating that as unconfigured.
        codexStore.configuredModel ?? (codexStore.usesOfficialAccount ? "官方默认模型" : "默认模型")
    }

    private var codexVendor: String {
        if codexStore.usesOfficialAccount { return "OpenAI 官方" }
        return codexStore.providers.first { $0.id == codexStore.configuredProviderID }?.name ?? "Codex"
    }

    /// Rate-limit windows under the model name. Vendor stays when the
    /// ChatGPT usage call has not returned yet.
    private var codexSubtitle: String {
        let windows = codexStore.quotaWindows
        if windows.isEmpty {
            if codexStore.quotaLoading { return "额度…" }
            return codexStore.quotaNote ?? codexVendor
        }
        return windows.map { "\($0.label)已用 \($0.usedText)" }.joined(separator: " · ")
    }

    // MARK: Cursor allowance

    /// The chip's headline. Prefers the account's plan tier (Pro / Ultra / Free)
    /// because that is the stable answer — the percentages live on the gauges
    /// below, and repeating one here would be the same number twice.
    private var cursorTitle: String {
        if let plan = cursorStore.grok?.planName, !plan.isEmpty { return plan }
        return "Cursor"
    }

    /// What the chip says when the gauges have nothing to draw. Once a reading
    /// exists the gauges replace this line, so it only has to carry the loading
    /// and failure states.
    ///
    /// A plan with **no named pool** is the one loaded state that has no gauge:
    /// legacy / team payloads send only `totalPercentUsed`, so `额度` there is a
    /// truthful reading rather than a spinner the row does not need.
    private var cursorSubtitle: String {
        if cursorStore.plan != nil || cursorStore.grok != nil { return "额度" }
        if cursorStore.loading { return "额度…" }
        return cursorStore.note ?? "未登录"
    }

    /// The two named pools inside the monthly plan, as the chip's two gauges:
    /// **Cursor Models** (`autoPercentUsed`) and **Other Models**
    /// (`apiPercentUsed`).
    ///
    /// These are Cursor's own names for the pools — taken from its
    /// `auto-spillover-ui.ts` — and they replace the old 「月度」/「Grok」pair,
    /// which mixed the month with the Grok *Bot* weekly window and never named
    /// the second pool at all. The Grok Bot window still exists and still has
    /// its own weekly reset; it now lives where a non-monthly reading belongs,
    /// in the chip's popover (`CursorUsagePanel`), which spells both names in
    /// full.
    ///
    /// Both carry **used** percentages, the units Cursor reports; the gauge cell
    /// subtracts to the remaining reading the popup shows, and the money rides
    /// underneath as `quotaDetail` — it is the *shared* monthly figure these two
    /// pools sit under, which is why it is not repeated per gauge.
    ///
    /// **Abbreviated to one word here on purpose.** The full names are the
    /// reading, but the chip's allowance row is ~119pt and two `GaugeCell`s
    /// carrying "Cursor Models" / "Other Models" measure **166pt** together —
    /// measured, that clipped both to "Cursor Mo…" / "Other Mod…", which is
    /// worse than a clean short name. One word each ("Cursor" / "Other") is
    /// 103pt, fits the 119pt budget with room to spare, and cannot be misread:
    /// the pair sits inside the **Cursor** chip, under `Cursor`'s own plan name,
    /// and the popover this chip opens names both pools in full. The order is
    /// Cursor's own — Cursor Models first, Other Models second.
    ///
    /// Either pool can be missing (`nil` on legacy / team shapes): a lone pool
    /// still draws, and only a plan with neither leaves the row empty.
    private var cursorGaugeWindows: [CodexQuotaWindow] {
        var windows: [CodexQuotaWindow] = []
        if let plan = cursorStore.plan {
            let reset = plan.resetsAt
            if let cursorModels = plan.cursorModelsFraction {
                windows.append(CodexQuotaWindow(
                    label: "Cursor",
                    usedPercent: cursorModels * 100,
                    resetsAt: reset,
                    durationMinutes: 0
                ))
            }
            if let otherModels = plan.otherModelsFraction {
                windows.append(CodexQuotaWindow(
                    label: "Other",
                    usedPercent: otherModels * 100,
                    resetsAt: reset,
                    durationMinutes: 0
                ))
            }
        }
        return windows
    }

    /// The money line under the gauges, e.g. "$492.45 / $20".
    private var cursorDetail: String { cursorStore.plan?.spendText ?? "" }
}

// MARK: - Switch chip

/// The four vertical zones every switcher chip draws, and their fixed heights.
///
/// They live outside `HeaderSwitchChip` because that type is generic over its
/// popover and Swift does not allow stored statics in a generic type. One table
/// here beats four magic numbers spread through the chip's body: the row's
/// alignment *is* the sum of these, and reading it in one place is how the three
/// columns stay level when a chip has nothing for a zone.
private enum ChipZone {
    static let mark: CGFloat = 15        // the brand mark + disclosure chevron
    static let name: CGFloat = 16        // the model name
    static let allowance = QuotaSwayGauge.height   // gauges, or the no-quota dash
    static let footer: CGFloat = 11      // vendor, or the spend line
}

/// One cell of the header switcher row. Eyebrow + current value + popover.
private struct HeaderSwitchChip<Popover: View>: View {
    let eyebrow: String
    let title: String
    /// The family's current provider name. Drawn in the footer zone for a chip
    /// with no allowance to spend against (CC), where it is the most useful
    /// thing left to say; a chip with a spend line shows that instead.
    var vendor: String? = nil
    /// Kept as the chip's secondary line for the states that have to say
    /// something other than the model name — "额度…", "未登录", a failure note.
    let subtitle: String
    /// The chip's own mark, drawn on the row above the model name.
    ///
    /// It is the **only** statement of the family on the chip: the artwork is
    /// the brand, so no word is drawn beside it (see `CodexModelMark` for the
    /// duplicate this replaced). `eyebrow` survives as the family's name for
    /// tooltips, accessibility and the quota buttons' labels.
    /// Type-erased so a family that is not CC/Codex can supply its own mark
    /// (`CursorMark`) instead of being forced through `CodexModelMark`'s
    /// `codex: Bool`.
    var mark: (() -> AnyView)? = nil
    var quotaWindows: [CodexQuotaWindow] = []
    /// A hard ceiling on the width the chip *draws* at.
    ///
    /// **Always `nil` today — kept as the seam for the change, not as live
    /// behaviour.** A popup scaled wider than the 424pt it was measured at hands
    /// the three columns the extra width as three wider cells, and a two-window
    /// allowance row has nothing to spend it on, so the surplus became a longer
    /// empty gap after the second window. Capping the drawn width was tried to
    /// hold the density where it was measured — and it *did* fix the gap, but the
    /// inset chip left the row's 1pt hairline fill showing as a 13pt grey band
    /// either side of every column, so the row read as three tiles with gutters
    /// (see the screenshots in the change that added this) instead of one control
    /// group. Dropping the fill fixed the band but cost the divider. Both were
    /// worse than the plain greedy chip, so the cap is off and the width question
    /// is answered by the shell instead: `MenuBarView` is 460pt wide and the row
    /// simply draws at 143pt per column. The seam stays so a future pass can
    /// re-open it with a row treatment that keeps the divider.
    var visualPercentCap: CGFloat? = nil
    /// Chip accent — also drives the eyebrow, which is text.
    var tint: Color
    /// Readable counterpart of `tint` for the eyebrow; see `StatusPill`.
    var ink: Color? = nil
    var quotaLoading = false
    /// A quiet second line under the gauges — the spend reading for a family
    /// whose allowance is also a dollar figure (Cursor). Empty for Codex, whose
    /// gauges already carry everything it has.
    var quotaDetail: String = ""
    var refreshQuota: (() -> Void)? = nil
    @ViewBuilder var popover: (Binding<Bool>) -> Popover

    @State private var open = false
    /// The chip's own content width, measured once and handed to the quota row.
    ///
    /// `QuotaSwayGauge` sizes its arcs and type from the width it is given, and
    /// a `GeometryReader` only knows the width it is *proposed*. Inside the
    /// chip's greedy VStack that proposal collapsed to the row's own ideal, so
    /// the two chips that carry gauges measured differently — Codex (no money
    /// line under its gauges) came out ~13pt arcs while Cursor (a wide
    /// `$492.45 / $20` line) came out ~15pt. Two chips in one row at two
    /// scales is the bug; measuring the chip once and passing that width down
    /// is the fix. `-14` is the chip's own horizontal padding.
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        // Four fixed zones, so the three chips in the row line up.
        //
        // The chips carry different things — CC has a vendor but no allowance,
        // Codex an allowance but (until this change) no vendor, Cursor both plus
        // a spend figure — so building the stack from whatever each chip happens
        // to hold left the three columns ragged: measured, CC's content ended at
        // y≈61, Codex's at y≈77 and Cursor's at y≈90. Nothing in a row of
        // switchers should read as *staircased*; the eye is comparing like with
        // like. Every zone below is therefore always present, and a chip with
        // nothing to put in one reserves its height rather than closing the gap:
        //
        //   1. mark (and the disclosure chevron)     18pt
        //   2. model name                            17pt
        //   3. allowance row (gauges, or blank)      26pt
        //   4. footer — vendor, or the spend line    12pt
        VStack(alignment: .leading, spacing: 2) {
            Button { open.toggle() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    // Mark over name, not beside it. The mark used to sit in a
                    // row with a `Text(eyebrow)` that repeated the word the mark
                    // already drew, so each chip said its family twice and spent
                    // ~20pt of a 133pt cell on the echo. The artwork *is* the
                    // family; the name still reaches the tooltip and VoiceOver.
                    HStack(spacing: 4) {
                        if let mark {
                            mark()
                                .accessibilityHidden(true)
                        }
                        // The family word, drawn beside the mark rather than
                        // instead of it. The chip carried only the artwork for a
                        // while, on the theory that the mark *is* the family —
                        // but at 13pt on a phone-thin chip the Anthropic "A\",
                        // the OpenAI knot and Cursor's cube read as three
                        // similar smudges to anyone who does not already know
                        // them, and the row they sat on was mostly empty space.
                        // The word costs ~30pt of a row that had it, and the
                        // mark keeps the recognition the word cannot carry.
                        Text(eyebrow)
                            .font(Theme.Font.eyebrow)
                            .foregroundColor(ink ?? tint)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold)).foregroundColor(Theme.textTertiary())
                    }
                    .frame(height: ChipZone.mark, alignment: .center)

                    // `minimumScaleFactor` before the truncation: at the popup's
                    // real 118.7pt of content width a 12pt model name is 1.4pt
                    // short of fitting ("deepseek-v4.1-flash" measures 120.1pt),
                    // so `lineLimit(1)` alone turned every long model into
                    // "deepsee...v4.1-flash" — a name with its identifying middle
                    // cut out. Letting it scale to 85% first keeps the whole name
                    // at a still-legible size; `.middle` truncation stays as the
                    // last resort for a name that cannot fit at any size.
                    Text(title).font(Theme.Font.section).foregroundColor(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.85)
                        .frame(height: ChipZone.name, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.uiversePress)
            .popover(isPresented: $open, arrowEdge: .bottom) { popover($open) }
            .help("\(eyebrow)：\(title) · \(subtitle)")
            // Measured on the *button*, not the whole chip: the button is the
            // chip's one greedy row (`maxWidth: .infinity`), so its width is the
            // full content width, and it does not contain the gauge. Measuring
            // the outer VStack fed `contentWidth` back into the gauge, whose
            // fixed-width frame then changed the VStack's own measured width —
            // a feedback loop that never converged and pinned the render loop.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }

            // Zone 3 — the allowance row. Present for every chip: one without a
            // quota still reserves the height so its footer sits on the same
            // baseline as the chips that have gauges.
            allowanceRow

            if !footer.isEmpty {
                Text(footer)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(height: ChipZone.footer, alignment: .center)
                    .help(footerHelp)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.cardSurface)
        // No cap: the chip is greedy in its slot, so the three columns tile
        // edge-to-edge and the row's 1pt spacing is a true divider. See
        // `visualPercentCap` for why an inset chip was tried and withdrawn.
    }

    /// Zone 3, for every chip. A family with allowances draws the gauges; one
    /// without (CC) draws a dash, so the zone is never an invisible hole that
    /// makes the column look broken when its neighbours have rows of figures.
    @ViewBuilder private var allowanceRow: some View {
        Group {
            if let refreshQuota {
                Button(action: refreshQuota) {
                    quotaRowBody
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(quotaLoading)
                .help(quotaHelp)
                .accessibilityLabel(quotaLoading ? "正在刷新\(eyebrow)额度" : "刷新\(eyebrow)额度")
            } else {
                // A dash, not a spinner and not empty: the zone exists and this
                // family has no allowance to show, which is a fact worth stating
                // rather than a hole worth reserving silently.
                Text("—")
                    .font(Theme.Font.meta)
                    .foregroundColor(Theme.textTertiary())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("\(eyebrow) 无额度读数")
                    .accessibilityLabel("\(eyebrow) 无额度读数")
            }
        }
        .frame(height: ChipZone.allowance, alignment: .top)
    }

    /// What fills the allowance zone for a chip that has a quota.
    ///
    /// The spinner is the *empty* state, not the busy one. A refresh that has
    /// figures to keep keeps them (`stripSpinner`), because at launch — when the
    /// probe cannot succeed yet — replacing the last reading with "刷新额度…"
    /// would take the allowance off screen for the seconds the tunnel needs and
    /// make a working chip look broken. `quotaLoading` still disables the button
    /// the whole time, so a second tap cannot stack a probe.
    @ViewBuilder private var quotaRowBody: some View {
        if quotaLoading && quotaWindows.isEmpty {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("刷新额度…").font(Theme.Font.meta).foregroundColor(Theme.textSecondary)
            }
        } else if quotaWindows.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
                Text(subtitle)
                    .rollingNumber()
                    .font(Theme.Font.meta).foregroundColor(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        } else {
            // `QuotaSwayGauge` reads **remaining** — the headroom, not the
            // draw-down. Both quota windows are a cap the user is spending
            // against, so "还剩多少" is the answer they came for, and the
            // percentage under each name is `100 - used` with the arc filling
            // the same way (a fuller arc = more left). The reset rides under
            // each arc — see its own doc for why that is what lets two windows
            // fit one switcher column whole.
            QuotaSwayGauge(
                metrics: quotaWindows.map {
                    QuotaSwayGauge.Metric(label: $0.label,
                                          usedPercent: $0.usedPercent,
                                          resetCompact: $0.resetCompact)
                },
                width: contentWidth
            )
            // The figures stay; this is the only mark that a probe is in flight
            // over them. It is deliberately faint — the reading on screen is
            // still the last true one, and a quota that moves monthly does not
            // become wrong while a refresh runs.
            .opacity(quotaLoading ? 0.45 : 1)
        }
    }

    /// Zone 4 — the quiet line under the allowance row. The spend figure for a
    /// family whose allowance is also a dollar amount (Cursor); the vendor for a
    /// family that has no allowance to amount it against (CC, Codex).
    private var footer: String {
        if !quotaDetail.isEmpty && !quotaWindows.isEmpty { return quotaDetail }
        return vendor ?? ""
    }

    private var footerHelp: String {
        if !quotaDetail.isEmpty && !quotaWindows.isEmpty {
            return "\(eyebrow) 本周期花费 \(quotaDetail)"
        }
        return "\(eyebrow) 供应商 \(footer)"
    }

    /// The gauge row's tooltip. Names the *family* (`eyebrow`) rather than
    /// "Codex", so the same chip serves every quota-bearing client.
    private var quotaHelp: String {
        if quotaLoading { return "正在获取 \(eyebrow) 额度（显示上一次读数）" }
        var text = "点击刷新 \(eyebrow) 额度"
        if !quotaDetail.isEmpty { text += " · \(quotaDetail)" }
        return text
    }

}

// MARK: - Model switch list

private enum ModelSwitchKind { case claude, codex }

private struct ModelSwitchList: View {
    @ProviderState([.configuration, .sessions]) var providerStore: ProviderStore
    @EnvironmentObject var codexStore: CodexProviderStore
    let kind: ModelSwitchKind
    var panel: PanelState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kind == .claude ? "切换 Claude Code" : "切换 Codex")
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if rows.isEmpty {
                Button("去添加供应商") {
                    dismiss()
                    NotificationCenter.default.post(.showMainWindow(page: .providers, editor: true))
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.Ink.claude)
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            if row.isHeader {
                                Text(row.title)
                                    .font(Theme.Font.micro)
                                    .foregroundColor(Theme.textTertiary())
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 3)
                            } else {
                                Button {
                                    activate(row)
                                    panel.showFeedback("\(kind == .claude ? "CC" : "Codex") · \(row.title)")
                                    dismiss()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: row.active ? "checkmark" : "")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundColor(Theme.Ink.claude)
                                            .frame(width: 12)
                                        Text(row.title)
                                            .font(Theme.Font.caption)
                                            .foregroundColor(row.active ? Theme.claude : Theme.textPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(row.active ? Theme.claude.opacity(0.12) : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 6)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 240)
    }

    private struct Row: Identifiable {
        let id: String
        var isHeader: Bool
        var title: String
        var providerID: UUID
        var modelID: UUID
        var active: Bool
    }

    private var rows: [Row] {
        switch kind {
        case .claude:
            return providerStore.providers.flatMap { p -> [Row] in
                let header = Row(id: "h-\(p.id)", isHeader: true, title: p.name,
                                 providerID: p.id, modelID: p.id, active: false)
                let models = p.models.map { m in
                    Row(id: "\(p.id)-\(m.id)", isHeader: false, title: m.name,
                        providerID: p.id, modelID: m.id,
                        active: p.id == providerStore.activeProviderID
                            && m.name.caseInsensitiveCompare(providerStore.currentEnv?.ANTHROPIC_MODEL ?? "") == .orderedSame)
                }
                return [header] + models
            }
        case .codex:
            return codexStore.providers.flatMap { p -> [Row] in
                let header = Row(id: "h-\(p.id)", isHeader: true, title: p.name,
                                 providerID: p.id, modelID: p.id, active: false)
                let models = p.models.map { m in
                    let active = p.id == codexStore.activeProviderID
                        && (p.activeModelID == m.id
                            || (p.activeModelID == nil && m.id == p.models.first?.id))
                    return Row(id: "\(p.id)-\(m.id)", isHeader: false, title: m.name,
                               providerID: p.id, modelID: m.id, active: active)
                }
                return [header] + models
            }
        }
    }

    private func activate(_ row: Row) {
        switch kind {
        case .claude:
            providerStore.activateModel(providerID: row.providerID, modelID: row.modelID)
        case .codex:
            codexStore.activate(providerID: row.providerID, modelID: row.modelID)
        }
    }
}
