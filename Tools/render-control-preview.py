#!/usr/bin/env python3
"""Render the app's control language — buttons, chips, switches — as a sheet.

Reads the production `InstrumentControls.swift` / `Interaction.swift` /
`UiverseSurfaces.swift`, so the sheet cannot drift onto a drawing the app has
moved on from. Fixtures are synthetic; no store, no account files, no network.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / '.build/control-preview'
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

source = ''

source += '''
import SwiftUI
import AppKit
'''
# The shared scalars: the theme, and the surface the preview sits on.
source += declaration('Sources/ClaudeBar/Theme/Theme.swift', 'extension Color {')
source += declaration('Sources/ClaudeBar/Theme/Theme.swift', 'enum Theme {')
source += (root / 'Tools/control-preview-support.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/LucideHardwareGeometry.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/LucideHardwarePaths.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/InstrumentGlyph.swift').read_text() + '\n'

source += (root / 'Sources/ClaudeBar/Views/Shared/SignatureGlyph.swift').read_text() + '\n'
source += (root / 'Tools/control-preview-sheet.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/ProductBrandMark.swift').read_text() + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/UiverseSurfaces.swift').read_text().replace('private struct SegmentedItem', 'struct SegmentedItem') + '\n'
source += (root / 'Sources/ClaudeBar/Views/Shared/DecorativeMotion.swift').read_text() + '\n'
_tile = (root / 'Sources/ClaudeBar/Views/Shared/Tile.swift').read_text()
source += _tile[: _tile.index('// MARK: - Tile grid')] + '\n'



# `Interaction.swift` carries the historical `adaptiveGlassButton` alias, which
# `InstrumentControls.swift` (taken whole below) now also defines. Take the two
# pieces the sheet actually builds, and drop the alias — `CodexModelMark`'s lane
# and `IconChip` come from it in the app, not in this sheet.
_interaction = (root / 'Sources/ClaudeBar/Views/Shared/Interaction.swift').read_text()
_lo = _interaction.index('// MARK: - Action buttons')
_hi = _interaction.index('// MARK: - HoverState')
source += _interaction[: _lo] + '\n' + _interaction[_hi:] + '\n'
source += declaration('Sources/ClaudeBar/Utils/CodexQuotaFetcher.swift', 'struct CodexQuotaWindow: Equatable, Identifiable {')
source += (root / 'Sources/ClaudeBar/Views/Shared/CodexQuotaGauges.swift').read_text() + '\n'
# `AppGlyph` → `StatusPill` are contiguous in `Theme.swift`; one slice keeps
# their private helpers (`IconChip`'s drawing, `PillMark`) inside the cut.
_theme = (root / 'Sources/ClaudeBar/Theme/Theme.swift').read_text()
source += _theme[_theme.index('struct AppGlyph: View {'):] + '\n'

# The control language under test, whole file.
_controls = (root / 'Sources/ClaudeBar/Views/Shared/InstrumentControls.swift').read_text()
# The page-band shim is app-side glue, not part of the control language; the
# sheet builds no band. Dropping it avoids a second `View` extension here.
source += _controls[: _controls.index("// MARK: - The page band's own control")] + '\n'



source += '''
@main struct Probe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        for dark in [false, true] {
            AppPreferences.shared.isDark = dark
            let sheet = PreviewSheet()
                .environment(\\.colorScheme, dark ? .dark : .light)
                .frame(width: 900)
                .padding(28)
                .background(Theme.bgPrimary)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { fatalError("Render failed") }
            try png.write(to: out.appendingPathComponent("sheet-\\(dark ? "dark" : "light").png"))
        }
        print("Rendered control sheet to \\(out.path)")
    }
}
'''
path = out / 'Probe.swift'
path.write_text(source)
binary = out / 'probe'
subprocess.run(['swiftc', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                str(path), '-o', str(binary)], check=True)
subprocess.run([str(binary), str(out)], check=True)
