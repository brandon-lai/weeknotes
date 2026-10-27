@preconcurrency import AVFoundation
import Foundation
import WeeknotesCore
import WhisperKit

/// Which speech and formatting engines the app uses. Config values, switchable on the internal
/// bake-off screen (PRD §12, "Transcription abstraction"). UI code asks this for an engine and
/// never names one.
@Observable
final class EngineSettings {
    static let transcriptionIDs = ["apple-speech", "apple-dictation", "apple-sfspeech", "whisperkit-turbo", "openai-hosted"]
    static let formattingIDs = ["apple-foundation", "hosted-small"]

    /// SpeechAnalyzer and Foundation Models arrived in iOS 26; on iOS 18 the app uses the
    /// older Apple recognizer and the hosted formatter.
    static var hasModernSpeech: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    var transcriptionID: String {
        didSet { UserDefaults.standard.set(transcriptionID, forKey: "engine.transcription") }
    }
    var primaryFormatterID: String {
        didSet { UserDefaults.standard.set(primaryFormatterID, forKey: "engine.formatting") }
    }

    init() {
        transcriptionID = UserDefaults.standard.string(forKey: "engine.transcription") ?? (Self.hasModernSpeech ? "apple-speech" : "apple-sfspeech")
        primaryFormatterID = UserDefaults.standard.string(forKey: "engine.formatting") ?? "apple-foundation"
    }

    static func name(_ id: String) -> String {
        switch id {
        case "apple-speech": "Apple Speech (SpeechTranscriber)"
        case "apple-dictation": "Apple Dictation (DictationTranscriber)"
        case "apple-sfspeech": "Apple Speech, iOS 18 (SFSpeechRecognizer)"
        case "whisperkit-turbo": "Whisper large-v3 turbo (WhisperKit)"
        case "openai-hosted": "OpenAI hosted"
        case "apple-foundation": "Apple Foundation Models (on device)"
        case "hosted-small": "Hosted small model (Claude Haiku)"
        default: id
        }
    }

    func transcriptionEngine(_ id: String? = nil, api: API?) -> any TranscriptionEngine {
        Self.makeEngine(id ?? transcriptionID, api: api)
    }

    /// The engine for an ID. The iOS 26 engines map to the iOS 18 recognizer on older systems.
    static func makeEngine(_ id: String, api: API?) -> any TranscriptionEngine {
        switch id {
        case "whisperkit-turbo": return WhisperKitEngine.shared
        case "openai-hosted": return OpenAIHostedEngine(accessToken: { [weak api] in await api?.accessToken() })
        case "apple-sfspeech": return LegacySpeechEngine()
        default:
            if #available(iOS 26.0, *) {
                return AppleSpeechEngine(model: id == "apple-dictation" ? .dictation : .speech)
            }
            return LegacySpeechEngine()
        }
    }

    /// The configured engine if it can run on this device, else the next one that can.
    /// iOS 26: Apple Speech → Apple Dictation → hosted (Apple's SpeechTranscriber doesn't run in
    /// the Simulator or on devices without its model). iOS 18: SFSpeechRecognizer → hosted.
    func availableTranscriptionEngine(api: API?) async -> any TranscriptionEngine {
        var order = [transcriptionID]
        let chain = Self.hasModernSpeech ? ["apple-speech", "apple-dictation", "openai-hosted"] : ["apple-sfspeech", "openai-hosted"]
        for fallback in chain where !order.contains(fallback) { order.append(fallback) }
        for id in order {
            let engine = Self.makeEngine(id, api: api)
            if #available(iOS 26.0, *), let apple = engine as? AppleSpeechEngine {
                if await apple.isSupported() { return apple }
                continue
            }
            if let legacy = engine as? LegacySpeechEngine {
                if legacy.isSupported { return legacy }
                continue
            }
            if id == "whisperkit-turbo" && !WhisperKitEngine.shared.isLoaded { continue }
            return engine
        }
        return Self.makeEngine("openai-hosted", api: api)
    }

    func hostedFormatter(api: API?) -> HostedFormatter? {
        guard let functions = AppEnvironment.functionsURL else { return nil }
        return HostedFormatter(functionsURL: functions, apiKey: AppEnvironment.supabaseAnonKey, accessToken: { [weak api] in await api?.accessToken() })
    }

    /// Apple's on-device formatter, or nil before iOS 26 (and when turned off for testing).
    static var onDeviceFormatter: (any FormattingEngine)? {
        if LaunchOptions.disableOnDeviceFormatting { return nil }
        if #available(iOS 26.0, *) { return AppleFoundationFormatter() }
        return nil
    }

    /// The formatting pipeline: on-device first, hosted as fallback (or the reverse, if the
    /// bake-off made the hosted model the default). On iOS 18 it's hosted only.
    func pipeline(api: API?) -> DictationPipeline {
        let hosted = hostedFormatter(api: api)
        let onDevice = Self.onDeviceFormatter
        if primaryFormatterID == "hosted-small" {
            return DictationPipeline(primary: hosted, fallback: onDevice)
        }
        return DictationPipeline(primary: onDevice, fallback: hosted)
    }

    var onDeviceFormattingStatus: String {
        if LaunchOptions.disableOnDeviceFormatting { return "Turned off for testing" }
        guard #available(iOS 26.0, *) else { return "Needs iOS 26 (uses the hosted model)" }
        switch AppleFoundationFormatter.unavailableReason {
        case nil: return "Available"
        case "deviceNotEligible": return "This iPhone doesn't support Apple Intelligence"
        case "appleIntelligenceNotEnabled": return "Apple Intelligence is turned off"
        case "modelNotReady": return "Downloading"
        default: return "Unavailable"
        }
    }
}

/// Whisper large-v3 turbo on device, through WhisperKit (MIT). Downloads the model (~630 MB)
/// on first use. Names are biased with a glossary prompt; Whisper reads only the last 224
/// prompt tokens, so the most important names go last.
nonisolated final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    static let shared = WhisperKitEngine()
    let id = "whisperkit-turbo"
    static let model = "openai_whisper-large-v3-v20240930_turbo_632MB"

    private let lock = NSLock()
    private var kit: WhisperKit?
    private var promptTokens: [Int]?

    /// Only the bake-off downloads Whisper; dictation uses it once it's there.
    var isLoaded: Bool { lock.withLock { kit != nil } }

    func prepare(vocabulary: [String]) async throws {
        let kit: WhisperKit
        if let existing = lock.withLock({ self.kit }) {
            kit = existing
        } else {
            kit = try await WhisperKit(WhisperKitConfig(model: Self.model, verbose: false, prewarm: true, load: true, download: true))
            lock.withLock { self.kit = kit }
        }
        let glossary = Vocabulary.whisperGlossary(vocabulary)
        let tokens = glossary.isEmpty ? nil : kit.tokenizer.map { tokenizer in
            Array(tokenizer.encode(text: " " + glossary).filter { $0 < tokenizer.specialTokens.specialTokenBegin }.suffix(224))
        }
        lock.withLock { promptTokens = tokens }
    }

    private func options() -> DecodingOptions {
        DecodingOptions(language: "en", usePrefillPrompt: true, wordTimestamps: true, promptTokens: lock.withLock { promptTokens }, chunkingStrategy: .vad)
    }

    func transcribeFile(at url: URL) async throws -> Transcript {
        guard let kit = lock.withLock({ self.kit }) else { throw TranscriptionError.modelUnavailable("Whisper isn't downloaded yet") }
        let started = Date()
        let results = try await kit.transcribe(audioPath: url.path(percentEncoded: false), decodeOptions: options())
        let words = results.flatMap { $0.segments }.flatMap { $0.words ?? [] }
            .map { TimedWord(text: $0.word.trimmingCharacters(in: .whitespaces), start: TimeInterval($0.start), end: TimeInterval($0.end), confidence: $0.probability) }
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        _ = started
        return Transcript(text: text, words: words, engineID: id, durationMs: Int(MemoRecorder.duration(of: url) * 1000))
    }

    /// Whisper isn't a streaming model: audio is collected and re-transcribed every few
    /// seconds for partial text, then once more at the end.
    func liveTranscribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptChunk, Error> {
        let input = UnsafeTransfer(audio)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let kit = self.lock.withLock({ self.kit }) else { throw TranscriptionError.modelUnavailable("Whisper isn't downloaded yet") }
                    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
                    var samples: [Float] = []
                    var converter: AVAudioConverter?
                    var lastPartial = Date()
                    for await buffer in input.value {
                        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: target) }
                        if let converted = Self.convert(buffer, with: converter, to: target), let data = converted.floatChannelData {
                            samples += UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength))
                        }
                        if Date().timeIntervalSince(lastPartial) > 3, samples.count > 16_000 {
                            lastPartial = Date()
                            let partial = try await kit.transcribe(audioArray: samples, decodeOptions: self.options())
                            continuation.yield(TranscriptChunk(text: partial.map(\.text).joined(separator: " "), isFinal: false, words: []))
                        }
                    }
                    let results = try await kit.transcribe(audioArray: samples, decodeOptions: self.options())
                    let words = results.flatMap { $0.segments }.flatMap { $0.words ?? [] }
                        .map { TimedWord(text: $0.word.trimmingCharacters(in: .whitespaces), start: TimeInterval($0.start), end: TimeInterval($0.end), confidence: $0.probability) }
                    continuation.yield(TranscriptChunk(text: results.map(\.text).joined(separator: " "), isFinal: true, words: words))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let given = UnsafeTransfer(buffer)
        nonisolated(unsafe) var done = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if done {
                status.pointee = .noDataNow
                return nil
            }
            done = true
            status.pointee = .haveData
            return given.value
        }
        return output
    }
}

/// The hosted fallback for memos (and the bake-off's hosted engine): audio goes to the
/// `transcribe` Edge Function, which calls OpenAI. Live use records to a file first.
nonisolated struct OpenAIHostedEngine: TranscriptionEngine {
    let id = "openai-hosted"
    let accessToken: @Sendable () async -> String?
    private let vocabulary = VocabularyBox()

    final class VocabularyBox: @unchecked Sendable {
        var words: [String] = []
    }

    func prepare(vocabulary: [String]) async throws {
        guard AppEnvironment.functionsURL != nil else { throw TranscriptionError.notConfigured("Hosted transcription isn't set up") }
        self.vocabulary.words = vocabulary
    }

    func transcribeFile(at url: URL) async throws -> Transcript {
        guard let base = AppEnvironment.functionsURL, let token = await accessToken() else {
            throw TranscriptionError.notConfigured("Sign in to use hosted transcription")
        }
        let boundary = "weeknotes-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("prompt", Vocabulary.whisperGlossary(vocabulary.words))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"memo.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: url))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: base.appending(path: "transcribe"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AppEnvironment.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Reply: Decodable { let text: String?; let error: String? }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = reply?.text else {
            throw TranscriptionError.failed(reply?.error ?? "Hosted transcription failed")
        }
        return Transcript(text: text, words: [], engineID: id, durationMs: Int(MemoRecorder.duration(of: url) * 1000))
    }

    func liveTranscribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptChunk, Error> {
        let input = UnsafeTransfer(audio)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString).m4a")
                    var file: AVAudioFile?
                    for await buffer in input.value {
                        if file == nil {
                            var settings = MemoRecorder.settings
                            settings[AVSampleRateKey] = buffer.format.sampleRate
                            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
                        }
                        try file?.write(from: buffer)
                    }
                    file = nil
                    let transcript = try await transcribeFile(at: url)
                    try? FileManager.default.removeItem(at: url)
                    continuation.yield(TranscriptChunk(text: transcript.text, isFinal: true, words: transcript.words))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
