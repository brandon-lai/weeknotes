import Foundation

public enum ValidationResult: Sendable, Equatable {
    case accepted
    case rejected(Reason)

    public enum Reason: Sendable, Equatable {
        /// The model wrote a word the speaker never said.
        case addedWords([String])
        /// Too much of what the speaker said is gone, and no self-correction explains it.
        case droppedContent(kept: Double)
        /// A `[[NL]]` or `[[P]]` marker went missing, appeared, or moved.
        case markersChanged
        case empty
    }

    public var isAccepted: Bool { self == .accepted }
}

/// Stage 5: compare the model's output with its input, word by word, after lowercasing and
/// stripping punctuation. Formatting may remove fillers, repeats and corrected spans, turn
/// number words into digits and number a list. Anything else is the model writing, and
/// the output is rejected.
public struct FormatValidator: Sendable {
    /// Output must keep at least this share of the non-filler words (unless the speaker corrected themselves).
    public var minimumRetention: Double
    /// Words the output may introduce: names and terms from the dictionary and vocabulary.
    public var vocabulary: Set<String>

    public init(minimumRetention: Double = 0.6, vocabulary: [String] = []) {
        self.minimumRetention = minimumRetention
        self.vocabulary = Set(vocabulary.flatMap { TextTools.words($0) })
    }

    public static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "mm", "like"]
    public static let fillerPhrases: [[String]] = [["you", "know"], ["i", "mean"]]
    public static let backtrackPhrases: [[String]] = [
        ["actually"], ["scratch", "that"], ["no", "wait"], ["wait", "no"], ["never", "mind"], ["nevermind"], ["i", "mean"], ["sorry"],
    ]
    public static let numberWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion", "point", "half",
        "quarter", "dollars", "dollar", "cents", "percent", "o'clock", "first", "second", "third",
        "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "twentieth", "thirtieth",
    ]
    public static let ordinals: Set<String> = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    public func validate(input: String, output: String) -> ValidationResult {
        let inWords = TextTools.words(input)
        let outWords = TextTools.words(output)
        guard !outWords.filter({ !TextTools.isMarker($0) }).isEmpty else {
            return inWords.filter({ !TextTools.isMarker($0) }).isEmpty ? .accepted : .rejected(.empty)
        }

        // Markers must survive in the same order, and each segment between them is checked on
        // its own: a moved marker shows up as a word added to the wrong segment.
        let inMarkers = inWords.filter(TextTools.isMarker)
        let outMarkers = outWords.filter(TextTools.isMarker)
        guard inMarkers == outMarkers else { return .rejected(.markersChanged) }
        let inSegments = Self.segments(inWords)
        let outSegments = Self.segments(outWords)
        let listNumbers = Self.listNumbers(in: output)

        var added: [String] = []
        var total = 0
        var kept = 0
        var backtrack = false
        for (source, result) in zip(inSegments, outSegments) {
            let check = checkSegment(source: source, result: result, listNumbers: listNumbers)
            added += check.added
            total += check.total
            kept += check.kept
            backtrack = backtrack || check.backtrack
        }
        if !added.isEmpty { return .rejected(.addedWords(added)) }
        let retention = total == 0 ? 1 : Double(kept) / Double(total)
        if !backtrack && retention < minimumRetention { return .rejected(.droppedContent(kept: retention)) }
        return .accepted
    }

    /// Small connecting words formatting models like to slip in ("brunch on Sunday").
    public static let connectingWords: Set<String> = ["on", "the", "a", "an", "to", "and", "of", "in", "at", "for", "it", "is", "was"]

    /// When the only problem is a few added connecting words, remove exactly those words from
    /// the output and return it (the validator then checks it again). Returns nil when the
    /// output has no such additions or has other problems. This enforces "never add words"
    /// without trusting the model to comply, and never removes a word the speaker said.
    public func repair(input: String, output: String, maxRemovals: Int = 3) -> String? {
        guard case .rejected(.addedWords(let added)) = validate(input: input, output: output),
              added.count <= maxRemovals, added.allSatisfy(Self.connectingWords.contains) else { return nil }
        // Tokens with the line they sit on, so list and paragraph breaks survive the edit
        var tokens: [(line: Int, raw: String, word: String?)] = []
        for (lineIndex, line) in output.components(separatedBy: "\n").enumerated() {
            for raw in TextTools.rawTokens(line) { tokens.append((lineIndex, raw, TextTools.normalizedWord(raw))) }
        }
        let inSegments = Self.segments(TextTools.words(input))
        var outSegments: [[(index: Int, word: String)]] = [[]]
        for (i, token) in tokens.enumerated() {
            guard let word = token.word else { continue }
            if TextTools.isMarker(word) { outSegments.append([]) } else { outSegments[outSegments.count - 1].append((i, word)) }
        }
        guard inSegments.count == outSegments.count else { return nil }
        var drop = Set<Int>()
        for (source, result) in zip(inSegments, outSegments) {
            let matched = Set(Self.lcsMatches(source, result.map(\.word)).map(\.1))
            for (j, item) in result.enumerated() where !matched.contains(j) && Self.connectingWords.contains(item.word) {
                drop.insert(item.index)
            }
        }
        guard !drop.isEmpty else { return nil }
        var lines = [[String]](repeating: [], count: output.components(separatedBy: "\n").count)
        for (i, token) in tokens.enumerated() {
            if drop.contains(i) {
                // Keep punctuation the dropped word carried
                if let last = token.raw.last, ".,!?;:".contains(last), !lines[token.line].isEmpty {
                    lines[token.line][lines[token.line].count - 1] += String(last)
                }
                continue
            }
            lines[token.line].append(token.raw)
        }
        return lines.map { $0.joined(separator: " ") }.joined(separator: "\n")
    }

    private struct SegmentCheck {
        var added: [String] = []
        var total = 0
        var kept = 0
        var backtrack = false
    }

    private func checkSegment(source: [String], result: [String], listNumbers: Set<String>) -> SegmentCheck {
        var check = SegmentCheck()
        let matched = Self.lcsMatches(source, result)
        let matchedSource = Set(matched.map(\.0))
        let matchedResult = Set(matched.map(\.1))
        let fillerIndexes = Self.fillerIndexes(source)
        check.backtrack = Self.containsPhrase(Self.backtrackPhrases, in: source)

        let removed = source.indices.filter { !matchedSource.contains($0) }
        let removedNumberWords = removed.contains { Self.numberWords.contains(source[$0]) }
        let removedOrdinals = removed.contains { Self.ordinals.contains(source[$0]) }

        for j in result.indices where !matchedResult.contains(j) {
            let word = result[j]
            if TextTools.isNumeric(word) {
                // Digits replacing number words, or list numbering
                if removedNumberWords || (removedOrdinals && listNumbers.contains(word)) || listNumbers.contains(word) { continue }
            }
            if vocabulary.contains(word) { continue }
            check.added.append(word)
        }

        // Retention: share of non-filler words kept. Repeats ("pretty pretty") and number
        // words that became digits count as kept.
        let hasDigits = result.contains(where: TextTools.isNumeric)
        for i in source.indices where !fillerIndexes.contains(i) {
            check.total += 1
            if matchedSource.contains(i) {
                check.kept += 1
            } else if i > 0 && source[i - 1] == source[i] {
                check.kept += 1
            } else if hasDigits && Self.numberWords.contains(source[i]) {
                check.kept += 1
            }
        }
        return check
    }

    // MARK: Helpers

    static func segments(_ words: [String]) -> [[String]] {
        var out: [[String]] = [[]]
        for word in words {
            if TextTools.isMarker(word) { out.append([]) } else { out[out.count - 1].append(word) }
        }
        return out
    }

    /// Numbers that start a list line ("1." / "2)") in the output.
    static func listNumbers(in text: String) -> Set<String> {
        var numbers = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = trimmed.firstMatch(of: /^(\d{1,2})[.)]\s/) {
                numbers.insert(String(match.1))
            }
        }
        // Inline lists ("... 1. a 2. b") still number from 1
        if let inline = try? Regex(#"(?:^|\s)(\d{1,2})[.)]\s"#) {
            for match in text.matches(of: inline) {
                if let range = match.output[1].range { numbers.insert(String(text[range])) }
            }
        }
        return numbers
    }

    static func fillerIndexes(_ words: [String]) -> Set<Int> {
        var indexes = Set<Int>()
        for (i, word) in words.enumerated() where fillers.contains(word) { indexes.insert(i) }
        for phrase in fillerPhrases {
            guard words.count >= phrase.count else { continue }
            for i in 0...(words.count - phrase.count) where Array(words[i..<i + phrase.count]) == phrase {
                indexes.formUnion(i..<i + phrase.count)
            }
        }
        return indexes
    }

    static func containsPhrase(_ phrases: [[String]], in words: [String]) -> Bool {
        for phrase in phrases where words.count >= phrase.count {
            for i in 0...(words.count - phrase.count) where Array(words[i..<i + phrase.count]) == phrase {
                return true
            }
        }
        return false
    }

    /// Longest common subsequence alignment; returns matched (source, result) index pairs.
    static func lcsMatches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
