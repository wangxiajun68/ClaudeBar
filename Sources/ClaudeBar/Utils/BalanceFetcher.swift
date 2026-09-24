import Foundation

struct BalanceFetcher {
    struct BalanceResult {
        let balance: String
        let currency: String

        /// Ready-to-display string. Callers used to prepend `¥` themselves,
        /// which printed the symbol twice for the common DeepSeek response
        /// ("¥12.34 CNY") and mislabelled every other currency as yuan.
        var display: String {
            switch currency.uppercased() {
            case "CNY": return "¥\(balance)"
            case "USD": return "$\(balance)"
            default: return "\(balance) \(currency)"
            }
        }
    }

    /// Official account-balance endpoints that accept the same API key used
    /// for inference. Subscription / coding-plan hosts and gateways without
    /// a documented balance call are intentionally absent.
    private enum Source {
        case deepseek
        case moonshotCN
        case moonshotGlobal
        case siliconflow
        case openrouter

        var url: URL? {
            switch self {
            case .deepseek:
                return URL(string: "https://api.deepseek.com/user/balance")
            case .moonshotCN:
                return URL(string: "https://api.moonshot.cn/v1/users/me/balance")
            case .moonshotGlobal:
                return URL(string: "https://api.moonshot.ai/v1/users/me/balance")
            case .siliconflow:
                return URL(string: "https://api.siliconflow.cn/v1/user/info")
            case .openrouter:
                return URL(string: "https://openrouter.ai/api/v1/key")
            }
        }
    }

    static func supports(_ baseURL: String) -> Bool {
        source(for: baseURL) != nil
    }

    /// Fetch the official account balance; unsupported hosts and failed requests return nil.
    static func fetch(authToken: String, baseURL: String) async -> BalanceResult? {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let source = source(for: baseURL), let url = source.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return parse(json, source: source)
        } catch {
            return nil
        }
    }

    private static func source(for baseURL: String) -> Source? {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return nil }
        if host == "api.deepseek.com" { return .deepseek }
        if host == "api.moonshot.cn" || host == "api.moonshot.com" { return .moonshotCN }
        if host == "api.moonshot.ai" { return .moonshotGlobal }
        if host == "api.siliconflow.cn" || host == "api.siliconflow.com" { return .siliconflow }
        if host == "openrouter.ai" { return .openrouter }
        return nil
    }

    private static func parse(_ json: [String: Any], source: Source) -> BalanceResult? {
        switch source {
        case .deepseek:
            guard let infos = json["balance_infos"] as? [[String: Any]],
                  let first = infos.first,
                  let balance = text(first["total_balance"]),
                  let currency = text(first["currency"]) else { return nil }
            return BalanceResult(balance: balance, currency: currency)
        case .moonshotCN, .moonshotGlobal:
            let payload = json["data"] as? [String: Any] ?? json
            guard let amount = number(payload["available_balance"]) else { return nil }
            let currency = source == .moonshotCN ? "CNY" : "USD"
            return BalanceResult(balance: format(amount), currency: currency)
        case .siliconflow:
            let payload = json["data"] as? [String: Any] ?? json
            guard let balance = text(payload["balance"]) else { return nil }
            return BalanceResult(balance: balance, currency: "CNY")
        case .openrouter:
            let payload = json["data"] as? [String: Any] ?? json
            guard let remaining = number(payload["limit_remaining"]) else { return nil }
            return BalanceResult(balance: format(remaining), currency: "USD")
        }
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let amount = number(value) { return format(amount) }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let amount = number.doubleValue
            return amount.isFinite ? amount : nil
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func format(_ amount: Double) -> String {
        String(format: "%.2f", amount)
    }
}
