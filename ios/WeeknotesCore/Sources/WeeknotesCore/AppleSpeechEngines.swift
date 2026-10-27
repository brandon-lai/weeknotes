@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import OSLog
import Speech

let speechLog = Logger(subsystem: "com.blai.weeknotes", category: "speech")

/// Apple's on-device speech models through SpeechAnalyzer (iOS 26).
///
/// - "apple-speech": `SpeechTranscriber`. The MVP default: free, fast, live partial results.
///   It ignores contextual strings, so names are fixed later, in stages 3 and 4.
/// - "apple-dictation": `DictationTranscriber`, which accepts up to 100 contextual strings
///   (friends' names). The bake-off decides whether it wins on names.
public final class AppleSpeechEngine: TranscriptionEngine, @unchecked Sendable {
    public enum Model: Sendable {
        case speech
        case dictation
    }

    public let id: String
    let model: Model
    let requestedLocale: Locale
    private let lock = NSLock()
    private var vocabulary: [String] = []
    private var resolvedLocale: Locale?

    public init(model: Model = .speech, locale: Locale = .current) {
        self.model = model
        self.requestedLocale = locale
        self.id = model == .speech ? "apple-speech" : "apple-dictation"
    }

    /// Whether this model can run here at all. SpeechTranscriber reports itself unavailable on
    /// devices without the model, and in the iOS Simulator.
    public func isSupported() async -> Bool {
        guard let locale = try? await locale() else { return false }
        if model == .speech && !SpeechTranscriber.isAvailable { return false }
        let status = await AssetInventory.status(forModules: [makeModule(locale: locale, live: false)])
        return status != .unsupported
    }

    public func prepare(vocabulary: [String]) async throws {
        lock.withLock { self.vocabulary = Array(vocabulary.prefix(AppConfig.vocabularyLimit)) }
        let locale = try await locale()
        let module = makeModule(locale: locale, live: false)
        let reserved = await AssetInventory.reservedLocales
        speechLog.info("prepare \(self.id, privacy: .public) locale=\(locale.identifier, privacy: .public) reserved=\(reserved.map(\.identifier), privacy: .public) available=\(SpeechTranscriber.isAvailable)")
        // On iOS the app must reserve the locale before it can check or download its assets
        // ("not subscribed to transcription.en" otherwise)
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            do {
                let ok = try await AssetInventory.reserve(locale: locale)
                speechLog.info("reserve \(locale.identifier, privacy: .public) -> \(ok)")
            } catch {
                speechLog.error("reserve failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        let status = await AssetInventory.status(forModules: [module])
        speechLog.info("asset status \(String(describing: status), privacy: .public)")
        if status == .unsupported || (model == .speech && !SpeechTranscriber.isAvailable) {
            throw TranscriptionError.modelUnavailable("not supported on this device")
        }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                speechLog.info("downloading speech assets")
                try await request.downloadAndInstall()
            }
        } catch {
            speechLog.error("asset request failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func locale() async throws -> Locale {
        if let cached = lock.withLock({ resolvedLocale }) { return cached }
        let supported: Locale?
        switch model {
        case .speech:
            supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        case .dictation:
            supported = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale)
        }
        guard let supported else { throw TranscriptionError.unsupportedLocale }
        lock.withLock { resolvedLocale = supported }
        return supported
    }

    func makeModule(locale: Locale, live: Bool) -> any SpeechModule {
        switch model {
        case .speech:
            return SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: live ? [.volatileResults, .fastResults] : [],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )
        case .dictation:
            return DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: live ? [.volatileResults, .frequentFinalization] : [],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )
        }
    }

    private func context() -> AnalysisContext {
        let context = AnalysisContext()
        let words = lock.withLock { vocabulary }
        if model == .dictation && !words.isEmpty {
            context.contextualStrings = [.general: words]
        }
        return context
    }

    /// Partial results as they come (`isFinal == false` replaces the previous partial), and
    /// final results to keep.
    public func liveTranscribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptChunk, Error> {
        // Buffers move from the producer to this task and are never touched again by it
        let input = UnsafeTransfer(audio)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let locale = try await self.locale()
                    let module = self.makeModule(locale: locale, live: true)
                    let analyzer = SpeechAnalyzer(modules: [module])
                    try await analyzer.setContext(self.context())
                    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                        throw TranscriptionError.modelUnavailable("no audio format")
                    }
                    try await analyzer.prepareToAnalyze(in: format)
                    let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
                    try await analyzer.start(inputSequence: inputs)

                    let results = Task {
                        for try await chunk in Self.chunks(from: module) { continuation.yield(chunk) }
                    }
                    let converter = BufferConverter(to: format)
                    for await buffer in input.value {
                        if let converted = try converter.convert(buffer) { feed.yield(AnalyzerInput(buffer: converted)) }
                    }
                    feed.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    try await results.value
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func transcribeFile(at url: URL) async throws -> Transcript {
        let locale = try await locale()
        let module = makeModule(locale: locale, live: false)
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.setContext(context())
        let collector = Task { () -> [TranscriptChunk] in
            var finals: [TranscriptChunk] = []
            for try await chunk in Self.chunks(from: module) where chunk.isFinal { finals.append(chunk) }
            return finals
        }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let finals = try await collector.value
        let words = finals.flatMap(\.words)
        let text = finals.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return Transcript(text: text, words: words, engineID: id, durationMs: Int(duration * 1000))
    }

    static func chunks(from module: any SpeechModule) -> AsyncThrowingStream<TranscriptChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let transcriber = module as? SpeechTranscriber {
                        for try await result in transcriber.results {
                            continuation.yield(TranscriptChunk(text: String(result.text.characters), isFinal: result.isFinal, words: words(in: result.text)))
                        }
                    } else if let transcriber = module as? DictationTranscriber {
                        for try await result in transcriber.results {
                            continuation.yield(TranscriptChunk(text: String(result.text.characters), isFinal: result.isFinal, words: words(in: result.text)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Word timings and confidence from the result's attributed runs.
    static func words(in text: AttributedString) -> [TimedWord] {
        var words: [TimedWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            let range = run.audioTimeRange
            let start = range.map { $0.start.seconds } ?? 0
            let end = range.map { $0.end.seconds } ?? 0
            let confidence = run.transcriptionConfidence.map { Float($0) }
            // A run can hold more than one word when attributes match; split evenly
            let parts = piece.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count <= 1 {
                words.append(TimedWord(text: piece, start: start.isFinite ? start : 0, end: end.isFinite ? end : 0, confidence: confidence))
            } else {
                let step = (end - start) / Double(parts.count)
                for (i, part) in parts.enumerated() {
                    words.append(TimedWord(text: part, start: start + step * Double(i), end: start + step * Double(i + 1), confidence: confidence))
                }
            }
        }
        return words
    }
}

/// Converts microphone buffers to whatever format the speech model wants.
final class BufferConverter {
    let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to format: AVAudioFormat) {
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let consumed = Flag()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed.isSet {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed.isSet = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error, let error { throw error }
        return output.frameLength > 0 ? output : nil
    }
}

/// Plays an audio file into a buffer stream at real-time speed, standing in for the
/// microphone in tests and the bake-off.
public enum AudioFileStream {
    public static func buffers(from url: URL, realTime: Bool = true, chunk: AVAudioFrameCount = 4096) throws -> AsyncStream<AVAudioPCMBuffer> {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        return AsyncStream { continuation in
            let task = Task {
                while file.framePosition < file.length, !Task.isCancelled {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                    do { try file.read(into: buffer, frameCount: chunk) } catch { break }
                    // A fresh buffer per read, handed off and never reused here
                    nonisolated(unsafe) let handoff = buffer
                    continuation.yield(handoff)
                    if realTime {
                        try? await Task.sleep(for: .seconds(Double(buffer.frameLength) / format.sampleRate))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Hands a non-Sendable value to another task that becomes its only user.
public struct UnsafeTransfer<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

private final class Flag: @unchecked Sendable {
    var isSet = false
}
