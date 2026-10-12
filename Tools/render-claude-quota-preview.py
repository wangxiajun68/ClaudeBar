#!/usr/bin/env python3
"""Render the production CC quota card with synthetic responses; no credentials or network."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / '.build/claude-quota-preview'
out.mkdir(parents=True, exist_ok=True)

def declaration(path, marker):
    text = (root / path).read_text()
    start = text.index(marker)
    end = text.index('{', start) + 1
    level = 1
    while level:
        level += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end] + '\n'

source = 'import SwiftUI\nimport AppKit\n'
source += (root / 'Tools/control-preview-support.swift').read_text() + '\n'
for path, marker in [
    ('Sources/ClaudeBar/Theme/Theme.swift', 'extension Color {'),
    ('Sources/ClaudeBar/Theme/Theme.swift', 'enum Theme {'),
    ('Sources/ClaudeBar/Theme/Theme.swift', 'struct PanelCardModifier:'),
    ('Sources/ClaudeBar/Views/Shared/UiverseSurfaces.swift', 'struct InnerFrameRing:'),
    ('Sources/ClaudeBar/Views/Shared/UiverseSurfaces.swift', 'struct OrbitGauge:'),
    ('Sources/ClaudeBar/Utils/CodexQuotaFetcher.swift', 'struct CodexQuotaWindow:'),
]:
    source += declaration(path, marker)
source += '''
extension View {
    func panelCard(radius: CGFloat = Theme.Radius.lg, tint: Color? = nil, framed: Bool = true) -> some View {
        modifier(PanelCardModifier(radius: radius, tint: tint, framed: framed))
    }
}
enum ClaudeQuotaFetcher {
    struct Snapshot {
        var windows: [CodexQuotaWindow] = []
        var note: String? = nil
        var failed = false
        var clearWindows = false
        var accountKey: String? = "synthetic"
        var retryAt: Date? = nil
    }
    static func fetch() async -> Snapshot { fatalError("Preview must never query") }
}
'''
for path in ['Sources/ClaudeBar/Models/ClaudeQuotaStore.swift',
             'Sources/ClaudeBar/Views/Shared/ClaudeQuotaCard.swift']:
    fragment = (root / path).read_text()
    if path.endswith('ClaudeQuotaCard.swift'):
        # ImageRenderer mounts .task too; render only the production layout.
        anchor = '.task { await quota.refresh(manual: false) }'
        assert anchor in fragment
        fragment = fragment.replace(anchor, '')
    source += fragment + '\n'
source += r'''
@main struct Preview {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        for dark in [false, true] {
            AppPreferences.shared.isDark = dark
            for width in [320, 440, 800] {
                for populated in [false, true] {
                    ClaudeQuotaStore.shared.apply(.init(windows: populated ? [
                        .init(slot: "five_hour", label: "5 小时", usedPercent: 22.5,
                              resetsAt: Date().addingTimeInterval(3600), durationMinutes: 300),
                        .init(slot: "seven_day", label: "7 天", usedPercent: 81,
                              resetsAt: Date().addingTimeInterval(86400 * 3), durationMinutes: 10080),
                        .init(slot: "seven_day_sonnet", label: "Sonnet · 7 天", usedPercent: 0,
                              resetsAt: nil, durationMinutes: 10080),
                    ] : [], note: populated ? nil : "账号未返回额度窗口"))
                    let card = ClaudeQuotaCard().padding(16).frame(width: CGFloat(width))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .background(Theme.bgPrimary)
                    let renderer = ImageRenderer(content: card)
                    renderer.scale = 2
                    guard let image = renderer.cgImage,
                          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    else { fatalError("Render failed") }
                    try png.write(to: out.appendingPathComponent("quota-\(width)-\(dark ? "dark" : "light")-\(populated ? "windows" : "empty").png"))
                }
            }
        }
    }
}
'''
path = out / 'Probe.swift'
path.write_text(source)
binary = out / 'probe'
subprocess.run(['swiftc', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                str(path), '-o', str(binary)], check=True)
subprocess.run([str(binary), str(out)], check=True)
print(f'Rendered synthetic CC quota cards to {out}')
