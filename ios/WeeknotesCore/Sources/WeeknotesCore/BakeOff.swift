import Foundation

/// Scoring for the transcription bake-off (PRD §7): friends' names spelled right, overall
/// accuracy against a reference transcript, time to final text.
public enum BakeOffScore {
    /// Word error rate: (substitutions + deletions + insertions) / reference words, after
    /// normalizing case and punctuation. 0 is perfect.
    public static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = TextTools.words(reference).filter { !TextTools.isMarker($0) }
        let hyp = TextTools.words(hypothesis).filter { !TextTools.isMarker($0) }
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        var previous = Array(0...hyp.count)
        var current = [Int](repeating: 0, count: hyp.count + 1)
        for i in 1...ref.count {
            current[0] = i
            if !hyp.isEmpty {
                for j in 1...hyp.count {
                    let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                    current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                }
            }
            swap(&previous, &current)
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }

    /// Which vocabulary names appear in the reference, and how many the hypothesis spells
    /// exactly (case-sensitive, as the reader would see them).
    public static func names(_ vocabulary: [String], reference: String, hypothesis: String) -> (expected: Int, correct: Int) {
        var expected = 0
        var correct = 0
        for name in Set(vocabulary) where contains(reference, name, caseSensitive: false) {
            expected += 1
            if contains(hypothesis, name, caseSensitive: true) { correct += 1 }
        }
        return (expected, correct)
    }

    static func contains(_ text: String, _ name: String, caseSensitive: Bool) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        var options: String.CompareOptions = [.regularExpression]
        if !caseSensitive { options.insert(.caseInsensitive) }
        return text.range(of: "\\b\(escaped)\\b", options: options) != nil
    }
}

/// One recording's results across every engine, as exported.
public struct BakeOffRun: Codable, Sendable, Identifiable {
    public struct EngineResult: Codable, Sendable {
        public var engineID: String
        public var raw: String?
        public var formatted: [String: String]
        public var formattingMs: [String: Int]
        public var transcribeMs: Int?
        public var error: String?
        public var wordErrorRate: Double?
        public var namesCorrect: Int?
        public var namesExpected: Int?

        public init(engineID: String) {
            self.engineID = engineID
            formatted = [:]
            formattingMs = [:]
        }
    }

    public var id: String { recording }
    public var recording: String
    public var label: String
    public var durationMs: Int
    public var reference: String?
    public var ranAt: Date
    public var results: [EngineResult]

    public init(recording: String, label: String, durationMs: Int, reference: String?, ranAt: Date = Date(), results: [EngineResult] = []) {
        self.recording = recording
        self.label = label
        self.durationMs = durationMs
        self.reference = reference
        self.ranAt = ranAt
        self.results = results
    }

    /// One row per recording × engine, for a spreadsheet.
    public static func csv(_ runs: [BakeOffRun], formatters: [String]) -> String {
        var header = ["recording", "label", "duration_s", "engine", "transcribe_ms", "wer", "names_correct", "names_expected", "error", "raw"]
        for f in formatters { header += ["formatted_\(f)", "format_ms_\(f)"] }
        var lines = [header.joined(separator: ",")]
        for run in runs {
            for r in run.results {
                var row: [String] = [
                    run.recording, run.label, String(format: "%.1f", Double(run.durationMs) / 1000), r.engineID,
                    r.transcribeMs.map(String.init) ?? "", r.wordErrorRate.map { String(format: "%.3f", $0) } ?? "",
                    r.namesCorrect.map(String.init) ?? "", r.namesExpected.map(String.init) ?? "", r.error ?? "", r.raw ?? "",
                ]
                for f in formatters { row += [r.formatted[f] ?? "", r.formattingMs[f].map(String.init) ?? ""] }
                lines.append(row.map(escape).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
