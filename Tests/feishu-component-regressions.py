#!/usr/bin/env python3
"""Production signing and loopback transport, with no user credentials or App launch."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
identity = (root / 'Sources/ClaudeBar/Models/FeishuDocumentStore.swift').read_text()
identity = identity[identity.index('struct FeishuIdentity:'):identity.index('enum FeishuConnection:')]
sources = '\n'.join((root / name).read_text() for name in [
    'Sources/Shared/BuildChannel.swift',
    'Sources/ClaudeBar/Utils/FeishuCLI.swift',
    'Sources/ClaudeBar/Utils/FeishuComponentAuthentication.swift',
    'Sources/ClaudeBar/Utils/FeishuComponentHost.swift',
]) + identity
fixture = r'''
@main struct Regression {
    @MainActor static func main() async throws {
        let page = URL(string: "https://m.mm.cn/ttc/3541093/3131_1.html")!
        let signature = FeishuComponentSignature.make(
            ticket: "a885c93b03d6b6057e992ddda519e6ac857b5d6c", appID: "fixture-app", openID: "fixture-user",
            pageURL: page, now: Date(timeIntervalSince1970: 1609904126.124), nonce: "Y7a8KkqX041bsSwT")
        precondition(signature.signature == "fc87e50e5fa427ffad0685cc5040a004531d8e9c")
        precondition(signature.timestamp == 1609904126124)
        let json = try JSONSerialization.data(withJSONObject: signature.arguments)
        let payload = String(decoding: json, as: UTF8.self)
        precondition(!payload.contains("a885c93") && !payload.contains("ticket") && !payload.contains("access_token"))
        precondition(signature.arguments["jsApiList"] as? [String] == ["DocsComponent"])
        let granted = try FeishuJSON.payload(Data(#"{"identities":{"user":{"scope":"docs:document:readonly drive:drive"}}}"#.utf8))
        try FeishuComponentAuthentication.requireComponentScope(granted)
        for scope in ["", "drive:drive:readonly", "prefix-drive:drive"] {
            let data = try JSONSerialization.data(withJSONObject: ["identities": ["user": ["scope": scope]]])
            let denied = try FeishuJSON.payload(data)
            do {
                try FeishuComponentAuthentication.requireComponentScope(denied)
                preconditionFailure("component accepted missing drive scope")
            } catch {
                precondition(error.localizedDescription.contains("drive:drive"))
            }
        }
        let host = FeishuComponentHost()
        if !BuildChannel.allowsSystemIntegration {
            do { _ = try await host.start(); preconditionFailure("dev opened listener") } catch {}
            do { _ = try await FeishuComponentAuthentication.signature(for: page); preconditionFailure("dev used credentials") } catch {}
            print("PASS: SDK signature vector, credential-free payload, dev host/auth entry gates")
            return
        }
        let url = try await host.start()
        precondition(url.host == "127.0.0.1" && url.port != nil && url.query == nil && url.fragment == nil)
        let session = URLSession(configuration: .ephemeral)
        let (body, response) = try await session.data(from: url)
        precondition((response as! HTTPURLResponse).statusCode == 200)
        precondition(String(decoding: body, as: UTF8.self) == FeishuComponentPage.html)
        precondition((response as! HTTPURLResponse).value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let (_, missing) = try await session.data(from: url.deletingLastPathComponent().appendingPathComponent("wrong"))
        precondition((missing as! HTTPURLResponse).statusCode == 404)
        var request = URLRequest(url: url); request.httpMethod = "POST"
        let (_, rejected) = try await session.data(for: request)
        precondition((rejected as! HTTPURLResponse).statusCode == 404)
        host.stop()
        var afterStop = URLRequest(url: url); afterStop.timeoutInterval = 1
        do { _ = try await session.data(for: afterStop); preconditionFailure("stopped host served content") } catch {}
        session.invalidateAndCancel()
        print("PASS: exact ephemeral loopback route, GET only, cache suppression, shutdown")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='claudebar-feishu-component-') as tmp:
    source = Path(tmp) / 'Regression.swift'
    source.write_text(sources + fixture)
    for channel in ['CLAUDEBAR_DEV', 'CLAUDEBAR_RELEASE']:
        binary = Path(tmp) / channel
        subprocess.run(['swiftc', '-parse-as-library', '-O', '-D', channel, str(source), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=25)
