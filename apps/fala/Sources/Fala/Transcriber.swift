import Foundation
import WhisperKit

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
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text)
            .joined(separator: " ")
            .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
