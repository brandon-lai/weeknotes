import AVFAudio
import Foundation
import Testing
@testable import WeeknotesCore

/// M1: "formatted text within 1.5 seconds of tapping stop, for a 60-second dictation".
/// A 60-second spoken update plays into live transcription in real time; the clock starts
/// when the audio ends (the user taps stop) and stops when formatted text is ready.
/// Takes over a minute, so it runs only with WEEKNOTES_LATENCY=1. On a Mac this measures the
/// same pipeline the phone runs; the phone number itself needs a device (README).
@Suite("Latency", .enabled(if: ProcessInfo.processInfo.environment["WEEKNOTES_LATENCY"] == "1" && SpokenFixture.available))
struct LatencyTests {
    static let sixtySeconds = """
    okay so this week was um pretty full honestly. monday I started the new project at work and it was a lot of meetings \
    but the team is really nice. tuesday I went for a run with Jaylen before work, we did about three miles which felt good. \
    wednesday was quiet, I mostly cooked and watched the new season of that baking show. thursday Priya came over and we made \
    dumplings from scratch which took forever but they were so good. friday I was tired so I stayed in and read. \
    saturday we went to the farmers market and I bought way too many peaches, then we had a picnic in the park with Maya. \
    sunday I cleaned the apartment, called my mom, and planned next week. overall a good week, kind of tiring, but good. \
    next week I want to sleep more and maybe try the climbing gym that just opened near me. \
    I also need to finally fix my bike, the back tire has been flat for like two weeks now. \
    and I want to call my grandma, it has been a while and she always has the best stories.
    """

    @Test func formattedWithinBudgetAfterStop() async throws {
        #if canImport(FoundationModels)
        guard AppleFoundationFormatter.unavailableReason == nil else { return }
        let url = try SpokenFixture.make("sixty-seconds", text: Self.sixtySeconds)
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(seconds > 50, "fixture is \(seconds)s")

        let engine = AppleSpeechEngine(model: .speech, locale: Locale(identifier: "en_US"))
        try await engine.prepare(vocabulary: ["Jaylen", "Priya", "Maya"])
        let clock = ContinuousClock()
        var finals: [TranscriptChunk] = []
        let stopped = StopTime()
        let audio = UnsafeTransfer(try AudioFileStream.buffers(from: url, realTime: true))
        let tracked = AsyncStream<AVAudioPCMBuffer> { continuation in
            Task {
                for await buffer in audio.value {
                    nonisolated(unsafe) let handoff = buffer
                    continuation.yield(handoff)
                }
                stopped.set(clock.now)
                continuation.finish()
            }
        }
        let pipeline = DictationPipeline(primary: AppleFoundationFormatter(), fallback: nil)
        let context = FormattingContext(vocabulary: ["Jaylen", "Priya", "Maya"], dictionary: [], isDictation: true)
        let live = LiveDictationFormatter(pipeline: pipeline, context: context)
        for try await chunk in engine.liveTranscribe(tracked) where chunk.isFinal {
            finals.append(chunk)
            await live.append(chunk.words)
        }
        let words = finals.flatMap(\.words)
        let result = await live.finish()
        let latency = clock.now - (stopped.value ?? clock.now)
        print("[latency] audio \(Int(seconds))s, \(words.count) words, stop→formatted \(latency), format \(result.durationMs)ms, engine \(result.engineID), skipped \(result.formattingSkipped)")
        print("[latency] formatted: \(result.formatted)")
        #expect(!result.formatted.isEmpty)
        #expect(latency < .milliseconds(1500), "stop→formatted took \(latency)")
        #endif
    }
}

final class StopTime: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant?
    func set(_ value: ContinuousClock.Instant) { lock.withLock { instant = value } }
    var value: ContinuousClock.Instant? { lock.withLock { instant } }
}
