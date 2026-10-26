import AVFAudio
import Foundation
import Testing
@testable import WeeknotesCore

/// Stage 1 on real audio: macOS speech synthesis (`say`) speaks a weekly update, the file is
/// encoded like a voice memo (AAC, mono, 64 kbps), and Apple's on-device models transcribe it.
/// Runs on a Mac with macOS 26; skipped where `say` or the speech assets aren't available.
enum SpokenFixture {
    static let directory = FileManager.default.temporaryDirectory.appending(path: "weeknotes-speech-fixtures", directoryHint: .isDirectory)

    /// Speaks `text` with an optional silence after a word ("[[slnc 600]]"), returns an m4a.
    static func make(_ name: String, text: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let aiff = directory.appending(path: "\(name).aiff")
        let m4a = directory.appending(path: "\(name).m4a")
        if FileManager.default.fileExists(atPath: m4a.path()) { return m4a }
        try run("/usr/bin/say", ["-v", "Samantha", "-r", "150", "-o", aiff.path(), text])
        try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", "64000", "-c", "1", aiff.path(), m4a.path()])
        return m4a
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TranscriptionError.failed("\(tool) failed") }
    }

    static var available: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/say") && FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert")
    }
}

@Suite("Stage 1: Apple speech engines", .enabled(if: SpokenFixture.available), .serialized)
struct SpeechEngineTests {
    @Test func transcribesAMemoFileWithTimings() async throws {
        let url = try SpokenFixture.make("memo", text: "This week was pretty busy. We got dinner on Saturday and then I went for a long run.")
        let engine = AppleSpeechEngine(model: .speech, locale: Locale(identifier: "en_US"))
        try await engine.prepare(vocabulary: [])
        let transcript = try await engine.transcribeFile(at: url)
        let text = transcript.text.lowercased()
        #expect(text.contains("dinner"))
        #expect(text.contains("saturday"))
        #expect(text.contains("run"))
        #expect(transcript.engineID == "apple-speech")
        #expect(transcript.durationMs > 3000)
        #expect(transcript.words.count >= 10)
        #expect(transcript.words.contains { $0.end > 2 }, "words carry audio timings")
        let starts = transcript.words.map(\.start)
        #expect(starts == starts.sorted(), "timings are in order")
    }

    @Test func liveTranscriptionStreamsPartialsThenFinals() async throws {
        let url = try SpokenFixture.make("live", text: "Hung out with friends at the park and had pizza afterwards.")
        let engine = AppleSpeechEngine(model: .speech, locale: Locale(identifier: "en_US"))
        try await engine.prepare(vocabulary: [])
        var partials = 0
        var finals: [TranscriptChunk] = []
        for try await chunk in engine.liveTranscribe(try AudioFileStream.buffers(from: url, realTime: false)) {
            if chunk.isFinal { finals.append(chunk) } else { partials += 1 }
        }
        let text = finals.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("park"))
        #expect(text.contains("pizza"))
        #expect(partials > 0, "live dictation shows text while the speaker talks")
    }

    /// Stage 1 into stage 2 with real word timings: the spoken "question mark" at the end and
    /// "comma" after a pause become punctuation.
    @Test func spokenCommandsFromRealTimings() async throws {
        let url = try SpokenFixture.make("commands", text: "work was fine comma [[slnc 700]] can you come saturday question mark")
        let engine = AppleSpeechEngine(model: .speech, locale: Locale(identifier: "en_US"))
        try await engine.prepare(vocabulary: [])
        let transcript = try await engine.transcribeFile(at: url)
        let stage2 = SpokenCommands.apply(transcript.words, pauseThreshold: AppConfig.spokenCommandPause)
        #expect(stage2.hasSuffix("?"), "got: \(stage2) from \(transcript.words.map(\.text))")
        #expect(!stage2.lowercased().contains("question mark"))
    }

    @Test func dictationModelAcceptsContextualStrings() async throws {
        let url = try SpokenFixture.make("names", text: "I hung out with Jaylen and Priya on Friday.")
        let engine = AppleSpeechEngine(model: .dictation, locale: Locale(identifier: "en_US"))
        try await engine.prepare(vocabulary: ["Jaylen", "Priya"])
        let transcript = try await engine.transcribeFile(at: url)
        #expect(transcript.engineID == "apple-dictation")
        #expect(transcript.text.lowercased().contains("friday"), "got: \(transcript.text)")
    }
}
