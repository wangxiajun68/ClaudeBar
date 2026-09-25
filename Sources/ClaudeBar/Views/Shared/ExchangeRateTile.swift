import SwiftUI

/// The exchange-rate control behind 设置 → 模型花费 → 显示货币.
///
/// Only shown once the display is set to a converted mode. Two things live
/// here that the user needs in order to trust a converted total: the rate and
/// its date, and a way to stop the app fetching one at all.
///
/// The manual field is the escape hatch for people who would rather not have
/// the app make an outbound request: pin a number and nothing is fetched, ever.
/// It is also the honest answer to "your rate is wrong" — the user's own bank
/// rate beats the ECB's mid-market rate for what they actually paid.
struct ExchangeRateTile: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @ObservedObject private var fx = ExchangeRate.shared
    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        SettingTile(icon: "arrow.left.arrow.right", title: "汇率",
                    caption: caption, tint: Theme.chartGreen) {
            HStack(spacing: 6) {
                rateField
                Button(fx.isFetching ? "查询中…" : "更新") { fx.refresh() }
                    .adaptiveGlassButton()
                    .disabled(fx.isFetching)
            }
        }
    }

    /// While editing, a plain `TextField` — the same choice the API-key field
    /// makes, for the same reason: `SecureField`-style affordances here would
    /// fight the system's password manager over what is not a secret.
    @ViewBuilder
    private var rateField: some View {
        if editing {
            TextField("7.2", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
                .onSubmit(commit)
                // Losing focus is a commit, not a cancel: a half-typed number
                // left in the box while the user clicks elsewhere is almost
                // always meant to be applied, and there is no other way to
                // finish editing on a settings tile.
                .onChange(of: editing) { _, isEditing in if !isEditing { commit() } }
        } else {
            Button(buttonLabel) {
                draft = fx.effectiveRate.map { String(format: "%.4f", $0) } ?? ""
                editing = true
            }
            .adaptiveGlassButton()
            .help(fx.isManual ? "改为使用实时汇率；点击可编辑手动值" : "手动指定汇率；设定后不再联网查询")
        }
    }

    private var buttonLabel: String {
        guard let rate = fx.effectiveRate else { return "手动" }
        return String(format: "%.4f", rate)
    }

    private var caption: String {
        if let error = fx.lastError { return error }
        if fx.isManual {
            return "手动汇率，不会联网查询。点数字可改回实时汇率。"
        }
        guard let note = fx.note else {
            return fx.isFetching ? "正在查询汇率…" : "点击「更新」获取实时汇率。"
        }
        return "\(note)。点数字可改用手动汇率。"
    }

    /// Accept a plausible rate, clear the override on anything else.
    ///
    /// The bounds are not a prediction — 1 CNY per USD and 20 CNY per USD are
    /// both far outside any plausible range, and a fat-fingered `72` typed into
    /// a field prefilled with `7.2` would otherwise inflate every converted
    /// figure tenfold with no error anywhere.
    private func commit() {
        editing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            prefs.manualUSDToCNY = nil
            return
        }
        guard let value = Double(trimmed), value > 1, value < 20 else {
            // An unusable entry clears the override rather than keeping the
            // previous manual value silently in place — the field showed what
            // was typed, so keeping the old number would contradict it.
            prefs.manualUSDToCNY = nil
            draft = ""
            return
        }
        prefs.manualUSDToCNY = value
    }
}
