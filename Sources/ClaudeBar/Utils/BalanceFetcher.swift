import Foundation

struct BalanceFetcher {
    struct BalanceResult {
        let balance: String
        let currency: String

        /// Ready-to-display string. Callers used to prepend `¥` themselves,
        /// which printed the symbol twice for the common DeepSeek response
        /// ("¥12.34 CNY") and mislabelled every other currency as yuan.
        var display: String {
            currency.uppercased() == "CNY" ? "¥\(balance)" : "\(balance) \(currency)"
        }
    }

    static func supports(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "api.deepseek.com"
    }

    /// Fetch DeepSeek balance. Returns nil for non-DeepSeek URLs or on failure.
    static func fetch(authToken: String, baseURL: String) async -> BalanceResult? {
        // Only fetch for DeepSeek — match on the URL host so a misconfigured
        // baseURL like `https://deepseek-proxy.evil.com/` can't trick us into
        // sending the auth token to an unintended host (a plain `.contains`
        // would). Verify the host before constructing the request URL.
        guard !authToken.isEmpty,
              let base = URL(string: baseURL),
              let host = base.host?.lowercased(),
              supports(baseURL) else { return nil }

        guard let url = URL(string: "https://api.deepseek.com/user/balance"),
              url.host?.lowercased() == host else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let infos = json?["balance_infos"] as? [[String: Any]],
                  let first = infos.first,
                  let balance = first["total_balance"] as? String,
                  let currency = first["currency"] as? String else { return nil }

            return BalanceResult(balance: balance, currency: currency)
        } catch {
            // Network/HTTP failures are expected (offline, bad token, rate
            // limit); the balance is an optional UI nicety, so nil is the
            // correct silent outcome.
            return nil
        }
    }
}
