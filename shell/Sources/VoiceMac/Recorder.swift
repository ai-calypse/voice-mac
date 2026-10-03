import AVFoundation

/// Records the microphone while the hotkey is held and returns 16 kHz mono 16-bit WAV, whisper.cpp's native input.
final class Recorder {
    private let engine = AVAudioEngine()
    private var samples: [Int16] = []
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private(set) var recording = false
    /// Microphone loudness (RMS, ~0–0.3) for the notch's level bars.
    var onLevel: ((Double) -> Void)?

    func start() throws {
        guard !recording else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: target)
        lock.withLock { samples.removeAll() }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        recording = true
    }

    /// Stops and returns the WAV, or nil when the clip is too short to be speech.
    func stop() -> Data? {
        guard recording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recording = false
        let pcm = lock.withLock { samples }
        guard pcm.count > 16_000 / 4 else { return nil } // under 250 ms
        return Recorder.wav(pcm.suffix(16_000 * 15)) // the local model's window is 15 s
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
            onLevel?(Double(sqrt(sum / Float(buffer.frameLength))))
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.int16ChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    static func wav<S: Collection>(_ pcm: S) -> Data where S.Element == Int16 {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        for s in pcm { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }
}
