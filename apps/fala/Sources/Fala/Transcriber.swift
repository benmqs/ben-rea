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

    /// Downloads (first run only) and loads the model. Safe to call repeatedly.
    func prepare(model: String) async throws {
        if pipe != nil, loadedModel == model { return }
        pipe = try await WhisperKit(WhisperKitConfig(model: model))
        loadedModel = model
    }

    /// Transcribes 16 kHz mono samples. `language` nil means auto-detect.
    func transcribe(_ samples: [Float], language: String?, model: String) async throws -> String {
        try await prepare(model: model)
        guard let pipe else { return "" }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: Self.options(language))
        return Self.strip(results.map(\.text).joined(separator: " "))
    }

    /// Transcribes an audio file of any length and returns timestamped segments.
    func transcribeFile(at url: URL, language: String?, model: String) async throws -> [TimedText] {
        try await prepare(model: model)
        guard let pipe else { return [] }
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: Self.options(language))
        return results.flatMap(\.segments).compactMap { segment in
            let text = Self.strip(segment.text)
            return text.isEmpty ? nil : TimedText(start: segment.start, end: segment.end, text: text)
        }
    }

    private static func options(_ language: String?) -> DecodingOptions {
        DecodingOptions(task: .transcribe, language: language, detectLanguage: language == nil)
    }

    /// Removes Whisper control tokens such as <|pt|> and <|0.00|>.
    private static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
