#!/usr/bin/env python3
"""The six vendor pricing pages and the models.dev extract, parsed by the
production parsers.

These pages are the *only* input the fetch path has, and every failure they
can produce is silent and expensive: a parser that reads the wrong column
prices DeepSeek at half its rate, and a flatten that decodes `&lt;` before it
strips tags deletes the two numbers 阿里's page prints. Neither shows up as
an error — the card just shows a confidently wrong number.

The fixtures in `Tests/fixtures/price-pages/` are gzipped snapshots, so the
assertions run offline and a vendor redesign becomes a red test rather than a
quiet change in the month's total. Compiling the production parsers (no app,
no network) is what keeps the fixtures from drifting from the code.

Restored from 776f3b7^ along with this harness: the cleanup commit deleted
both, and that is how `parseAliyun` shipped unable to read a single row.
"""
from __future__ import annotations

import gzip
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UTILS = ROOT / "Sources/ClaudeBar/Utils"
FIXTURES = ROOT / "Tests/fixtures/price-pages"

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
    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
    var isZero: Bool { totalTokens == 0 }
}
"""

DRIVER = """
PRICING

TABLE

SOURCES

MODEL_USAGE

@main
struct Driver {
    static func main() {
        let name = CommandLine.arguments[1]
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let rows: [ModelPriceSources.ParsedRow]
        switch name {
        case "glm": rows = ModelPriceSources.parseGLM(text)
        case "stepfun": rows = ModelPriceSources.parseStepFun(text)
        case "minimax": rows = ModelPriceSources.parseMiniMax(text)
        case "deepseek": rows = ModelPriceSources.parseDeepSeek(text)
        case "kimi": rows = ModelPriceSources.parseKimi(text)
        case "aliyun": rows = ModelPriceSources.parseAliyun(text)
        case "modelsdev":
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            rows = ModelPriceSources.rowsFromModelsDev(json)
        default: rows = []
        }
        for row in rows {
            let rate = row.rate
            print("\\(row.slug)|\\(rate.currency)|\\(rate.input)|\\(rate.output)|\\(rate.cacheRead)|\\(rate.cacheWrite)")
        }
    }
}
"""


def compile_driver() -> Path:
    source = (DRIVER
              .replace("PRICING", pricing)
              .replace("TABLE", table)
              .replace("SOURCES", sources)
              .replace("MODEL_USAGE", MODEL_USAGE))
    folder = Path(tempfile.mkdtemp(prefix="claudebar-price-tests-"))
    path = folder / "Driver.swift"
    path.write_text(source)
    binary = folder / "driver"
    build = subprocess.run(["swiftc", "-parse-as-library", "-O", "-o", str(binary), str(path)],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[:6000])
        FAILURES.append("the parser slice did not compile")
        sys.exit(1)
    return binary


def parse(binary: Path, fn: str, text: str) -> list[dict]:
    result = subprocess.run([str(binary), fn], input=text, capture_output=True, text=True)
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
    return next((row for row in rows if row["slug"] == slug), None)


def table_rate(slug: str) -> tuple[float, float, float, float] | None:
    """The bundled table's row, read textually — a compiled copy would be one."""
    match = re.search(
        rf'slug:\s*"{re.escape(slug)}",\s*rate:\s*R\(currency:\s*\.\w+,\s*'
        r"input:\s*([\d.]+),\s*output:\s*([\d.]+),\s*"
        r"cacheRead:\s*([\d.]+),\s*cacheWrite:\s*([\d.]+)\)", table)
    return tuple(float(match.group(i)) for i in range(1, 5)) if match else None


def agrees(rows: list[dict], slug: str) -> bool:
    """The parsed row is the bundled table's row (4 buckets, one currency)."""
    row = find(rows, slug)
    bundled = table_rate(slug)
    if row is None or bundled is None:
        return False
    parsed = (row["input"], row["output"], row["cache_read"], row["cache_write"])
    return all(abs(a - b) < 1e-6 for a, b in zip(parsed, bundled))


def main() -> int:
    binary = compile_driver()
    print("China vendor pages (fixtures, offline):")

    glm = parse(binary, "glm", fixture("glm"))
    check("GLM has rows and no zero bucket",
          glm and all(min(r["input"], r["output"], r["cache_read"], r["cache_write"]) > 0
                      for r in glm),
          str([r["slug"] for r in glm if min(r["input"], r["output"],
                                             r["cache_read"], r["cache_write"]) <= 0]))
    check("GLM takes the base band, like the bundled table",
          agrees(glm, "glm-5") and agrees(glm, "glm-5.3") and agrees(glm, "glm-5.3-flash"),
          str(find(glm, "glm-5")))

    step = parse(binary, "stepfun", fixture("stepfun"))
    check("StepFun step-5-preview agrees with the table", agrees(step, "step-5-preview"),
          str(find(step, "step-5-preview")))
    check("StepFun folds the two context bands to one row per model",
          len([r for r in step if r["slug"] == "step-5-preview"]) == 1)

    mini = parse(binary, "minimax", fixture("minimax"))
    check("MiniMax M3 takes the discounted price, like the table",
          agrees(mini, "minimax-m3"), str(find(mini, "minimax-m3")))
    check("MiniMax folds the two context bands to one row per model",
          len([r for r in mini if r["slug"] == "minimax-m3"]) == 1)
    check("MiniMax M2.x carries the published write price",
          agrees(mini, "minimax-m2.7"), str(find(mini, "minimax-m2.7")))

    kimi = parse(binary, "kimi", fixture("kimi"))
    check("Kimi k2.7-code agrees with the table", agrees(kimi, "kimi-k2.7-code"),
          str(find(kimi, "kimi-k2.7-code")))
    check("Kimi highspeed is its own row", agrees(kimi, "kimi-k2.7-code-highspeed"),
          str(find(kimi, "kimi-k2.7-code-highspeed")))
    # The K3 row carries two extra 缓存写入 columns; reading fixed indices put
    # ¥20 (the write bucket) in the cache-hit slot.
    check("Kimi k3 reads its column sheet (two write buckets, not the hit price)",
          agrees(kimi, "kimi-k3"), str(find(kimi, "kimi-k3")))

    ds = parse(binary, "deepseek", fixture("deepseek"))
    # Peak, not off-peak: the same line prints 空闲 first, and reading the
    # first number pair halves every DeepSeek row.
    check("DeepSeek v4-pro takes the PEAK price, like the table",
          agrees(ds, "deepseek-v4-pro") and agrees(ds, "deepseek-flash"),
          str(find(ds, "deepseek-v4-pro")))
    check("DeepSeek carries the legacy flash ids at the flash price",
          agrees(ds, "deepseek-v4-flash") and agrees(ds, "deepseek-v4.1-flash"))

    ali = parse(binary, "aliyun", fixture("aliyun"))
    # 阿里 writes the band as `0&lt;Token≤1M`; decoding the entity before
    # stripping tags deleted both prices and made this vendor unreadable.
    check("Aliyun reads the table at all", bool(ali), f"{len(ali)} rows")
    check("Aliyun qwen3.7-max agrees with the table", agrees(ali, "qwen3.7-max"),
          str(find(ali, "qwen3.7-max")))
    check("Aliyun reads the prices, not the slug's digits",
          all(r["input"] > 0 and r["output"] > 0 for r in ali),
          str([r["slug"] for r in ali if r["input"] <= 0 or r["output"] <= 0]))
    check("Aliyun drops dated snapshots",
          all(not re.search(r"-\d{4}-", r["slug"]) for r in ali),
          str([r["slug"] for r in ali if re.search(r"-\d{4}-", r["slug"])]))
    # `0902` is the model's own version stamp, not a snapshot date, and the
    # page prints it beside the bare id — dropping it would drop the id.
    check("Aliyun keeps the model's own version stamp (qwen3.8-max-0902)",
          find(ali, "qwen3.8-max-0902") is not None,
          str([r["slug"] for r in ali if r["slug"].startswith("qwen3.8")]))

    print("\nmodels.dev (extract fixture):")
    usd = parse(binary, "modelsdev", fixture("models-dev"))
    by_slug = {r["slug"]: r for r in usd}
    check("models.dev claude-opus-5-5 agrees with the bundled table",
          agrees(usd, "claude-opus-5-5"), str(by_slug.get("claude-opus-5-5")))
    check("models.dev rows are USD", bool(usd) and all(r["currency"] == "usd" for r in usd))
    check("models.dev rows all have four non-zero buckets",
          bool(usd) and all(min(r["input"], r["output"], r["cache_read"], r["cache_write"]) > 0
                            for r in usd),
          str([r["slug"] for r in usd if min(r["input"], r["output"],
                                             r["cache_read"], r["cache_write"]) <= 0]))
    # A dated snapshot must fold onto the base id rather than appear beside it.
    check("dated snapshots fold onto the base id",
          all(not re.search(r"-\d{4,}$", r["slug"]) for r in usd),
          str([r["slug"] for r in usd if re.search(r"-\d{4,}$", r["slug"])]))
    # A fetched row the catalog's own writer refuses (`cacheRead > input`, a
    # zero bucket) must be dropped at parse time. Returned as a proposal, it
    # lands in 待确认, fails the same validation on 应用/全部应用, and can never
    # be applied — the button becomes a permanent no-op for that row.
    refused = parse(binary, "modelsdev", fixture("models-dev-refused"))
    refused_slugs = {r["slug"] for r in refused}
    check("a fetched cache read above input never leaves the parser",
          "read-above-input" not in refused_slugs and
          refused_slugs == {"known-model", "write-above-input"},
          str(sorted(refused_slugs)))
    check("a fetched zero cache bucket never leaves the parser",
          "zero-read" not in refused_slugs, str(sorted(refused_slugs)))

    if FAILURES:
        print(f"\nFAIL: {len(FAILURES)} assertion(s)")
        for item in FAILURES:
            print(f"  - {item}")
        return 1
    print("\nPASS: all six vendor pages parse to the numbers in the bundled table; "
          "the column sheets, the peak/off-peak pairs and the entity decoding are pinned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
