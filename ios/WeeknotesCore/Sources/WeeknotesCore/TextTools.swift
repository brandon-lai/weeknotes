import Foundation

/// Tokenizing and tidying shared by the pipeline stages, the validator and edit learning.
public enum TextTools {
    public static let newLineMarker = "[[NL]]"
    public static let paragraphMarker = "[[P]]"

    public static func isMarker(_ token: String) -> Bool {
        token == newLineMarker || token == paragraphMarker
    }

    public static func isPunctuationOnly(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
            && !token.contains(where: \.isNumber)
    }

    /// Whitespace-separated tokens, with markers split out even when glued to a word
    /// ("fine.[[P]]On" becomes "fine.", "[[P]]", "On").
    public static func rawTokens(_ text: String) -> [String] {
        var spaced = text
        for marker in [paragraphMarker, newLineMarker] {
            spaced = spaced.replacingOccurrences(of: marker, with: " \(marker) ")
        }
        return spaced.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Canonical form of a word for comparing texts: lowercased, straight apostrophes,
    /// surrounding punctuation stripped. Numbers keep their inner `.` and `:` ("3.1", "6:30")
    /// and lose currency and percent signs. Returns nil for tokens with no letters or digits
    /// (bullets, dashes, stray punctuation).
    public static func normalizedWord(_ raw: String) -> String? {
        if isMarker(raw) { return raw }
        var s = raw.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        // "a.m." and "p.m." compare as "am" and "pm"
        if s.hasPrefix("a.m") || s.hasPrefix("p.m") { s = s.replacingOccurrences(of: ".", with: "") }
        let keep = CharacterSet.alphanumerics
        let scalars = Array(s.unicodeScalars)
        guard let first = scalars.firstIndex(where: { keep.contains($0) }),
              let last = scalars.lastIndex(where: { keep.contains($0) }) else { return nil }
        var core = String(String.UnicodeScalarView(scalars[first...last]))
        // Possessive and contraction apostrophes stay; anything else inside a word goes
        let hasDigit = core.contains(where: \.isNumber)
        core = String(core.filter { c in
            c.isLetter || c.isNumber || c == "'" || (hasDigit && (c == "." || c == ":" || c == ","))
        })
        if hasDigit { core = core.replacingOccurrences(of: ",", with: "") }
        return core.isEmpty ? nil : core
    }

    /// Normalized words of a text, in order. Hyphenated and slashed words split into parts,
    /// so "check-in" and "check in" compare equal. Markers survive as tokens.
    public static func words(_ text: String) -> [String] {
        rawTokens(text).flatMap { token -> [String] in
            if isMarker(token) { return [token] }
            let parts = token.contains(where: \.isNumber) ? [token] : token.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "\u{2013}" }).map(String.init)
            return parts.compactMap(normalizedWord)
        }
    }

    public static func isNumeric(_ normalized: String) -> Bool {
        normalized.contains(where: \.isNumber)
    }

    /// Turns markers into line breaks: `[[NL]]` is one, `[[P]]` is a blank line.
    public static func convertMarkers(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: #"[ \t]*\[\[P\]\][ \t]*"#, with: "\n\n", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[ \t]*\[\[NL\]\][ \t]*"#, with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The fallback when formatting is skipped: capitalize sentence starts and "I",
    /// and remove spaces before punctuation. Words are untouched.
    public static func capitalizeSentences(_ text: String) -> String {
        var tidy = text.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
        tidy = tidy.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var out = ""
        var capitalizeNext = true
        for token in rawTokens(tidy) {
            if isMarker(token) {
                out += (out.isEmpty ? "" : " ") + token
                capitalizeNext = true
                continue
            }
            var word = token
            let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if bare == "i" || bare.hasPrefix("i'") || bare.hasPrefix("i\u{2019}") {
                word = word.replacingOccurrences(of: #"^i"#, with: "I", options: .regularExpression)
            }
            if capitalizeNext, let index = word.firstIndex(where: \.isLetter) {
                word.replaceSubrange(index...index, with: String(word[index]).uppercased())
                capitalizeNext = false
            }
            out += (out.isEmpty ? "" : " ") + word
            if let lastChar = word.last, ".!?".contains(lastChar) { capitalizeNext = true }
        }
        return out
    }

    /// Normalizes what formatting models tend to vary on but the speaker never said:
    /// curly quotes, em dashes (never wanted), runs of spaces, blank lines inside lists.
    public static func tidyModelOutput(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        out = out.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        out = out.replacingOccurrences(of: "\\s*\u{2014}\\s*", with: ", ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        // "Three highlights:\n\n1. ..." and "1. a\n\n2. b" read the same as single-spaced lists
        out = out.replacingOccurrences(of: #"\n\s*\n(?=\s*(\d+[.)]|[-•*])\s)"#, with: "\n", options: .regularExpression)
        return out
    }

    /// Pure hesitation sounds. Unlike "like" or "you know" these are never words, so code can
    /// remove them safely.
    public static let hesitations: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm", "mm"]

    /// Deterministic finishing after any formatting model: drops hesitation sounds, capitalizes
    /// sentence and list-item starts and a lone "i", and ends every sentence, list item and
    /// paragraph with punctuation. Never changes, adds or reorders a word.
    public static func polish(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            var tokens: [String] = []
            for token in rawTokens(rawLine) {
                let bare = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if hesitations.contains(bare) {
                    // Keep sentence-ending punctuation the hesitation carried ("busy uh." → "busy.")
                    if let last = token.last, ".!?".contains(last), !tokens.isEmpty, let prev = tokens.last?.last, !".!?".contains(prev) {
                        tokens[tokens.count - 1] += String(last)
                    }
                    continue
                }
                tokens.append(token)
            }
            lines.append(tokens.joined(separator: " "))
        }

        var out: [String] = []
        for line in lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                out.append("")
                continue
            }
            var result = ""
            var capitalizeNext = true
            let tokens = rawTokens(line)
            for (i, token) in tokens.enumerated() {
                var word = token
                if isMarker(word) {
                    result += (result.isEmpty ? "" : " ") + word
                    capitalizeNext = true
                    continue
                }
                // A list number ("1.", "2)") or bullet leaves the next word to be capitalized
                let isListLead = i == 0 && (word.wholeMatch(of: /\d{1,2}[.)]/) != nil || ["-", "•", "*"].contains(word))
                let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if bare == "i" || bare.hasPrefix("i'") {
                    word = word.replacingOccurrences(of: #"^i"#, with: "I", options: .regularExpression)
                }
                if capitalizeNext && !isListLead, let index = word.firstIndex(where: \.isLetter), word[..<index].allSatisfy({ !$0.isNumber }) {
                    word.replaceSubrange(index...index, with: String(word[index]).uppercased())
                    capitalizeNext = false
                } else if capitalizeNext && !isListLead && word.contains(where: \.isNumber) {
                    capitalizeNext = false
                }
                let next = i + 1 < tokens.count ? tokens[i + 1] : nil
                // End the sentence before a marker
                if let next, isMarker(next), let last = word.last, last.isLetter || last.isNumber {
                    word += "."
                }
                result += (result.isEmpty ? "" : " ") + word
                if let last = word.last, ".!?".contains(last) { capitalizeNext = true }
            }
            if let last = result.last, last.isLetter || last.isNumber || last == "'" {
                result += "."
            }
            out.append(result)
        }
        return out.joined(separator: "\n")
    }
}
