import AppKit
import SwiftUI

enum DictationState: Equatable {
    case idle
    case loadingModel
    case listening
    case transcribing
    case cleaning
    case done(String)
    case error(String)

    var bubbleLabel: String {
        switch self {
        case .idle: ""
        case .loadingModel: "Loading speech model…"
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .cleaning: "Polishing…"
        case .done(let msg): msg
        case .error(let msg): msg
        }
    }

    var menuLabel: String {
        switch self {
        case .idle, .done: "Ready"
        default: bubbleLabel
        }
    }
}

/// Runs one dictation: hold key -> record -> release -> transcribe -> clean up -> paste or copy.
@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var lastText: String?

    let settings = AppSettings()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private lazy var hotkey = HotkeyMonitor { [settings] in settings.hotkey.keyCode }
    private lazy var bubble = BubblePanel(controller: self)
    private var recordingStartedAt: Date?
    private var hideTask: Task<Void, Never>?

    /// Shorter holds are treated as an accidental tap (or Option used as a modifier) and ignored.
    private let minimumHold: TimeInterval = 0.35

    func start() {
        recorder.onLevel = { [weak self] in self?.level = $0 }
        hotkey.onPress = { [weak self] in Task { @MainActor in self?.beginRecording() } }
        hotkey.onRelease = { [weak self] in Task { @MainActor in await self?.finishRecording() } }
        hotkey.start()

        Task {
            _ = await AudioRecorder.requestPermission()
            // Warm the model in the background so the first dictation is fast.
            show(.loadingModel)
            do {
                try await transcriber.prepare(model: settings.whisperModel)
                show(.done("Ready — hold \(settings.hotkey.label)"), hideAfter: 2)
            } catch {
                show(.error("Couldn't load speech model"), hideAfter: 4)
            }
        }
    }

    private func beginRecording() {
        guard state != .listening else { return }
        do {
            try recorder.start()
            recordingStartedAt = Date()
            show(.listening)
        } catch {
            show(.error("Microphone unavailable"), hideAfter: 3)
        }
    }

    private func finishRecording() async {
        guard state == .listening, let started = recordingStartedAt else { return }
        let samples = recorder.stop()
        recordingStartedAt = nil

        guard Date().timeIntervalSince(started) >= minimumHold,
              samples.count > Int(AudioRecorder.sampleRate * 0.3) else {
            hide()
            return
        }

        do {
            show(.transcribing)
            let raw = try await transcriber.transcribe(
                samples, language: settings.language.whisperCode, model: settings.whisperModel
            )
            guard !raw.isEmpty else {
                show(.error("Didn't catch that"), hideAfter: 2)
                return
            }

            var text = raw
            var note: String?
            if settings.cleanupEnabled {
                show(.cleaning)
                do {
                    text = try await TextCleaner(
                        apiKey: settings.anthropicKey,
                        model: settings.cleanupModel,
                        vocabulary: settings.vocabularyList
                    ).clean(raw)
                } catch {
                    // Never lose the dictation because clean-up failed: fall back to the raw transcript.
                    note = (error as? LocalizedError)?.errorDescription
                }
            }

            lastText = text
            let outcome = await TextInserter.insert(text)
            let label = outcome == .pasted ? "Pasted" : "Copied — press ⌘V"
            show(note == nil ? .done(label) : .error("\(label) (raw)"), hideAfter: 1.6)
            if let note { NSLog("Fala clean-up: %@", note) }
        } catch {
            show(.error("Transcription failed"), hideAfter: 3)
            NSLog("Fala transcription error: %@", String(describing: error))
        }
    }

    private func show(_ newState: DictationState, hideAfter: TimeInterval? = nil) {
        hideTask?.cancel()
        state = newState
        bubble.show()
        if let hideAfter {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(hideAfter))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    private func hide() {
        state = .idle
        bubble.hide()
    }
}
