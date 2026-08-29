import Foundation

struct BalanceFetcher {
    struct BalanceResult {
        let balance: String
        let currency: String
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
              host.contains("deepseek.com") else { return nil }

        guard let url = URL(string: "user/balance", relativeTo: base) else { return nil }

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
            return nil
        }
    }
}
