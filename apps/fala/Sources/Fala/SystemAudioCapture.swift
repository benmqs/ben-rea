import AVFoundation
import ScreenCaptureKit

/// Captures what the Mac is playing (the other people in a Zoom, Meet or Teams call) with
/// ScreenCaptureKit, as 16 kHz mono samples. Needs the Screen & System Audio Recording permission.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display found to capture system audio from." }
    }

    var onChunk: ([Float]) -> Void = { _ in }

    private var stream: SCStream?
    private let resampler = Resampler()
    private let queue = DispatchQueue(label: "fala.system-audio")

    func start() async throws {
        // First call triggers the macOS permission prompt.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Audio only: keep the unavoidable video stream as small and slow as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              case let format = AVAudioFormat(cmAudioFormatDescription: description) else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: UnsafePointer(list.unsafePointer)) else { return }
            let samples = resampler.convert(pcm)
            if !samples.isEmpty { onChunk(samples) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Fala system audio stopped: %@", String(describing: error))
    }
}
