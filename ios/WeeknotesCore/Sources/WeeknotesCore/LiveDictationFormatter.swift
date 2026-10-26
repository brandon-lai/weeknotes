import Foundation

/// Live dictation runs the same stages 2 to 5 as `DictationPipeline`, but on finished
/// sentences while the user is still talking, so tapping stop only waits for the last few.
///
/// Why: the on-device model formats about 30 words a second. A 60-second dictation is ~150
/// words, ~5 s in one pass after stop, against a 1.5 s target (PRD §8, "Latency target").
/// Formatting sentence groups as they finalize leaves ~1 group for after stop.
///
/// Windows end at a sentence boundary once they hold `windowWords` words. The last word is
/// held back until the next one arrives, because stage 2 needs the pause after a word to
/// know whether "period" was a command. Windows are formatted one at a time, in order.
public actor LiveDictationFormatter {
    public let pipeline: DictationPipeline
    public let context: FormattingContext
    public var windowWords = 25
    public var maxWindowWords = 80

    private var pending: [TimedWord] = []
    private var allWords: [TimedWord] = []
    private var jobs: [Task<WindowResult, Never>] = []
    private let started = ContinuousClock.now

    struct WindowResult {
        let text: String
        let engineID: String
        let fellBack: Bool
        let skipped: Bool
    }

    public init(pipeline: DictationPipeline, context: FormattingContext) {
        self.pipeline = pipeline
        self.context = context
    }

    /// Feed final words from the engine as they arrive.
    public func append(_ words: [TimedWord]) {
        allWords += words
        pending += words
        dispatchReadyWindows()
    }

    /// The raw transcript so far.
    public var rawText: String { allWords.joinedText }

    /// Formats what's left and returns the whole dictation.
    public func finish() async -> FormattedResult {
        if !pending.isEmpty {
            schedule(pending, isLast: true)
            pending = []
        }
        var texts: [String] = []
        var engines: [String] = []
        var fellBack = false
        var skipped = false
        for job in jobs {
            let result = await job.value
            if !result.text.isEmpty { texts.append(result.text) }
            engines.append(result.engineID)
            fellBack = fellBack || result.fellBack
            skipped = skipped || result.skipped
        }
        let engine = Set(engines).count <= 1 ? (engines.first ?? "none") : engines.joined(separator: "+")
        let joined = TextTools.convertMarkers(texts.joined(separator: " "))
        return FormattedResult(
            raw: allWords.joinedText,
            formatted: joined,
            engineID: engine,
            fellBack: fellBack,
            formattingSkipped: skipped,
            durationMs: Int((ContinuousClock.now - started) / .milliseconds(1))
        )
    }

    private func dispatchReadyWindows() {
        // Keep one word of lookahead for spoken-command pauses
        while pending.count > windowWords + 1 {
            let candidates = pending.dropLast()
            let boundary = candidates.indices.dropFirst(windowWords - 1).first { index in
                guard let last = candidates[index].text.last else { return false }
                // Never right before a command: "new | paragraph" must stay together
                if SpokenCommands.startsCommand(pending[index + 1].text) { return false }
                return ".!?".contains(last) || SpokenCommands.isSentenceEndCommand(candidates[index].text)
            }
            let cut: Int
            if let boundary {
                cut = boundary + 1
            } else if candidates.count >= maxWindowWords,
                      let forced = (windowWords..<maxWindowWords).last(where: { !SpokenCommands.startsCommand(pending[$0].text) }) {
                // No punctuation from the engine: cut anyway rather than wait forever
                cut = forced
            } else {
                return
            }
            let window = Array(pending[..<cut])
            pending.removeFirst(cut)
            schedule(window, lookahead: pending.first, isLast: false)
        }
    }

    private func schedule(_ window: [TimedWord], lookahead: TimedWord? = nil, isLast: Bool) {
        let previous = jobs.last
        let pipeline = pipeline
        let context = context
        let job = Task { () -> WindowResult in
            // One window at a time: the on-device model isn't faster in parallel, and order matters
            _ = await previous?.value
            let words = lookahead.map { window + [$0] } ?? window
            var stage2 = context.isDictation
                ? SpokenCommands.apply(words, pauseThreshold: context.pauseThreshold, keepTrailingMarkers: !isLast)
                : words.joinedText
            if let lookahead {
                // The lookahead word belongs to the next window
                stage2 = Self.dropLastWord(stage2, matching: lookahead.text)
            }
            let stage3 = pipeline.applyDictionary(stage2, entries: context.dictionary)
            let vocabulary = context.vocabulary + context.dictionary.map(\.written)
            let result = await pipeline.format(stage3, vocabulary: vocabulary, convertMarkers: false)
            return WindowResult(text: result.text, engineID: result.engineID, fellBack: result.fellBack, skipped: result.skipped)
        }
        jobs.append(job)
    }

    static func dropLastWord(_ text: String, matching word: String) -> String {
        var tokens = TextTools.rawTokens(text)
        if let last = tokens.last, last.lowercased().hasPrefix(word.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }
}
