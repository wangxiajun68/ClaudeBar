import Foundation

/// Usage aggregation for external agent tools — Codex, OpenClaw.
///
/// Since the persistent `UsageIndex` landed, external transcripts are parsed
/// into the same rollup as Claude Code transcripts (source kind is part of
/// the indexed path key), so this type is now a thin query over the index.
/// The doc comments describing each tool's transcript shape have moved to
/// the parsers in `UsageIndex`.
struct ExternalUsageStats {

    /// Per-model usage within `interval` across all external tools, sorted by
    /// total tokens descending. Reads from the shared index; `updateIndex()`
    /// is the caller's responsibility (UsageStats.fetch does both).
    static func fetch(in interval: DateInterval) -> [ModelUsage] {
        UsageIndex.fetch(in: interval)
    }
}
