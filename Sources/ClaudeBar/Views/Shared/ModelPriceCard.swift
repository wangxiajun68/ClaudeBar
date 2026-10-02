import SwiftUI

/// 设置 ▸ 用量与花费 ▸ 模型定价.
///
/// The price table used to be a constant the user could neither see nor correct.
/// This is the surface that makes it a live document: every row the app can bill
/// against, with where its number came from, a way to edit it, and one button
/// that goes and looks.
///
/// Three things drive the layout, and they are all consequences of the same
/// rule — a number the user cannot trace is a number they cannot trust:
///
/// 1. **Provenance leads.** 内置 / 官方页 / 手动 / 待确认 are four different
///    claims, so each row states its own. A fetched row shows the page it came
///    from; a manual row shows the day it took effect.
/// 2. **Proposals are separate from facts.** A background check produces
///    candidates; they sit in their own block above the list until applied or
///    dismissed, so a diff is never mixed in with rows that are in force.
/// 3. **The list is quiet.** 56 rows is too many to read as prose, so a row is
///    slug + price + provenance and nothing else until it is being edited.
struct ModelPriceCard: View {
    @ObservedObject private var catalog = ModelPriceCatalog.shared

    @State private var filter = ""
    @State private var editing: String?
    /// A slug the user is adding whose row the filter is not drawing — either
    /// one the catalog has never heard of, or a known one the current search
    /// word excludes. `editing` alone cannot express it: the editor mounts
    /// *inside a row* (`ForEach(rows) → PriceRow → if editing == slug`), so a
    /// slug in no visible row would set state that nothing drew. The draft is
    /// rendered as its own row above the table until its editor closes.
    @State private var draftSlug: String?
    @State private var showReport = false
    @State private var addSlug = ""
    @State private var adding = false

    /// Tall enough to show a screenful of a 56-row table, capped so the settings
    /// page below it stays reachable. The list owns its own scroll for the same
    /// reason `ProviderModelPicker` does: the settings page is already a
    /// `ScrollView`, and a second unbounded one would make the wheel ambiguous.
    private static let listHeight: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            header
            SettingsDivider()
            if !catalog.candidates.isEmpty {
                candidates
                SettingsDivider()
            }
            if catalog.report != nil {
                reportBlock
                SettingsDivider()
            }
            search
            list
        }
    }

    // MARK: - Header

    private var header: some View {
        SettingsRow(title: "模型定价", caption: caption) {
            HStack(spacing: 6) {
                ActionButton("查询更新", symbol: "arrow.triangle.2.circlepath", tone: .neutral) {
                    catalog.dismissAllCandidates()
                    Task { await catalog.check(autoApply: true) }
                }
                .disabled(catalog.isChecking)
                .help("按厂商官方价源核对价格；美元模型从 models.dev 取，人民币模型解析厂商定价页")
                .accessibilityLabel("查询更新模型价格")
            }
        }
    }

    /// What is pending, then the table's check date and size, then how much has
    /// been edited by hand and how stale it all is. Check errors are not
    /// repeated here — the report block below leads with them instead
    /// (`catalog.report?.headline`).
    private var caption: String {
        if catalog.isChecking { return "正在核对价源…" }
        var parts: [String] = []
        if !catalog.candidates.isEmpty {
            parts.append("有 \(catalog.candidates.count) 条待确认")
        }
        parts.append("核查于 \(ModelPricing.updated) · \(catalog.allSlugs.count) 个模型")
        if catalog.customSlugCount > 0 {
            parts.append("\(catalog.customSlugCount) 条已改")
        }
        if catalog.isStale, let last = catalog.lastCheckedAt {
            parts.append("上次查询 \(Self.day.string(from: last))")
        }
        return parts.joined(separator: " · ")
    }

    private static let day: DateFormatter = {
        let made = DateFormatter()
        made.locale = Locale(identifier: "zh_CN")
        made.dateFormat = "M月d日"
        return made
    }()

    // MARK: - Candidates

    private var candidates: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("待确认 \(catalog.candidates.count)")
                    .font(Theme.Font.microSemibold)
                    .foregroundColor(Theme.Ink.warning)
                Spacer()
                ActionButton("全部应用", tone: .accent, size: .regular) {
                    catalog.applyAllCandidates()
                }
                ActionButton("全部忽略", tone: .neutral) { catalog.dismissAllCandidates() }
            }
            ForEach(catalog.candidates) { candidate in
                candidateRow(candidate)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func candidateRow(_ candidate: ModelPriceCatalog.Candidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.slug)
                        .font(Theme.Font.microMono)
                        .foregroundColor(Theme.textPrimary)
                    StatusPill(label: candidate.source.label, tint: Theme.Ink.claude)
                }
                Text(diffLine(candidate))
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textSecondary)
                if let note = candidate.note {
                    Text(note)
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textTertiary())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                ActionButton("应用", tone: .accent) { catalog.apply(candidate) }
                ActionButton("忽略", tone: .neutral) { catalog.dismiss(candidate) }
            }
        }
        .padding(.vertical, 4)
    }

    /// 现在 → 抓到的样子. Shows both sides, because "changed" is only meaningful
    /// next to what it changed from — and states 未计价 / 无价 rather than
    /// leaving a blank where the old number was.
    private func diffLine(_ candidate: ModelPriceCatalog.Candidate) -> String {
        let before = describe(candidate.current)
        let after = candidate.rate.map { rateText($0) } ?? "无价"
        return "\(before) → \(after)"
    }

    private func describe(_ resolution: ModelPricing.Resolution?) -> String {
        switch resolution {
        case .priced(let rate): return rateText(rate)
        case .unpriced(let reason): return reason.label
        case nil: return "未收录"
        }
    }

    // MARK: - Report

    private var reportBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Theme.Animation.smooth) { showReport.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showReport ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    Text(catalog.report?.headline ?? "")
                        .font(Theme.Font.micro)
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("上次核对结果")
            .accessibilityHint(showReport ? "收起核对明细" : "展开核对明细")

            if showReport, let report = catalog.report {
                ForEach(report.failures) { failure in
                    HStack(alignment: .top, spacing: 6) {
                        SignatureGlyph(name: "exclamationmark.triangle", tint: Theme.Ink.warning, size: 11)
                        Text("\(failure.vendor)：\(failure.reason)")
                            .font(Theme.Font.micro)
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("核对只覆盖能自动读取的厂商；未能读取的保持表中原值，绝不会退回到聚合价源——它们记的国产价是国际站美元价。")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Search / add

    private var search: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                InstrumentSearchField(prompt: "搜索模型名", text: $filter)
                ActionButton(adding ? "取消" : "添加", tone: .neutral) {
                    adding.toggle()
                    if !adding { addSlug = "" }
                }
                .help("为表中没有的模型手工添加一条价格")
            }
            if adding {
                HStack(spacing: 8) {
                    TextField("厂商的规范模型名，例如 glm-5.4", text: $addSlug)
                        .textFieldStyle(InstrumentFieldStyle(onCard: false))
                        .onSubmit(startAdding)
                    ActionButton("编辑价格", tone: .accent, action: startAdding)
                        .disabled(addSlug.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// The manual add path: hand the typed name to the same editor every row
    /// uses, in the canonical spelling the catalog can store.
    ///
    /// `record` refuses a non-canonical slug, so a relay-style name
    /// (`anthropic/claude-sonnet-4-6`, `-latest`, a dated snapshot) is reduced
    /// to the vendor id before it is matched — that is what opens the table's
    /// own row, pre-filled, instead of an editor whose save would be refused. A
    /// name that reduces to nothing (a trailing `/`) keeps its typed form, so
    /// the editor can still open and say why it cannot be stored.
    private func startAdding() {
        let typed = addSlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !typed.isEmpty else { return }
        let canonical = ModelPricing.canonical(typed)
        let name = canonical.isEmpty ? typed : canonical
        editing = name
        // A slug whose row is on screen gets its editor mounted in place;
        // anything else — a brand-new id, or a known one the current search
        // word hid — is the draft row above the table, which lives outside the
        // filter so the editor that was just opened cannot be swallowed by it.
        draftSlug = rows.contains(name) ? nil : name
        adding = false
        addSlug = ""
    }

    // MARK: - List

    private var rows: [String] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return catalog.allSlugs }
        return catalog.allSlugs.filter { $0.lowercased().contains(needle) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let draftSlug, !rows.contains(draftSlug) {
                    // The row 编辑价格 just opened, for a slug the table below is
                    // not drawing: either one the catalog has never heard of, or
                    // a known one the search word excludes. Living outside the
                    // filter is what stops that word from hiding the editor that
                    // was just opened; as soon as `rows` lists the slug the row
                    // below mounts the editor instead. Closing the editor either
                    // way retires this draft — a save has made the slug a real
                    // row, a cancel leaves no phantom behind.
                    PriceRow(slug: draftSlug,
                             editing: $editing,
                             sourceURL: sourceURL(for: draftSlug),
                             onDraftEnded: { self.draftSlug = nil })
                        .padding(.horizontal, 20)
                    SettingsDivider()
                }
                if rows.isEmpty && draftSlug == nil {
                    StandbyEmptyState(label: "没有匹配的模型", symbol: "magnifyingglass")
                        .padding(.vertical, 20)
                }
                ForEach(rows, id: \.self) { slug in
                    PriceRow(slug: slug,
                             editing: $editing,
                             sourceURL: sourceURL(for: slug))
                        .padding(.horizontal, 20)
                    SettingsDivider()
                }
            }
        }
        .frame(height: Self.listHeight)
        .scrollHoverGate()
    }

    /// The vendor's own pricing page for a row, when we know one. Only vendors
    /// whose page this app already reads are listed — the link goes to the
    /// numbers' source, not to a search engine.
    private func sourceURL(for slug: String) -> String? {
        for vendor in ModelPriceSources.vendors where vendor.slugs.contains(slug) {
            return vendor.url
        }
        if ModelPriceSources.usdVendor(for: slug) != nil {
            return "https://models.dev"
        }
        return nil
    }

    // MARK: - Formatting

    /// A per-million unit price. `%g` so `8` reads as `8` and not `8.000`, and
    /// `0.23` keeps its precision — the numbers here are quoted to two or three
    /// significant figures and padding them out would imply more.
    static func rateTextFor(_ value: Double) -> String { String(format: "%g", value) }

    private func rateText(_ rate: ModelPricing.Rate) -> String {
        "\(rate.currency.symbol) \(Self.rateTextFor(rate.input)) / \(Self.rateTextFor(rate.output))"
            + " · 读 \(Self.rateTextFor(rate.cacheRead))"
    }
}

// MARK: - One row

/// A single model's line: what it costs, where the number came from, and the
/// controls to change or undo it.
///
/// Split out as its own view so the list stays a list and the editing state
/// lives next to the row it belongs to. The row owns no storage — it reads the
/// catalog and writes through it.
private struct PriceRow: View {
    let slug: String
    @Binding var editing: String?
    let sourceURL: String?
    /// Called when this row's editor closes, so the card can retire the draft
    /// row of a slug that never made it into the catalog. Nil for table rows.
    var onDraftEnded: (() -> Void)? = nil

    @ObservedObject private var catalog = ModelPriceCatalog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(slug)
                    .font(Theme.Font.microMono)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                priceText
                provenance
                actions
            }
            .frame(minHeight: 30)

            if editing == slug {
                PriceEditor(slug: slug, existing: catalog.activeOverride(for: slug),
                            onDone: { editing = nil; onDraftEnded?() })
            } else if let override = catalog.activeOverride(for: slug), let note = override.note {
                Text(note)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var priceText: some View {
        switch catalog.resolution(for: slug) {
        case .priced(let rate):
            HStack(spacing: 4) {
                Text(rate.currency.symbol)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textSecondary)
                Text("\(ModelPriceCard.rateTextFor(rate.input)) / \(ModelPriceCard.rateTextFor(rate.output))")
                    .font(Theme.Font.microMono)
                    .foregroundColor(Theme.textPrimary)
                    .monospacedDigit()
                Text("读 \(ModelPriceCard.rateTextFor(rate.cacheRead))")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textSecondary)
                    .monospacedDigit()
            }
            .help("每百万 token 的刊例价：输入 / 输出 · 缓存命中 \(ModelPriceCard.rateTextFor(rate.cacheRead))"
                  + " · 缓存写入 \(ModelPriceCard.rateTextFor(rate.cacheWrite))")
        case .unpriced(let reason):
            Text(reason.label)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textTertiary())
                .help(reason.explanation)
        case nil:
            Text("未计价")
                .font(Theme.Font.micro)
                .foregroundColor(Theme.Ink.warning)
                .help("价目表未收录该模型名")
        }
    }

    /// The row's claim about its own number. This is the whole point of the
    /// card, so it is never abbreviated away: 内置 means the bundled table,
    /// 官方页 means a parsed vendor page (dated), 手动 means the user typed it.
    @ViewBuilder
    private var provenance: some View {
        if let override = catalog.activeOverride(for: slug) {
            StatusPill(label: "\(override.source.label) · 自 \(shortDay(override.effectiveFrom))",
                       tint: Theme.Ink.claude)
                .help(provenanceHelp(override))
        } else if sourceURL != nil {
            StatusPill(label: "内置", tint: Theme.textSecondary)
                .help("来自应用内置的价目表（核查于 \(ModelPricing.updated)），点右侧链接可核对官方定价页")
        } else {
            StatusPill(label: "内置", tint: Theme.textSecondary)
                .help("来自应用内置的价目表，核查于 \(ModelPricing.updated)")
        }
    }

    private func provenanceHelp(_ override: ModelPricing.PriceOverride) -> String {
        var lines = [override.source.explanation, "自 \(override.effectiveFrom) 起生效"]
        if let url = override.sourceURL { lines.append("来源：\(url)") }
        if let checked = override.checkedAt {
            lines.append("写入于 \(Self.stamp.string(from: checked))")
        }
        lines.append("改动只影响该日期之后的用量，之前的记录保持原价")
        return lines.joined(separator: "\n")
    }

    private func shortDay(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return key }
        return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }

    private static let stamp: DateFormatter = {
        let made = DateFormatter()
        made.locale = Locale(identifier: "zh_CN")
        made.dateFormat = "M月d日 HH:mm"
        return made
    }()

    private var actions: some View {
        HStack(spacing: 4) {
            if let url = sourceURL, let parsed = URL(string: url) {
                ActionChip(systemImage: "arrow.up.right.square", tint: Theme.textSecondary,
                           help: "打开官方定价页") {
                    NSWorkspace.shared.open(parsed)
                }
            }
            if catalog.activeOverride(for: slug) != nil {
                ActionChip(systemImage: "arrow.uturn.backward", tint: Theme.textSecondary,
                           help: "改回内置价格表的值") {
                    catalog.revert(slug: slug)
                }
            }
            ActionChip(systemImage: editing == slug ? "xmark" : "slider.horizontal.3",
                       tint: editing == slug ? Theme.textSecondary : Theme.Ink.claude,
                       help: editing == slug ? "收起编辑" : "编辑这一行的价格") {
                        editing = editing == slug ? nil : slug
            }
        }
    }
}

// MARK: - Inline editor

/// The row-level editor. Four buckets, a currency, and the day the price takes
/// effect — the last one is the field that makes a correction honest, because
/// back-dating it is what would re-cost usage already recorded.
private struct PriceEditor: View {
    let slug: String
    let existing: ModelPricing.PriceOverride?
    let onDone: () -> Void

    @ObservedObject private var catalog = ModelPriceCatalog.shared

    @State private var currency: ModelPricing.Currency = .cny
    @State private var input = ""
    @State private var output = ""
    @State private var cacheRead = ""
    @State private var cacheWrite = ""
    @State private var from = ModelPricing.dayKey(Date())
    @State private var unpriced: ModelPricing.Unpriced?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("币种", selection: $currency) {
                    ForEach(ModelPricing.Currency.allCases, id: \.self) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .help("厂商自己用哪种货币刊例价；本应用不做汇率换算")

                Spacer()

                Picker("无价", selection: $unpriced) {
                    Text("按量计价").tag(ModelPricing.Unpriced?.none)
                    Text("订阅制").tag(ModelPricing.Unpriced?.some(.subscription))
                    Text("未公开价").tag(ModelPricing.Unpriced?.some(.notPublished))
                }
                .labelsHidden()
                .frame(width: 120)
                .help("该模型没有按 token 的刊例价时选这里，它会被排除在合计之外并说明原因")
            }

            if unpriced == nil {
                HStack(spacing: 8) {
                    field("输入", $input)
                    field("输出", $output)
                    field("缓存读", $cacheRead)
                    field("缓存写", $cacheWrite)
                }
                Text("单位：\(currency.code) / 百万 token。缓存写没有独立档时填与输入相同（多数厂商这样计费）。")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textTertiary())
            }

            HStack(spacing: 8) {
                Text("自")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textSecondary)
                TextField("2026-09-30", text: $from)
                    .textFieldStyle(InstrumentFieldStyle(onCard: false))
                    .frame(width: 120)
                    .help("生效日期。此日期之前的用量保持原价，之后的按新价计算")
                Text("起生效")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                ActionButton("取消", tone: .neutral, action: onDone)
                ActionButton("保存", tone: .accent, action: commit)
            }

            if let error {
                Text(error)
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.Ink.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let existing, existing.effectiveFrom != from, from < ModelPricing.dayKey(Date()) {
                Text("注意：这个日期在已有用量之前，改价会重算该日期之后已经记录的花费。")
                    .font(Theme.Font.micro)
                    .foregroundColor(Theme.Ink.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Theme.fieldWell, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .onAppear(perform: seed)
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.Font.micro)
                .foregroundColor(Theme.textSecondary)
            TextField("0", text: text)
                .textFieldStyle(InstrumentFieldStyle(onCard: false))
                .frame(width: 64)
                .help("\(label)单价，每百万 token")
        }
    }

    private func seed() {
        guard let existing else {
            // A new row starts from whatever the table resolves today, so the
            // user is editing a plausible price rather than a blank.
            if case .priced(let rate)? = catalog.resolution(for: slug) {
                fill(from: rate)
            }
            return
        }
        from = existing.effectiveFrom
        unpriced = existing.unpriced
        if let rate = existing.rate {
            fill(from: rate)
        }
    }

    /// One rate → fields, shared by both seeding paths: today's table for a new
    /// row, the stored override for an edit.
    private func fill(from rate: ModelPricing.Rate) {
        currency = rate.currency
        input = ModelPriceCard.rateTextFor(rate.input)
        output = ModelPriceCard.rateTextFor(rate.output)
        cacheRead = ModelPriceCard.rateTextFor(rate.cacheRead)
        cacheWrite = ModelPriceCard.rateTextFor(rate.cacheWrite)
    }

    private func commit() {
        do {
            if let unpriced {
                try catalog.record(slug: slug, rate: nil, unpriced: unpriced,
                                   effectiveFrom: from, source: .manual)
            } else {
                guard let inputValue = Double(input), let outputValue = Double(output) else {
                    error = "请填写输入与输出单价"
                    return
                }
                // A vendor with no separate write bucket bills a write as a
                // miss; defaulting to the input price is that vendor's own
                // rule, not a guess, and an empty field means exactly that.
                let readValue = Double(cacheRead) ?? inputValue * 0.1
                let writeValue = Double(cacheWrite) ?? inputValue
                let rate = ModelPricing.Rate(currency: currency,
                                             input: inputValue,
                                             output: outputValue,
                                             cacheRead: readValue,
                                             cacheWrite: writeValue)
                try catalog.record(slug: slug, rate: rate, effectiveFrom: from,
                                   source: existing?.source == .fetchedCNY || existing?.source == .fetchedUSD
                                       ? .fetchedAndEdited : .manual,
                                   sourceURL: existing?.sourceURL,
                                   note: existing?.note)
            }
            error = nil
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
