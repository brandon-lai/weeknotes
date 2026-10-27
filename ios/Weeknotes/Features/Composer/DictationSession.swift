import Foundation
import Speech
import WeeknotesCore

/// Live dictation for the composer: microphone → speech engine (live partial text) →
/// stages 2 to 5 on finished sentences while the user talks → formatted text on stop.
/// The audio is never stored; buffers are dropped as soon as the engine has them.
@Observable
final class DictationSession {
    enum State: Equatable {
        case idle
        case preparing
        case listening
        case finishing
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Raw text while talking: finished results plus the current partial.
    private(set) var liveText = ""
    private(set) var level: Float = 0

    private var finals: [String] = []
    private var mic: MicrophoneStream?
    private var work: Task<FormattedResult?, Never>?

    var isActive: Bool { state == .preparing || state == .listening || state == .finishing }

    func start(engine: any TranscriptionEngine, pipeline: DictationPipeline, context: FormattingContext) async {
        guard !isActive else { return }
        state = .preparing
        liveText = ""
        finals = []
        let usingFixture = LaunchOptions.dictationFixture != nil
        if !usingFixture {
            guard await AudioPermission.requestMicrophone() else {
                state = .failed("Weeknotes needs the microphone to dictate. You can allow it in Settings.")
                return
            }
        }
        if !usingFixture && SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        do {
            try await engine.prepare(vocabulary: context.vocabulary)
            let mic = MicrophoneStream()
            let audio = try mic.start { [weak self] level in self?.level = level }
            self.mic = mic
            state = .listening
            let live = LiveDictationFormatter(pipeline: pipeline, context: context)
            let stream = engine.liveTranscribe(audio)
            work = Task { [weak self] in
                do {
                    for try await chunk in stream {
                        guard let self else { break }
                        if chunk.isFinal {
                            let text = chunk.text.trimmingCharacters(in: .whitespaces)
                            if !text.isEmpty { self.finals.append(text) }
                            self.liveText = self.finals.joined(separator: " ")
                            await live.append(chunk.words.isEmpty ? DictationPipeline.untimedWords(text) : chunk.words)
                        } else {
                            self.liveText = (self.finals + [chunk.text]).joined(separator: " ")
                        }
                    }
                    return await live.finish()
                } catch {
                    self?.state = .failed(error.localizedDescription)
                    return nil
                }
            }
        } catch {
            mic?.stop()
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops listening and returns the formatted dictation (nil when nothing was heard).
    func stop() async -> FormattedResult? {
        guard state == .listening || state == .preparing else { return nil }
        state = .finishing
        mic?.stop()
        mic = nil
        let result = await work?.value
        work = nil
        if case .failed = state { return nil }
        state = .idle
        guard let result, !result.raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return result
    }

    func cancel() {
        mic?.stop()
        mic = nil
        work?.cancel()
        work = nil
        state = .idle
        liveText = ""
    }

    func clearError() {
        if case .failed = state { state = .idle }
    }
}
