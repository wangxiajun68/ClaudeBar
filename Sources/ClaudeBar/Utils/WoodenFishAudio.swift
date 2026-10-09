import AppKit

/// A short, damped wooden resonator. PCM lives in memory; no downloaded
/// sound, microphone permission, audio session, or filesystem write.
enum WoodenFishTone {
    static func wave() -> Data {
        let rate = 44_100, count = Int(Double(rate) * 0.34)
        var pcm = Data(capacity: count * 2)
        var noise: UInt32 = 0x574F4F44
        for index in 0..<count {
            let t = Double(index) / Double(rate)
            noise = 1_664_525 &* noise &+ 1_013_904_223
            let grain = Double(noise) / Double(UInt32.max) * 2 - 1
            let attack = min(1, t / 0.0025)
            let body = sin(2 * .pi * 545 * t) * exp(-t * 24)
                + 0.55 * sin(2 * .pi * 873 * t) * exp(-t * 38)
                + 0.28 * sin(2 * .pi * 1_462 * t) * exp(-t * 65)
                + grain * 0.28 * exp(-t * 160)
            let sample = Int16(max(-1, min(1, body * attack * 0.48)) * 32_767)
            append(UInt16(bitPattern: sample), to: &pcm)
        }
        var data = Data("RIFF".utf8)
        append(UInt32(36 + pcm.count), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data); append(UInt16(1), to: &data)
        append(UInt32(rate), to: &data); append(UInt32(rate * 2), to: &data)
        append(UInt16(2), to: &data); append(UInt16(16), to: &data)
        data.append(Data("data".utf8)); append(UInt32(pcm.count), to: &data)
        data.append(pcm)
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

@MainActor
final class WoodenFishAudio {
    private let voices: [NSSound]
    private var cursor = 0
    var available: Bool { !voices.isEmpty }

    init() {
        let wave = WoodenFishTone.wave()
        voices = (0..<4).compactMap { _ in NSSound(data: wave) }
    }

    @discardableResult func play(volume: Double) -> Bool {
        guard !voices.isEmpty else { return false }
        let voice = voices[cursor]
        cursor = (cursor + 1) % voices.count
        voice.stop()
        voice.volume = Float(min(1, max(0, volume)))
        return voice.play()
    }

    func stop() { voices.forEach { $0.stop() } }
}
