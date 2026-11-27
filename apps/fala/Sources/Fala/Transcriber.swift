import Foundation
import WhisperKit

struct TimedText {
    let start: Float
    let end: Float
    let text: String
}

/// Local speech-to-text with WhisperKit (Core ML on Apple Silicon). Nothing leaves the Mac.
actor Transcriber {
    private var pipe: WhisperKit?
    private var loadedModel: String?
    private var loading: (model: String, task: Task<Void, Error>)?

    func isReady(model: String) -> Bool {
        pipe != nil && loadedModel == model
    }

    /// Downloads (first run only), loads and warms the model. Safe to call repeatedly and
    /// concurrently: callers that arrive while a load is running wait for that same load.
    func prepare(model: String) async throws {
        if isReady(model: model) { return }
        if let loading, loading.model == model {
            try await loading.task.value
            return
        }
        let task = Task {
            let kit = try await Self.load(model)
            // The first prediction after a load is slow: spend it here on 2 s of silence.
            _ = try? await kit.transcribe(
                audioArray: [Float](repeating: 0, count: 32_000),
                decodeOptions: Self.dictationOptions("en", sampleCount: 32_000)
            )
            pipe = kit
            loadedModel = model
        }
        loading = (model, task)
        defer { if loading?.task == task { loading = nil } }
        try await task.value
    }

    private static func load(_ model: String) async throws -> WhisperKit {
        // Remember where the model was downloaded, so later launches load it straight from disk
        // without asking Hugging Face first (faster, and works offline).
        let key = "modelFolder." + model
        let cached = UserDefaults.standard.string(forKey: key)
            .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let kit: WhisperKit
        do {
            // load: true is required. Without it WhisperKit only downloads, and the slow Core ML
            // load happens inside the first transcription. prewarm would load twice.
            kit = try await WhisperKit(WhisperKitConfig(
                model: model, modelFolder: cached, verbose: false, prewarm: false, load: true))
        } catch where cached != nil {
            // The cached folder is broken or incomplete: forget it and download again.
            UserDefaults.standard.removeObject(forKey: key)
            kit = try await WhisperKit(WhisperKitConfig(
                model: model, verbose: false, prewarm: false, load: true))
        }
        UserDefaults.standard.set(kit.modelFolder?.path, forKey: key)
        return kit
    }

    /// Transcribes 16 kHz mono samples. `language` nil means auto-detect.
    func transcribe(_ samples: [Float], language: String?, model: String) async throws -> String {
        try await prepare(model: model)
        guard let pipe else { return "" }
        // WhisperKit skips audio of 1 s or less, so pad short phrases ("Sim", "Ok") with silence.
        var audio = samples
        let minimum = 24_000    // 1.5 s
        if audio.count < minimum {
            audio.append(contentsOf: [Float](repeating: 0, count: minimum - audio.count))
        }
        let results = try await pipe.transcribe(
            audioArray: audio,
            decodeOptions: Self.dictationOptions(language, sampleCount: audio.count)
        )
        return Self.strip(results.map(\.text).joined(separator: " "))
    }

    /// Transcribes an audio file of any length and returns timestamped segments.
    func transcribeFile(at url: URL, language: String?, model: String) async throws -> [TimedText] {
        try await prepare(model: model)
        guard let pipe else { return [] }
        // An empty or unreadable track (e.g. no system audio arrived) simply has no lines.
        guard let audio = try? AudioProcessor.loadAudioAsFloatArray(fromPath: url.path),
              audio.count > 16_000 else { return [] }
        let results = try await pipe.transcribe(audioArray: audio, decodeOptions: Self.fileOptions(language))
        return results.flatMap(\.segments).compactMap { segment -> TimedText? in
            // Whisper invents text for silent stretches: keep only segments that contain sound.
            let from = max(0, Int(segment.start * 16_000))
            let to = min(audio.count, Int(segment.end * 16_000))
            guard to > from, Resampler.containsSpeech(audio[from..<to], minFrames: 1) else { return nil }
            let text = Self.strip(segment.text)
            return text.isEmpty ? nil : TimedText(start: segment.start, end: segment.end, text: text)
        }
        .sorted { $0.start < $1.start }
    }

    /// Short push-to-talk audio: no timestamps, no special tokens, at most one retry.
    private static func dictationOptions(_ language: String?, sampleCount: Int) -> DecodingOptions {
        let fitsOneWindow = sampleCount <= 480_000      // 30 s at 16 kHz
        return DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: fitsOneWindow,           // longer hands-free audio needs timestamps to seek
            wordTimestamps: false,
            chunkingStrategy: fitsOneWindow ? nil : .vad
        )
    }

    /// Meeting files: keep timestamps, split on silence and decode the chunks concurrently.
    private static func fileOptions(_ language: String?) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 2,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            chunkingStrategy: .vad
        )
    }

    /// Removes Whisper control tokens such as <|pt|> and <|0.00|>.
    private static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
