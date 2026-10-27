@preconcurrency import AVFAudio
import Foundation
import Speech

/// "apple-sfspeech": Apple's older recognizer (`SFSpeechRecognizer`), the speech engine on
/// iOS 18, where SpeechAnalyzer doesn't exist. Unlike `SpeechTranscriber` it accepts
/// contextual strings, so friends' names still bias recognition (stage 1).
///
/// It runs on device when the phone supports that for the language. Otherwise Apple's servers
/// recognize the audio, which they cap at about a minute, so long memos throw and the app
/// falls back to hosted transcription.
public final class LegacySpeechEngine: TranscriptionEngine, @unchecked Sendable {
    public let id = "apple-sfspeech"
    private let recognizer: SFSpeechRecognizer?
    private let lock = NSLock()
    private var vocabulary: [String] = []
    /// Server recognition stops after about a minute of audio.
    static let serverLimit: TimeInterval = 55

    public init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// The recognizer exists for this language and can run right now.
    public var isSupported: Bool { recognizer?.isAvailable == true }

    public var runsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition == true }

    public func prepare(vocabulary: [String]) async throws {
        lock.withLock { self.vocabulary = Array(vocabulary.prefix(AppConfig.vocabularyLimit)) }
        guard let recognizer else { throw TranscriptionError.unsupportedLocale }
        guard recognizer.isAvailable else { throw TranscriptionError.modelUnavailable("speech recognition isn't available right now") }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            if status != .authorized { throw TranscriptionError.permissionDenied }
        default:
            throw TranscriptionError.permissionDenied
        }
    }

    private func configure(_ request: SFSpeechRecognitionRequest) {
        request.contextualStrings = lock.withLock { vocabulary }
        request.addsPunctuation = true
        request.taskHint = .dictation
        if runsOnDevice { request.requiresOnDeviceRecognition = true }
    }

    public func liveTranscribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptChunk, Error> {
        let input = UnsafeTransfer(audio)
        return AsyncThrowingStream { continuation in
            guard let recognizer = self.recognizer else {
                continuation.finish(throwing: TranscriptionError.unsupportedLocale)
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.configure(request)
            let state = LiveState()
            let task = UnsafeTransfer(recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    for chunk in state.chunks(for: result) { continuation.yield(chunk) }
                    if result.isFinal { continuation.finish() }
                } else if let error {
                    // Ending the audio with nothing said reports "no speech"; that's not a failure
                    if state.hasText { continuation.finish() } else { continuation.finish(throwing: error) }
                }
            })
            let feeder = Task {
                for await buffer in input.value { request.append(buffer) }
                request.endAudio()
            }
            continuation.onTermination = { _ in
                feeder.cancel()
                task.value.finish()
            }
        }
    }

    public func transcribeFile(at url: URL) async throws -> Transcript {
        guard let recognizer else { throw TranscriptionError.unsupportedLocale }
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        if !runsOnDevice && duration > Self.serverLimit {
            throw TranscriptionError.modelUnavailable("too long for server recognition")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        // Partials on: after a long pause the recognizer restarts from empty, and only the
        // partials show where that happened. Each restart's text is kept (Segments).
        request.shouldReportPartialResults = true
        configure(request)
        let segments = Segments()
        let (text, words): (String, [TimedWord]) = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    segments.update(text: result.bestTranscription.formattedString, words: Self.words(result.bestTranscription))
                    if result.isFinal { once.run { continuation.resume(returning: segments.finish()) } }
                } else if let error {
                    let partial = segments.finish()
                    once.run {
                        if partial.0.isEmpty { continuation.resume(throwing: error) } else { continuation.resume(returning: partial) }
                    }
                }
            }
        }
        return Transcript(text: text, words: words, engineID: id, durationMs: Int(duration * 1000))
    }

    static func words(_ transcription: SFTranscription) -> [TimedWord] {
        transcription.segments.map { segment in
            TimedWord(
                text: segment.substring,
                start: segment.timestamp,
                end: segment.timestamp + segment.duration,
                confidence: segment.confidence > 0 ? segment.confidence : nil
            )
        }
    }

    /// Partial results are cumulative ("the whole utterance so far"). On device, a long pause
    /// sometimes restarts the transcription from empty; when the text suddenly shrinks, what
    /// came before is kept as final instead of disappearing.
    final class LiveState: @unchecked Sendable {
        private let lock = NSLock()
        private var lastText = ""
        private var lastWords: [TimedWord] = []
        private(set) var hasText = false

        func chunks(for result: SFSpeechRecognitionResult) -> [TranscriptChunk] {
            lock.withLock {
                let text = result.bestTranscription.formattedString
                let words = LegacySpeechEngine.words(result.bestTranscription)
                var out: [TranscriptChunk] = []
                if !lastText.isEmpty && text.count < lastText.count / 2 && !lastText.hasPrefix(text) {
                    out.append(TranscriptChunk(text: lastText, isFinal: true, words: lastWords))
                }
                hasText = hasText || !text.isEmpty
                lastText = text
                lastWords = words
                out.append(TranscriptChunk(text: text, isFinal: result.isFinal, words: result.isFinal ? words : []))
                if result.isFinal {
                    lastText = ""
                    lastWords = []
                }
                return out
            }
        }
    }

    /// Collects a file's transcription across the recognizer's restarts.
    final class Segments: @unchecked Sendable {
        private let lock = NSLock()
        private var committed: [(String, [TimedWord])] = []
        private var current: (String, [TimedWord]) = ("", [])

        func update(text: String, words: [TimedWord]) {
            lock.withLock {
                let previous = current.0
                if !previous.isEmpty && text.count < previous.count / 2 && !previous.hasPrefix(text) {
                    committed.append(current)
                }
                current = (text, words)
            }
        }

        func finish() -> (String, [TimedWord]) {
            lock.withLock {
                let all = committed + [current]
                let text = all.map { $0.0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
                return (text, all.flatMap(\.1))
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { body() }
        }
    }
}
