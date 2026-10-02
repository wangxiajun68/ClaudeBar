import Foundation

/// One POSIX single-quote for every path this app hands to `sh -c`.
///
/// The two privileged installers (`BatteryHelperInstaller` /
/// `FanHelperInstaller`) build their scripts the same way, and the escaping is
/// security-relevant: a path containing a quote must not be able to end the
/// single-quoted run. One copy, so the two cannot drift.
enum ShellQuote {
    static func single(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
