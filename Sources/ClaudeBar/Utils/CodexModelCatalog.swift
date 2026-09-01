import Foundation

/// Writes `~/.codex/claude-bar-model-catalog.json` and the matching
/// `model_catalog_json` pointer — the same mechanism cc-switch uses so Codex
/// Desktop/CLI treat third-party model slugs as first-class catalog entries
/// instead of falling back to a "自定义" picker with a broken reasoning UI.
///
/// Schema follows the required fields Codex actually parses (`visibility`,
/// `supported_reasoning_levels` as `{effort, description}` objects,
/// `shell_type`, `base_instructions`, …). Native Responses profile: no
/// freeform `apply_patch` declaration (strict gateways reject `type:custom`).
enum CodexModelCatalog {
    static let filename = "claude-bar-model-catalog.json"

    static var fileURL: URL { FilePaths.codexDir.appendingPathComponent(filename) }

    static func write(provider: CodexProvider, fallbackContextWindow: Int?) throws {
        var models: [[String: Any]] = []
        for (i, model) in provider.models.enumerated() {
            models.append(entry(model: model, priority: 1000 + i,
                                fallbackContext: fallbackContextWindow))
        }
        let doc: [String: Any] = ["models": models]
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: FilePaths.codexDir, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    static func readJSON() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    private static func entry(model: CodexModelConfig, priority: Int, fallbackContext: Int?) -> [String: Any] {
        let window = Int(model.contextWindow).flatMap { $0 > 0 ? $0 : nil }
            ?? fallbackContext
            ?? 128_000
        let display = model.name
        let effort = model.reasoningEffort
        let defaultLevel = effort.isEmpty ? "high" : effort
        return [
            "slug": model.name,
            "display_name": display,
            "description": display,
            "base_instructions": "You are a coding agent. Collaborate with the user until their goal is handled.",
            "context_window": window,
            "max_context_window": window,
            "priority": priority,
            "visibility": "list",
            "supported_in_api": true,
            "shell_type": "shell_command",
            "input_modalities": ["text", "image"],
            "supports_parallel_tool_calls": true,
            "supports_reasoning_summaries": true,
            "default_reasoning_summary": "none",
            "support_verbosity": true,
            "default_verbosity": "low",
            "default_reasoning_level": defaultLevel,
            "supported_reasoning_levels": [
                ["effort": "low", "description": "Fast responses with lighter reasoning"],
                ["effort": "medium", "description": "Balances speed and reasoning depth for everyday tasks"],
                ["effort": "high", "description": "Greater reasoning depth for complex problems"],
                ["effort": "xhigh", "description": "Extra high reasoning depth for complex problems"],
            ],
            "additional_speed_tiers": [] as [Any],
            "service_tiers": [] as [Any],
            "availability_nux": NSNull(),
            "upgrade": NSNull(),
        ]
    }
}
