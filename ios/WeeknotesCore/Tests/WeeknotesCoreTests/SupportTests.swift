import Foundation
import Testing
@testable import WeeknotesCore

@Suite("Double Metaphone")
struct DoubleMetaphoneTests {
    /// 1,669 words (names and the most common English words) coded by the reference JS
    /// implementation (`double-metaphone` 2.0.1).
    @Test func matchesTheReferenceImplementation() throws {
        let url = try #require(Bundle.module.url(forResource: "double-metaphone", withExtension: "json", subdirectory: "Fixtures"))
        let vectors = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        #expect(vectors.count > 1500)
        var mismatches: [String] = []
        for (word, expected) in vectors {
            let codes = DoubleMetaphone.codes(word)
            if [codes.primary, codes.secondary] != expected {
                mismatches.append("\(word): \(codes) vs \(expected)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20))")
    }

    @Test func namesThatSoundAlike() {
        #expect(DoubleMetaphone.soundAlike("Jaylen", "Jalen"))
        #expect(DoubleMetaphone.soundAlike("Priya", "pria"))
        #expect(DoubleMetaphone.soundAlike("Aiden", "Aidan"))
        #expect(!DoubleMetaphone.soundAlike("Maya", "Priya"))
    }
}

@Suite("Edit learning")
struct EditLearningTests {
    @Test func findsAReplacedName() {
        let corrections = EditLearner.corrections(formatted: "Hung out with Jalen and Maya.", final: "Hung out with Jaylen and Maya.")
        #expect(corrections == [Correction(heard: "Jalen", written: "Jaylen")])
    }

    @Test func findsTwoWordMishearings() {
        let corrections = EditLearner.corrections(formatted: "Dinner with jay lynn tonight.", final: "Dinner with Jaylen tonight.")
        #expect(corrections == [Correction(heard: "jay lynn", written: "Jaylen")])
    }

    @Test func ignoresOrdinaryEdits() {
        #expect(EditLearner.corrections(formatted: "It was good.", final: "It was great.").isEmpty)
        #expect(EditLearner.corrections(formatted: "the week was long.", final: "The week was long.").isEmpty)
    }

    @Test func knownNamesCountEvenWhenLowercase() {
        let corrections = EditLearner.corrections(formatted: "saw pria", final: "saw priya", knownNames: ["Priya"])
        #expect(corrections == [Correction(heard: "pria", written: "priya")])
    }

    /// M1 acceptance: correcting the same misheard name twice adds it to the dictionary, and
    /// the next dictation spells it right.
    @Test func secondCorrectionLearnsAndTheNextDictationIsRight() {
        var ledger = LearningLedger()
        var dictionary: [DictionaryEntry] = []
        let correction = Correction(heard: "Jaelin", written: "Jaylen")

        let first = ledger.record([correction], existing: dictionary)
        #expect(first == [.offer(correction)])

        let second = ledger.record([correction], existing: dictionary)
        guard case .autoAdd(let entry) = second.first else {
            Issue.record("expected autoAdd, got \(second)")
            return
        }
        #expect(entry == DictionaryEntry(written: "Jaylen", soundsLike: ["jaelin"]))
        dictionary.append(entry)

        // A third identical correction does nothing more
        #expect(ledger.record([correction], existing: dictionary).isEmpty)
        // And stage 3 now fixes it before any model runs
        #expect(PersonalDictionary(entries: dictionary).apply("dinner with jaelin") == "dinner with Jaylen")
    }

    @Test func ordinaryWordsAreNeverLearnedAsVariants() {
        let entry = LearningLedger.entry(for: Correction(heard: "may", written: "Maya"), existing: [])
        #expect(entry == DictionaryEntry(written: "Maya", soundsLike: []))
    }
}

@Suite("Week boundaries")
struct WeekTests {
    let toronto = TimeZone(identifier: "America/Toronto")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// Shared with `supabase/tests/week_start.sql`.
    @Test(arguments: [
        ("2026-10-26T15:59:00Z", "America/Toronto", "2026-10-19"), // Mon 11:59 local → last week
        ("2026-10-26T16:00:00Z", "America/Toronto", "2026-10-26"), // Mon 12:00 local → this week
        ("2026-10-26T03:59:00Z", "America/Toronto", "2026-10-19"), // Sun 23:59 local
        ("2026-10-21T12:00:00Z", "America/Toronto", "2026-10-19"), // Wed
        ("2026-10-26T02:00:00Z", "Asia/Tokyo", "2026-10-19"),      // Mon 11:00 Tokyo
        ("2026-10-26T03:00:00Z", "Asia/Tokyo", "2026-10-26"),      // Mon 12:00 Tokyo
        ("2026-11-02T15:30:00Z", "America/Toronto", "2026-10-26"), // Mon 10:30 after DST ends
        ("2027-01-03T23:00:00Z", "UTC", "2026-12-28"),             // across a year
    ])
    func weekStart(_ instant: String, _ zone: String, _ expected: String) {
        #expect(Week.start(for: date(instant), in: TimeZone(identifier: zone)!).iso == expected)
    }

    @Test func cutoffIsConfigurable() {
        let mondayMorning = date("2026-10-26T13:00:00Z") // 09:00 Toronto
        #expect(Week.start(for: mondayMorning, in: toronto, mondayCutoffHour: 12).iso == "2026-10-19")
        #expect(Week.start(for: mondayMorning, in: toronto, mondayCutoffHour: 0).iso == "2026-10-26")
    }

    @Test func labels() {
        let locale = Locale(identifier: "en_US")
        #expect(Week.label(for: LocalDate("2026-10-19")!, locale: locale) == "Oct 19 – 25")
        #expect(Week.label(for: LocalDate("2026-09-28")!, locale: locale) == "Sep 28 – Oct 4")
    }

    @Test func localDateCodable() throws {
        let data = try JSONEncoder().encode(["d": LocalDate("2026-10-19")!])
        #expect(String(data: data, encoding: .utf8) == #"{"d":"2026-10-19"}"#)
        #expect(try JSONDecoder().decode([String: LocalDate].self, from: data)["d"]?.iso == "2026-10-19")
    }
}

@Suite("Phone numbers")
struct PhoneNumberTests {
    @Test(arguments: [
        ("(415) 555-0101", "US", "+14155550101"),
        ("1-415-555-0101", "US", "+14155550101"),
        ("+1 415 555 0101", "GB", "+14155550101"),
        ("07700 900123", "GB", "+447700900123"),
        ("+44 7700 900123", "US", "+447700900123"),
        ("0044 7700 900123", "FR", "+447700900123"),
        ("011 44 7700 900123", "US", "+447700900123"),
        ("06 12 34 56 78", "FR", "+33612345678"),
        ("415-555-0101 x204", "CA", "+14155550101"),
    ])
    func normalizes(_ raw: String, _ region: String, _ expected: String) {
        #expect(PhoneNumber.e164(raw, region: region) == expected)
    }

    @Test func rejectsNonsense() {
        #expect(PhoneNumber.e164("555-0101", region: "US") == nil)
        #expect(PhoneNumber.e164("hello", region: "US") == nil)
        #expect(PhoneNumber.e164("12345", region: nil) == nil)
    }

    @Test func hashIsSHA256Hex() {
        #expect(PhoneNumber.hash("+15555550101") == "ae1d87d920613913add7e6c046d5708340ddbe2cb40d14c4709fb654322447e7")
        #expect(PhoneNumber.hash("+15555550101") == PhoneNumber.hash("+15555550101"))
    }
}

@Suite("Waveform and vocabulary")
struct WaveformVocabularyTests {
    @Test func summarizesToOneHundredValues() {
        let samples = (0..<44_100).map { i in Float(sin(Double(i) / 20)) * (i < 22_050 ? 0.1 : 0.8) }
        let summary = Waveform.summarize(samples)
        #expect(summary.count == 100)
        #expect(summary.allSatisfy { (0...1).contains($0) })
        #expect(summary.max() == 1)
        #expect(summary[10] < summary[90])
    }

    @Test func silenceIsFlat() {
        #expect(Waveform.summarize([Float](repeating: 0, count: 1000)) == [Float](repeating: 0, count: 100))
        #expect(Waveform.summarize([]).count == 100)
    }

    @Test func vocabularyRanksAndCaps() {
        let now = Date()
        let friends = (0..<80).map { Vocabulary.Friend(name: "Friend\($0) Last\($0)", lastInteraction: now.addingTimeInterval(TimeInterval(-$0 * 60))) }
        let vocabulary = Vocabulary.build(friends: friends, circles: ["College"], dictionary: [DictionaryEntry(written: "Jaylen")])
        #expect(vocabulary.count == 100)
        #expect(vocabulary.first == "Jaylen")
        #expect(vocabulary[1] == "Friend0 Last0")
        #expect(!vocabulary.contains("Friend79 Last79"))
    }

    @Test func whisperGlossaryPutsTheMostImportantNamesLast() {
        #expect(Vocabulary.whisperGlossary(["Maya", "Jaylen", "Priya"]) == "Friends: Priya, Jaylen, Maya.")
        #expect(Vocabulary.whisperGlossary([]) == "")
    }
}

@Suite("Formatting prompt")
struct FormattingPromptTests {
    /// The hosted fallback keeps its own copy of the prompt; they must not drift.
    @Test func matchesTheEdgeFunctionCopy() throws {
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ts = try String(contentsOf: repo.appending(path: "supabase/functions/_shared/formatting-prompt.ts"), encoding: .utf8)
        let start = try #require(ts.range(of: "export const FORMATTING_PROMPT = `"))
        let end = try #require(ts.range(of: "`;", range: start.upperBound..<ts.endIndex))
        #expect(String(ts[start.upperBound..<end.lowerBound]) == FormattingPrompt.template)
    }

    @Test func fillsVocabulary() {
        #expect(FormattingPrompt.instructions(vocabulary: ["Maya", "Jaylen"]).contains("exactly like this: Maya, Jaylen\n"))
        #expect(!FormattingPrompt.instructions(vocabulary: []).contains("{vocabulary}"))
    }
}
