import Foundation
import CryptoKit

/// The web host receives only a one-use signature, never an access token or ticket.
struct FeishuComponentSignature: Sendable {
    let openId: String
    let appId: String
    let signature: String
    let timestamp: Int64
    let nonceStr: String
    let url: String
    let jsApiList = ["DocsComponent"]

    static func make(ticket: String, appID: String, openID: String, pageURL: URL,
                     now: Date = Date(), nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) -> Self {
        let timestamp = Int64(now.timeIntervalSince1970 * 1000)
        let input = "jsapi_ticket=\(ticket)&noncestr=\(nonce)&timestamp=\(timestamp)&url=\(pageURL.absoluteString)"
        let hash = Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(openId: openID, appId: appID, signature: hash, timestamp: timestamp, nonceStr: nonce, url: pageURL.absoluteString)
    }

    var arguments: [String: Any] {
        ["openId": openId, "appId": appId, "signature": signature, "timestamp": timestamp,
         "nonceStr": nonceStr, "url": url, "jsApiList": jsApiList]
    }
}

enum FeishuComponentAuthentication {
    static func signature(for pageURL: URL) async throws -> FeishuComponentSignature {
        // The gate belongs at the credential side-effect entry, even for reads.
        guard BuildChannel.allowsSystemIntegration else {
            throw FeishuCLIError.failed("开发版不连接真实飞书文档。")
        }
        let identityData = try await FeishuCLI.run(["auth", "status", "--json"], timeout: 30)
        let identity = FeishuIdentity.parse(identityData)
        guard identity.available else { throw FeishuCLIError.failed("请先连接飞书用户账号。") }
        let ticket = try await FeishuCLI.run(["api", "POST", "/open-apis/jssdk/ticket/get", "--as", "user"], timeout: 30)
        try Task.checkCancellation()
        // Do not sign with an openId from an account switched during this request.
        let currentData = try await FeishuCLI.run(["auth", "status", "--json"], timeout: 30)
        guard FeishuIdentity.parse(currentData) == identity, !ticket["ticket"].text.isEmpty else {
            throw FeishuCLIError.failed("飞书账号已变化或组件授权不可用，请重新连接。")
        }
        return .make(ticket: ticket["ticket"].text, appID: identityData["appId"].text,
                     openID: identityData["identities"]["user"]["openId"].text, pageURL: pageURL)
    }
}
