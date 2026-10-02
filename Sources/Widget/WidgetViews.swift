import SwiftUI
import WidgetKit

/// Local copy of the main-app palette tokens so the Widget (which compiles as
/// an independent appex target and cannot import `Theme`) stays visually
/// consistent with the main app. Mirrors `Sources/ClaudeBar/Theme/Theme.swift`
/// — keep both sides in sync when a token changes.
///
/// The app's appearance is an *authored* toggle (`AppearanceMode`), not
/// "follow system", so the widget cannot derive it from `colorScheme`: it
/// arrives in the snapshot (`WidgetSnapshot.isDark`) and only falls back to
/// the system scheme for a snapshot written by an older build.
struct WidgetPalette {
    let isDark: Bool

    // MARK: Foundation

    var bgPrimary: Color { isDark ? Color(hex: 0x16181C) : Color(hex: 0xEEF3F8) }
    var bgSecondary: Color { isDark ? Color(hex: 0x1E2228) : Color(hex: 0xF7FAFC) }
    var accent: Color { isDark ? Color(hex: 0x5B9CFF) : Color(hex: 0x2B62D6) }
    var cursorAccent: Color { isDark ? Color(hex: 0xA99BFF) : Color(hex: 0x7A34B8) }

    /// Idle dot / neutral indicator. Solid rather than a 50 %-alpha wash of
    /// `statusIdle`: at that alpha the dot was ~1.5:1 on the dark card and
    /// effectively invisible.
    var idleDot: Color { isDark ? Color(hex: 0xA8ADB4) : Color(hex: 0x6C6C70) }
    var busyDot: Color { isDark ? Color(hex: 0x6EA8FF) : Color(hex: 0x1D4FB8) }
    /// A session parked on the user. The main app's `statusWarning` reads on
    /// the widget's darker card as well as the ice canvas, and it is already
    /// the hue the context gauge uses for its middle band — the widget has one
    /// amber, so this is it.
    var waitingDot: Color { Color(hex: 0xFF9F0A) }

    // MARK: Text

    var textPrimary: Color { isDark ? Color(hex: 0xF5F5F7) : Color(hex: 0x1C1C1E) }
    var textSecondary: Color { isDark ? Color(hex: 0xA8ADB4) : Color(hex: 0x6E6E73) }
    /// Tertiary text stays legible: the main app's `0.38` default measures
    /// 2.6:1 on the ice canvas, which is fine there only because it is used
    /// for large/decorative labels — the widget uses it for real captions.
    var textTertiary: Color {
        isDark ? Color.white.opacity(0.58) : Color.black.opacity(0.56)
    }

    var cardFill: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06) }

    // MARK: Context health — same 0.6 / 0.85 thresholds as the main app.

    /// Fill color for the context bar (a graphic, not text).
    func contextFill(_ ratio: Double) -> Color {
        if ratio < 0.6 { return isDark ? Color(hex: 0x5B9CFF) : Color(hex: 0x3D7DFF) }
        if ratio < 0.85 { return Color(hex: 0xFF9F0A) }
        return isDark ? Color(hex: 0xFF6B61) : Color(hex: 0xFF3B30)
    }

    /// The same three states as *text ink*. The chart hues above measure
    /// 1.8–3.4:1 on the light canvas, so they cannot carry the "NN %" label.
    func contextInk(_ ratio: Double) -> Color {
        if ratio < 0.6 { return isDark ? Color(hex: 0x6EA8FF) : Color(hex: 0x1D4FB8) }
        if ratio < 0.85 { return isDark ? Color(hex: 0xFFB340) : Color(hex: 0x8A4B00) }
        return isDark ? Color(hex: 0xFF6B61) : Color(hex: 0xB3261C)
    }
}

/// Hash-stable per-model tint mirroring `Theme.barGradient(for:)`. Fills, so
/// the saturated palette is correct in both schemes.
private enum WidgetBars {
    static let palette: [Color] = [
        Color(hex: 0x5B9CFF),
        Color(hex: 0xBF5AF2),
        Color(hex: 0x34C759),
        Color(hex: 0xFF9F0A),
        Color(hex: 0xFF3B30),
    ]

    static func color(for model: String) -> Color {
        // djb2 — stable across launches/processes so Widget matches the main
        // app's tint for the same model (String.hashValue is NOT stable).
        //
        // The `% Int.max` step is `Theme.djb2`'s, and dropping it is a real
        // divergence rather than a rounding detail: `2^63-1 ≡ 2 (mod 5)`, so
        // the two indices differ by two for every hash at or above `Int.max`.
        // Of the 56 slugs in the bundled price table, 19 came out a different
        // colour in the widget than in the popup — e.g. `gpt-5-codex` was
        // violet in the app and amber here.
        var h: UInt64 = 5_381
        for b in model.utf8 { h = (h &* 33) &+ UInt64(b) }
        return palette[Int(h % UInt64(Int.max)) % palette.count]
    }

    static func gradient(for model: String) -> LinearGradient {
        let c = color(for: model)
        return LinearGradient(colors: [c, c.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
    }
}

extension Color {
    fileprivate init(hex: UInt, opacity: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: opacity)
    }
}

/// How many models get a bar *and* a legend entry. One number for both: the
/// bar row used to render `prefix(5)` while the legend rendered `prefix(4)`,
/// so the last bar had no label and the two rows disagreed about the data.
private let modelSlots = 4

struct WidgetEntryView: View {
    let entry: WidgetEntry

    @Environment(\.colorScheme) private var colorScheme

    private var palette: WidgetPalette {
        WidgetPalette(isDark: entry.snapshot.isDark ?? (colorScheme == .dark))
    }

    var body: some View {
        let s = entry.snapshot
        let p = palette
        // A Codex-only user has no Claude sessions and no Cursor sessions, so
        // this used to render "暂无数据" over a non-empty payload.
        let isEmpty = s.todayTotalTokens == 0
            && s.totalSessionCount == 0
            && s.cursorSessions.isEmpty
            && s.externalSessions.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            if isEmpty {
                Spacer()
                Text("暂无数据")
                    .font(.system(size: 14))
                    .foregroundColor(p.textTertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                header(s, p)
                providerLine(s, p)
                modelBars(s, p)
                sessionSection(s, p)
                cursorSection(s, p)
                externalSection(s, p)
                Spacer(minLength: 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            p.bgPrimary
        }
    }

    // MARK: - Header (token total + balance)

    private func header(_ s: WidgetSnapshot, _ p: WidgetPalette) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ClaudeBar")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(p.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatTokens(s.todayTotalTokens, style: s.unitStyle))
                        .font(.system(size: 28, weight: .semibold))
                        .widgetRollingNumber()
                        .foregroundColor(p.textPrimary)
                    // "今天" / "9月" / "2026年" — the total belongs to the
                    // period the user is browsing, which is not always today.
                    Text(s.usagePeriodLabel ?? "Token")
                        .font(.system(size: 9))
                        .foregroundColor(p.textTertiary)
                }
            }
            Spacer()
            if let bal = s.balanceText {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("余额")
                        .font(.system(size: 9))
                        .foregroundColor(p.textTertiary)
                    // `balanceText` already carries its currency symbol.
                    Text(bal)
                        .font(.system(size: 15, weight: .semibold))
                        .widgetRollingNumber()
                        .foregroundColor(p.accent)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    // MARK: - Provider + freshness

    private func providerLine(_ s: WidgetSnapshot, _ p: WidgetPalette) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(p.accent)
                .frame(width: 6, height: 6)
            Text(s.activeProviderName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(p.textSecondary)
            Text(s.activeModelName)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(p.textTertiary)
                .lineLimit(1)
            Spacer()
            Text(relativeTime(s.updatedAt))
                .widgetRollingNumber()
                .font(.system(size: 9))
                .foregroundColor(p.textTertiary)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    // MARK: - Model breakdown

    @ViewBuilder
    private func modelBars(_ s: WidgetSnapshot, _ p: WidgetPalette) -> some View {
        let models = Array(s.modelBreakdown.prefix(modelSlots))
        if models.count > 1 {
            // Widths come from the real container rather than a hard-coded
            // 260pt: the large widget is ~330pt wide and the row is inset by
            // 16pt on each side, so the absolute-width version overflowed (or
            // under-filled) depending on the widget size.
            GeometryReader { geo in
                HStack(spacing: 2) {
                    let widths = barWidths(models,
                                           available: geo.size.width,
                                           spacing: 2)
                    ForEach(Array(models.enumerated()), id: \.element.model) { index, m in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(WidgetBars.gradient(for: m.model))
                            .frame(width: widths[index])
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 16).padding(.top, 8)

            HStack(spacing: 10) {
                ForEach(models, id: \.model) { m in
                    HStack(spacing: 3) {
                        Circle().fill(WidgetBars.color(for: m.model)).frame(width: 4, height: 4)
                        Text(truncateModel(m.model))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(p.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 6)
        }
    }

    /// Proportional segment widths with a small floor, scaled back down when
    /// the floors would push the row past the available width.
    private func barWidths(_ models: [WidgetSnapshot.ModelTokenUsage],
                           available: CGFloat,
                           spacing: CGFloat) -> [CGFloat] {
        let gaps = spacing * CGFloat(max(0, models.count - 1))
        let usable = max(0, available - gaps)
        guard usable > 0 else { return models.map { _ in 0 } }
        let total = max(1, models.reduce(0) { $0 + max(0, $1.totalTokens) })
        let floor: CGFloat = 3
        var widths = models.map { usable * CGFloat(max(0, $0.totalTokens)) / CGFloat(total) }
        for i in widths.indices where widths[i] < floor { widths[i] = floor }
        let used = widths.reduce(0, +)
        if used > usable {
            let scale = usable / used
            widths = widths.map { $0 * scale }
        }
        return widths
    }

    // MARK: - Sections

    /// "· N 待确认" appended to a section's detail line, empty when there are
    /// none. Waiting sessions are the ones the *user* has to act on, so the
    /// header has to say they exist — counting them under 运行中 would hide the
    /// only number on the widget that asks for anything.
    private func waitingSuffix(_ count: Int) -> String {
        count > 0 ? " · \(count) 待确认" : ""
    }

    @ViewBuilder
    private func sessionSection(_ s: WidgetSnapshot, _ p: WidgetPalette) -> some View {
        if !s.sessions.isEmpty {
            // The carried totals, not the payload's row count: the host caps
            // `sessions` at five rows, so counting them reported "5 个" on a
            // machine with more — and a busy count drawn only from the first
            // five. `totalSessionCount` / `busySessionCount` exist on the
            // snapshot for exactly this.
            sectionHeader(title: "活跃会话",
                          detail: "\(s.totalSessionCount) 个 · \(s.busySessionCount) 运行中"
                              + waitingSuffix(s.sessions.filter { $0.status == "waiting" }.count),
                          icon: nil,
                          p: p,
                          topPadding: 10)

            ForEach(s.sessions.prefix(3), id: \.pid) { session in
                sessionRow(session, p)
            }
        }
    }

    @ViewBuilder
    private func cursorSection(_ s: WidgetSnapshot, _ p: WidgetPalette) -> some View {
        if !s.cursorSessions.isEmpty {
            // Cursor's own cube, the same artwork the app's headers draw.
            sectionHeader(title: "Cursor",
                          detail: "\(s.cursorSessions.count) · \(s.cursorSessions.filter { $0.status == "active" }.count) 活跃"
                              + waitingSuffix(s.cursorSessions.filter { $0.status == "waiting" }.count),
                          icon: nil,
                          p: p,
                          topPadding: s.sessions.isEmpty ? 10 : 6,
                          mark: .cursor)

            ForEach(s.cursorSessions.prefix(3), id: \.composerId) { session in
                cursorSessionRow(session, p)
            }
        }
    }

    @ViewBuilder
    private func externalSection(_ s: WidgetSnapshot, _ p: WidgetPalette) -> some View {
        if !s.externalSessions.isEmpty {
            // The appex cannot import `Theme`, so the widget carries its own
            // copy of the app's identity marks (`WidgetBrandMark`). That is the
            // same arrangement as `WidgetPalette` below: the surface is a
            // separate target and the tokens are mirrored, not shared.
            sectionHeader(title: "Codex",
                          detail: "\(s.externalSessions.count) · \(s.externalSessions.filter { $0.status == "busy" }.count) 运行中"
                              + waitingSuffix(s.externalSessions.filter { $0.status == "waiting" }.count),
                          icon: nil,
                          p: p,
                          topPadding: (s.sessions.isEmpty && s.cursorSessions.isEmpty) ? 10 : 6,
                          brand: true)

            ForEach(s.externalSessions.prefix(3), id: \.id) { session in
                externalSessionRow(session, p)
            }
        }
    }

    /// The client families' marks, for the widget target.
    ///
    /// **Why a copy.** The appex compiles `Sources/Widget/*.swift` and nothing
    /// else (`Sources/build.sh`), and it cannot import `Theme`: the app's
    /// `ProductBrandMark` lives in `Views/Shared` and reads `Theme.isDark` /
    /// `Theme.bgSecondary`, so it is not in this target's scope at all. That is
    /// the same situation, and the same answer, as `WidgetPalette` above — the
    /// surface is a separate process with its own bundle, so the *values* are
    /// mirrored rather than shared. Keeping the asset names and the well's inset
    /// identical to the app's is what makes the two surfaces draw one mark.
    ///
    /// It reads the same normalised PNGs: `Sources/build.sh` copies
    /// `Sources/BrandAssets` into the appex's `Contents/Resources/BrandAssets`,
    /// because an extension resolves `Bundle.main` to itself — without that copy
    /// the widget would silently draw the fallback with no build error.
    private struct WidgetBrandMark: View {
        /// The four families, mirroring `ProductBrandMark.Brand` in the app.
        /// Cursor is artwork here too: the appex cannot import the app's type,
        /// and the widget's Cursor section header had the same wrong glyph.
        /// `claudebar` mirrors the app's own mark (its icon's rings) for the one
        /// tally that names no other product.
        enum Brand {
            case claude, codex, cursor, claudebar

            /// `false` = CC, `true` = Codex — the app's own convention, kept so
            /// a call site reads the same in both targets.
            init(codex: Bool) { self = codex ? .codex : .claude }

            var asset: String {
                switch self {
                case .claude: return "anthropic"
                case .codex: return "openai"
                case .cursor: return "cursor"
                case .claudebar: return "claudebar"
                }
            }

            var label: String {
                switch self {
                case .claude: return "Claude Code"
                case .codex: return "Codex"
                case .cursor: return "Cursor"
                case .claudebar: return "第三方"
                }
            }
        }

        let brand: Brand

        /// The one initialiser: declaring the two convenience inits below
        /// suppresses the memberwise one, so `dark:` has no other way in and
        /// every spelling has to list it. See the same shape in the app's
        /// `ProductBrandMark`.
        init(brand: Brand, dark: Bool) {
            self.brand = brand
            self.dark = dark
        }
        init(codex: Bool, dark: Bool) {
            self.init(brand: Brand(codex: codex), dark: dark)
        }
        /// The snapshot's *authored* appearance, not the system one — see the
        /// note on `WidgetPalette`. `true` = the widget is drawn dark, so it
        /// needs **white** ink.
        var dark: Bool

        private var asset: String { brand.asset }

        var body: some View {
            // `artworkIsDark` selects the *file*, and LobeHub's `-dark` file is
            // the **white** mark (measured; see `ProductBrandMark.page:` in the
            // app). A dark widget therefore needs `artworkIsDark: true`, which is
            // what `dark` already means — this used to pass `!dark` and drew
            // black ink on a black ground, the same inversion the app had.
            if let image = Self.image(asset, artworkIsDark: dark) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 11, height: 11)
                    .accessibilityLabel(brand.label)
            } else {
                // A missing resource must not read as "no client": fall back to
                // the family's own initial rather than a blank.
                Text(String(brand.label.prefix(1)))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(WidgetPalette(isDark: dark).textPrimary)
            }
        }

        /// Decoded once per variant: a section header is rebuilt for every
        /// timeline entry, and `NSImage(contentsOf:)` decodes the PNG each call.
        private static let cache = NSCache<NSString, NSImage>()

        /// `artworkIsDark` is the *file* variant: `true` = LobeHub's `-dark`
        /// asset, which is the **white** ink. The cache key is built from the
        /// same parameter, so the ink and the key cannot disagree.
        private static func image(_ asset: String, artworkIsDark: Bool) -> NSImage? {
            let key = "\(asset)-\(artworkIsDark ? "dark" : "light")"
            if let hit = cache.object(forKey: key as NSString) { return hit }
            guard let root = Bundle.main.resourceURL?.appendingPathComponent("BrandAssets", isDirectory: true),
                  let image = NSImage(contentsOf: root.appendingPathComponent("\(key).png")) else { return nil }
            cache.setObject(image, forKey: key as NSString)
            return image
        }
    }

    private func sectionHeader(title: String,
                               detail: String,
                               icon: String?,
                               p: WidgetPalette,
                               topPadding: CGFloat,
                               brand: Bool? = nil,
                               mark: WidgetBrandMark.Brand? = nil) -> some View {
        HStack(spacing: 4) {
            if let mark {
                WidgetBrandMark(brand: mark, dark: p.isDark)
            } else if let brand {
                WidgetBrandMark(codex: brand, dark: p.isDark)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(p.textTertiary)
            }
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(p.textTertiary)
            Spacer()
            Text(detail)
                .font(.system(size: 9))
                .widgetRollingNumber()
                .foregroundColor(p.textTertiary)
        }
        .padding(.horizontal, 16).padding(.top, topPadding).padding(.bottom, 4)
    }

    // MARK: - Session rows

    private func sessionRow(_ s: WidgetSnapshot.SessionSummary, _ p: WidgetPalette) -> some View {
        let isBusy = s.status == "busy"
        let isWaiting = s.status == "waiting"
        return HStack(spacing: 8) {
            Circle()
                .fill(isWaiting ? p.waitingDot : (isBusy ? p.busyDot : p.idleDot))
                .frame(width: 6, height: 6)

            rowTitle(s.projectFolder.isEmpty ? "session-\(s.pid)" : s.projectFolder,
                     detail: s.currentActivity,
                     p: p)

            Spacer()

            contextBar(percentText: "\(Int(s.contextRatio * 100))%",
                       ratio: s.contextRatio,
                       fill: p.contextFill(s.contextRatio),
                       ink: p.contextInk(s.contextRatio),
                       p: p)
        }
        .padding(.horizontal, 16).padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func cursorSessionRow(_ s: WidgetSnapshot.CursorSessionSummary, _ p: WidgetPalette) -> some View {
        let isActive = s.status == "active"
        let isWaiting = s.status == "waiting"
        return HStack(spacing: 8) {
            Circle()
                .fill(isWaiting ? p.waitingDot : (isActive ? p.cursorAccent : p.idleDot))
                .frame(width: 6, height: 6)

            rowTitle(s.projectFolder.isEmpty ? "cursor" : s.projectFolder,
                     detail: s.currentActivity,
                     p: p)

            Spacer()

            // Cursor exposes a fill percentage rather than token counts.
            contextBar(percentText: s.relativeUpdated,
                       ratio: s.contextRatio,
                       fill: p.cursorAccent,
                       ink: p.textTertiary,
                       p: p,
                       visible: s.contextPercent >= 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func externalSessionRow(_ s: WidgetSnapshot.ExternalSessionSummary, _ p: WidgetPalette) -> some View {
        let isBusy = s.status == "busy"
        // "waiting" cannot occur for a current Codex build (see
        // `ExternalSessionInfo.isWaiting`); the branch is here so all three
        // agents' rows read the same vocabulary and a future signal needs no
        // widget change.
        let isWaiting = s.status == "waiting"
        return HStack(spacing: 8) {
            Circle()
                .fill(isWaiting ? p.waitingDot : (isBusy ? p.busyDot : p.idleDot))
                .frame(width: 6, height: 6)

            rowTitle(s.projectFolder.isEmpty ? "codex" : s.projectFolder,
                     detail: s.model.isEmpty ? s.relativeUpdated : s.model,
                     p: p)

            Spacer()

            contextBar(percentText: "\(Int(s.contextRatio * 100))%",
                       ratio: s.contextRatio,
                       fill: p.contextFill(s.contextRatio),
                       ink: p.contextInk(s.contextRatio),
                       p: p,
                       visible: s.contextLimit > 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func rowTitle(_ title: String, detail: String, p: WidgetPalette) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(p.textPrimary)
                .lineLimit(1)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(p.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func contextBar(percentText: String,
                            ratio: Double,
                            fill: Color,
                            ink: Color,
                            p: WidgetPalette,
                            visible: Bool = true) -> some View {
        if visible {
            VStack(alignment: .trailing, spacing: 2) {
                Text(percentText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .widgetRollingNumber()
                    .foregroundColor(ink)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(p.cardFill)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(fill)
                            .frame(width: geo.size.width * min(max(ratio, 0), 1))
                    }
                }
                .frame(width: 54, height: 3)
            }
        }
    }

    // MARK: - Formatting

    /// `style` is the raw `TokenUnitStyle` from the snapshot. The widget
    /// process has its own `UserDefaults.standard` — the app's domain is not
    /// visible to it, so reading the key here always missed and every widget
    /// silently used the 万/亿 default.
    private func formatTokens(_ n: Int, style: String?) -> String {
        if style == "metric" {
            if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
            if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
            if n >= 1_000 { return String(format: "%dK", Int(round(Double(n) / 1_000))) }
            return "\(n)"
        }
        // Mirrors UsageStats.formatTokens(.chinese): one decimal, no padding.
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
        if n >= 10_000 { return String(format: "%.1f万", Double(n) / 10_000) }
        if n >= 1_000 { return String(format: "%dK", Int(round(Double(n) / 1_000))) }
        return "\(n)"
    }

    private func truncateModel(_ name: String) -> String {
        if name.count > 16 { return String(name.prefix(16)) + "…" }
        return name
    }

    /// Freshness label in the app's language — the widget previously said
    /// "just now" / "5m ago" inside an otherwise all-Chinese surface.
    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }
}

/// The widget target cannot see `View.rollingNumber()` in the app. This is the
/// same transition: `.numericText(countsDown: true)`, digits only, no implicit
/// `.animation(value:)`.
private struct WidgetRollingNumber: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
    }
}

private extension View {
    func widgetRollingNumber() -> some View { modifier(WidgetRollingNumber()) }
}
