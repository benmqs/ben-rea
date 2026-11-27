import AppKit
import AVFoundation
import SwiftUI

enum DictationState: Equatable {
    case idle
    case loadingModel
    case listening
    case transcribing
    case cleaning
    case meetingRecording(seconds: Int)
    case meetingProcessing(String)
    case done(String)
    case error(String)
    case needsPermission(Permission)

    var bubbleLabel: String {
        switch self {
        case .idle: ""
        case .loadingModel: "Loading speech model…"
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .cleaning: "Polishing…"
        case .meetingRecording(let s): String(format: "Recording meeting  %d:%02d", s / 60, s % 60)
        case .meetingProcessing(let step): step
        case .done(let msg): msg
        case .error(let msg): msg
        case .needsPermission(let p): p.message
        }
    }

    var menuLabel: String {
        switch self {
        case .idle, .done: "Ready"
        default: bubbleLabel
        }
    }

    var isMeeting: Bool {
        switch self {
        case .meetingRecording, .meetingProcessing: true
        default: false
        }
    }
}

/// Runs dictation (hold key -> record -> release -> transcribe -> clean up -> paste or copy)
/// and meeting recording (mic + system audio -> transcript -> notes).
@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var lastText: String?
    @Published private(set) var lastMeetingFolder: URL?

    let settings = AppSettings()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private lazy var hotkey = HotkeyMonitor { [settings] in settings.hotkey.keyCode }
    private lazy var bubble = BubblePanel(controller: self)
    private var recordingStartedAt: Date?
    private var hideTask: Task<Void, Never>?
    private var meeting: MeetingSession?
    /// Started by a click: keeps listening until the finish button or another click.
    private var handsFree = false

    private var isReadyForDictation: Bool {
        switch state {
        case .idle, .done, .error: true
        default: false
        }
    }

    /// Shorter holds are treated as an accidental tap (or Option used as a modifier) and ignored.
    private let minimumHold: TimeInterval = 0.35

    private var claude: ClaudeClient {
        ClaudeClient(apiKey: settings.anthropicKey, model: settings.cleanupModel)
    }

    func start() {
        recorder.onLevel = { [weak self] in self?.level = $0 }
        hotkey.onPress = { [weak self] in Task { @MainActor in self?.beginRecording() } }
        hotkey.onRelease = { [weak self] in Task { @MainActor in await self?.finishRecording() } }
        hotkey.start()
        bubble.show()

        Task {
            // Warm the model in the background so the first dictation is fast.
            show(.loadingModel)
            do {
                try await transcriber.prepare(model: settings.whisperModel)
            } catch {
                show(.error("Couldn't load speech model"), hideAfter: 4)
                return
            }
            await ensurePermissions()
            show(.done("Ready: click me or hold \(settings.hotkey.label)"), hideAfter: 3)
        }
    }

    /// Waits until Microphone and Accessibility are granted, showing which one is missing.
    private func ensurePermissions() async {
        if !(await AudioRecorder.requestPermission()) {
            show(.needsPermission(.microphone))
            while AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if !Permissions.hasAccessibility {
            show(.needsPermission(.accessibility))
            while !Permissions.hasAccessibility {
                try? await Task.sleep(for: .seconds(2))
            }
            // Key monitors added before access was granted don't receive events: re-add them.
            hotkey.stop()
            hotkey.start()
        }
    }

    func openMeetingsFolder() {
        let folder = URL.documentsDirectory.appending(path: "Fala/Meetings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(lastMeetingFolder ?? folder)
    }

    // MARK: - Dictation

    /// Click on the bubble: start hands-free dictation, or finish it if already listening.
    func toggleDictation() {
        if state == .listening {
            Task { await finishRecording(force: true) }
        } else {
            beginRecording(handsFree: true)
        }
    }

    /// Stops listening and throws the audio away.
    func cancelDictation() {
        guard state == .listening else { return }
        _ = recorder.stop()
        recordingStartedAt = nil
        handsFree = false
        hide()
    }

    private func beginRecording(handsFree: Bool = false) {
        // The microphone is busy while a meeting records; never start over a pending permission prompt.
        guard isReadyForDictation else { return }
        self.handsFree = handsFree
        do {
            recorder.onChunk = nil
            try recorder.start(keepSamples: true)
            recordingStartedAt = Date()
            show(.listening)
        } catch {
            show(.error("Microphone unavailable"), hideAfter: 3)
        }
    }

    /// Key released (or finish clicked). A release ends only hold-to-talk dictation.
    private func finishRecording(force: Bool = false) async {
        guard state == .listening, let started = recordingStartedAt else { return }
        if handsFree && !force { return }
        let samples = recorder.stop()
        recordingStartedAt = nil
        handsFree = false

        guard force || Date().timeIntervalSince(started) >= minimumHold,
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
                    text = try await TextCleaner(client: claude, vocabulary: settings.vocabularyList).clean(raw)
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

    // MARK: - Meetings

    func toggleMeeting() {
        if case .meetingRecording = state {
            Task { await stopMeeting() }
        } else if isReadyForDictation {
            Task { await startMeeting() }
        }
    }

    private func startMeeting() async {
        do {
            let session = try MeetingSession.create()
            recorder.onChunk = { [sink = session.micSink] in sink.append($0) }
            try recorder.start(keepSamples: false)
            do {
                try await session.system.start()
            } catch {
                // Still useful with the mic alone (e.g. in-person meetings).
                session.systemAudioFailed = true
                NSLog("Fala system audio unavailable: %@", String(describing: error))
            }
            meeting = session
            show(.meetingRecording(seconds: 0))
            session.ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, case .meetingRecording = self.state else { return }
                    self.state = .meetingRecording(seconds: Int(Date().timeIntervalSince(session.startedAt)))
                }
            }
        } catch {
            _ = recorder.stop()
            show(.error("Couldn't start recording"), hideAfter: 3)
            NSLog("Fala meeting start error: %@", String(describing: error))
        }
    }

    private func stopMeeting() async {
        guard let session = meeting else { return }
        meeting = nil
        session.ticker?.cancel()
        _ = recorder.stop()
        recorder.onChunk = nil
        await session.system.stop()
        session.micSink.close()
        session.systemSink.close()

        do {
            show(.meetingProcessing("Transcribing meeting…"))
            let language = settings.language.whisperCode
            let model = settings.whisperModel
            let mine = try await transcriber.transcribeFile(at: session.micSink.url, language: language, model: model)
            let theirs = session.systemAudioFailed
                ? []
                : try await transcriber.transcribeFile(at: session.systemSink.url, language: language, model: model)
            let transcript = MeetingSession.mergeTranscript(you: mine, others: theirs)

            var notes: String?
            if settings.cleanupEnabled, !transcript.isEmpty {
                show(.meetingProcessing("Writing notes…"))
                notes = try? await MeetingSummarizer(client: claude).summarize(transcript)
            }

            let file = try session.writeMarkdown(transcript: transcript, notes: notes)
            lastMeetingFolder = session.folder
            NSWorkspace.shared.open(file)
            show(.done("Meeting saved"), hideAfter: 2)
        } catch {
            show(.error("Meeting transcription failed"), hideAfter: 4)
            NSLog("Fala meeting error: %@", String(describing: error))
        }
    }

    // MARK: - Bubble

    private func show(_ newState: DictationState, hideAfter: TimeInterval? = nil) {
        hideTask?.cancel()
        state = newState
        bubble.position()
        if let hideAfter {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(hideAfter))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    /// Returns the bubble to its small resting state (it stays on screen).
    private func hide() {
        hideTask?.cancel()
        state = .idle
    }
}
