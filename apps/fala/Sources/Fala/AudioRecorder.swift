import AVFoundation

/// Converts any PCM buffer to 16 kHz mono Float32, the format Whisper expects.
final class Resampler {
    static let sampleRate: Double = 16_000
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Resampler.sampleRate, channels: 1, interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
            sourceFormat = buffer.format
        }
        guard let converter else { return [] }

        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    /// RMS level mapped to 0...1 for meters.
    static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        return min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 50))
    }
}

/// Records the default microphone as 16 kHz mono samples and publishes a smoothed input level.
/// With `keepSamples` it accumulates everything for `stop()` to return (dictation); either way
/// each converted chunk is passed to `onChunk` (meetings stream it to disk).
final class AudioRecorder {
    static let sampleRate = Resampler.sampleRate

    var onLevel: (Float) -> Void = { _ in }
    var onChunk: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private let resampler = Resampler()
    private var samples: [Float] = []
    private var keepSamples = true
    private let lock = NSLock()

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(keepSamples: Bool = true) throws {
        self.keepSamples = keepSamples
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops recording and returns what was kept since `start()`.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onLevel(0)
        return lock.withLock { samples }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let chunk = resampler.convert(buffer)
        guard !chunk.isEmpty else { return }
        if keepSamples { lock.withLock { samples.append(contentsOf: chunk) } }
        onChunk?(chunk)
        let level = Resampler.level(of: chunk)
        DispatchQueue.main.async { self.onLevel(level) }
    }
}

/// Appends 16 kHz mono samples to a WAV file on a background queue.
final class AudioFileSink {
    let url: URL
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "fala.audio-file-sink")

    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(
            forWriting: url, settings: Resampler.format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
    }

    func append(_ samples: [Float]) {
        queue.async { [weak self] in
            guard let file = self?.file,
                  let buffer = AVAudioPCMBuffer(pcmFormat: Resampler.format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try? file.write(from: buffer)
        }
    }

    /// Waits for pending writes and closes the file so it can be read.
    func close() {
        queue.sync { file = nil }
    }
}
