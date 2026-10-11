import Foundation

/// Validates a batch against current saved connections before its one private
/// write. Only model metadata and provider IDs enter the pool.
enum GatewayProviderImport {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Shared by import, runtime and recovery UI. Never echo credentials or a
    /// URL's query/userinfo into an error message.
    static func endpointIssue(_ base: String) -> String? {
        guard let url = URLComponents(string: base), let host = url.host, !host.isEmpty else {
            return "接口地址不完整。请填写供应商提供的 HTTP／HTTPS OpenAI 兼容 Base URL。"
        }
        if LocalProxyAddress.isLoopback(base) {
            return "当前配置指向本机接口。Auto 池使用远端上游，请填写供应商地址，避免请求回到本机代理。"
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return "接口协议不支持。请使用供应商提供的 HTTP／HTTPS OpenAI 兼容地址。"
        }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            return "接口地址包含登录信息、查询参数或片段。请使用纯 Base URL，并将密钥填在 Key 字段。"
        }
        if host.lowercased() == "openrouter.ai", !FreeModelPool.isOpenRouter(base) {
            return "OpenRouter 免费目录使用官方 HTTPS 地址：https://openrouter.ai/api/v1。"
        }
        return nil
    }

    struct ConnectionChoice: Identifiable {
        var provider: CodexProvider
        var ids: Set<UUID>
        var id: UUID { provider.id }
        /// Never includes a key, query or user info.
        var address: String { URLComponents(string: provider.baseURL)?.host ?? "已保存连接" }
    }

    /// Display aliases together without rewriting saved UUIDs or model assignments.
    /// Different accounts stay separate even when their names/hosts match.
    static func connectionChoices(_ providers: [CodexProvider], selectedID: UUID?) -> [ConnectionChoice] {
        var choices: [ConnectionChoice] = []
        for provider in providers {
            if let index = choices.firstIndex(where: {
                $0.provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) == provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    && $0.provider.apiKey == provider.apiKey
            }) {
                choices[index].ids.insert(provider.id)
                if provider.id == selectedID { choices[index].provider = provider }
            } else { choices.append(.init(provider: provider, ids: [provider.id])) }
        }
        return choices
    }

    static func merge(_ members: [FreeModelPool.Member], into pool: FreeModelPool,
                      providers: [CodexProvider], confirmedFree: Bool,
                      now: Date = Date()) throws -> FreeModelPool {
        guard confirmedFree else { throw Failure(message: "请确认所选模型可免费使用。") }
        guard !members.isEmpty else { throw Failure(message: "请至少选择一个模型。") }
        var next = pool
        for draft in members {
            // Existing assignments, health identity and enablement survive a
            // repeat import; duplicates do not spend the 200-member budget.
            if next.members.contains(where: { $0.id == draft.id }) { continue }
            guard let provider = providers.first(where: { $0.id == draft.providerID }),
                  provider.models.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == draft.model }),
                  !provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(message: "供应商或模型配置已变化，请重新选择已保存的模型。")
            }
            if let issue = endpointIssue(provider.baseURL) {
                throw Failure(message: "\(provider.name)：\(issue)")
            }
            var member = draft
            member.discovered = false
            if FreeModelPool.isOpenRouter(provider.baseURL) {
                guard now.timeIntervalSince(pool.discoveredAt ?? .distantPast) < 48 * 3600,
                      let model = pool.catalog.first(where: { $0.id == member.model }) else {
                    throw Failure(message: "OpenRouter 模型须在有效的免费目录中，请先到「发现模型」刷新目录。")
                }
                member = model.member(providerID: provider.id)
                member.difficulties = draft.difficulties
            }
            next.members.append(member)
        }
        if let error = next.validationError { throw Failure(message: error) }
        return next
    }
}
