import AVFAudio
import Foundation

/// One recognized word with its position in the audio. Engines that don't report
/// timings or confidence (hosted models) leave `start`/`end` at 0 and `confidence` nil.
public struct TimedWord: Sendable, Codable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float?

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct TranscriptChunk: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public let words: [TimedWord]

    public init(text: String, isFinal: Bool, words: [TimedWord]) {
        self.text = text
        self.isFinal = isFinal
        self.words = words
    }
}

public struct Transcript: Sendable, Codable, Equatable {
    public let text: String
    public let words: [TimedWord]
    public let engineID: String
    public let durationMs: Int

    public init(text: String, words: [TimedWord], engineID: String, durationMs: Int) {
        self.text = text
        self.words = words
        self.engineID = engineID
        self.durationMs = durationMs
    }
}

/// Every speech-to-text engine sits behind this, so UI code never names one and the
/// bake-off screen can run the same audio through each. IDs: "apple-speech",
/// "apple-dictation", "whisperkit-turbo", "openai-hosted".
public protocol TranscriptionEngine: Sendable {
    var id: String { get }
    /// Model download, permissions, name biasing. Call before the first use and whenever
    /// the vocabulary changes.
    func prepare(vocabulary: [String]) async throws
    /// Partial and final chunks while the user talks. The stream finishes when `audio` does.
    func liveTranscribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptChunk, Error>
    func transcribeFile(at url: URL) async throws -> Transcript
}

public enum TranscriptionError: Error, LocalizedError, Equatable {
    case permissionDenied
    case unsupportedLocale
    case modelUnavailable(String)
    case notConfigured(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Speech recognition isn't allowed. You can turn it on in Settings."
        case .unsupportedLocale: "Dictation doesn't support your language on this device yet."
        case .modelUnavailable(let detail): "The speech model isn't ready: \(detail)"
        case .notConfigured(let detail): detail
        case .failed(let detail): detail
        }
    }
}

extension Array where Element == TimedWord {
    /// Plain text from words, with no space before punctuation-only tokens.
    public var joinedText: String {
        var out = ""
        for word in self {
            let text = word.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if out.isEmpty || TextTools.isPunctuationOnly(text) {
                out += text
            } else {
                out += " " + text
            }
        }
        return out
    }
}
