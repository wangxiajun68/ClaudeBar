#!/usr/bin/env python3
"""The writable price layer: validation, the day-key, load/write failure paths.

`ModelPriceCatalog` is the one place a price is written, and every write is a
promise about the file on disk. Three of those promises had no coverage at all
(a review pass measured zero references to this type under `Tests/`):

  * **validation** — a zero bucket, a cache read above input, a non-canonical
    slug or an impossible date must be refused, in the same words the editor
    shows;
  * **the day-key** — `yyyy-MM-dd` is what an override's `effectiveFrom`
    compares against a usage day, so `2026-13-45` must not pass;
  * **the file** — a corrupt file must be quarantined rather than overwritten,
    a future version must be left alone, and a write that *fails* must say so
    instead of leaving the UI claiming 已应用.

Compiled from the production source with the two app dependencies stubbed
(`FilePaths` → a temp dir, `ModelUsage` → the fields `ModelPricing` reads), no
app launch, no network, no real user configuration touched.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
UTILS = ROOT / 'Sources/ClaudeBar/Utils'

SLICE = [
    'ModelPricing.swift',
    'ModelPriceTable.swift',
    'ModelPriceSources.swift',
    'ModelPriceCatalog.swift',
]

STUBS = r'''
import Foundation
import Combine

/// The catalog's own file lives under this, and the whole point of this suite
/// is what happens when reading or writing it fails — so it is a temp dir the
/// fixture owns, never the real Application Support directory.
enum FilePaths {
    static var appSupportDir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDEBAR_TEST_DIR"]!) }
}

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
'''

DRIVER = r'''
import Foundation

@main
@MainActor
struct Regression {
    static var file: URL {
        FilePaths.appSupportDir.appendingPathComponent("price-overrides.json")
    }

    /// The singleton is built once per process, so the two file states below
    /// (a corrupt file, a future-version file) have to be the *startup* state
    /// of a run — the suite seeds the temp dir and launches this binary again.
    static var phase: String { CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "main" }

    static func expectRefusal(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
            preconditionFailure("\(label) must be refused")
        } catch let error as ModelPriceCatalog.WriteError {
            precondition(!(error.errorDescription ?? "").isEmpty,
                         "\(label) must say why")
        } catch {
            preconditionFailure("\(label) refused with the wrong error: \(error)")
        }
    }

    static func main() async throws {
        switch phase {
        case "corrupt": try corruptFilePhase(); return
        case "future-version": try futureVersionPhase(); return
        case "write-failed": try writeFailedPhase(); return
        default: break
        }
        let catalog = ModelPriceCatalog.shared
        let today = ModelPricing.dayKey(Date())
        let rate = ModelPricing.Rate(currency: .usd, input: 5, output: 30,
                                     cacheRead: 0.5, cacheWrite: 5)

        // 1. The day-key: shape, digits, and impossible dates.
        precondition(ModelPriceCatalog.isDayKey("2026-09-30"))
        precondition(ModelPriceCatalog.isDayKey("2026-02-28"))
        for bad in ["2026-2-28", "2026/02/28", "20260228", "2026-13-45", "2026-00-10",
                    "2026-09-31", "", "abcd-ef-gh"] {
            precondition(!ModelPriceCatalog.isDayKey(bad), "\(bad) must not be a day key")
        }
        precondition(ModelPricing.dayKey(fromDayKey: "2026-09-31") == nil,
                     "an impossible date must not round-trip")

        // 2. Validation, in the editor's own words.
        expectRefusal("empty slug") {
            try catalog.record(slug: "  ", rate: rate, effectiveFrom: today, source: .manual)
        }
        expectRefusal("non-canonical slug") {
            try catalog.record(slug: "anthropic/claude-sonnet-4-6", rate: rate,
                               effectiveFrom: today, source: .manual)
        }
        expectRefusal("impossible date") {
            try catalog.record(slug: "valid-slug", rate: rate, effectiveFrom: "2026-13-45",
                               source: .manual)
        }
        expectRefusal("missing rate") {
            try catalog.record(slug: "valid-slug", rate: nil, effectiveFrom: today, source: .manual)
        }
        expectRefusal("zero output bucket") {
            try catalog.record(slug: "valid-slug",
                               rate: .init(currency: .usd, input: 5, output: 0,
                                           cacheRead: 0.5, cacheWrite: 5),
                               effectiveFrom: today, source: .manual)
        }
        expectRefusal("cache read above input") {
            try catalog.record(slug: "valid-slug",
                               rate: .init(currency: .usd, input: 5, output: 30,
                                           cacheRead: 9, cacheWrite: 5),
                               effectiveFrom: today, source: .manual)
        }
        // …and the rejected rows left nothing behind.
        precondition(catalog.overrides.isEmpty, "a refused write must not be half-applied")
        precondition(ModelPricing.resolve("valid-slug") == nil,
                     "a refused slug must not resolve")

        // 3. A written row takes effect, and a same-day re-edit replaces rather
        //    than stacking. Two separate writes are two commits (the control the
        //    batch path below is measured against).
        var notifications = 0
        let token = NotificationCenter.default.addObserver(
            forName: .modelPriceDidChange, object: nil, queue: nil) { _ in notifications += 1 }
        try catalog.record(slug: "audit-model", rate: rate, effectiveFrom: today, source: .manual)
        precondition(notifications == 1, "a single write must announce itself once")
        precondition(ModelPricing.resolve("audit-model")?.rate == rate,
                     "the written row must be what resolves")
        precondition(catalog.overrides["audit-model"]?.count == 1)
        try catalog.record(slug: "audit-model",
                           rate: .init(currency: .usd, input: 9, output: 40,
                                       cacheRead: 0.9, cacheWrite: 9),
                           effectiveFrom: today, source: .manual)
        precondition(catalog.overrides["audit-model"]?.count == 1,
                     "re-editing the same day must replace the row, not stack a second")
        precondition(ModelPricing.resolve("audit-model")?.rate?.input == 9)
        precondition(notifications == 2)

        // A future-dated row is stored but not in force yet — that is what
        // makes a price change forward-only.
        try catalog.record(slug: "future-model", rate: rate,
                           effectiveFrom: "2099-01-01", source: .manual)
        precondition(catalog.activeOverride(for: "future-model") == nil,
                     "a row starting later must not be the active one")
        precondition(ModelPricing.resolve("future-model") == nil,
                     "…nor may it price today's usage")

        // 4. Revert drops the row and the money goes back to the bundled table.
        catalog.revert(slug: "audit-model")
        precondition(catalog.overrides["audit-model"] == nil)
        precondition(ModelPricing.resolve("audit-model") == nil)
        precondition(notifications == 4, "a revert is a change too")

        // 5. The candidate identities the card can hand back: a slug the catalog
        //    refuses must not be written, and `apply` must say so.
        func candidate(_ slug: String, _ value: ModelPricing.Rate) -> ModelPriceCatalog.Candidate {
            ModelPriceCatalog.Candidate(slug: slug, rate: value, unpriced: nil,
                                        source: .fetchedUSD, sourceURL: nil,
                                        current: nil, note: nil, isUnchanged: false)
        }
        let before = notifications
        precondition(catalog.apply(candidate("anthropic/relay-name", rate)) == false,
                     "a non-canonical proposal must be refused")
        precondition(catalog.apply(candidate("cache-above", .init(currency: .usd, input: 5,
                                                                  output: 30, cacheRead: 99,
                                                                  cacheWrite: 5))) == false,
                     "a cache read above input must be refused")
        precondition(notifications == before, "a refused proposal must not write the file")
        precondition(catalog.apply(candidate("accepted-model", rate)) == true)
        precondition(ModelPricing.resolve("accepted-model")?.rate == rate)
        precondition(notifications == before + 1, "an applied proposal announces itself once")

        // 6. The batch path commits once per pass, not once per row: with ~70
        //    rows on a first 查询更新 that difference is ~70 encodes, atomic
        //    writes and `refreshUsage` passes. Pinned textually because the
        //    candidate queue is only fillable by a live fetch.
        let source = try String(contentsOfFile: ProcessInfo.processInfo.environment["CLAUDEBAR_CATALOG_SOURCE"]!,
                                encoding: .utf8)
        func body(_ name: String) -> String {
            guard let start = source.range(of: "func \(name)(") else {
                preconditionFailure("\(name) is gone")
            }
            let rest = source[start.lowerBound...]
            guard let end = rest.range(of: "\n    }") else {
                preconditionFailure("\(name) has no end")
            }
            return String(rest[..<end.lowerBound])
        }
        // Only live comments are stripped: a comment *about* the old per-row
        // path must not count as one.
        func stripComments(_ text: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    guard let marker = line.range(of: "//") else { return String(line) }
                    return String(line[..<marker.lowerBound])
                }
                .joined(separator: "\n")
        }
        let batch = stripComments(body("applyAllCandidates"))
        precondition(batch.contains("commit()"), "the batch must commit")
        precondition(batch.components(separatedBy: "commit()").count == 2,
                     "the batch must commit exactly once:\n\(batch)")
        precondition(!batch.contains("apply(") && !batch.contains("record("),
                     "the batch must not go through the per-row writers:\n\(batch)")
        let applyBody = stripComments(body("apply"))
        precondition(applyBody.contains("store(") && applyBody.components(separatedBy: "commit()").count == 2,
                     "the single apply must store then commit once:\n\(applyBody)")

        // 7. A run with no file at all has nothing to report — this is the
        //    common case, and it keeps the two notices below from being
        //    permanently on.
        precondition(catalog.loadError == nil && catalog.writeError == nil,
                     "a fresh install has nothing to report")

        print("PASS: validation, day-key, forward-dated overrides, single vs batch commit")
    }

    /// Startup with a corrupt file: the only phase in which `load()` runs.
    static func corruptFilePhase() throws {
        let catalog = ModelPriceCatalog.shared
        precondition(catalog.loadError != nil, "a corrupt file must be reported at startup")
        let backup = file.appendingPathExtension("bak")
        precondition(FileManager.default.fileExists(atPath: backup.path),
                     "a corrupt file must be moved aside, not left to be overwritten")
        precondition(!FileManager.default.fileExists(atPath: file.path),
                     "the unreadable file must not stay in place")
        // The next write starts a fresh file and clears the notice; the backup
        // is what the user can still recover from.
        let rate = ModelPricing.Rate(currency: .usd, input: 5, output: 30,
                                     cacheRead: 0.5, cacheWrite: 5)
        let candidate = ModelPriceCatalog.Candidate(
            slug: "recovered-model", rate: rate, unpriced: nil, source: .manual,
            sourceURL: nil, current: nil, note: nil, isUnchanged: false)
        precondition(catalog.apply(candidate), "a write after a quarantine must succeed")
        precondition(FileManager.default.fileExists(atPath: file.path),
                     "…and must create the file again")
        precondition(catalog.writeError == nil)
        print("PASS: a corrupt price file is quarantined to .bak, reported, and replaced on the next write")
    }

    /// A write that cannot reach the disk: the in-memory table has already
    /// changed, so the only honest thing left is to *say* so where the user
    /// reads the number. `try?` used to swallow this entirely.
    static func writeFailedPhase() throws {
        let catalog = ModelPriceCatalog.shared
        precondition(catalog.loadError == nil, "the file is unreadable as a price table, not as bytes")
        let rate = ModelPricing.Rate(currency: .usd, input: 5, output: 30,
                                     cacheRead: 0.5, cacheWrite: 5)
        let candidate = ModelPriceCatalog.Candidate(
            slug: "unwritable-model", rate: rate, unpriced: nil, source: .manual,
            sourceURL: nil, current: nil, note: nil, isUnchanged: false)
        precondition(catalog.apply(candidate), "the row is still applied in memory")
        precondition(ModelPricing.resolve("unwritable-model")?.rate == rate,
                     "…and the session bills from it")
        precondition(catalog.writeError != nil,
                     "a failed write must surface: the number on screen looks saved")
        print("PASS: a failed write is reported, and the in-memory edit is not pretended to be persisted")
    }

    /// Startup with a file written by a newer version: not corruption, and the
    /// file must survive untouched so a downgrade does not eat it.
    static func futureVersionPhase() throws {
        let catalog = ModelPriceCatalog.shared
        precondition(catalog.loadError != nil, "a future version must be reported")
        precondition(catalog.overrides.isEmpty, "…and its contents must not be loaded as ours")
        precondition(FileManager.default.fileExists(atPath: file.path),
                     "the file must be left in place")
        precondition(!FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path),
                     "a future version is not corruption: nothing is moved aside")
        let original = try String(contentsOf: file, encoding: .utf8)
        precondition(original.contains("\"version\": 99"), "the file must be untouched")
        print("PASS: a future price-file version is reported and left untouched")
    }
}
'''


def run_phase(binary: Path, folder: Path, phase: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(binary), phase],
        capture_output=True, text=True, timeout=120,
        env={
            'PATH': '/usr/bin:/bin',
            'CLAUDEBAR_TEST_DIR': str(folder),
            'CLAUDEBAR_CATALOG_SOURCE': str(UTILS / 'ModelPriceCatalog.swift'),
        })


def main() -> int:
    with tempfile.TemporaryDirectory(prefix='claudebar-price-catalog-') as folder:
        temp = Path(folder)
        swift = STUBS + '\n'.join((UTILS / name).read_text() for name in SLICE) + DRIVER
        path = temp / 'Regression.swift'
        path.write_text(swift)
        binary = temp / 'regression'
        build = subprocess.run(['swiftc', '-O', '-parse-as-library', str(path), '-o', str(binary)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stderr[:6000])
            print('FAIL: the catalog slice did not compile')
            return 1

        file = temp / 'price-overrides.json'
        backup = temp / 'price-overrides.json.bak'

        # The catalogue is a process-wide singleton, so each startup state is
        # its own run of the same binary against the same temp dir.
        phases = [
            ('main', None),
            ('corrupt', b'{ this is not json'),
            ('future-version', b'{"version": 99, "overrides": [], '
                               b'"lastCheckedAt": "2099-01-01T00:00:00Z"}'),
            # Not bytes at all: a directory in the file's place cannot be
            # replaced by an atomic write, which is how a full disk or a
            # read-only directory behaves from here.
            ('write-failed', 'directory'),
        ]
        for phase, seed in phases:
            # Each phase owns the dir's whole state: a `.bak` left by the
            # previous phase would make this run's file look like a recovery
            # instead of a fresh file.
            for stale in (file, backup):
                shutil.rmtree(stale, ignore_errors=True)
                try:
                    stale.unlink()
                except (FileNotFoundError, IsADirectoryError):
                    pass
            if seed == 'directory':
                file.mkdir(parents=True)
            elif seed is not None:
                file.write_bytes(seed)
            run = run_phase(binary, temp, phase)
            print(run.stdout.strip())
            if run.returncode != 0:
                print(f'FAIL: phase {phase} crashed')
                print(run.stdout[-2000:])
                print(run.stderr[-3000:])
                return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
