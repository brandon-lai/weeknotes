import Foundation

/// Stage 2: spoken commands ("comma", "new paragraph", ...) become punctuation and markers
/// before any model sees the text. Dictation only; memos skip it.
///
/// A phrase counts as a command only when the speaker pauses right after it or it ends the
/// dictation, so "the period of time" stays as words.
public enum SpokenCommands {
    public struct Command: Sendable {
        public let words: [String]
        public let output: String
    }

    /// Longest phrases first, so "question mark" wins over a lone word.
    public static let all: [Command] = [
        ("exclamation point", "!"), ("exclamation mark", "!"), ("question mark", "?"),
        ("new paragraph", TextTools.paragraphMarker), ("new line", TextTools.newLineMarker),
        ("next line", TextTools.newLineMarker), ("line break", TextTools.newLineMarker),
        ("full stop", "."), ("semicolon", ";"), ("period", "."), ("comma", ","), ("colon", ":"),
    ]
    .map { Command(words: $0.0.split(separator: " ").map(String.init), output: $0.1) }
    .sorted { $0.words.count > $1.words.count }

    /// Words that begin a command phrase. Live dictation never splits a window right before one.
    public static let commandStarters: Set<String> = Set(all.map { $0.words[0] })

    public static func startsCommand(_ word: String) -> Bool {
        commandStarters.contains(bare(word))
    }

    /// The spoken word ends a sentence-ending command ("period", "question mark", "full stop").
    public static func isSentenceEndCommand(_ word: String) -> Bool {
        ["period", "mark", "point", "stop"].contains(bare(word))
    }

    /// - Parameter keepTrailingMarkers: live dictation formats in pieces; a "new paragraph"
    ///   at the end of one piece still separates it from the next.
    public static func apply(_ words: [TimedWord], pauseThreshold: TimeInterval, keepTrailingMarkers: Bool = false) -> String {
        var tokens: [String] = []
        var i = 0
        while i < words.count {
            if let command = command(at: i, in: words, pauseThreshold: pauseThreshold) {
                emit(command.output, into: &tokens)
                i += command.words.count
                continue
            }
            let text = words[i].text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                if TextTools.isPunctuationOnly(text), !tokens.isEmpty, !TextTools.isMarker(tokens[tokens.count - 1]) {
                    tokens[tokens.count - 1] += text
                } else {
                    tokens.append(text)
                }
            }
            i += 1
        }
        // A trailing "new paragraph" has nothing to separate
        while !keepTrailingMarkers, let last = tokens.last, TextTools.isMarker(last) { tokens.removeLast() }
        return tokens.joined(separator: " ")
    }

    private static func command(at i: Int, in words: [TimedWord], pauseThreshold: TimeInterval) -> Command? {
        for command in all {
            let n = command.words.count
            guard i + n <= words.count else { continue }
            let spoken = words[i..<i + n].map { bare($0.text) }
            guard spoken == command.words else { continue }
            let lastIndex = i + n - 1
            if lastIndex == words.count - 1 { return command }
            let pause = words[lastIndex + 1].start - words[lastIndex].end
            if pause >= pauseThreshold { return command }
        }
        return nil
    }

    /// Engines sometimes attach their own punctuation ("comma,"); compare the bare word.
    private static func bare(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    private static func emit(_ output: String, into tokens: inout [String]) {
        if TextTools.isMarker(output) {
            // Two markers in a row collapse to the stronger one
            if let last = tokens.last, TextTools.isMarker(last) {
                if output == TextTools.paragraphMarker { tokens[tokens.count - 1] = output }
                return
            }
            if !tokens.isEmpty { tokens.append(output) }
            return
        }
        // Punctuation attaches to the previous word, replacing punctuation the engine guessed
        guard let last = tokens.last, !TextTools.isMarker(last) else { return }
        var word = last
        while let c = word.last, ".,!?;:".contains(c) { word.removeLast() }
        tokens[tokens.count - 1] = word + output
    }
}
