import Foundation
import Testing
import WeeknotesCore
@testable import Weeknotes

/// App-level logic that isn't in WeeknotesCore: deep links, decoding what the server sends,
/// recorder settings. The pipeline itself is tested in the package (`swift test`).
@MainActor
struct WeeknotesTests {
    @Test func inviteLinksParse() {
        let token = "AbCdEfGhIjKlMnOpQrStUvWx"
        #expect(DeepLink.inviteToken(from: URL(string: "weeknotes://u/\(token)")!) == token)
        #expect(DeepLink.inviteToken(from: URL(string: "https://weeknotes.vercel.app/u/\(token)")!) == token)
        #expect(DeepLink.inviteToken(from: URL(string: "https://weeknotes.vercel.app/u/short")!) == nil)
        #expect(DeepLink.inviteToken(from: URL(string: "https://weeknotes.vercel.app/privacy")!) == nil)
    }

    @Test func postgresTimestampsParse() {
        #expect(API.parseTimestamp("2026-10-26T22:50:11.451537+00:00") != nil)
        #expect(API.parseTimestamp("2026-10-26T22:50:11+00:00") != nil)
        #expect(API.parseTimestamp("2026-10-26 22:50:11.4+00:00") != nil)
        #expect(API.parseTimestamp("not a date") == nil)
    }

    /// The exact shape `feed()` returns (snake_case, jsonb memo and photos, Postgres dates).
    @Test func feedRowsDecode() throws {
        let json = """
        [{"update_id":"6f1c2c6e-6f4e-4b6f-9e0e-2b8a8f3c1a11","author_id":"0b0a6c43-58f8-4e0c-9c9f-5b2d6e1f7a22",
          "author_name":"Hana Sato","week_start":"2026-10-26","is_current_week":true,"prompt":null,
          "body_text":"Walked by the river.","posted_at":"2026-10-26T22:47:00.123456+00:00","edited_at":null,
          "memo":{"id":"5e3d1a90-1c2b-4c3d-8e9f-0a1b2c3d4e5f","storage_path":"a/b/memo.m4a","duration_ms":61000,
                  "waveform":[0.1,0.5,1],"transcript_clean":"Hi.","transcript_raw":"hi"},
          "photos":[{"id":"7a6b5c4d-3e2f-4a1b-9c8d-7e6f5a4b3c2d","storage_path":"a/b/0.jpg","position":0,"width":1200,"height":900}],
          "read_at":null,"listened_ms":0,"my_reaction":"❤️"}]
        """
        let cards = try API.decoder.decode([FeedCard].self, from: Data(json.utf8))
        #expect(cards.count == 1)
        #expect(cards[0].authorName == "Hana Sato")
        #expect(cards[0].weekStart.iso == "2026-10-26")
        #expect(cards[0].memo?.waveform == [0.1, 0.5, 1])
        #expect(cards[0].photos.first?.width == 1200)
        #expect(cards[0].isUnread)
    }

    @Test func publishParamsEncodeAsTheRPCExpects() throws {
        let request = API.PublishRequest(
            pId: UUID(), pPrompt: nil, pBody: "Hi", pRawTranscript: nil, pComposedWith: ["typed"], pComposeMs: 1000,
            pCircles: [], pMemo: .init(storagePath: "x", durationMs: 1, waveform: [0.5], transcriptRaw: nil, transcriptClean: nil, engineId: "apple-speech"),
            pPhotos: []
        )
        let object = try JSONSerialization.jsonObject(with: API.encoder.encode(request)) as! [String: Any]
        #expect(Set(object.keys) == ["p_id", "p_prompt", "p_body", "p_raw_transcript", "p_composed_with", "p_compose_ms", "p_circles", "p_memo", "p_photos"])
        let memo = object["p_memo"] as! [String: Any]
        #expect(memo["storage_path"] as? String == "x")
        #expect(memo["engine_id"] as? String == "apple-speech")
    }

    @Test func memosRecordAsAACMono64k() {
        let settings = MemoRecorder.settings
        #expect(settings["AVNumberOfChannelsKey"] as? Int == 1)
        #expect(settings["AVEncoderBitRateKey"] as? Int == 64_000)
    }

    @Test func promptsAreStablePerWeek() {
        let week = LocalDate("2026-10-26")!
        #expect(Prompts.suggestions(for: week) == Prompts.suggestions(for: week))
        #expect(Prompts.suggestions(for: week).count == 3)
    }
}
