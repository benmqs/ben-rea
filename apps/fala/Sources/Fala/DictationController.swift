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
        case .meetingRecording(let s): String(format: "%d:%02d", s / 60, s % 60)
        case .meetingProcessing(let step): step
        case .done(let msg): msg
        case .error(let msg): msg
        case .needsPermission(let p): p.message
        }
    }

    var menuLabel: String {
        switch self {
        case .idle, .done: "Ready"
        case .meetingRecording: "Recording meeting  " + bubbleLabel
        default: bubbleLabel
        }
    }

    var isMeeting: Bool {
        switch self {
        case .meetingRecording, .meetingProcessing: true
        default: false
        }
    }

    /// Nothing in progress: the pill is at rest (or showing a result that is about to fade).
    var isResting: Bool {
        switch self {
        case .idle, .done, .error: true
        default: false
        }
    }
}

/// Runs dictation (hold key or click -> record -> transcribe -> clean up -> paste)
/// and meeting recording (mic + system audio -> transcript -> notes).
@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var lastText: String?
    @Published private(set) var lastMeetingFolder: URL?
    /// Started by a click: keeps listening until the finish button or another click.
    @Published private(set) var handsFree = false

    let settings = AppSettings()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private lazy var hotkey = HotkeyMonitor { [settings] in settings.hotkey.keyCode }
    private lazy var bubble = BubblePanel(controller: self)
    private var recordingStartedAt: Date?
    private var hideTask: Task<Void, Never>?
    private var meeting: MeetingSession?
    /// Dictations are processed one at a time, in order, so WhisperKit is never entered twice.
    private var pipeline: Task<Void, Never>?
    /// Dictations recorded but not yet pasted.
    private var pending = 0

    /// Shorter holds are treated as an accidental tap and ignored.
    private let minimumHold: TimeInterval = 0.35

    private var claude: ClaudeClient {
        ClaudeClient(apiKey: settings.anthropicKey, model: settings.cleanupModel)
    }

    /// A new dictation may start, including while the model loads or an earlier one is processed.
    private var isReadyForDictation: Bool {
        switch state {
        case .idle, .done, .error, .loadingModel, .transcribing, .cleaning: true
        default: false
        }
    }

    private var canStartMeeting: Bool {
        guard pending == 0 else { return false }
        switch state {
        case .idle, .done, .error, .loadingModel: return true
        default: return false
        }
    }

    func start() {
        // Read the key once now, so any Keychain prompt appears at launch and not mid-dictation.
        _ = settings.anthropicKey
        recorder.onLevel = { [weak self] in self?.level = $0 }
        hotkey.onPress = { [weak self] in Task { @MainActor in self?.beginRecording() } }
        hotkey.onRelease = { [weak self] in Task { @MainActor in await self?.finishRecording() } }
        hotkey.onCancel = { [weak self] in Task { @MainActor in self?.cancelHeldDictation() } }
        hotkey.start()
        bubble.show()

        show(.loadingModel)
        Task {
            // Download (first run), load and warm the model now, in parallel with the permission
            // prompts, so the first dictation is fast.
            let model = settings.whisperModel
            let load = Task { try await transcriber.prepare(model: model) }
            await ensurePermissions()   // always runs, so the hotkey is re-armed even if the load fails
            if case .needsPermission = state { show(.loadingModel) }
            do {
                try await load.value
                if state == .loadingModel, pending == 0 {
                    show(.done("Ready: click here or hold \(settings.hotkey.label)"), hideAfter: 4)
                }
            } catch {
                NSLog("Fala model load error: %@", String(describing: error))
                if state == .loadingModel, pending == 0 {
                    show(.error("Couldn't load speech model. Check your connection."), hideAfter: 6)
                }
            }
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
            hotkey.start()
        }
    }

    func openMeetingsFolder() {
        let folder = URL.documentsDirectory.appending(path: "Fala/Meetings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(lastMeetingFolder ?? folder)
    }

    /// Downloads and loads a newly chosen speech model now, visibly, not during the next dictation.
    func preloadModel(_ model: String) {
        guard state.isResting else { return }
        Task {
            show(.loadingModel)
            do {
                try await transcriber.prepare(model: model)
                if state == .loadingModel { settle() }
            } catch {
                if state == .loadingModel { show(.error("Couldn't load speech model"), hideAfter: 4) }
            }
        }
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

    /// The ✓ on the pill: finish and paste, however the dictation was started.
    func finishDictation() {
        guard state == .listening else { return }
        Task { await finishRecording(force: true) }
    }

    /// Stops listening and throws the audio away.
    func cancelDictation() {
        guard state == .listening else { return }
        _ = recorder.stop()
        recordingStartedAt = nil
        handsFree = false
        settle()
    }

    /// The push-to-talk key was used as a modifier for another key. Never cancels hands-free dictation.
    private func cancelHeldDictation() {
        guard state == .listening, !handsFree else { return }
        cancelDictation()
    }

    private func beginRecording(handsFree: Bool = false) {
        // Pressing the key during a click-started dictation finishes it.
        if state == .listening, self.handsFree, !handsFree {
            finishDictation()
            return
        }
        // The microphone is busy while a meeting records; never start over a pending permission prompt.
        guard isReadyForDictation else { return }
        do {
            recorder.onChunk = nil
            try recorder.start(keepSamples: true)
            self.handsFree = handsFree
            recordingStartedAt = Date()
            show(.listening)
            // Open the HTTPS connection while the user is still speaking.
            if settings.cleanupEnabled, !settings.anthropicKey.isEmpty { ClaudeClient.warmUp() }
        } catch {
            show(.error("Microphone unavailable"), hideAfter: 3)
        }
    }

    /// Key released (or finish clicked). A release ends only hold-to-talk dictation.
    private func finishRecording(force: Bool = false) async {
        guard state == .listening, let started = recordingStartedAt else { return }
        if handsFree && !force { return }
        recordingStartedAt = nil    // a second release or click during the tail is ignored
        let intended = force || Date().timeIntervalSince(started) >= minimumHold
        if intended {
            // Keep recording briefly so the end of the last word is not cut off.
            try? await Task.sleep(for: .milliseconds(200))
            guard state == .listening else { return }   // cancelled during the tail
        }
        let samples = recorder.stop()
        handsFree = false

        guard intended, samples.count > Int(AudioRecorder.sampleRate * 0.3) else {
            settle()
            return
        }
        // Whisper invents text for silence, so don't transcribe a recording with no sound in it.
        guard Resampler.containsSpeech(samples[...]) else {
            show(.error("Didn't hear anything"), hideAfter: 2)
            return
        }

        pending += 1
        show(.transcribing)
        let previous = pipeline
        pipeline = Task { [weak self] in
            await previous?.value
            await self?.process(samples)
        }
    }

    /// Back to rest, unless an earlier dictation is still being processed.
    private func settle() {
        hideTask?.cancel()
        state = pending > 0 ? .transcribing : .idle
    }

    /// Status from a background dictation must not replace the "Listening…" of a newer recording.
    private func status(_ newState: DictationState, hideAfter: TimeInterval? = nil) {
        guard state != .listening else { return }
        show(newState, hideAfter: hideAfter)
    }

    private func process(_ samples: [Float]) async {
        defer { pending -= 1 }
        let model = settings.whisperModel
        do {
            if !(await transcriber.isReady(model: model)) {
                status(.loadingModel)
                try await transcriber.prepare(model: model)
            }
            status(.transcribing)
            let clock = ContinuousClock()
            let t0 = clock.now
            let raw = try await transcriber.transcribe(
                samples, language: settings.language.whisperCode, model: model
            )
            let whisperTime = clock.now - t0
            guard !raw.isEmpty else {
                status(.error("Didn't catch that"), hideAfter: 2)
                return
            }

            var text = raw
            var note: String?
            var polishTime: Duration?
            // Nothing to call without an API key, and very short phrases are not worth a round trip.
            let wordCount = raw.split(whereSeparator: \.isWhitespace).count
            if settings.cleanupEnabled, wordCount >= 4, !settings.anthropicKey.isEmpty {
                status(.cleaning)
                let t1 = clock.now
                do {
                    text = try await TextCleaner(client: claude, vocabulary: settings.vocabularyList).clean(raw)
                } catch {
                    // Never lose the dictation because clean-up failed: fall back to the raw transcript.
                    note = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                polishTime = clock.now - t1
            }

            lastText = text
            let outcome = TextInserter.insert(text)

            // Show how long each step took, so slow steps are easy to spot.
            let seconds = { (d: Duration) in
                String(format: "%.1fs", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
            }
            var timing = "speech \(seconds(whisperTime))"
            if let polishTime { timing += " · polish \(seconds(polishTime))" }
            NSLog("Fala timing: %@ for %.1fs of audio", timing, Double(samples.count) / AudioRecorder.sampleRate)
            let verb: String
            switch outcome {
            case .pasted: verb = "Pasted"
            case .pastedKeptOnClipboard: verb = "Pasted + copied"
            case .copied: verb = "Copied, press ⌘V"
            }
            let label = verb + " · " + timing
            status(note == nil ? .done(label) : .error("\(label) (raw)"), hideAfter: 3)
            if let note { NSLog("Fala clean-up: %@", note) }
        } catch {
            status(.error("Transcription failed"), hideAfter: 3)
            NSLog("Fala transcription error: %@", String(describing: error))
        }
    }

    // MARK: - Meetings

    func toggleMeeting() {
        if case .meetingRecording = state {
            show(.meetingProcessing("Transcribing meeting…"))
            Task { await stopMeeting() }
        } else if canStartMeeting {
            // Claim the state before any await, so dictation or a second start cannot grab the recorder.
            show(.meetingProcessing("Starting meeting…"))
            Task { await startMeeting() }
        }
    }

    private func startMeeting() async {
        let session: MeetingSession
        do {
            session = try MeetingSession.create()
        } catch {
            show(.error("Couldn't start recording"), hideAfter: 3)
            NSLog("Fala meeting start error: %@", String(describing: error))
            return
        }
        do {
            recorder.onChunk = { [sink = session.micSink] in sink.append($0) }
            try recorder.start(keepSamples: false)
        } catch {
            _ = recorder.stop()
            recorder.onChunk = nil
            session.micSink.close()
            session.systemSink.close()
            try? FileManager.default.removeItem(at: session.folder)
            show(.error("Couldn't start recording"), hideAfter: 3)
            NSLog("Fala meeting start error: %@", String(describing: error))
            return
        }
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
    }

    private func transcribeTrack(_ url: URL, name: String) async -> (segments: [TimedText], problem: String?) {
        do {
            let segments = try await transcriber.transcribeFile(
                at: url, language: settings.language.whisperCode, model: settings.whisperModel
            )
            return (segments, nil)
        } catch {
            NSLog("Fala meeting %@ track error: %@", name, String(describing: error))
            return ([], "The \(name) track could not be transcribed; its audio file is in this folder.")
        }
    }

    private func stopMeeting() async {
        guard let session = meeting else {
            settle()
            return
        }
        meeting = nil
        session.ticker?.cancel()
        _ = recorder.stop()
        recorder.onChunk = nil
        await session.system.stop()
        session.micSink.close()
        session.systemSink.close()

        show(.meetingProcessing("Transcribing meeting…"))
        // Set first, so "Open meeting notes folder" leads to the recordings whatever happens next.
        lastMeetingFolder = session.folder
        var problems: [String] = []

        let mine = await transcribeTrack(session.micSink.url, name: "microphone")
        if let problem = mine.problem { problems.append(problem) }
        var theirs: [TimedText] = []
        if !session.systemAudioFailed {
            let result = await transcribeTrack(session.systemSink.url, name: "system audio")
            theirs = result.segments
            if let problem = result.problem { problems.append(problem) }
        }
        let transcript = MeetingSession.mergeTranscript(you: mine.segments, others: theirs)

        var notes: String?
        if settings.cleanupEnabled, !settings.anthropicKey.isEmpty, !transcript.isEmpty {
            show(.meetingProcessing("Writing notes…"))
            do {
                notes = try await MeetingSummarizer(client: claude).summarize(transcript)
            } catch {
                NSLog("Fala meeting notes error: %@", String(describing: error))
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                problems.append("Notes were not written: \(reason)")
            }
        }
        if !problems.isEmpty {
            notes = (notes.map { $0 + "\n\n" } ?? "") + problems.map { "> " + $0 }.joined(separator: "\n>\n")
        }

        do {
            let file = try session.writeMarkdown(transcript: transcript, notes: notes)
            NSWorkspace.shared.open(file)
            show(problems.isEmpty ? .done("Meeting saved") : .error("Meeting saved, with problems (see notes)"),
                 hideAfter: 4)
        } catch {
            show(.error("Couldn't save meeting notes"), hideAfter: 4)
            NSLog("Fala meeting error: %@", String(describing: error))
        }
    }

    // MARK: - Bubble

    private func show(_ newState: DictationState, hideAfter: TimeInterval? = nil) {
        hideTask?.cancel()
        // Pick the display only when a session starts, so the pill does not jump mid-dictation.
        let startsSession = state.isResting
        state = newState
        if startsSession { bubble.position() }
        if let hideAfter {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(hideAfter))
                guard !Task.isCancelled else { return }
                self?.settle()
            }
        }
    }
}
