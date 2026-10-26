import Foundation
import Testing
@testable import WeeknotesCore

/// The golden test set (PRD §8): every formatting model must pass all 14 cases before it can
/// be the default. Inputs are text after stages 1 to 3; expected outputs are after markers
/// become line breaks.
struct GoldenCase: Codable, Sendable, CustomTestStringConvertible {
    let id: Int
    let input: String
    let expected: String
    let tests: String

    var testDescription: String { "#\(id) \(tests)" }

    /// What a model should return for this case, before markers become line breaks.
    var modelOutput: String {
        expected.replacingOccurrences(of: "\n\n", with: " [[P]] ")
    }
}

struct GoldenSet: Codable {
    let vocabulary: [String]
    let cases: [GoldenCase]

    static let shared: GoldenSet = {
        let url = Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(GoldenSet.self, from: Data(contentsOf: url))
    }()
}

/// Exact comparison, after trimming and tidying whitespace that has no meaning.
func sameText(_ a: String, _ b: String) -> Bool {
    func tidy(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }
    return tidy(a) == tidy(b)
}

/// Returns a canned answer per input, so the pipeline's plumbing is tested without a model.
struct ScriptedFormatter: FormattingEngine {
    let id: String
    let answers: [String: String]
    func format(_ text: String, vocabulary: [String]) async throws -> String {
        guard let answer = answers[text] else { throw FormattingError.failed("no script for \(text)") }
        return answer
    }
}

@Suite("Golden set")
struct GoldenSetTests {
    static let cases = GoldenSet.shared.cases
    let vocabulary = GoldenSet.shared.vocabulary

    @Test func hasAllFourteenCases() {
        #expect(Self.cases.map(\.id) == Array(1...14))
    }

    /// The validator must never reject the answer we want.
    @Test(arguments: cases)
    func validatorAcceptsExpectedOutput(_ c: GoldenCase) {
        let result = FormatValidator(vocabulary: vocabulary).validate(input: c.input, output: c.modelOutput)
        #expect(result == .accepted, "\(result)")
    }

    @Test(arguments: cases)
    func pipelinePassesThroughAcceptedOutput(_ c: GoldenCase) async {
        let engine = ScriptedFormatter(id: "scripted", answers: [c.input: c.modelOutput])
        let pipeline = DictationPipeline(primary: engine, fallback: nil)
        let result = await pipeline.format(c.input, vocabulary: vocabulary)
        #expect(sameText(result.text, c.expected), "got: \(result.text)")
        #expect(!result.fellBack)
    }
}

// MARK: - Real engines

#if canImport(FoundationModels)
@Suite("Golden set: apple-foundation", .enabled(if: AppleFoundationFormatter.unavailableReason == nil, "Apple Intelligence is not available on this machine"))
struct AppleFoundationGoldenTests {
    @Test(arguments: GoldenSetTests.cases)
    func passes(_ c: GoldenCase) async throws {
        let engine = AppleFoundationFormatter()
        let raw = try await engine.format(c.input, vocabulary: GoldenSet.shared.vocabulary)
        let verdict = FormatValidator(vocabulary: GoldenSet.shared.vocabulary).validate(input: c.input, output: TextTools.tidyModelOutput(raw))
        let pipeline = DictationPipeline(primary: engine, fallback: nil)
        let result = await pipeline.format(c.input, vocabulary: GoldenSet.shared.vocabulary)
        #expect(!result.skipped, "validator: \(verdict) model said: \(raw.debugDescription)")
        #expect(sameText(result.text, c.expected), "model said: \(raw.debugDescription)")
    }
}
#endif

/// The hosted fallback, through the deployed or locally served `format` Edge Function.
/// Set WEEKNOTES_FUNCTIONS_URL, WEEKNOTES_ANON_KEY and WEEKNOTES_TEST_JWT to run it
/// (`scripts/golden-hosted.sh` does this against the local Supabase stack).
enum HostedTestConfig {
    static let env = ProcessInfo.processInfo.environment
    static var engine: HostedFormatter? {
        guard let url = env["WEEKNOTES_FUNCTIONS_URL"].flatMap(URL.init(string:)),
              let key = env["WEEKNOTES_ANON_KEY"], let jwt = env["WEEKNOTES_TEST_JWT"] else { return nil }
        return HostedFormatter(functionsURL: url, apiKey: key, accessToken: { jwt })
    }
}

@Suite("Golden set: hosted-small", .enabled(if: HostedTestConfig.engine != nil, "WEEKNOTES_FUNCTIONS_URL / WEEKNOTES_ANON_KEY / WEEKNOTES_TEST_JWT not set"))
struct HostedGoldenTests {
    @Test(arguments: GoldenSetTests.cases)
    func passes(_ c: GoldenCase) async throws {
        let engine = try #require(HostedTestConfig.engine)
        let raw = try await engine.format(c.input, vocabulary: GoldenSet.shared.vocabulary)
        let pipeline = DictationPipeline(primary: engine, fallback: nil)
        let result = await pipeline.format(c.input, vocabulary: GoldenSet.shared.vocabulary)
        #expect(!result.skipped, "validator rejected: \(raw)")
        #expect(sameText(result.text, c.expected), "model said: \(raw)")
    }
}
