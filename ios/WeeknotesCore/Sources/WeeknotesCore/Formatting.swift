import Foundation

/// Stage 4: an LLM that formats a transcript. IDs: "apple-foundation", "hosted-small".
public protocol FormattingEngine: Sendable {
    var id: String { get }
    func format(_ text: String, vocabulary: [String]) async throws -> String
}

public enum FormattingError: Error, Equatable, LocalizedError {
    /// The on-device model can't run here: `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`.
    case unavailable(String)
    /// A safety guardrail stopped the model.
    case guardrail
    case tooLong
    case network(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Formatting model unavailable (\(reason))"
        case .guardrail: "Formatting was blocked by a safety guardrail"
        case .tooLong: "Too much text to format at once"
        case .network(let detail): "Couldn't reach the formatting service: \(detail)"
        case .failed(let detail): detail
        }
    }
}

/// The formatting prompt from the PRD, few-shot examples included. The hosted fallback
/// keeps an identical copy server-side (`supabase/functions/_shared/formatting-prompt.ts`);
/// `FormattingPromptTests` fails if the two drift.
public enum FormattingPrompt {
    public static let template = """
    You format a transcript of someone speaking about their week. Their friends will read it.
    Your job is formatting only. The words must stay the speaker's own.

    Do:
    - Remove filler words (um, uh, er, you know, I mean, and "like" only when it is filler),
      false starts, and stutters.
    - When the speaker corrects themselves ("actually", "scratch that", "no wait", "never mind",
      or restating), keep only the corrected version. If those words are not a correction, keep them.
    - Add punctuation and capitalization. Start a new paragraph at clear topic changes.
    - If the speaker lists items with "first/second/third" or "one/two/three", write a numbered list.
      If they say "a few things" and then name them, write a bulleted list.
    - Write times, dates, money, and measurements as digits. Write other numbers one to nine as words.
    - Spell these names and terms exactly like this: {vocabulary}
    - Keep [[NL]] and [[P]] markers exactly where they are.

    Do not:
    - Add any word, fact, emoji, heading, or summary that the speaker did not say.
    - Change slang, tone, or word choice. Do not make it more formal.
    - Use em dashes.

    Return only the formatted text.

    Example input: um so this week was uh pretty pretty busy honestly
    Example output: So this week was pretty busy, honestly.

    Example input: we got dinner at seven actually eight with maya
    Example output: We got dinner at 8 with Maya.

    Example input: the movie was actually really good
    Example output: The movie was actually really good.

    Example input: three highlights first I tried the new ramen place second maya visited third I finally started running again
    Example output:
    Three highlights:
    1. I tried the new ramen place.
    2. Maya visited.
    3. I finally started running again.
    """

    /// The prompt with the vocabulary filled in. With no vocabulary the spelling line is dropped
    /// rather than left pointing at nothing.
    public static func instructions(vocabulary: [String]) -> String {
        let names = vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if names.isEmpty {
            return template.replacingOccurrences(of: "- Spell these names and terms exactly like this: {vocabulary}\n", with: "")
        }
        return template.replacingOccurrences(of: "{vocabulary}", with: names.joined(separator: ", "))
    }
}

/// The fallback formatter: a small hosted model behind the `format` Edge Function, so the
/// API key never leaves the server.
public struct HostedFormatter: FormattingEngine {
    public let id = "hosted-small"
    let endpoint: URL
    let apiKey: String
    let accessToken: @Sendable () async -> String?
    let session: URLSession

    /// - Parameters:
    ///   - functionsURL: `https://<ref>.supabase.co/functions/v1`
    ///   - apiKey: the project's publishable (anon) key
    ///   - accessToken: the signed-in user's JWT
    public init(functionsURL: URL, apiKey: String, accessToken: @escaping @Sendable () async -> String?, session: URLSession = .shared) {
        self.endpoint = functionsURL.appending(path: "format")
        self.apiKey = apiKey
        self.accessToken = accessToken
        self.session = session
    }

    struct Body: Encodable { let text: String; let vocabulary: [String] }
    struct Reply: Decodable { let text: String?; let error: String? }

    public func format(_ text: String, vocabulary: [String]) async throws -> String {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = await accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Body(text: text, vocabulary: vocabulary))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FormattingError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard status == 200, let formatted = reply?.text else {
            throw FormattingError.failed(reply?.error ?? "Formatting service returned \(status)")
        }
        return formatted
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// The primary formatter: Apple's on-device model. Free, private, works offline; needs
/// Apple Intelligence. Throws `.unavailable` so the pipeline can fall back.
///
/// The ~3B on-device model needs more help than the hosted one to pass the golden set, so it
/// gets the PRD's rules with three changes (see README, "Formatting on device"):
/// - The examples are real conversation turns, and different from the golden cases: with the
///   PRD's inline examples the model copied words from them ("honestly", "finally").
/// - Output is guided generation into a single `text` field, so it can't add a preamble.
/// - Markers never reach the model. Text is split at `[[NL]]`/`[[P]]`, each piece is formatted
///   on its own, and the markers are put back, so they can't be lost or moved.
public struct AppleFoundationFormatter: FormattingEngine {
    public let id = "apple-foundation"

    public init() {}

    static var model: SystemLanguageModel {
        // Formatting rewrites the user's own words; the permissive guardrails are meant for that
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    /// nil when the model can run, otherwise the reason it can't.
    public static var unavailableReason: String? {
        switch model.availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "deviceNotEligible"
            case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
            case .modelNotReady: return "modelNotReady"
            @unknown default: return "unavailable"
            }
        }
    }

    @Generable
    struct Formatted {
        @Guide(description: "The transcript, formatted. Only the speaker's own words.")
        var text: String
    }

    public func format(_ text: String, vocabulary: [String]) async throws -> String {
        if let reason = Self.unavailableReason { throw FormattingError.unavailable(reason) }
        var out: [String] = []
        for piece in OnDevicePrompt.splitAtMarkers(text) {
            if TextTools.isMarker(piece) {
                out.append(piece)
            } else {
                out.append(try await formatPiece(piece, vocabulary: vocabulary))
            }
        }
        return out.joined(separator: " ")
    }

    private func formatPiece(_ text: String, vocabulary: [String]) async throws -> String {
        let session = LanguageModelSession(model: Self.model, transcript: OnDevicePrompt.transcript(vocabulary: vocabulary))
        let budget = max(64, Int(Double(text.count) / 2.5) + 64)
        do {
            let response = try await session.respond(
                to: OnDevicePrompt.prompt(text),
                generating: Formatted.self,
                includeSchemaInPrompt: false,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: budget)
            )
            return response.content.text
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation: throw FormattingError.guardrail
            case .exceededContextWindowSize: throw FormattingError.tooLong
            default: throw FormattingError.failed(error.localizedDescription)
            }
        }
    }
}

enum OnDevicePrompt {
    /// The PRD rules, minus the inline examples (they become turns below) and the marker rule
    /// (markers are handled in code).
    static func instructions(vocabulary: [String]) -> String {
        var rules = FormattingPrompt.instructions(vocabulary: vocabulary)
        if let examples = rules.range(of: "\n\nExample input:") { rules = String(rules[..<examples.lowerBound]) }
        rules = rules.replacingOccurrences(of: "- Keep [[NL]] and [[P]] markers exactly where they are.\n", with: "")
        return rules
    }

    /// Examples that teach each rule without overlapping the golden cases.
    static let examples: [(String, String)] = [
        ("uh so I I finally fixed my bike um yesterday", "So I finally fixed my bike yesterday."),
        ("the party starts at nine actually ten", "The party starts at 10."),
        ("we drove to the lake scratch that we took the train to the lake", "We took the train to the lake."),
        ("my sister visits friday no wait thursday", "My sister visits Thursday."),
        ("the hike was actually pretty easy", "The hike was actually pretty easy."),
        ("I like my new job a lot it was like so good", "I like my new job a lot. It was so good."),
        ("spent forty dollars on groceries and walked two point five miles at seven fifteen pm", "Spent $40 on groceries and walked 2.5 miles at 7:15 pm."),
        ("two wins first my plants survived second I cleaned the fridge", "Two wins:\n1. My plants survived.\n2. I cleaned the fridge."),
        ("lowkey the best taco ever ngl", "Lowkey the best taco ever, ngl."),
    ]

    static func prompt(_ text: String) -> String { text }

    static func transcript(vocabulary: [String]) -> FoundationModels.Transcript {
        var entries: [FoundationModels.Transcript.Entry] = [
            .instructions(FoundationModels.Transcript.Instructions(segments: [.text(.init(content: instructions(vocabulary: vocabulary)))], toolDefinitions: [])),
        ]
        for (input, output) in examples {
            entries.append(.prompt(FoundationModels.Transcript.Prompt(segments: [.text(.init(content: prompt(input)))])))
            entries.append(.response(FoundationModels.Transcript.Response(assetIDs: [], segments: [.text(.init(content: output))])))
        }
        return FoundationModels.Transcript(entries: entries)
    }

    /// "a [[P]] b" → ["a", "[[P]]", "b"]
    static func splitAtMarkers(_ text: String) -> [String] {
        var pieces: [String] = []
        var current: [String] = []
        for token in TextTools.rawTokens(text) {
            if TextTools.isMarker(token) {
                if !current.isEmpty { pieces.append(current.joined(separator: " ")) }
                pieces.append(token)
                current = []
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { pieces.append(current.joined(separator: " ")) }
        return pieces
    }
}
#endif
