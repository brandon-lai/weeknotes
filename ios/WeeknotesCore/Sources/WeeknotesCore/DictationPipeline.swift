import Foundation

public struct FormattingContext: Sendable {
    /// Names and terms to spell exactly: friends, circles, dictionary entries (ranked, at most 100).
    public var vocabulary: [String]
    public var dictionary: [DictionaryEntry]
    /// Stage 2 runs only for dictation; voice memo transcripts skip spoken commands.
    public var isDictation: Bool
    public var pauseThreshold: TimeInterval

    public init(vocabulary: [String], dictionary: [DictionaryEntry], isDictation: Bool, pauseThreshold: TimeInterval = AppConfig.spokenCommandPause) {
        self.vocabulary = vocabulary
        self.dictionary = dictionary
        self.isDictation = isDictation
        self.pauseThreshold = pauseThreshold
    }
}

public struct FormattedResult: Sendable, Equatable {
    /// What the engine heard, untouched. Stored as `body_raw_transcript`; "Show original" shows it.
    public let raw: String
    public let formatted: String
    /// The formatter whose output was used, or "none" when formatting was skipped.
    public let engineID: String
    /// True when the primary formatter wasn't used: it was unavailable, threw, or was rejected.
    public let fellBack: Bool
    /// True when every formatter was rejected or failed and the stage 3 text was shown instead
    /// ("Formatting skipped.").
    public let formattingSkipped: Bool
    public let durationMs: Int

    public init(raw: String, formatted: String, engineID: String, fellBack: Bool, formattingSkipped: Bool = false, durationMs: Int = 0) {
        self.raw = raw
        self.formatted = formatted
        self.engineID = engineID
        self.fellBack = fellBack
        self.formattingSkipped = formattingSkipped
        self.durationMs = durationMs
    }
}

/// Runs stages 2 to 5 of dictation formatting:
/// spoken commands → dictionary → smart formatting (LLM) → validate → editor.
/// Every stage but the LLM is a pure function, unit tested on its own.
public struct DictationPipeline: Sendable {
    public let primary: (any FormattingEngine)?
    public let fallback: (any FormattingEngine)?
    public var minimumRetention: Double = AppConfig.minimumRetention
    public var chunkWords: Int = AppConfig.formattingChunkWords

    public init(primary: (any FormattingEngine)?, fallback: (any FormattingEngine)?) {
        self.primary = primary
        self.fallback = fallback
    }

    public func applySpokenCommands(_ words: [TimedWord], pauseThreshold: TimeInterval) -> String {
        SpokenCommands.apply(words, pauseThreshold: pauseThreshold)
    }

    public func applyDictionary(_ text: String, entries: [DictionaryEntry]) -> String {
        PersonalDictionary(entries: entries).apply(text)
    }

    public func validate(input: String, output: String, vocabulary: [String]) -> ValidationResult {
        FormatValidator(minimumRetention: minimumRetention, vocabulary: vocabulary).validate(input: input, output: output)
    }

    public func validate(input: String, output: String) -> ValidationResult {
        validate(input: input, output: output, vocabulary: [])
    }

    public func run(_ transcript: Transcript, context: FormattingContext) async -> FormattedResult {
        let clock = ContinuousClock()
        let started = clock.now
        let stage2: String
        if context.isDictation {
            let words = transcript.words.isEmpty ? Self.untimedWords(transcript.text) : transcript.words
            stage2 = applySpokenCommands(words, pauseThreshold: context.pauseThreshold)
        } else {
            stage2 = transcript.text
        }
        let stage3 = applyDictionary(stage2, entries: context.dictionary)
        let vocabulary = context.vocabulary + context.dictionary.map(\.written)
        let result = await format(stage3, vocabulary: vocabulary)
        return FormattedResult(
            raw: transcript.text,
            formatted: result.text,
            engineID: result.engineID,
            fellBack: result.fellBack,
            formattingSkipped: result.skipped,
            durationMs: Int((clock.now - started) / .milliseconds(1))
        )
    }

    /// Stages 4 and 5 for text that has already been through stages 1 to 3. The golden tests
    /// enter here. Markers become line breaks at the end.
    public func format(_ stage3: String, vocabulary: [String], convertMarkers: Bool = true) async -> (text: String, engineID: String, fellBack: Bool, skipped: Bool) {
        guard !stage3.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("", primary?.id ?? "none", false, false)
        }
        var pieces: [String] = []
        var engineIDs: [String] = []
        var fellBack = false
        var skipped = false
        for chunk in Chunker.split(stage3, maxWords: chunkWords) {
            let attempt = await formatChunk(chunk.text, vocabulary: vocabulary)
            pieces.append(attempt.text + chunk.joiner)
            engineIDs.append(attempt.engineID)
            fellBack = fellBack || attempt.fellBack
            skipped = skipped || attempt.skipped
        }
        let joined = pieces.joined()
        let text = convertMarkers ? TextTools.convertMarkers(joined) : joined
        let engineID = engineIDs.allSatisfy({ $0 == engineIDs.first }) ? (engineIDs.first ?? "none") : engineIDs.joined(separator: "+")
        return (text, engineID, fellBack, skipped)
    }

    private func formatChunk(_ text: String, vocabulary: [String]) async -> (text: String, engineID: String, fellBack: Bool, skipped: Bool) {
        let validator = FormatValidator(minimumRetention: minimumRetention, vocabulary: vocabulary)
        var usedFallback = primary == nil
        for (index, engine) in [primary, fallback].enumerated() {
            guard let engine else { continue }
            if index == 1 { usedFallback = true }
            guard let output = try? await engine.format(text, vocabulary: vocabulary) else { continue }
            let tidy = TextTools.polish(TextTools.tidyModelOutput(output))
            if validator.validate(input: text, output: tidy).isAccepted {
                return (tidy, engine.id, usedFallback, false)
            }
            if let repaired = validator.repair(input: text, output: tidy), validator.validate(input: text, output: repaired).isAccepted {
                return (repaired, engine.id, usedFallback, false)
            }
        }
        // Every formatter failed or was rejected: the speaker's words, capitalized, nothing more
        return (TextTools.polish(TextTools.capitalizeSentences(text)), "none", true, true)
    }

    /// Words with no timing information: no pauses can be detected, so only a command that
    /// ends the dictation is applied.
    static func untimedWords(_ text: String) -> [TimedWord] {
        text.split(whereSeparator: \.isWhitespace).map { TimedWord(text: String($0), start: 0, end: 0) }
    }
}

/// Splits long input for a 4K-token model: at `[[P]]` markers first, then at sentence
/// boundaries near `maxWords`.
public enum Chunker {
    public struct Chunk: Sendable, Equatable {
        public let text: String
        /// What joins this chunk to the next one after formatting.
        public let joiner: String
    }

    public static func split(_ text: String, maxWords: Int) -> [Chunk] {
        let tokens = TextTools.rawTokens(text)
        let wordCount = tokens.filter { !TextTools.isMarker($0) }.count
        if wordCount <= maxWords { return [Chunk(text: text, joiner: "")] }

        // Paragraphs first
        var paragraphs: [[String]] = [[]]
        for token in tokens {
            if token == TextTools.paragraphMarker { paragraphs.append([]) } else { paragraphs[paragraphs.count - 1].append(token) }
        }
        var chunks: [Chunk] = []
        var current: [String] = []
        func flush(joiner: String) {
            guard !current.isEmpty else { return }
            chunks.append(Chunk(text: current.joined(separator: " "), joiner: joiner))
            current = []
        }
        for (p, paragraph) in paragraphs.enumerated() {
            let isLastParagraph = p == paragraphs.count - 1
            if current.count + paragraph.count > maxWords { flush(joiner: " [[P]] ") }
            if paragraph.count <= maxWords {
                current += paragraph
            } else {
                // A long paragraph: cut at the sentence end nearest maxWords
                var rest = paragraph[...]
                while rest.count > maxWords {
                    let window = rest.prefix(maxWords)
                    let cut = window.lastIndex(where: { $0.last.map { ".!?".contains($0) } ?? false }).map { $0 + 1 } ?? window.endIndex
                    current = Array(rest[rest.startIndex..<cut])
                    flush(joiner: " ")
                    rest = rest[cut...]
                }
                current = Array(rest)
            }
            if !isLastParagraph {
                // Keep the marker inside the chunk when the next paragraph fits too
                let next = paragraphs[p + 1]
                if current.count + next.count <= maxWords { current.append(TextTools.paragraphMarker) } else { flush(joiner: " [[P]] ") }
            }
        }
        flush(joiner: "")
        return chunks
    }
}
