#!/usr/bin/env python3
"""Execute real counts/PCM/placement with isolated defaults; no App or playback."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = '\n'.join((root / path).read_text() for path in (
    'Sources/ClaudeBar/Models/WoodenFishModel.swift',
    'Sources/ClaudeBar/Utils/WoodenFishAudio.swift',
    'Sources/ClaudeBar/Utils/WoodenFishGeometry.swift',
    'Sources/ClaudeBar/Utils/WoodenFishMotion.swift',
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
        expect(WoodenFishGeometry.captures(CGPoint(x: 110, y: 150)), "wood captures taps")
        expect(WoodenFishGeometry.captures(CGPoint(x: 130, y: 229)), "bold base line captures taps")
        expect(!WoodenFishGeometry.captures(CGPoint(x: 2, y: 100)), "transparent margins are click-through")
        expect(!WoodenFishGeometry.captures(CGPoint(x: 70, y: 18)), "invisible tools cannot steal clicks")
        expect(!WoodenFishGeometry.captures(CGPoint(x: 70, y: 18)), "removed controls cannot capture clicks")
        expect(!WoodenFishGeometry.captures(CGPoint(x: 85, y: 18)), "tool gaps remain click-through")
        expect(!WoodenFishGeometry.captures(CGPoint(x: 31, y: 182.75)), "transparent outer corner cannot steal clicks")
        expect(WoodenFishGeometry.captures(CGPoint(x: 248, y: 63)), "visible mallet tip captures taps")
        for size in WoodenFishSize.allCases {
            let s = size.scale
            let wood = CGPoint(x: 110 * s, y: 36 + (150 - 36) * s)
            expect(WoodenFishGeometry.captures(wood, scale: s), "scaled wood captures taps below native toolbar")
            let grip = CGPoint(x: size.panelSize.width / 2 - 60, y: 18)
            expect(!WoodenFishGeometry.captures(grip, scale: s), "removed native toolbar stays click-through at every size")
            expect(!WoodenFishGeometry.captures(CGPoint(x: grip.x + 15, y: 18), scale: s), "native tool gaps stay click-through")
            expect(!WoodenFishGeometry.captures(CGPoint(x: 2, y: 36), scale: s), "compact transparent margin stays click-through")
        }
        var bursts = WoodenFishBurstPool()
        for id in UInt(1)...UInt(1000) { bursts.emit(id) }
        expect(bursts.ids == Array(UInt(993)...UInt(1000)), "rapid taps retain only eight newest bursts")
        bursts.expire(1)
        expect(bursts.ids.count == 8, "evicted burst cleanup cannot remove newer feedback")
        bursts.emit(1000)
        expect(bursts.ids.count == 8, "duplicate trigger cannot leak a burst")
        for id in bursts.ids { bursts.expire(id) }
        expect(bursts.ids.isEmpty, "finished bursts release every entry")
        for lane in 0..<7 {
            let start = WoodenFishMotion.particle(progress: -1, lane: lane, reducedMotion: false)
            let middle = WoodenFishMotion.particle(progress: 0.4, lane: lane, reducedMotion: false)
            let end = WoodenFishMotion.particle(progress: 2, lane: lane, reducedMotion: false)
            expect(start.opacity == 0 && end.opacity == 0 && middle.opacity == 1, "fade has visible middle and invisible endpoints")
            expect(abs(middle.offset.x) < 100 && abs(middle.offset.y) < 100, "particles stay within reserved canvas")
            let reduced = WoodenFishMotion.particle(progress: 0.4, lane: lane, reducedMotion: true)
            expect(reduced.offset == .zero && reduced.angle == 0 && reduced.scale == 1 && reduced.opacity == middle.opacity,
                   "reduce motion keeps only a stationary fade")
        }
        let leftLabel = WoodenFishMotion.particle(progress: 0.5, lane: 0, reducedMotion: false)
        let rightLabel = WoodenFishMotion.particle(progress: 0.5, lane: 2, reducedMotion: false)
        expect(leftLabel.offset.x < 0 && rightLabel.offset.x > 0, "labels diverge on opposite sides")
        let painted = WoodenFishGeometry.bodyPath().boundingBoxOfPath.insetBy(dx: -WoodenFishGeometry.outlineWidth / 2, dy: -WoodenFishGeometry.outlineWidth / 2)
        expect(abs(painted.width / painted.height - (1 + sqrt(5.0)) / 2) < 0.00001, "visible resonator follows the golden ratio")
        var coalesced = WoodenFishBurstPool()
        coalesced.emit(from: 0, through: 1000, feedback: WoodenFishStrikeFeedback(combo: 32, surprise: .cache))
        expect(coalesced.ids == Array(UInt(993)...UInt(1000)), "coalesced input preserves eight independent recent words")
        expect(coalesced.entries.filter { $0.feedback.surprise != nil }.count == 1, "coalesced events cannot duplicate a surprise")
        coalesced.emit(from: 1000, through: 1000, feedback: .init())
        expect(coalesced.entries.count == 8, "duplicate publication creates no feedback")
        var wrapped = WoodenFishBurstPool()
        wrapped.emit(from: UInt.max - 1, through: 1, feedback: .init())
        expect(wrapped.ids == [UInt.max, 0, 1], "strike ID overflow still emits recent words")
        let leftWord = WoodenFishMotion.word(progress: 0.5, id: 1, reducedMotion: false)
        let rightWord = WoodenFishMotion.word(progress: 0.5, id: 2, reducedMotion: false)
        expect(rightWord.offset.x - leftWord.offset.x >= 68, "word columns leave space for native labels")
        expect(WoodenFishMotion.wordRowOffset(rank: 6) - WoodenFishMotion.wordRowOffset(rank: 4) <= -24, "word rows separate native labels")
        let stillWord = WoodenFishMotion.word(progress: 0.5, id: 3, reducedMotion: true)
        expect(stillWord.offset == .zero && stillWord.angle == 0 && stillWord.scale == 1, "reduced motion word is stationary")
        for size in WoodenFishSize.allCases {
            for rank in 0..<8 {
                for step in 0...10 {
                    let word = WoodenFishMotion.word(progress: Double(step) / 10, id: UInt(rank), reducedMotion: false)
                    let center = 36 + 91 * size.scale + word.offset.y + WoodenFishMotion.wordRowOffset(rank: rank)
                    expect(center - 12 > 36, "eight native labels clear hovered toolbar at every size")
                    expect(center + 12 < size.panelSize.height - 28, "labels clear count footer at every size")
                }
            }
        }
        var daily = WoodenFishRhythm()
        _ = daily.strike(at: date, automatic: true, today: 1, total: 1)
        expect(daily.strike(at: date.addingTimeInterval(1), automatic: false, today: 2, total: 2).surprise == .firstOfDay, "automatic beat cannot consume first manual greeting")
        daily.resetChain()
        expect(daily.strike(at: date.addingTimeInterval(10), automatic: false, today: 3, total: 3).surprise == nil, "resetting chain does not repeat daily greeting")
        expect(daily.strike(at: date.addingTimeInterval(86400), automatic: false, today: 1, total: 4).surprise == .firstOfDay, "new day enables first manual greeting")
        var rhythm = WoodenFishRhythm()
        var beat = WoodenFishStrikeFeedback()
        for i in 1...32 {
            beat = rhythm.strike(at: date.addingTimeInterval(Double(i) * 0.1), automatic: false, today: i, total: i)
            if i == 8 { expect(beat.surprise == .flow && beat.combo == 8, "eight manual beats reveal flow") }
            if i == 16 { expect(beat.surprise == .matrix, "sixteen manual beats reveal the Matrix surprise") }
            if i == 32 { expect(beat.surprise == .cache, "thirty-two manual beats reveal cache surprise") }
        }
        beat = rhythm.strike(at: date.addingTimeInterval(5), automatic: false, today: 33, total: 33)
        expect(beat.combo == 1, "pause resets manual combo")
        for i in 2...8 { beat = rhythm.strike(at: date.addingTimeInterval(5 + Double(i - 1) * 0.1), automatic: false, today: 33 + i, total: 33 + i) }
        expect(beat.combo == 8 && beat.surprise == nil, "same surprise cannot spam within eight seconds")
        for count in [1, 8, 16, 32, 108, 1024, 4096] {
            let automatic = rhythm.strike(at: date.addingTimeInterval(10), automatic: true, today: count, total: count)
            expect(automatic.combo == 0 && automatic.surprise == nil, "automatic beats do not farm combos or surprises")
        }
        var milestones = WoodenFishRhythm()
        expect(milestones.strike(at: date, automatic: false, today: 20, total: 108).surprise == .peace, "108 lifetime milestone")
        expect(milestones.strike(at: date.addingTimeInterval(1), automatic: false, today: 21, total: 1024).surprise == .hello, "1024 lifetime milestone")
        expect(milestones.strike(at: date.addingTimeInterval(2), automatic: false, today: 22, total: 4096).surprise == .innerPeace, "4096 lifetime milestone")
        expect(milestones.strike(at: date.addingTimeInterval(-1), automatic: false, today: 23, total: 4097).combo == 1, "clock reversal cannot extend a combo")
        model.endInteraction()
        model.strike(at: date, automatic: true)
        expect(model.feedback.combo == 0 && model.feedback.surprise == nil, "production model propagates automatic origin")
        model.strike(at: date.addingTimeInterval(0.1))
        expect(model.feedback.combo == 1, "new manual interaction starts cleanly")
        model.resetCounts(at: date)
        expect(model.feedback == WoodenFishStrikeFeedback(), "record reset clears session feedback")
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
        print("PASS: private counts, restoration, midnight, reset, overflow, multi-screen placement, golden proportions, manual rhythm, coalesced words, reduced motion and damped PCM")
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
