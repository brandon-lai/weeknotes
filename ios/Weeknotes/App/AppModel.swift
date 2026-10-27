import Foundation
import Observation
import SwiftUI
import WeeknotesCore

/// App-wide state: who is signed in, their profile, friends and circles, and where deep links
/// should take the user. Feature views keep their own local state.
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case notConfigured
        case signedOut
        case needsProfile
        case ready
    }

    enum Tab: Hashable {
        case week, archive, inbox, people
    }

    let api: API?
    var phase: Phase = .launching
    var profile: MyProfile?
    var flags = AppFlags(requirePostToRead: AppConfig.requirePostToReadDefault, mondayCutoffHour: AppConfig.mondayCutoffHour, shareLinkDays: AppConfig.shareLinkLifetimeDays, appStoreUrl: nil)
    var friends: [Friend] = []
    var circles: [CircleRow] = []
    var dictionary: [DictionaryRow] = []
    var unreadReplies = 0

    var selectedTab: Tab = .week
    var composerRequested = false
    /// An invite token from a share link opened before (or while) signing in.
    var pendingInvite: String?
    var toast: Toast?

    let learning = LearningStore()
    let engines = EngineSettings()

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let text: String
        var systemImage: String = "checkmark.circle.fill"
    }

    init() {
        api = API()
        if LaunchOptions.arguments.contains("-resetState") { Self.resetLocalState() }
    }

    var acceptedFriends: [Friend] { friends.filter(\.isAccepted) }
    var incomingRequests: [Friend] { friends.filter(\.isIncomingRequest) }

    var currentWeek: LocalDate {
        profile?.weekStart ?? Week.start(for: Date(), in: .current, mondayCutoffHour: flags.mondayCutoffHour)
    }

    var timeZone: TimeZone { profile.flatMap { TimeZone(identifier: $0.timezone) } ?? .current }

    // MARK: Session

    func start() async {
        guard let api else {
            phase = .notConfigured
            return
        }
        #if DEBUG
        if LaunchOptions.arguments.contains("-signedOutForTest") { await api.signOut() }
        if let email = LaunchOptions.signInAs {
            await api.signOut()
            try? await api.signIn(email: email, password: LaunchOptions.devPassword)
        }
        #endif
        if await api.restoreSession() == nil {
            phase = .signedOut
            return
        }
        await loadProfile()
    }

    func loadProfile() async {
        guard let api else { return }
        do {
            profile = try await api.myProfile()
            phase = profile == nil ? .needsProfile : .ready
            if phase == .ready { await afterSignIn() }
        } catch {
            // Offline at launch with a stored session: keep the user in, show errors per screen
            phase = profile == nil ? .needsProfile : .ready
        }
    }

    func signedIn() async {
        await loadProfile()
    }

    func signOut() async {
        await api?.signOut()
        profile = nil
        friends = []
        circles = []
        dictionary = []
        phase = .signedOut
    }

    private func afterSignIn() async {
        if let token = pendingInvite {
            pendingInvite = nil
            await accept(invite: token)
        }
        async let flagsLoaded: Void = refreshFlags()
        async let social: Void = refreshSocial()
        async let words: Void = refreshDictionary()
        async let inbox: Void = refreshUnread()
        _ = await (flagsLoaded, social, words, inbox)
        PushService.shared.register(api: api)
    }

    func refreshFlags() async {
        if let flags = try? await api?.flags() { self.flags = flags }
    }

    func refreshSocial() async {
        guard let api else { return }
        async let f = api.friends()
        async let c = api.circles()
        if let friends = try? await f { self.friends = friends }
        if let circles = try? await c { self.circles = circles }
    }

    func refreshDictionary() async {
        if let rows = try? await api?.dictionary() { dictionary = rows }
    }

    func refreshUnread() async {
        if let threads = try? await api?.inbox() { unreadReplies = threads.reduce(0) { $0 + $1.unread } }
    }

    func refreshProfile() async {
        if let profile = try? await api?.myProfile() { self.profile = profile }
    }

    // MARK: Deep links

    /// `weeknotes://u/{token}`, `https://<web reader>/u/{token}`, `weeknotes://compose`.
    func handle(url: URL) {
        if url.host() == "compose" || url.path() == "/compose" {
            selectedTab = .week
            composerRequested = true
            return
        }
        guard let token = DeepLink.inviteToken(from: url) else { return }
        if phase == .ready {
            Task { await accept(invite: token) }
        } else {
            pendingInvite = token
        }
    }

    func accept(invite token: String) async {
        guard let api else { return }
        do {
            let result = try await api.acceptInvite(token)
            if result.inviterId != profile?.id {
                show("You're connected with \(result.inviterName)", systemImage: "person.2.fill")
            }
            await refreshSocial()
        } catch {
            show(friendlyMessage(error), systemImage: "exclamationmark.triangle.fill")
        }
    }

    func show(_ text: String, systemImage: String = "checkmark.circle.fill") {
        toast = Toast(text: text, systemImage: systemImage)
    }

    // MARK: Vocabulary

    /// Stage 1 biasing list and the formatter's spelling list.
    var vocabulary: [String] {
        Vocabulary.build(
            friends: acceptedFriends.map { Vocabulary.Friend(name: $0.displayName, lastInteraction: $0.since) },
            circles: circles.map(\.name),
            dictionary: dictionary.map(\.entry)
        )
    }

    /// Friends' names are automatic dictionary entries (PRD §8, stage 3), not stored rows.
    var dictionaryEntries: [DictionaryEntry] {
        dictionary.map(\.entry) + acceptedFriends.flatMap { friend -> [DictionaryEntry] in
            let parts = friend.displayName.split(separator: " ").map(String.init)
            return [DictionaryEntry(written: friend.displayName)] + (parts.count > 1 ? parts.map { DictionaryEntry(written: $0) } : [])
        }
    }

    static func resetLocalState() {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        DraftStore.deleteAllFiles()
    }
}

enum DeepLink {
    static func inviteToken(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        // weeknotes://u/TOKEN has host "u"; https://host/u/TOKEN has path /u/TOKEN
        if url.scheme == "weeknotes", url.host() == "u", let token = parts.first { return valid(token) }
        if let index = parts.firstIndex(of: "u"), index + 1 < parts.count { return valid(parts[index + 1]) }
        return nil
    }

    private static func valid(_ token: String) -> String? {
        token.range(of: #"^[A-Za-z0-9_-]{16,64}$"#, options: .regularExpression) == nil ? nil : token
    }
}
