import Foundation

/// Validates a batch against current saved connections before its one private
/// write. Only model metadata and provider IDs enter the pool.
enum GatewayProviderImport {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
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
            guard let url = URLComponents(string: provider.baseURL), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  !LocalProxyAddress.isLoopback(provider.baseURL) else {
                throw Failure(message: "请先为供应商配置远端 HTTPS 兼容接口；不能导入本机代理自身。")
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
