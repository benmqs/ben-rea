import Foundation

/// One meeting recording: the folder it lives in, the two audio tracks, and the saved notes.
/// Your microphone and the computer's audio are recorded separately, which is what lets the
/// transcript say who spoke ("You" vs "Others") without speaker recognition.
@MainActor
final class MeetingSession {
    let folder: URL
    let startedAt = Date()
    let micSink: AudioFileSink
    let systemSink: AudioFileSink
    let system = SystemAudioCapture()
    var systemAudioFailed = false
    var ticker: Task<Void, Never>?

    private init(folder: URL) throws {
        self.folder = folder
        micSink = try AudioFileSink(url: folder.appending(path: "you.wav"))
        systemSink = try AudioFileSink(url: folder.appending(path: "others.wav"))
        system.onChunk = { [sink = systemSink] in sink.append($0) }
    }

    /// Creates ~/Documents/Fala/Meetings/<date time>/.
    static func create() throws -> MeetingSession {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let folder = URL.documentsDirectory
            .appending(path: "Fala/Meetings/\(formatter.string(from: Date()))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try MeetingSession(folder: folder)
    }

    /// Interleaves both tracks by time and joins consecutive lines from the same side.
    nonisolated static func mergeTranscript(you: [TimedText], others: [TimedText]) -> String {
        let lines = (you.map { ("You", $0) } + others.map { ("Others", $0) })
            .sorted { $0.1.start < $1.1.start }

        var blocks: [(speaker: String, start: Float, text: String)] = []
        for (speaker, segment) in lines {
            if let last = blocks.last, last.speaker == speaker {
                blocks[blocks.count - 1].text += " " + segment.text
            } else {
                blocks.append((speaker, segment.start, segment.text))
            }
        }
        return blocks.map { "[\(timestamp($0.start))] **\($0.speaker):** \($0.text)" }
            .joined(separator: "\n\n")
    }

    func writeMarkdown(transcript: String, notes: String?) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let minutes = Int(Date().timeIntervalSince(startedAt) / 60)

        var doc = "# Meeting, \(formatter.string(from: startedAt))\n\n"
        doc += "Duration: about \(max(minutes, 1)) min"
        if systemAudioFailed { doc += " · microphone only (system audio was not available)" }
        doc += "\n\n"
        if let notes, !notes.isEmpty { doc += notes + "\n\n" }
        doc += "## Transcript\n\n" + (transcript.isEmpty ? "_No speech detected._" : transcript) + "\n"

        let file = folder.appending(path: "notes.md")
        try doc.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private nonisolated static func timestamp(_ seconds: Float) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
