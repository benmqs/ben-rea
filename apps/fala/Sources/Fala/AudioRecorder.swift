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

    /// True when at least `minFrames` 50 ms frames are louder than about -50 dBFS
    /// (the point where the level meter reads zero).
    static func containsSpeech(_ samples: ArraySlice<Float>, threshold: Float = 0.003, minFrames: Int = 3) -> Bool {
        let frame = 800     // 50 ms at 16 kHz
        return samples.withUnsafeBufferPointer { buffer in
            var loud = 0
            var i = 0
            while i + frame <= buffer.count {
                var sum: Float = 0
                for j in i..<(i + frame) { sum += buffer[j] * buffer[j] }
                if (sum / Float(frame)).squareRoot() > threshold {
                    loud += 1
                    if loud >= minFrames { return true }
                }
                i += frame
            }
            return false
        }
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
    enum RecorderError: Error { case noInput }

    static let sampleRate = Resampler.sampleRate

    var onLevel: (Float) -> Void = { _ in }
    var onChunk: (([Float]) -> Void)?

    private var engine = AVAudioEngine()
    private let resampler = Resampler()
    private var samples: [Float] = []
    private var keepSamples = true
    private let lock = NSLock()

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private var configObserver: NSObjectProtocol?

    func start(keepSamples: Bool = true) throws {
        self.keepSamples = keepSamples
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        // A fresh engine each time picks up the current default microphone. A reused engine keeps
        // the format of the device it first saw (e.g. 24 kHz AirPods), and installing a tap with
        // that stale format after switching to a 48 kHz mic raises an exception and crashes.
        removeConfigObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        try startEngine()
        // The engine stops itself when the input device changes mid-recording (AirPods connect,
        // dock, USB mic). Restart it on the new device so a meeting keeps recording.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, !self.engine.isRunning else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            do {
                try self.startEngine()
            } catch {
                NSLog("Fala microphone restart failed: %@", String(describing: error))
            }
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func removeConfigObserver() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
    }

    /// Stops recording and returns what was kept since `start()`.
    func stop() -> [Float] {
        removeConfigObserver()
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
