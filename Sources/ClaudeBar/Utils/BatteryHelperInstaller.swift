import Foundation
import CryptoKit

/// A narrowly scoped, pipe-driven helper, installed only by an explicit control
/// action. No launch daemon, network listener, arbitrary-key or file-write API.
enum BatteryHelperInstaller {
    static let path = "/Library/PrivilegedHelperTools/com.claudebar.batteryctl"
    static var bundledURL: URL? { Bundle.main.url(forResource: "claudebar-batteryctl", withExtension: nil) }

    static func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isInstalled() -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0, info.st_mode & 0o7777 == 0o4755,
              let bundle = bundledURL, let expected = digest(bundle) else { return false }
        return digest(URL(fileURLWithPath: path)) == expected
    }

    /// Called off the UI thread. A root-owned staging copy is verified before
    /// its setuid bit is set, avoiding source replacement during authorization.
    static func installIfNeeded() -> String? {
        if isInstalled() { return nil }
        guard let source = bundledURL, let hash = digest(source) else { return "缺少电池辅助工具，请重新构建或安装应用。" }
        let directory = "/Library/PrivilegedHelperTools"
        let shell = """
        set -eu
        /bin/mkdir -p \(quote(directory))
        test ! -L \(quote(directory))
        test "$(/usr/bin/stat -f '%u' \(quote(directory)))" = 0
        test "$(/usr/bin/stat -f '%Lp' \(quote(directory)))" = 755
        stage=$(/usr/bin/mktemp \(quote(directory + "/.claudebar-battery.XXXXXX")))
        trap '/bin/rm -f "$stage"' EXIT
        /bin/cp \(quote(source.path)) "$stage"
        test "$(/usr/bin/shasum -a 256 "$stage" | /usr/bin/cut -d ' ' -f 1)" = \(quote(hash))
        /usr/bin/codesign --verify --strict "$stage"
        /usr/sbin/chown root:wheel "$stage"
        /bin/chmod 4755 "$stage"
        /bin/mv -f "$stage" \(quote(path))
        """
        let literal = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(literal)\" with administrator privileges"
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do { try process.run() } catch { return "无法启动系统授权：\(error.localizedDescription)" }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: data, as: UTF8.self)
            return message.contains("-128") ? "已取消授权，未改变充电设置。" : "辅助工具安装失败：\(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return isInstalled() ? nil : "辅助工具校验失败，未启用电池控制。"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
