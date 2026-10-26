import Foundation

/// Stage 1 biasing list: every dictionary entry, then friends' names (full, first and last)
/// by how recently you interacted, then circle names. Capped at 100, the most
/// `DictationTranscriber` accepts.
public enum Vocabulary {
    public struct Friend: Sendable {
        public let name: String
        /// Most recent of: shared a circle you last posted to, replied, reacted.
        public let lastInteraction: Date?

        public init(name: String, lastInteraction: Date?) {
            self.name = name
            self.lastInteraction = lastInteraction
        }
    }

    public static func build(friends: [Friend], circles: [String], dictionary: [DictionaryEntry], limit: Int = AppConfig.vocabularyLimit) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ term: String) {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, out.count < limit, seen.insert(t.lowercased()).inserted else { return }
            out.append(t)
        }
        for entry in dictionary { add(entry.written) }
        let ranked = friends.sorted { a, b in
            switch (a.lastInteraction, b.lastInteraction) {
            case let (x?, y?): x == y ? a.name < b.name : x > y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.name < b.name
            }
        }
        for friend in ranked {
            add(friend.name)
            let parts = friend.name.split(separator: " ").map(String.init)
            if parts.count > 1 { parts.forEach(add) }
        }
        circles.forEach(add)
        return out
    }

    /// The prompt WhisperKit and the hosted OpenAI model take. Whisper copies spelling from the
    /// prompt but doesn't follow instructions in it, and only reads the last 224 tokens, so the
    /// most important names go last.
    public static func whisperGlossary(_ vocabulary: [String], maxCharacters: Int = 800) -> String {
        guard !vocabulary.isEmpty else { return "" }
        var names: [String] = []
        var length = "Friends: .".count
        // Most important first in `vocabulary`; keep as many as fit, then reverse so they end the prompt
        for term in vocabulary {
            let added = term.count + 2
            if length + added > maxCharacters { break }
            names.append(term)
            length += added
        }
        return "Friends: " + names.reversed().joined(separator: ", ") + "."
    }
}
