import AVFAudio

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

/// All waveform preparation, player allocation and playback stay on one queue.
/// The lock only invalidates ownership; voices are never touched off that queue.
final class WoodenFishAudio: @unchecked Sendable {
    private let queue = DispatchQueue(label: "claudebar.wooden-fish-audio", qos: .userInteractive)
    private let lock = NSLock()
    private var generation: UInt = 0
    private var voices: [AVAudioPlayer] = []
    private var cursor = 0
    private var prepared = false
    private var ready = false
    private let voiceFactory: @Sendable (Data) -> [AVAudioPlayer]

    init(voiceFactory: @escaping @Sendable (Data) -> [AVAudioPlayer] = { wave in
        (0..<4).compactMap { _ in
            try? AVAudioPlayer(data: wave)
        }
    }) {
        self.voiceFactory = voiceFactory
        prewarm()
    }

    func prewarm() {
        let ticket = lock.withLock { generation }
        queue.async { [weak self] in
            guard let self, self.owns(ticket) else { return }
            self.prepare()
        }
    }

    func play(volume: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        let ticket = lock.withLock { generation }
        queue.async { [weak self] in
            guard let self, self.owns(ticket) else { return }
            self.prepare()
            guard self.owns(ticket) else { return }
            var success = false
            if !self.voices.isEmpty {
                let voice = self.voices[self.cursor]
                self.cursor = (self.cursor + 1) % self.voices.count
                // stop() releases the prepared audio hardware synchronously.
                // Pause keeps a warmed voice ready when rapid taps reuse it.
                voice.pause()
                voice.currentTime = 0
                voice.volume = Float(min(1, max(0, volume)))
                success = voice.play()
            }
            let result = success
            Task { @MainActor [weak self] in
                guard let self, self.owns(ticket) else { return }
                completion(result)
            }
        }
    }

    func stop() {
        // Invalidate queued requests immediately, even during a slow prepare.
        lock.withLock { generation &+= 1 }
        queue.async { [weak self] in
            guard let self else { return }
            self.voices.forEach { $0.stop() }
            self.ready = false
        }
    }

    private func owns(_ ticket: UInt) -> Bool { lock.withLock { generation == ticket } }

    private func prepare() {
        if !prepared {
            prepared = true
            voices = voiceFactory(WoodenFishTone.wave())
        }
        guard !ready else { return }
        voices.forEach { _ = $0.prepareToPlay() }
        ready = true
    }
}
