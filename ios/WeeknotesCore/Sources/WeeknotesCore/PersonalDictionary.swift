import Foundation

/// A name or term and how the speech model tends to mishear it.
/// Written "Jaylen", sounds like "Jalen", "Jay Lynn".
public struct DictionaryEntry: Sendable, Codable, Hashable {
    public var written: String
    public var soundsLike: [String]

    public init(written: String, soundsLike: [String] = []) {
        self.written = written
        self.soundsLike = soundsLike
    }
}

/// About 39,000 common English words (SCOWL sizes 10 to 35, no proper names). Fuzzy
/// dictionary matches never touch these, so "may" never turns into "Maya".
public final class CommonWords: Sendable {
    public static let shared = CommonWords()
    private let words: Set<String>

    init() {
        guard let url = Bundle.module.url(forResource: "common-words", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            words = []
            return
        }
        words = Set(text.split(separator: "\n").map(String.init))
    }

    public init(words: Set<String>) { self.words = words }

    public func contains(_ word: String) -> Bool {
        let w = word.lowercased()
        if words.contains(w) { return true }
        // Plain inflections the list might miss
        for suffix in ["s", "es", "ed", "ing", "'s"] where w.hasSuffix(suffix) && w.count > suffix.count + 2 {
            if words.contains(String(w.dropLast(suffix.count))) { return true }
        }
        return false
    }

    public var count: Int { words.count }
}

public enum EditDistance {
    /// Levenshtein distance over characters.
    public static func between(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}

/// Stage 3: fix known mishearings of names and terms.
///
/// 1. Exact "sounds like" variants (and the written form in any case), case-insensitive, on
///    word boundaries. Multi-word variants ("Jay Lynn") match across words.
/// 2. Close matches: a single word that sounds like an entry (shared Double Metaphone code)
///    and is within edit distance 2, as long as it is not a common English word.
public struct PersonalDictionary: Sendable {
    public let entries: [DictionaryEntry]
    public var maxDistance = 2
    public var minimumFuzzyLength = 3
    private let common: CommonWords
    private let exact: [(words: [String], written: String)]
    private let fuzzy: [(lower: String, written: String)]

    public init(entries: [DictionaryEntry], commonWords: CommonWords = .shared) {
        self.entries = entries
        self.common = commonWords
        var exact: [(words: [String], written: String)] = []
        var fuzzy: [(lower: String, written: String)] = []
        for entry in entries {
            let written = entry.written.trimmingCharacters(in: .whitespaces)
            guard !written.isEmpty else { continue }
            for variant in entry.soundsLike {
                let words = Self.bareWords(variant)
                if !words.isEmpty { exact.append((words, written)) }
            }
            // The written form in the wrong case, unless it is an ordinary word ("Will", "June")
            let writtenWords = Self.bareWords(written)
            if writtenWords.count > 1 || !commonWords.contains(written) {
                exact.append((writtenWords, written))
            }
            // Single-word forms (and each part of a multi-word name) are fuzzy candidates
            let parts = written.split(separator: " ").map(String.init)
            for part in parts where part.count >= 3 && !commonWords.contains(part) {
                fuzzy.append((part.lowercased(), part))
            }
        }
        self.exact = exact.sorted { $0.words.count > $1.words.count }
        self.fuzzy = fuzzy
    }

    public func apply(_ text: String) -> String {
        guard !entries.isEmpty else { return text }
        let tokens = TextTools.rawTokens(text).map(Piece.init)
        var out: [String] = []
        var i = 0
        tokenLoop: while i < tokens.count {
            let piece = tokens[i]
            if piece.isMarker || piece.core.isEmpty {
                out.append(piece.raw)
                i += 1
                continue
            }
            for candidate in exact {
                let n = candidate.words.count
                guard i + n <= tokens.count else { continue }
                let span = tokens[i..<i + n]
                guard !span.contains(where: \.isMarker) else { continue }
                // Only the last word of a span may carry a possessive
                let spoken = span.enumerated().map { offset, p in offset == n - 1 ? p.base : p.core }
                guard spoken.map({ $0.lowercased() }) == candidate.words else { continue }
                guard span.dropLast().allSatisfy({ $0.possessive.isEmpty }) else { continue }
                let lastPiece = tokens[i + n - 1]
                out.append(piece.prefix + candidate.written + lastPiece.possessive + lastPiece.suffix)
                i += n
                continue tokenLoop
            }
            if let written = fuzzyMatch(piece.base) {
                out.append(piece.prefix + written + piece.possessive + piece.suffix)
            } else {
                out.append(piece.raw)
            }
            i += 1
        }
        return out.joined(separator: " ")
    }

    /// The entry a misheard word most likely stands for, or nil.
    func fuzzyMatch(_ word: String) -> String? {
        let lower = word.lowercased()
        guard lower.count >= minimumFuzzyLength, lower.allSatisfy(\.isLetter), !common.contains(lower) else { return nil }
        var best: (distance: Int, written: String)?
        var tie = false
        for candidate in fuzzy where candidate.lower != lower {
            let distance = EditDistance.between(lower, candidate.lower)
            guard distance <= maxDistance, DoubleMetaphone.soundAlike(lower, candidate.lower) else { continue }
            if let current = best {
                if distance < current.distance {
                    best = (distance, candidate.written)
                    tie = false
                } else if distance == current.distance, current.written != candidate.written {
                    tie = true
                }
            } else {
                best = (distance, candidate.written)
            }
        }
        // Two names equally close: leave the word for the user rather than guess
        return tie ? nil : best?.written
    }

    static func bareWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// A raw token split into leading punctuation, the word, a possessive and trailing punctuation.
    struct Piece {
        let raw: String
        let prefix: String
        let core: String
        let base: String
        let possessive: String
        let suffix: String
        let isMarker: Bool

        init(_ raw: String) {
            self.raw = raw
            isMarker = TextTools.isMarker(raw)
            let chars = Array(raw)
            let start = chars.firstIndex(where: { $0.isLetter || $0.isNumber }) ?? chars.count
            let end = chars.lastIndex(where: { $0.isLetter || $0.isNumber }).map { $0 + 1 } ?? start
            prefix = String(chars[0..<start])
            core = start < end ? String(chars[start..<end]) : ""
            suffix = start < end ? String(chars[end...]) : String(chars[start...])
            let lower = core.lowercased()
            if lower.hasSuffix("'s") || lower.hasSuffix("\u{2019}s") {
                base = String(core.dropLast(2))
                possessive = String(core.suffix(2))
            } else {
                base = core
                possessive = ""
            }
        }
    }
}
