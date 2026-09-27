#!/usr/bin/env python3
"""Render the production status sheet at wide/narrow widths in both themes.
Only the store-dependent wrapper is omitted. Fixtures are synthetic; no account
files, live services or persistent preferences are read or changed.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / '.build/greeting-preview'
out.mkdir(parents=True, exist_ok=True)

def declaration(path, start):
    text = (root / path).read_text()
    pos = text.index(start)
    opening = text.index('{', pos)
    level = 1
    end = opening + 1
    while level:
        level += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[pos:end] + "\n"

source = '''import AppKit
import SwiftUI
final class AppPreferences {
    static let shared = AppPreferences()
    var isDark = false
}
struct SurfaceKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var surfaceIsVisible: Bool {
        get { self[SurfaceKey.self] }
        set { self[SurfaceKey.self] = newValue }
    }
}
// Static capture: transitions need no adapter or live store.
extension View { func rollingNumber(valueKey: String? = nil) -> some View { self.monospacedDigit() } }
enum UsageStats {
    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        return n.formatted()
    }
}
'''
source += declaration('Sources/ClaudeBar/Theme/Theme.swift', 'extension Color {')
source += declaration('Sources/ClaudeBar/Theme/Theme.swift', 'enum Theme {')
source += declaration('Sources/ClaudeBar/Utils/WeatherFetcher.swift', 'struct WeatherReading: Equatable {')
source += declaration('Sources/ClaudeBar/Utils/CodexQuotaFetcher.swift', 'struct CodexQuotaWindow: Equatable, Identifiable {')
source += (root / 'Sources/ClaudeBar/Views/Shared/WeatherBackdrop.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/SkyGreeting.swift').read_text().replace('@State private var opened = false', '@State private var opened = true') + '\n'
sheet = (root / 'Sources/ClaudeBar/Views/Shared/GreetingCard.swift').read_text()
source += sheet[sheet.index('struct GreetingStatusSheet: View {'):].replace('@State private var arrived = false', '@State private var arrived = true')
source += '''
@main struct Probe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        for dark in [false, true] {
            AppPreferences.shared.isDark = dark
            for width in [1100.0, 620.0] {
                for scene in ["sun", "rain", "night", "cloud", "snow", "empty"] {
                    let empty = scene == "empty"
                    let weather = WeatherReading(place: "广州", temperatureC: 29, feelsLikeC: 32,
                        conditionCode: scene == "rain" ? 296 : scene == "cloud" ? 119 : scene == "snow" ? 338 : 113, conditionText: "多云", highC: 32, lowC: 25, humidity: 68,
                        windKph: 8, windDirection: "东南", isDay: scene != "night", sunrise: "06:18", sunset: "18:22",
                        rainChance: 20, observedAt: Date())
                    let windows = [CodexQuotaWindow(label: "5 小时", usedPercent: 16,
                        resetsAt: Date().addingTimeInterval(8360)),
                        CodexQuotaWindow(label: "7 天", usedPercent: 42,
                        resetsAt: Date().addingTimeInterval(272160))]
                    let card = GreetingStatusSheet(name: "wangxiajun", ccModel: empty ? "未配置" : "claude-sonnet-4-6",
                        ccProvider: "Anthropic", codexModel: empty ? "默认模型" : "gpt-5.4",
                        codexProvider: "OpenAI", balance: empty ? "未提供余额" : "128.50 Credits",
                        tokens: empty ? 0 : 12840000, yesterdayTokens: empty ? 0 : 9640000,
                        calls: empty ? 0 : 286, spend: empty ? "暂无报价" : "¥404.70",
                        windows: empty ? [] : windows, quotaLoading: false,
                        quotaNote: empty ? "Codex 额度查询失败，请点击刷新重试" : nil,
                        reading: empty ? nil : weather, city: "广州", weatherLoading: false,
                        weatherNote: nil, refreshWeather: {}, refreshQuota: {}, showModels: {}, showUsage: {})
                        .environment(\\.colorScheme, dark ? .dark : .light)
                        .frame(width: width).padding(24).background(Theme.bgPrimary)
                    let renderer = ImageRenderer(content: card)
                    renderer.scale = 2
                    guard let image = renderer.cgImage,
                          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    else { fatalError("Render failed") }
                    let name = "\\(dark ? "dark" : "light")-\\(Int(width))-\\(scene).png"
                    try png.write(to: out.appendingPathComponent(name))
                }
            }
        }
        print("Rendered 24 synthetic fixture views to \\(out.path)")
    }
}
'''
path = out / 'Probe.swift'
path.write_text(source)
binary = out / 'probe'
subprocess.run(['swiftc', '-parse-as-library', '-target', 'arm64-apple-macos15.0', str(path), '-o', str(binary)], check=True)
subprocess.run([str(binary), str(out)], check=True)
