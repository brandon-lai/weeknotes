import CryptoKit
import Foundation
import Supabase
import WeeknotesCore

/// Every call to the backend. Views talk to this (through `AppModel`), never to the SDK.
@Observable
final class API {
    let client: SupabaseClient
    private(set) var userID: UUID?
    @ObservationIgnored private var signedURLs: [String: (url: URL, expires: Date)] = [:]

    init?() {
        guard let url = AppEnvironment.supabaseURL, AppEnvironment.isConfigured else { return nil }
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: AppEnvironment.supabaseAnonKey,
            options: SupabaseClientOptions(
                db: .init(encoder: Self.encoder, decoder: Self.decoder),
                auth: .init(emitLocalSessionAsInitialSession: true)
            )
        )
    }

    // MARK: JSON

    nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = parseTimestamp(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(raw)"))
        }
        return decoder
    }()

    nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Postgres timestamps: "2026-10-26T22:50:11.451537+00:00", with or without fractions.
    nonisolated static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        // Postgres sometimes sends a space instead of "T"
        let fixed = raw.replacingOccurrences(of: " ", with: "T")
        return fixed == raw ? nil : withFraction.date(from: fixed) ?? plain.date(from: fixed)
    }

    // MARK: Session

    func restoreSession() async -> UUID? {
        if let session = try? await client.auth.session, !session.isExpired {
            userID = session.user.id
        } else if let session = try? await client.auth.refreshSession() {
            userID = session.user.id
        } else {
            userID = nil
        }
        return userID
    }

    /// Native Sign in with Apple: the app gets an identity token from Apple, Supabase checks it.
    func signInWithApple(idToken: String, nonce: String) async throws {
        let session = try await client.auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: idToken, nonce: nonce))
        userID = session.user.id
    }

    /// Developer sign-in for the seeded local accounts. Not compiled into Release builds.
    func signIn(email: String, password: String) async throws {
        let session = try await client.auth.signIn(email: email, password: password)
        userID = session.user.id
    }

    func signOut() async {
        try? await client.auth.signOut()
        userID = nil
        signedURLs = [:]
    }

    func accessToken() async -> String? {
        try? await client.auth.session.accessToken
    }

    private var me: UUID {
        get throws {
            guard let userID else { throw APIError.signedOut }
            return userID
        }
    }

    // MARK: Profile

    func myProfile() async throws -> MyProfile? {
        let rows: [MyProfile] = try await client.rpc("my_profile").execute().value
        return rows.first
    }

    struct NewProfile: Encodable {
        let id: UUID
        let displayName: String
        let timezone: String
        let reminderWeekday: Int
        let reminderTime: String
    }

    func createProfile(name: String, timezone: String, reminderWeekday: Int, reminderTime: String) async throws {
        try await client.from("profiles")
            .insert(NewProfile(id: try me, displayName: name, timezone: timezone, reminderWeekday: reminderWeekday, reminderTime: reminderTime))
            .execute()
    }

    struct ProfileChanges: Encodable {
        var displayName: String?
        var timezone: String?
        var reminderWeekday: Int?
        var reminderTime: String?
        var remindersEnabled: Bool?
    }

    func updateProfile(_ changes: ProfileChanges) async throws {
        try await client.from("profiles").update(changes).eq("id", value: try me).execute()
    }

    /// Sends a code to `e164`. Once verified, the server derives the matchable phone hash
    /// itself, so nobody can claim a number they don't have.
    func startPhoneVerification(e164: String) async throws {
        try await client.auth.update(user: UserAttributes(phone: e164))
    }

    func confirmPhone(e164: String, code: String) async throws {
        try await client.auth.verifyOTP(phone: e164, token: code, type: .phoneChange)
    }

    func flags() async throws -> AppFlags {
        try await client.from("app_config").select().single().execute().value
    }

    // MARK: Friends

    func friends() async throws -> [Friend] {
        try await client.rpc("my_friends").execute().value
    }

    func matchContacts(_ hashes: [String]) async throws -> [ContactMatch] {
        struct Params: Encodable { let hashes: [String] }
        return try await client.rpc("match_contacts", params: Params(hashes: hashes)).execute().value
    }

    @discardableResult
    func sendFriendRequest(_ id: UUID) async throws -> String {
        struct Params: Encodable { let target: UUID }
        return try await client.rpc("send_friend_request", params: Params(target: id)).execute().value
    }

    func respondToRequest(from id: UUID, accept: Bool) async throws {
        struct Params: Encodable { let requester: UUID; let accept: Bool }
        try await client.rpc("respond_friend_request", params: Params(requester: id, accept: accept)).execute()
    }

    func removeFriend(_ id: UUID) async throws {
        struct Params: Encodable { let other: UUID }
        try await client.rpc("remove_friend", params: Params(other: id)).execute()
    }

    // MARK: Circles

    func circles() async throws -> [CircleRow] {
        try await client.from("circles").select("*, circle_members(user_id)").order("name").execute().value
    }

    func createCircle(name: String, members: Set<UUID>) async throws -> CircleRow {
        struct New: Encodable { let ownerId: UUID; let name: String }
        let circle: CircleRow = try await client.from("circles").insert(New(ownerId: try me, name: name)).select().single().execute().value
        try await setMembers(of: circle.id, to: members, from: [])
        return circle
    }

    func renameCircle(_ id: UUID, to name: String) async throws {
        struct Change: Encodable { let name: String }
        try await client.from("circles").update(Change(name: name)).eq("id", value: id).execute()
    }

    func deleteCircle(_ id: UUID) async throws {
        try await client.from("circles").delete().eq("id", value: id).execute()
    }

    func setMembers(of circle: UUID, to members: Set<UUID>, from previous: Set<UUID>) async throws {
        struct Row: Encodable { let circleId: UUID; let userId: UUID }
        let added = members.subtracting(previous)
        let removed = previous.subtracting(members)
        if !added.isEmpty {
            try await client.from("circle_members").insert(added.map { Row(circleId: circle, userId: $0) }).execute()
        }
        if !removed.isEmpty {
            try await client.from("circle_members").delete().eq("circle_id", value: circle).in("user_id", values: Array(removed)).execute()
        }
    }

    // MARK: Updates

    static let updateColumns = "*, voice_memos(*), update_photos(*), update_audiences(circle_id), profiles(display_name)"

    /// The archive: every week I've written, newest first.
    func myUpdates() async throws -> [UpdateRow] {
        try await client.from("updates").select(Self.updateColumns)
            .eq("author_id", value: try me)
            .order("week_start", ascending: false)
            .execute().value
    }

    func update(_ id: UUID) async throws -> UpdateRow? {
        let rows: [UpdateRow] = try await client.from("updates").select(Self.updateColumns).eq("id", value: id).execute().value
        return rows.first
    }

    func myUpdate(for week: LocalDate) async throws -> UpdateRow? {
        let rows: [UpdateRow] = try await client.from("updates").select(Self.updateColumns)
            .eq("author_id", value: try me).eq("week_start", value: week.iso)
            .execute().value
        return rows.first
    }

    /// Circles of my most recent update: the audience picker's default.
    func lastAudience() async throws -> [UUID] {
        let rows: [UpdateRow] = try await client.from("updates").select(Self.updateColumns)
            .eq("author_id", value: try me)
            .order("posted_at", ascending: false).limit(1)
            .execute().value
        return rows.first?.audienceIDs ?? []
    }

    func uploadMemo(updateID: UUID, fileURL: URL) async throws -> String {
        // A new name per recording: a re-recorded memo never overwrites one someone is playing
        let path = "\(try me.uuidString.lowercased())/\(updateID.uuidString.lowercased())/memo-\(Int(Date().timeIntervalSince1970)).m4a"
        try await client.storage.from("memos").upload(path, fileURL: fileURL, options: FileOptions(cacheControl: "31536000", contentType: "audio/mp4"))
        return path
    }

    func uploadPhoto(updateID: UUID, data: Data, index: Int) async throws -> String {
        let path = "\(try me.uuidString.lowercased())/\(updateID.uuidString.lowercased())/photo-\(index)-\(UUID().uuidString.prefix(8).lowercased()).jpg"
        try await client.storage.from("photos").upload(path, data: data, options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg"))
        return path
    }

    struct PublishRequest: Encodable {
        struct Memo: Encodable {
            let storagePath: String
            let durationMs: Int
            let waveform: [Float]
            let transcriptRaw: String?
            let transcriptClean: String?
            let engineId: String?
        }
        struct Photo: Encodable {
            let storagePath: String
            let position: Int
            let width: Int?
            let height: Int?
        }
        let pId: UUID
        let pPrompt: String?
        let pBody: String?
        let pRawTranscript: String?
        let pComposedWith: [String]
        let pComposeMs: Int?
        let pCircles: [UUID]
        let pMemo: Memo?
        let pPhotos: [Photo]
    }

    func publish(_ request: PublishRequest) async throws {
        try await client.rpc("publish_update", params: request).execute()
    }

    /// Deletes the files first, then the row (a trigger also queues the files, so a failure
    /// halfway still cleans up on the next sweep).
    func deleteUpdate(_ update: UpdateRow) async throws {
        if let memo = update.voiceMemos { _ = try? await client.storage.from("memos").remove(paths: [memo.storagePath]) }
        let photos = update.photos.map(\.storagePath)
        if !photos.isEmpty { _ = try? await client.storage.from("photos").remove(paths: photos) }
        try await client.from("updates").delete().eq("id", value: update.id).execute()
    }

    func shareLink(for updateID: UUID, circle: UUID?) async throws -> ShareLink {
        struct Params: Encodable { let target: UUID; let circle: UUID? }
        return try await client.rpc("create_share_link", params: Params(target: updateID, circle: circle)).single().execute().value
    }

    // MARK: Reading

    func feed() async throws -> [FeedCard] {
        try await client.rpc("feed").execute().value
    }

    func markRead(_ updateID: UUID, listenedMs: Int = 0) async {
        struct Params: Encodable { let target: UUID; let listened: Int }
        _ = try? await client.rpc("mark_read", params: Params(target: updateID, listened: listenedMs)).execute()
    }

    /// One reaction per person per update; nil removes it.
    func react(to updateID: UUID, with emoji: String?) async throws {
        struct Row: Encodable { let updateId: UUID; let userId: UUID; let emoji: String }
        if let emoji {
            try await client.from("reactions").upsert(Row(updateId: updateID, userId: try me, emoji: emoji), onConflict: "update_id,user_id").execute()
        } else {
            try await client.from("reactions").delete().eq("update_id", value: updateID).eq("user_id", value: try me).execute()
        }
    }

    /// Reactions on one of my updates (only the author sees them all).
    func reactions(for updateID: UUID) async throws -> [ReactionRow] {
        try await client.from("reactions").select("user_id, emoji, profiles(display_name)").eq("update_id", value: updateID).execute().value
    }

    /// Short-lived signed URL for a private memo or photo, cached until shortly before expiry.
    func signedURL(bucket: String, path: String) async throws -> URL {
        let key = "\(bucket)/\(path)"
        if let cached = signedURLs[key], cached.expires > Date().addingTimeInterval(60) { return cached.url }
        let lifetime = 3600
        let url = try await client.storage.from(bucket).createSignedURL(path: path, expiresIn: lifetime)
        signedURLs[key] = (url, Date().addingTimeInterval(TimeInterval(lifetime)))
        return url
    }

    // MARK: Replies

    func openThread(with friend: UUID) async throws -> UUID {
        struct Params: Encodable { let other: UUID }
        return try await client.rpc("open_thread", params: Params(other: friend)).execute().value
    }

    func inbox() async throws -> [ThreadSummary] {
        try await client.rpc("inbox").execute().value
    }

    func messages(in thread: UUID) async throws -> [Message] {
        try await client.from("messages").select().eq("thread_id", value: thread).order("created_at").execute().value
    }

    func send(_ body: String, in thread: UUID, about update: UUID?) async throws {
        struct Row: Encodable { let threadId: UUID; let senderId: UUID; let updateId: UUID?; let body: String }
        try await client.from("messages").insert(Row(threadId: thread, senderId: try me, updateId: update, body: body)).execute()
    }

    func markThreadRead(_ thread: UUID) async {
        struct Params: Encodable { let target: UUID }
        _ = try? await client.rpc("mark_thread_read", params: Params(target: thread)).execute()
    }

    // MARK: Dictionary

    func dictionary() async throws -> [DictionaryRow] {
        try await client.from("user_dictionary").select("id, written, sounds_like, source").order("written").execute().value
    }

    func saveDictionaryEntry(_ entry: DictionaryEntry, source: String) async throws {
        struct Row: Encodable { let userId: UUID; let written: String; let soundsLike: [String]; let source: String }
        try await client.from("user_dictionary")
            .upsert(Row(userId: try me, written: entry.written, soundsLike: entry.soundsLike, source: source), onConflict: "user_id,written")
            .execute()
    }

    func deleteDictionaryEntry(_ id: UUID) async throws {
        try await client.from("user_dictionary").delete().eq("id", value: id).execute()
    }

    // MARK: Push, invites, account

    func registerPushToken(_ token: String, sandbox: Bool) async {
        struct Row: Encodable { let token: String; let userId: UUID; let environment: String }
        guard let userID else { return }
        _ = try? await client.from("push_tokens")
            .upsert(Row(token: token, userId: userID, environment: sandbox ? "sandbox" : "production"), onConflict: "token")
            .execute()
    }

    func acceptInvite(_ token: String) async throws -> InviteResult {
        struct Params: Encodable { let token: String }
        return try await client.rpc("accept_invite", params: Params(token: token)).single().execute().value
    }

    /// Deletes the account, its files and everything it wrote. Irreversible.
    func deleteAccount() async throws {
        guard let base = AppEnvironment.functionsURL, let token = await accessToken() else { throw APIError.signedOut }
        var request = URLRequest(url: base.appending(path: "delete-account"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AppEnvironment.supabaseAnonKey, forHTTPHeaderField: "apikey")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.server("Couldn't delete your account. Try again.") }
        try? await client.auth.signOut()
        userID = nil
    }
}

enum APIError: LocalizedError {
    case signedOut
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: "You're signed out."
        case .server(let message): message
        }
    }
}

/// Sign in with Apple needs a random nonce; Apple gets its SHA-256, Supabase the original.
enum Nonce {
    static func make(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Turns any error into something a person can read.
func friendlyMessage(_ error: Error) -> String {
    if let api = error as? APIError { return api.errorDescription ?? "Something went wrong." }
    let text = "\(error)"
    if text.contains("NSURLErrorDomain") || (error as NSError).domain == NSURLErrorDomain {
        return "Can't reach Weeknotes. Check your connection and try again."
    }
    if let postgrest = error as? PostgrestError { return postgrest.message }
    if let auth = error as? AuthError { return auth.message }
    return error.localizedDescription
}
