import Foundation

// VPN 代理模块偏好：直接在 AppPreferences 主类里声明（Swift extension 不能
// 有存储属性），键名全部以 vpn 前缀隔离，不触碰原 LLM 代理设置。

extension AppPreferences {
    static func vpnDefaults() -> [String: Any] {
        // One-time migration: 7897 was the original mixed-port default;
        // move stored values matching it to 7890 so existing installs follow.
        if UserDefaults.standard.integer(forKey: "vpnMixedPort") == 7897 {
            UserDefaults.standard.set(7890, forKey: "vpnMixedPort")
        }
        let vpnDefaults: [String: Any] = [
            "vpnEnabled": UserDefaults.standard.object(forKey: "vpnEnabled") as? Bool ?? false,
            "vpnSystemProxyEnabled": UserDefaults.standard.object(forKey: "vpnSystemProxyEnabled") as? Bool ?? false,
            "vpnTunEnabled": UserDefaults.standard.object(forKey: "vpnTunEnabled") as? Bool ?? false,
            "vpnMixedPort": UserDefaults.standard.object(forKey: "vpnMixedPort") as? Int ?? 7890,
            "vpnAllowLan": UserDefaults.standard.object(forKey: "vpnAllowLan") as? Bool ?? false,
            "vpnControllerSecret": {
                if let s = UserDefaults.standard.string(forKey: "vpnControllerSecret"), !s.isEmpty {
                    return s
                }
                let generated = Self.makeVpnControllerSecret()
                UserDefaults.standard.set(generated, forKey: "vpnControllerSecret")
                return generated
            }(),
            "vpnGuardEnabled": UserDefaults.standard.object(forKey: "vpnGuardEnabled") as? Bool ?? true,
        ]
        return vpnDefaults
    }

    /// Random 24-char secret so the external-controller is never open.
    static func makeVpnControllerSecret() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyz23456789")
        return String((0..<24).map { _ in alphabet.randomElement()! })
    }

    static func ensureVpnControllerSecret() {
        if AppPreferences.shared.vpnControllerSecret.isEmpty {
            AppPreferences.shared.vpnControllerSecret = makeVpnControllerSecret()
        }
    }
}
