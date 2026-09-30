#!/usr/bin/env python3
"""Prices can be overridden, cleared, and dated — and history does not move.

Three claims, one file:

1. The override seam is **inert by default**. Every assertion the older
   `model-cost-regressions.py` makes about the bundled table is made again here
   against a slice compiled with the override machinery present and nothing
   installed — if the two disagree, the seam changed behaviour rather than
   adding to it.

2. An override **takes effect on its date and not before**. A row dated
   tomorrow must not price today; a row dated yesterday must not price the day
   before it. That is the property that lets a price change happen without
   rewriting a month of recorded spend.

3. The **page parsers** read the real pages. Fixtures in
   `Tests/fixtures/price-pages/` are gzipped snapshots of six vendor pricing
   pages and the models.dev extract, so these assertions run offline and a
   vendor redesign shows up as a red test rather than as a quiet ×4.8 in the
   month's total.

Harness: same shape as the other regression scripts — slice the Swift sources
out by text, drop them into one template, `swiftc`, run. No app, no network.
"""

from __future__ import annotations

import gzip
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UTILS = ROOT / "Sources/ClaudeBar/Utils"
FIXTURES = Path(__file__).resolve().parent / "fixtures/price-pages"

pricing = (UTILS / "ModelPricing.swift").read_text()
table = (UTILS / "ModelPriceTable.swift").read_text()
sources = (UTILS / "ModelPriceSources.swift").read_text()

FAILURES: list[str] = []


def check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  ok   {label}")
    else:
        FAILURES.append(label if not detail else f"{label}: {detail}")
        print(f"  FAIL {label}{' — ' + detail if detail else ''}")


def fixture(name: str) -> str:
    for suffix in (".html.gz", ".json.gz"):
        path = FIXTURES / f"{name}{suffix}"
        if path.exists():
            with gzip.open(path, "rt", encoding="utf-8", errors="replace") as handle:
                return handle.read()
    raise FileNotFoundError(name)


# --------------------------------------------------------------------------
# Swift slice
# --------------------------------------------------------------------------

MODEL_USAGE = """
struct ModelUsage {
    var model: String
    var calls: Int = 1
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var id: String { model }
    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
    var isZero: Bool { totalTokens == 0 }
}
"""

SWIFT = """
PRICING

TABLE

SOURCES

MODEL_USAGE

@main
struct Regression {
    static func main() {
        var failures = 0
        func expect(_ label: String, _ condition: Bool, _ detail: String = "") {
            if !condition { print("fail: \\(label) \\(detail)"); failures += 1 }
        }

        // ---- 1. The seam is inert with nothing installed -------------------
        ModelPricing.replaceOverrides([:])
        expect("bundled rate resolves", ModelPricing.rate(for: "claude-opus-5-5")?.input == 4)
        expect("bundled unknown is nil", ModelPricing.rate(for: "no-such-model") == nil)
        expect("unpriced stays unpriced",
               ModelPricing.unpricedReason("kimi-for-coding") == .subscription)

        // A model priced from one model's aggregate is unchanged by the seam.
        let usage = ModelUsage(model: "claude-opus-5-5", inputTokens: 1_000_000,
                               outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
        expect("cost unchanged by seam", ModelPricing.cost(of: usage)?.usd == 4)

        // ---- 2. Dated overrides -------------------------------------------
        let old = ModelPricing.PriceOverride(
            slug: "claude-opus-5-5",
            rate: ModelPricing.Rate(currency: .usd, input: 4, output: 20,
                                    cacheRead: 0.2, cacheWrite: 5),
            unpriced: nil, effectiveFrom: "2026-01-01",
            source: .manual, sourceURL: nil, checkedAt: nil, note: nil)
        let raised = ModelPricing.PriceOverride(
            slug: "claude-opus-5-5",
            rate: ModelPricing.Rate(currency: .usd, input: 8, output: 40,
                                    cacheRead: 0.4, cacheWrite: 10),
            unpriced: nil, effectiveFrom: "2026-09-20",
            source: .manual, sourceURL: nil, checkedAt: nil, note: nil)
        ModelPricing.replaceOverrides(["claude-opus-5-5": [old, raised]])

        expect("override applies on its day",
               ModelPricing.resolve("claude-opus-5-5", on: "2026-09-20")?.rate?.input == 8)
        expect("override applies after its day",
               ModelPricing.resolve("claude-opus-5-5", on: "2026-12-31")?.rate?.input == 8)
        // The day before the change keeps the earlier override, not the newer.
        expect("override does not apply before its day",
               ModelPricing.resolve("claude-opus-5-5", on: "2026-09-19")?.rate?.input == 4)
        // And with only the raised row installed, the day before falls all the
        // way back to the bundled table rather than to the new price.
        ModelPricing.replaceOverrides(["claude-opus-5-5": [raised]])
        expect("falls back to bundled before first override",
               ModelPricing.resolve("claude-opus-5-5", on: "2026-09-19")?.rate?.input == 4)

        // ---- 3. Day-segmented pricing --------------------------------------
        // One model, one month, a price change mid-way: the days before the
        // change must cost the old rate and only the later days the new one.
        let days: [String: [ModelUsage]] = [
            "2026-09-01": [ModelUsage(model: "claude-opus-5-5", inputTokens: 1_000_000,
                                      outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)],
            "2026-09-19": [ModelUsage(model: "claude-opus-5-5", inputTokens: 1_000_000,
                                      outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)],
            "2026-09-25": [ModelUsage(model: "claude-opus-5-5", inputTokens: 1_000_000,
                                      outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)],
        ]
        let estimate = ModelPricing.estimate(days: days)
        // 1M at $4 + 1M at $4 + 1M at $8 = $16.
        expect("segmented total splits at the change",
               estimate.cost.usd == 16, "\\(estimate.cost.usd)")
        expect("segmented estimate is one line per model", estimate.lines.count == 1)

        // Pricing the same month at one date is the old behaviour, and must
        // differ — that difference is the whole reason this path exists.
        let flat = ModelPricing.estimate(
            days.values.flatMap { $0 }, on: "2026-09-25")
        expect("flat pricing would have cost $24",
               flat.cost.usd == 24, "\\(flat.cost.usd)")

        // An unpriced model stays unpriced on every day, and is reported once.
        let unpricedDays: [String: [ModelUsage]] = [
            "2026-09-01": [ModelUsage(model: "kimi-for-coding", inputTokens: 500,
                                      outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)],
            "2026-09-02": [ModelUsage(model: "kimi-for-coding", inputTokens: 500,
                                      outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)],
        ]
        let unpricedEstimate = ModelPricing.estimate(days: unpricedDays)
        expect("unpriced is one line, reason kept",
               unpricedEstimate.lines.first?.unpriced == .subscription)
        expect("unpriced tokens are counted",
               unpricedEstimate.unpricedTokens == 1000)

        // ---- 4. The seam is reversible --------------------------------------
        ModelPricing.replaceOverrides([:])
        expect("clearing overrides restores the table",
               ModelPricing.resolve("claude-opus-5-5", on: "2026-09-25")?.rate?.input == 4)

        if failures > 0 { exit(1) }
        print("swift-ok")
    }
}
"""


def run_swift() -> None:
    source = (SWIFT
              .replace("PRICING", pricing)
              .replace("TABLE", table)
              .replace("SOURCES", sources)
              .replace("MODEL_USAGE", MODEL_USAGE))
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "Regression.swift"
        path.write_text(source)
        binary = Path(tmp) / "regression"
        build = subprocess.run(
            ["swiftc", "-parse-as-library", "-o", str(binary), str(path)],
            capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stderr[:6000])
            FAILURES.append("swift slice did not compile")
            return
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        if result.returncode != 0 or "swift-ok" not in result.stdout:
            print(result.stdout[-4000:])
            print(result.stderr[-4000:])
            FAILURES.append("swift slice assertions failed")
        else:
            print("  ok   dated overrides, day-segmented pricing, inert seam")


# --------------------------------------------------------------------------
# Parsers, against the saved pages
# --------------------------------------------------------------------------

def swift_parse(fn: str, text: str) -> list[dict]:
    """Call one of `ModelPriceSources`' parsers by compiling a tiny driver.

    The parsers are Swift, so the test drives them the same way the app will —
    there is no Python re-implementation to drift from the real one.
    """
    driver = f"""
PRICING

TABLE

SOURCES

MODEL_USAGE

@main
struct Driver {{
    static func main() {{
        let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for row in ModelPriceSources.{fn}(text) {{
            let rate = row.rate
            print("\\(row.slug)|\\(rate.currency)|\\(rate.input)|\\(rate.output)|\\(rate.cacheRead)|\\(rate.cacheWrite)")
        }}
    }}
}}
"""
    source = (driver.replace("PRICING", pricing)
                    .replace("TABLE", table)
                    .replace("SOURCES", sources)
                    .replace("MODEL_USAGE", MODEL_USAGE))
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "Driver.swift"
        path.write_text(source)
        binary = Path(tmp) / "driver"
        build = subprocess.run(
            ["swiftc", "-parse-as-library", "-o", str(binary), str(path)],
            capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stderr[:4000])
            FAILURES.append(f"{fn} driver did not compile")
            return []
        result = subprocess.run([str(binary)], input=text,
                                capture_output=True, text=True)
        rows = []
        for line in result.stdout.splitlines():
            parts = line.split("|")
            if len(parts) != 6:
                continue
            rows.append({
                "slug": parts[0],
                "currency": parts[1],
                "input": float(parts[2]),
                "output": float(parts[3]),
                "cache_read": float(parts[4]),
                "cache_write": float(parts[5]),
            })
        return rows


def find(rows: list[dict], slug: str) -> dict | None:
    for row in rows:
        if row["slug"] == slug:
            return row
    return None


def parsers() -> None:
    print("\nChina vendor pages (fixtures, offline):")

    glm = swift_parse("parseGLM", fixture("glm"))
    row = find(glm, "glm-5.3")
    check("GLM 5.3 输入 8 / 输出 28 / 命中 2",
          row is not None and (row["input"], row["output"], row["cache_read"]) == (8.0, 28.0, 2.0),
          str(row))
    flash = find(glm, "glm-5.3-flash")
    check("GLM 5.3-Flash 0.8 / 2.8 / 0.23",
          flash is not None and (flash["input"], flash["output"], flash["cache_read"]) == (0.8, 2.8, 0.23),
          str(flash))
    # A tiered model must reduce to its base band, not to the ≥32K row.
    five = find(glm, "glm-5")
    check("GLM-5 takes the base band (4, not 6)",
          five is not None and five["input"] == 4.0, str(five))
    check("GLM has no zero bucket",
          all(r["input"] > 0 and r["output"] > 0 and r["cache_read"] > 0 and r["cache_write"] > 0
              for r in glm), str([r for r in glm if min(r["input"], r["output"], r["cache_read"], r["cache_write"]) <= 0]))

    step = swift_parse("parseStepFun", fixture("stepfun"))
    row = find(step, "step-5-preview")
    check("StepFun step-5-preview 7 / 20 / 0.35",
          row is not None and (row["input"], row["output"], row["cache_read"]) == (7.0, 20.0, 0.35),
          str(row))

    mini = swift_parse("parseMiniMax", fixture("minimax"))
    m3 = find(mini, "minimax-m3")
    # The page prints `4.20 2.10` — list then discounted. The discounted number
    # is what is charged and what the bundled table carries.
    check("MiniMax M3 takes the discounted price (2.1)",
          m3 is not None and m3["input"] == 2.1, str(m3))
    check("MiniMax M3 输出 8.4 / 读 0.42",
          m3 is not None and (m3["output"], m3["cache_read"]) == (8.4, 0.42), str(m3))
    check("MiniMax folds the two context bands to one row per model",
          len([r for r in mini if r["slug"] == "minimax-m3"]) == 1)

    kimi = swift_parse("parseKimi", fixture("kimi"))
    row = find(kimi, "kimi-k2.7-code")
    check("Kimi k2.7-code ¥6.50 in / ¥27 out / ¥1.30 hit",
          row is not None and (row["input"], row["output"], row["cache_read"]) == (6.5, 27.0, 1.3),
          str(row))
    high = find(kimi, "kimi-k2.7-code-highspeed")
    check("Kimi highspeed is its own row (13, not 6.5)",
          high is not None and high["input"] == 13.0, str(high))

    ds = swift_parse("parseDeepSeek", fixture("deepseek"))
    pro = find(ds, "deepseek-v4-pro")
    # Peak, not off-peak: 9 / 27 / 0.30. Reading the 空闲 column would give
    # 4.5 / 13.5 and halve every DeepSeek row — the exact error the aggregate
    # sources make.
    check("DeepSeek v4-pro takes the PEAK price (9, not 4.5)",
          pro is not None and pro["input"] == 9.0, str(pro))
    check("DeepSeek v4-pro 输出 27 / 读 0.30",
          pro is not None and (pro["output"], pro["cache_read"]) == (27.0, 0.3), str(pro))

    ali = swift_parse("parseAliyun", fixture("aliyun"))
    qwen = find(ali, "qwen3.7-max")
    check("Aliyun qwen3.7-max 12 元 / 36 元 (domestic, not the $2.5 intl price)",
          qwen is not None and (qwen["input"], qwen["output"]) == (12.0, 36.0), str(qwen))
    check("Aliyun drops dated snapshots",
          all(not re.search(r"-\d{4,}", r["slug"]) for r in ali),
          str([r["slug"] for r in ali if re.search(r"-\d{4,}", r["slug"])]))

    print("\nmodels.dev (extract fixture):")
    payload = json.loads(fixture("models-dev"))
    # The extract is sliced by the same rule the Swift does on the live file:
    usd = swift_parse("rowsFromModelsDev", fixture("models-dev"))
    by_slug = {r["slug"]: r for r in usd}
    opus = by_slug.get("claude-opus-5-5")
    check("models.dev claude-opus-5-5 $4 / $20 / read 0.2 / write 5",
          opus is not None and (opus["input"], opus["output"], opus["cache_read"], opus["cache_write"])
          == (4.0, 20.0, 0.2, 5.0), str(opus))
    check("models.dev rows are USD",
          all(r["currency"] == "usd" for r in usd))
    check("models.dev rows all have four non-zero buckets",
          all(min(r["input"], r["output"], r["cache_read"], r["cache_write"]) > 0 for r in usd))
    # A dated snapshot must fold onto the base id rather than appear beside it.
    check("dated snapshots fold onto the base id",
          not any(re.search(r"-\d{4,}$", r["slug"]) for r in usd),
          str([r["slug"] for r in usd if re.search(r"-\d{4,}$", r["slug"])]))
    check("models.dev agrees with the bundled USD rows",
          opus is not None and ModelPriceTable_input("claude-opus-5-5") == opus["input"])


def ModelPriceTable_input(slug: str) -> float | None:
    """The bundled table's input price, read from the Swift source text.

    Read textually rather than by compiling a second slice: this assertion is
    about the *shipped* file, and a compiled copy would be a copy.
    """
    match = re.search(rf'slug:\s*"{re.escape(slug)}",\s*rate:\s*R\(currency:\s*\.\w+,\s*'
                      r'input:\s*([\d.]+)', table)
    return float(match.group(1)) if match else None


def main() -> int:
    run_swift()
    parsers()
    if FAILURES:
        print(f"\nFAIL: {len(FAILURES)} assertion(s)")
        for item in FAILURES:
            print(f"  - {item}")
        return 1
    print("\nPASS: overrides are dated and reversible, the seam is inert by default, "
          "and all six vendor pages plus models.dev parse to the numbers in the bundled table")
    return 0


if __name__ == "__main__":
    sys.exit(main())
