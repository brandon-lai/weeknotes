import Foundation

/// A word the user replaced after dictating: they changed `heard` to `written`.
public struct Correction: Sendable, Hashable, Codable {
    public let heard: String
    public let written: String

    public init(heard: String, written: String) {
        self.heard = heard
        self.written = written
    }

    var key: String { "\(heard.lowercased())→\(written)" }
}

/// Learning from edits: diff the formatted dictation against what the user finally kept, and
/// find names they had to fix.
public enum EditLearner {
    /// Replacements of one or two words by a capitalized word or a known name.
    /// "hung out with jalen" edited to "hung out with Jaylen" → Correction("jalen", "Jaylen").
    public static func corrections(formatted: String, final: String, knownNames: Set<String> = [], commonWords: CommonWords = .shared) -> [Correction] {
        let before = displayWords(formatted)
        let after = displayWords(final)
        let pairs = FormatValidator.lcsMatches(before.map(\.normalized), after.map(\.normalized))
        let known = Set(knownNames.map { $0.lowercased() })
        var corrections: [Correction] = []

        // Walk the gaps between matched words: each gap is a replacement
        var lastBefore = -1, lastAfter = -1
        for (b, a) in pairs + [(before.count, after.count)] {
            let removed = Array(before[(lastBefore + 1)..<b])
            let inserted = Array(after[(lastAfter + 1)..<a])
            lastBefore = b
            lastAfter = a
            guard (1...2).contains(removed.count), inserted.count == 1 else { continue }
            let new = inserted[0]
            let heard = removed.map(\.text).joined(separator: " ")
            guard heard.lowercased() != new.text.lowercased() else { continue }
            let isName = known.contains(new.text.lowercased())
            let isCapitalized = new.text.first?.isUppercase ?? false
            // Capitalizing an ordinary word ("The", "Saturday" at a sentence start) isn't a name
            let capitalizedName = isCapitalized && !commonWords.contains(new.text)
            guard isName || capitalizedName else { continue }
            corrections.append(Correction(heard: heard, written: new.text))
        }
        return corrections
    }

    struct DisplayWord {
        let text: String
        let normalized: String
        let sentenceStart: Bool
    }

    static func displayWords(_ text: String) -> [DisplayWord] {
        var out: [DisplayWord] = []
        var sentenceStart = true
        for token in TextTools.rawTokens(TextTools.convertMarkers(text)) {
            guard let normalized = TextTools.normalizedWord(token) else { continue }
            let bare = token.trimmingCharacters(in: .punctuationCharacters)
            let word = bare.hasSuffix("'s") ? String(bare.dropLast(2)) : bare
            out.append(DisplayWord(text: word, normalized: normalized, sentenceStart: sentenceStart))
            sentenceStart = token.last.map { ".!?:".contains($0) } ?? false
        }
        return out
    }
}

/// What to do about a correction the user just made.
public enum LearningAction: Sendable, Equatable {
    /// First time: ask "Add 'Jaylen' to your dictionary?"
    case offer(Correction)
    /// Second time: add it, and show a small confirmation.
    case autoAdd(DictionaryEntry)
}

/// Counts corrections across dictations. The same correction twice is learned automatically;
/// learned entries keep the misheard form as a "sounds like" variant so stage 3 fixes it next time.
public struct LearningLedger: Codable, Sendable, Equatable {
    public private(set) var counts: [String: Int] = [:]
    public private(set) var learned: Set<String> = []
    public private(set) var declined: Set<String> = []

    public init() {}

    public mutating func record(_ corrections: [Correction], existing: [DictionaryEntry], commonWords: CommonWords = .shared) -> [LearningAction] {
        var actions: [LearningAction] = []
        for correction in corrections {
            let key = correction.key
            if learned.contains(key) || alreadyCovered(correction, by: existing) { continue }
            counts[key, default: 0] += 1
            if counts[key]! >= 2 {
                learned.insert(key)
                actions.append(.autoAdd(Self.entry(for: correction, existing: existing, commonWords: commonWords)))
            } else if !declined.contains(key) {
                actions.append(.offer(correction))
            }
        }
        return actions
    }

    /// The user tapped "Not now" on an offer; a second identical correction still learns it.
    public mutating func decline(_ correction: Correction) {
        declined.insert(correction.key)
    }

    public mutating func markLearned(_ correction: Correction) {
        learned.insert(correction.key)
    }

    /// The entry to save: the written form, plus the misheard form as a variant unless it's an
    /// ordinary word (learning "may" → "Maya" would rewrite every "may").
    public static func entry(for correction: Correction, existing: [DictionaryEntry], commonWords: CommonWords = .shared) -> DictionaryEntry {
        var entry = existing.first { $0.written == correction.written } ?? DictionaryEntry(written: correction.written)
        let heardIsCommon = correction.heard.split(separator: " ").allSatisfy { commonWords.contains(String($0)) }
        if !heardIsCommon && !entry.soundsLike.contains(where: { $0.lowercased() == correction.heard.lowercased() }) {
            entry.soundsLike.append(correction.heard.lowercased())
        }
        return entry
    }

    private func alreadyCovered(_ correction: Correction, by entries: [DictionaryEntry]) -> Bool {
        entries.contains { entry in
            entry.written == correction.written && entry.soundsLike.contains { $0.lowercased() == correction.heard.lowercased() }
        }
    }
}
