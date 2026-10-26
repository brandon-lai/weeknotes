import Foundation
import Testing
@testable import WeeknotesCore

/// Builds timed words from "word word | word" where "|" marks a pause longer than the threshold.
func timed(_ script: String, gap: TimeInterval = 0.05, pause: TimeInterval = 0.6) -> [TimedWord] {
    var words: [TimedWord] = []
    var t: TimeInterval = 0
    var pendingPause = false
    for token in script.split(separator: " ") {
        if token == "|" {
            pendingPause = true
            continue
        }
        t += pendingPause ? pause : gap
        pendingPause = false
        words.append(TimedWord(text: String(token), start: t, end: t + 0.25))
        t += 0.25
    }
    return words
}

@Suite("Stage 2: spoken commands")
struct SpokenCommandTests {
    @Test func periodOfTimeStaysWords() {
        #expect(SpokenCommands.apply(timed("it was the period of time when we lived there"), pauseThreshold: 0.3)
            == "it was the period of time when we lived there")
    }

    @Test func commandFollowedByPauseBecomesPunctuation() {
        #expect(SpokenCommands.apply(timed("it rained all week period | the weekend was nice"), pauseThreshold: 0.3)
            == "it rained all week. the weekend was nice")
    }

    @Test func commandAtTheEndNeedsNoPause() {
        #expect(SpokenCommands.apply(timed("can you guys come saturday question mark"), pauseThreshold: 0.3)
            == "can you guys come saturday?")
    }

    @Test func everyCommand() {
        let script = "a comma | b colon | c semicolon | d exclamation point | e exclamation mark | f full stop | g question mark | h new line | i next line | j line break | k new paragraph | l"
        #expect(SpokenCommands.apply(timed(script), pauseThreshold: 0.3)
            == "a, b: c; d! e! f. g? h [[NL]] i [[NL]] j [[NL]] k [[P]] l")
    }

    @Test func commandWithoutPauseIsLeftAlone() {
        #expect(SpokenCommands.apply(timed("I need a comma splice fixed"), pauseThreshold: 0.3) == "I need a comma splice fixed")
        #expect(SpokenCommands.apply(timed("we started a new line of work"), pauseThreshold: 0.3) == "we started a new line of work")
    }

    @Test func pauseThresholdIsConfigurable() {
        let words = timed("done period | next", pause: 0.4)
        #expect(SpokenCommands.apply(words, pauseThreshold: 0.3) == "done. next")
        #expect(SpokenCommands.apply(words, pauseThreshold: 0.5) == "done period next")
    }

    @Test func replacesPunctuationTheEngineGuessed() {
        let words = [TimedWord(text: "busy,", start: 0, end: 0.3), TimedWord(text: "period", start: 0.35, end: 0.6)]
        #expect(SpokenCommands.apply(words, pauseThreshold: 0.3) == "busy.")
    }

    @Test func trailingAndLeadingMarkersAreDropped() {
        #expect(SpokenCommands.apply(timed("new paragraph | hello there new paragraph"), pauseThreshold: 0.3) == "hello there")
    }

    @Test func consecutiveMarkersCollapse() {
        #expect(SpokenCommands.apply(timed("a new line | new paragraph | b"), pauseThreshold: 0.3) == "a [[P]] b")
    }
}

@Suite("Stage 3: dictionary")
struct DictionaryTests {
    let dictionary = PersonalDictionary(entries: [
        DictionaryEntry(written: "Jaylen", soundsLike: ["Jalen", "Jay Lynn"]),
        DictionaryEntry(written: "Priya"),
        DictionaryEntry(written: "Pho Bang", soundsLike: ["fo bang"]),
    ])

    @Test func exactVariantCaseInsensitive() {
        #expect(dictionary.apply("hung out with JALEN today") == "hung out with Jaylen today")
    }

    @Test func multiWordVariant() {
        #expect(dictionary.apply("me and jay lynn went out") == "me and Jaylen went out")
        #expect(dictionary.apply("dinner at fo bang again") == "dinner at Pho Bang again")
    }

    @Test func keepsPunctuationAndPossessives() {
        #expect(dictionary.apply("it was jalen's birthday, and jalen.") == "it was Jaylen's birthday, and Jaylen.")
    }

    @Test func wordBoundariesOnly() {
        #expect(dictionary.apply("jalenx and xjalen") == "jalenx and xjalen")
    }

    @Test func fuzzyPhoneticMatch() {
        // Not a listed variant: caught by sound + edit distance
        #expect(dictionary.apply("saw pria and jaylin") == "saw Priya and Jaylen")
    }

    @Test func fuzzyNeverTouchesCommonWords() {
        let maya = PersonalDictionary(entries: [DictionaryEntry(written: "Maya"), DictionaryEntry(written: "Will")])
        #expect(maya.apply("I may go and I will") == "I may go and I will")
        #expect(maya.apply("maya came") == "Maya came")
    }

    @Test func fuzzyLeavesTiesAlone() {
        let twins = PersonalDictionary(entries: [DictionaryEntry(written: "Jaylen"), DictionaryEntry(written: "Jalyn")])
        // "jaylyn" is one edit from both
        #expect(twins.fuzzyMatch("jaylyn") == nil)
    }

    @Test func markersPassThrough() {
        #expect(dictionary.apply("jalen [[P]] pria") == "Jaylen [[P]] Priya")
    }

    @Test func commonWordListLoaded() {
        #expect(CommonWords.shared.count > 30_000)
        #expect(CommonWords.shared.contains("period"))
        #expect(!CommonWords.shared.contains("jalen"))
    }
}

@Suite("Stage 5: validator")
struct ValidatorTests {
    let validator = FormatValidator(vocabulary: ["Maya", "Priya"])

    @Test func rejectsAddedWords() {
        #expect(validator.validate(input: "maya's birthday dinner was so fun", output: "Maya's birthday dinner was so fun! 🎉 What a night.")
            == .rejected(.addedWords(["what", "a", "night"])))
    }

    @Test func rejectsHeavyDropWithoutBacktrack() {
        let result = validator.validate(input: "we went to the market and then to the park and then home", output: "We went home.")
        guard case .rejected(.droppedContent) = result else {
            Issue.record("expected droppedContent, got \(result)")
            return
        }
    }

    @Test func allowsHeavyDropWhenTheSpeakerCorrectedThemselves() {
        #expect(validator.validate(input: "I went to the gym and the pool scratch that I went for a run", output: "I went for a run.") == .accepted)
    }

    @Test func rejectsLostMarker() {
        #expect(validator.validate(input: "work was fine [[P]] the weekend", output: "Work was fine. The weekend.") == .rejected(.markersChanged))
    }

    @Test func rejectsMovedMarker() {
        let result = validator.validate(input: "work was fine on monday [[P]] the weekend was fun", output: "Work was fine [[P]] on Monday the weekend was fun.")
        #expect(!result.isAccepted)
    }

    @Test func rejectsReordering() {
        #expect(!validator.validate(input: "saturday no wait sunday", output: "Sunday. No wait, Saturday.").isAccepted)
    }

    @Test func allowsDigitsForNumberWords() {
        #expect(validator.validate(input: "spent forty dollars at seven thirty pm", output: "Spent $40 at 7:30 pm.") == .accepted)
    }

    @Test func rejectsDigitsNobodySaid() {
        #expect(!validator.validate(input: "we had dinner", output: "We had dinner at 8.").isAccepted)
    }

    @Test func allowsVocabularySpelling() {
        #expect(validator.validate(input: "saw pria today", output: "Saw Priya today.") == .accepted)
    }

    @Test func repairRemovesOnlyAddedConnectingWords() {
        let input = "we're doing brunch saturday no wait sunday"
        let output = "We're doing brunch on Sunday."
        #expect(validator.repair(input: input, output: output) == "We're doing brunch Sunday.")
        // Other additions aren't repaired
        #expect(validator.repair(input: "we had fun", output: "We had so much fun.") == nil)
    }

    @Test func repairKeepsLineStructure() {
        let input = "two things first I cleaned second I cooked"
        let output = "Two things:\n1. I cleaned the.\n2. I cooked."
        #expect(validator.repair(input: input, output: output) == "Two things:\n1. I cleaned.\n2. I cooked.")
    }

    @Test func emptyOutputIsRejected() {
        #expect(validator.validate(input: "hello there", output: "  ") == .rejected(.empty))
    }
}

/// A formatter that always fails or always answers something fixed.
struct FixedFormatter: FormattingEngine {
    let id: String
    let answer: String?
    func format(_ text: String, vocabulary: [String]) async throws -> String {
        guard let answer else { throw FormattingError.unavailable("deviceNotEligible") }
        return answer
    }
}

@Suite("Pipeline")
struct PipelineTests {
    @Test func fallsBackWhenTheDeviceModelIsUnavailable() async {
        let pipeline = DictationPipeline(
            primary: FixedFormatter(id: "apple-foundation", answer: nil),
            fallback: FixedFormatter(id: "hosted-small", answer: "We got dinner at 8.")
        )
        let result = await pipeline.format("we got dinner at seven actually eight", vocabulary: [])
        #expect(result.text == "We got dinner at 8.")
        #expect(result.engineID == "hosted-small")
        #expect(result.fellBack)
        #expect(!result.skipped)
    }

    @Test func fallsBackWhenTheDeviceOutputIsRejected() async {
        let pipeline = DictationPipeline(
            primary: FixedFormatter(id: "apple-foundation", answer: "We got dinner at 8 with everyone!"),
            fallback: FixedFormatter(id: "hosted-small", answer: "We got dinner at 8.")
        )
        let result = await pipeline.format("we got dinner at seven actually eight", vocabulary: [])
        #expect(result.engineID == "hosted-small")
    }

    @Test func skipsFormattingWhenEverythingIsRejected() async {
        let pipeline = DictationPipeline(
            primary: FixedFormatter(id: "apple-foundation", answer: "Totally different."),
            fallback: FixedFormatter(id: "hosted-small", answer: "Also different.")
        )
        let result = await pipeline.format("um we got dinner [[P]] it was fun", vocabulary: [])
        #expect(result.skipped)
        #expect(result.engineID == "none")
        #expect(result.text == "We got dinner.\n\nIt was fun.")
    }

    @Test func runAppliesEveryStageAndKeepsTheRawTranscript() async {
        let words = timed("hung out with jalen | new paragraph | then dinner at seven")
        let transcript = Transcript(text: words.joinedText, words: words, engineID: "apple-speech", durationMs: 4000)
        let context = FormattingContext(
            vocabulary: ["Jaylen"],
            dictionary: [DictionaryEntry(written: "Jaylen", soundsLike: ["jalen"])],
            isDictation: true
        )
        let expectedStage3 = "hung out with Jaylen [[P]] then dinner at seven"
        let engine = ScriptedFormatter(id: "apple-foundation", answers: [expectedStage3: "Hung out with Jaylen. [[P]] Then dinner at 7."])
        let result = await DictationPipeline(primary: engine, fallback: nil).run(transcript, context: context)
        #expect(result.raw == "hung out with jalen new paragraph then dinner at seven")
        #expect(result.formatted == "Hung out with Jaylen.\n\nThen dinner at 7.")
        #expect(result.engineID == "apple-foundation")
    }

    @Test func memoTranscriptsSkipSpokenCommands() async {
        let transcript = Transcript(text: "the period of my life period", words: [], engineID: "apple-speech", durationMs: 2000)
        let context = FormattingContext(vocabulary: [], dictionary: [], isDictation: false)
        let engine = ScriptedFormatter(id: "x", answers: ["the period of my life period": "The period of my life period."])
        let result = await DictationPipeline(primary: engine, fallback: nil).run(transcript, context: context)
        #expect(result.formatted == "The period of my life period.")
    }

    @Test func longInputIsChunked() {
        let sentence = "I walked to the store and bought some bread."
        let long = Array(repeating: sentence, count: 150).joined(separator: " ")
        let chunks = Chunker.split(long, maxWords: 600)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.text.split(separator: " ").count <= 600 })
        #expect(chunks.dropLast().allSatisfy { $0.text.hasSuffix(".") })
        let rejoined = chunks.map { $0.text + $0.joiner }.joined()
        #expect(TextTools.words(rejoined) == TextTools.words(long))
    }

    @Test func chunksSplitAtParagraphsFirst() {
        let paragraph = Array(repeating: "word", count: 400).joined(separator: " ")
        let chunks = Chunker.split("\(paragraph) [[P]] \(paragraph)", maxWords: 600)
        #expect(chunks.count == 2)
        #expect(chunks[0].joiner == " [[P]] ")
    }

    @Test func shortInputIsOneChunk() {
        #expect(Chunker.split("hello there [[P]] friend", maxWords: 600).count == 1)
    }
}

@Suite("Text tools")
struct TextToolTests {
    @Test func polishCapitalizesAndPunctuates() {
        #expect(TextTools.polish("um so i went out") == "So I went out.")
        #expect(TextTools.polish("three highlights:\n1. i cooked\n2. maya visited") == "Three highlights:\n1. I cooked.\n2. Maya visited.")
        #expect(TextTools.polish("fine [[P]] then home") == "Fine. [[P]] Then home.")
        #expect(TextTools.polish("Ran 3.1 miles at 6:30 am") == "Ran 3.1 miles at 6:30 am.")
        #expect(TextTools.polish("Ran at 6:30 AM. Back by 8pm, then 9 p.m. bed.") == "Ran at 6:30 am. Back by 8 pm, then 9 pm bed.")
        #expect(TextTools.polish("I am fine at the AMC") == "I am fine at the AMC.")
    }

    @Test func tidyRemovesEmDashes() {
        #expect(TextTools.tidyModelOutput("went out \u{2014} it was fun") == "went out, it was fun")
    }

    @Test func markersBecomeLineBreaks() {
        #expect(TextTools.convertMarkers("a [[NL]] b [[P]] c") == "a\nb\n\nc")
    }

    @Test func normalizedWords() {
        #expect(TextTools.words("I'm at 6:30 a.m., \u{2019}cause $40!") == ["i'm", "at", "6:30", "am", "cause", "40"])
    }
}
