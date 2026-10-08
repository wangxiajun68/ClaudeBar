#!/usr/bin/env python3
"""Execute real counts/PCM/placement with isolated defaults; no App or playback."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = '\n'.join((root / path).read_text() for path in (
    'Sources/ClaudeBar/Models/WoodenFishModel.swift',
    'Sources/ClaudeBar/Utils/WoodenFishAudio.swift',
))
source += r'''
func expect(_ condition: @autoclosure () -> Bool, _ reason: String, line: UInt = #line) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL line \(line): \(reason)\n".utf8)); exit(1)
    }
}
@main struct Regression {
    @MainActor static func main() {
        let suite = "wooden-fish-regression-" + UUID().uuidString
        let otherSuite = suite + "-other"
        let defaults = UserDefaults(suiteName: suite)!, other = UserDefaults(suiteName: otherSuite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            other.removePersistentDomain(forName: otherSuite)
        }
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 23, minute: 59))!
        let next = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        let model = WoodenFishModel(defaults: defaults, now: date)
        expect(!model.enabled && !model.isAutomatic && model.total == 0, "opt-in and silence on first launch")
        for _ in 0..<1_000 { model.strike(at: date) }
        expect(model.total == 1_000 && model.today == 1_000 && model.strikeID == 1_000, "all rapid taps counted")
        model.enabled = true; model.muted = true; model.volume = 0.7
        model.interval = 0.5; model.size = .small; model.isAutomatic = true
        model.saveOrigin(CGPoint(x: -1200, y: 96))
        let restored = WoodenFishModel(defaults: defaults, now: date)
        expect(restored.total == 1_000 && restored.today == 1_000, "counters restored")
        expect(restored.enabled && restored.muted && restored.volume == 0.7, "visibility and audio restored")
        expect(restored.interval == 0.5 && restored.size == .small && !restored.isAutomatic, "auto does not restart on launch")
        expect(restored.savedOrigin == CGPoint(x: -1200, y: 96), "negative monitor positions preserved")
        expect(WoodenFishModel(defaults: other, now: date).total == 0, "distinct defaults cannot share counts")
        restored.strike(at: next)
        expect(restored.today == 1 && restored.total == 1_001, "midnight preserves lifetime")
        let tomorrow = WoodenFishModel(defaults: defaults, now: next)
        expect(tomorrow.today == 1 && tomorrow.total == 1_001, "rolled counters persisted together")
        tomorrow.refreshDay(at: date)
        expect(tomorrow.today == 0 && tomorrow.total == 1_001, "day refresh does not need a tap")
        tomorrow.resetCounts(at: date)
        expect(WoodenFishModel(defaults: defaults, now: date).total == 0, "reset persists")
        defaults.set(-4, forKey: "woodenFishVolume"); defaults.set(0.01, forKey: "woodenFishInterval")
        defaults.set(["total": -5, "today": 900], forKey: "woodenFishCounts")
        let damaged = WoodenFishModel(defaults: defaults, now: date)
        expect(damaged.volume == 0 && damaged.interval == 1 && damaged.total == 0, "invalid persisted values bounded")
        defaults.set([0.0, Double.infinity], forKey: "woodenFishOrigin")
        expect(damaged.savedOrigin == nil, "non-finite origin rejected")
        defaults.set(["total": Int.max, "today": 0], forKey: "woodenFishCounts")
        let saturated = WoodenFishModel(defaults: defaults, now: date)
        saturated.strike(at: date)
        expect(saturated.total == Int.max, "count saturation cannot crash")
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let size = WoodenFishSize.regular.panelSize
        expect(screen.contains(WoodenFishPlacement.frame(origin: nil, size: size, screens: [screen])), "default fits visible screen")
        let secondary = WoodenFishPlacement.frame(origin: CGPoint(x: -1200, y: 96), size: size, screens: [screen, left])
        expect(left.contains(secondary) && secondary.minX == -1200, "secondary display restored")
        expect(screen.contains(WoodenFishPlacement.frame(origin: secondary.origin, size: size, screens: [screen])), "removed display recovered")
        expect(screen.contains(WoodenFishPlacement.frame(origin: CGPoint(x: 1439, y: 874), size: size, screens: [screen])), "top and right clamped")
        let wave = WoodenFishTone.wave()
        expect(String(data: wave.prefix(4), encoding: .utf8) == "RIFF", "RIFF header")
        expect(String(data: wave[8..<16], encoding: .utf8) == "WAVEfmt ", "WAVE format")
        expect(wave.count == 44 + 14_994 * 2, "340ms PCM duration")
        let samples = stride(from: 44, to: wave.count, by: 2).map { offset in
            Int16(bitPattern: UInt16(wave[offset]) | UInt16(wave[offset + 1]) << 8)
        }
        expect(samples.first == 0 && samples.contains { abs(Int($0)) > 10_000 }, "audible attack without hard onset")
        expect(samples.suffix(441).allSatisfy { abs(Int($0)) < 30 }, "damped tail avoids click")
        expect(samples.allSatisfy { abs(Int($0)) < 32_767 }, "waveform not clipped")
        print("PASS: private counts, restoration, midnight, reset, overflow, multi-screen placement and damped PCM")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='wooden-fish-regression-') as tmp:
    path = Path(tmp) / 'Regression.swift'
    path.write_text(source)
    binary = Path(tmp) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
subprocess.run(['python3', str(root / 'Tools/render-wooden-fish-preview.py'), '--check'], check=True)
