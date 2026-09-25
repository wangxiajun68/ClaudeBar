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
              let bundle = bundledURL else { return false }
        let installed = URL(fileURLWithPath: path)
        // CMS signing timestamps change the file digest even when every
        // executable code page is identical. Compare verified CodeDirectories
        // for every architecture instead; changed code still requires install.
        guard let expected = codeIdentity(bundle),
              let actual = codeIdentity(installed) else { return false }
        return expected == actual
    }

    private static func codeIdentity(_ url: URL) -> [String: String]? {
        guard command("/usr/bin/codesign", ["--verify", "--strict", "--all-architectures", url.path]) != nil,
              let details = command("/usr/bin/codesign", ["-d", "--verbose=4", url.path]),
              let format = details.split(separator: "\n").first(where: { $0.hasPrefix("Format=Mach-O") }),
              let opening = format.firstIndex(of: "("),
              let closing = format.lastIndex(of: ")"), opening < closing else { return nil }
        // codesign is included with macOS; do not require lipo / developer tools.
        let listed = format[format.index(after: opening)..<closing]
        let architectures = listed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !architectures.isEmpty else { return nil }
        var hashes: [String: String] = [:]
        for architecture in architectures {
            guard let details = command("/usr/bin/codesign", ["-d", "--verbose=4", "--arch", architecture, url.path]),
                  let line = details.split(separator: "\n").first(where: { $0.hasPrefix("CDHash=") }) else { return nil }
            let hash = String(line.dropFirst("CDHash=".count))
            guard hash.count >= 40, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
            hashes[architecture] = hash
        }
        return hashes
    }

    /// Installer entry points run off the main actor. Arguments are passed
    /// directly, and verification never runs the privileged executable.
    private static func command(_ executable: String, _ arguments: [String]) -> String? {
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardOutput = output
        child.standardError = output
        do { try child.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        guard child.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
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
