import Foundation
import Observation
import SwiftData
import SwiftUI
import WeeknotesCore

/// App-wide state. The app works with no account: weeks are written and kept on the phone. An
/// account (`account == .signedIn`) adds friends, circles, sharing, replies and a private backup.
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        /// First launch: the welcome and the optional weekly reminder.
        case welcome
        case ready
    }

    enum Account: Equatable {
        case signedOut
        /// Signed in, but hasn't chosen a name yet.
        case needsProfile
        case signedIn
    }

    enum Tab: Hashable {
        case week, archive, inbox, people
    }

    let api: API?
    let context: ModelContext
    var phase: Phase = .launching
    var account: Account = .signedOut
    var profile: MyProfile?
    var flags = AppFlags(requirePostToRead: AppConfig.requirePostToReadDefault, mondayCutoffHour: AppConfig.mondayCutoffHour, shareLinkDays: AppConfig.shareLinkLifetimeDays, appStoreUrl: nil)
    var friends: [Friend] = []
    var circles: [CircleRow] = []
    var unreadReplies = 0

    var selectedTab: Tab = .week
    var composerRequested = false
    /// Opens the account sheet (sign in, name, backup, find friends).
    var accountFlowRequested = false
    /// An invite token from a share link, accepted once there's an account.
    var pendingInvite: String?
    var toast: Toast?

    let learning = LearningStore()
    let engines = EngineSettings()
    let words = DictionaryStore()

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let text: String
        var systemImage: String = "checkmark.circle.fill"
    }

    private static let welcomedKey = "hasSeenWelcome"

    init(context: ModelContext) {
        self.context = context
        api = API()
        if LaunchOptions.arguments.contains("-resetState") { Self.resetPreferences() }
    }

    var isSignedIn: Bool { account == .signedIn }
    /// Accounts need a backend; a build without one is a private journal only.
    var accountsAvailable: Bool { api != nil }
    var acceptedFriends: [Friend] { friends.filter(\.isAccepted) }
    var incomingRequests: [Friend] { friends.filter(\.isIncomingRequest) }

    /// Your week, in this phone's time zone (weeks run Monday to Sunday, and Monday morning
    /// still counts toward the week that just ended).
    var currentWeek: LocalDate {
        Week.start(for: Date(), in: .current, mondayCutoffHour: flags.mondayCutoffHour)
    }

    // MARK: Launch

    func start() async {
        #if DEBUG
        if LaunchOptions.arguments.contains("-signedOutForTest") { await api?.signOut() }
        if let email = LaunchOptions.signInAs, let api {
            await api.signOut()
            try? await api.signIn(email: email, password: LaunchOptions.devPassword)
            UserDefaults.standard.set(true, forKey: Self.welcomedKey)
        }
        if LaunchOptions.arguments.contains("-skipWelcome") { UserDefaults.standard.set(true, forKey: Self.welcomedKey) }
        #endif
        phase = UserDefaults.standard.bool(forKey: Self.welcomedKey) ? .ready : .welcome
        await LocalReminders.reschedule(context: context)
        if let api, await api.restoreSession() != nil {
            await loadProfile()
        }
    }

    func finishWelcome(signIn: Bool = false) {
        UserDefaults.standard.set(true, forKey: Self.welcomedKey)
        phase = .ready
        if signIn { accountFlowRequested = true }
    }

    // MARK: Account

    func loadProfile() async {
        guard let api, api.accountID != nil else {
            account = .signedOut
            return
        }
        do {
            profile = try await api.myProfile()
            account = profile == nil ? .needsProfile : .signedIn
        } catch {
            // Offline with a stored session: treat it as signed in and let screens show errors
            account = profile == nil ? .needsProfile : .signedIn
        }
        if account == .signedIn {
            await afterSignIn()
        } else if account == .needsProfile {
            accountFlowRequested = true
        }
    }

    private func afterSignIn() async {
        guard let api else { return }
        if let token = pendingInvite {
            pendingInvite = nil
            await accept(invite: token)
        }
        // The account follows the phone's time zone, which decides which week a post belongs to
        if let profile, profile.timezone != TimeZone.current.identifier {
            try? await api.updateProfile(.init(timezone: TimeZone.current.identifier))
        }
        async let flagsLoaded: Void = refreshFlags()
        async let social: Void = refreshSocial()
        async let inbox: Void = refreshUnread()
        _ = await (flagsLoaded, social, inbox)
        await words.sync(api: api)
        await syncWeeks()
    }

    /// Backs up weeks saved on this phone and brings down weeks written elsewhere.
    func syncWeeks() async {
        guard let api, isSignedIn else { return }
        try? await EntrySync.downloadOwn(api: api, context: context)
        await EntrySync.uploadPending(api: api, context: context)
        await LocalReminders.reschedule(context: context)
    }

    func signOut() async {
        await api?.signOut()
        profile = nil
        account = .signedOut
        friends = []
        circles = []
        unreadReplies = 0
        selectedTab = .week
    }

    func refreshFlags() async {
        if let flags = try? await api?.flags() { self.flags = flags }
    }

    func refreshSocial() async {
        guard let api, isSignedIn else { return }
        async let f = api.friends()
        async let c = api.circles()
        if let friends = try? await f { self.friends = friends }
        if let circles = try? await c { self.circles = circles }
    }

    func refreshUnread() async {
        guard isSignedIn else { return }
        if let threads = try? await api?.inbox() { unreadReplies = threads.reduce(0) { $0 + $1.unread } }
    }

    func refreshProfile() async {
        if let profile = try? await api?.myProfile() { self.profile = profile }
    }

    // MARK: Saving a week

    /// After a week is saved: plan reminders again (that week no longer needs one) and, with an
    /// account, back it up and share it. Returns a line for the toast.
    func didSave(_ entry: Entry) async -> String {
        await LocalReminders.reschedule(context: context)
        guard let api, isSignedIn else { return "Saved" }
        do {
            try await EntrySync.upload(entry, api: api, context: context)
            let names = circles.filter { (entry.circleIDs ?? []).contains($0.id) }.map(\.name)
            return names.isEmpty ? "Saved" : "Shared with \(names.formatted(.list(type: .and)))"
        } catch {
            entry.needsSync = true
            try? context.save()
            return "Saved. It'll be shared when you're back online."
        }
    }

    func delete(_ entry: Entry) async {
        if let api, isSignedIn { await EntrySync.deleteRemote(entry, api: api) }
        EntryStore.delete(entry, in: context)
        await LocalReminders.reschedule(context: context)
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
        if isSignedIn {
            Task { await accept(invite: token) }
        } else {
            pendingInvite = token
            accountFlowRequested = accountsAvailable
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
            dictionary: words.entries
        )
    }

    /// Friends' names are automatic dictionary entries (PRD §8, stage 3), not stored words.
    var dictionaryEntries: [DictionaryEntry] {
        words.entries + acceptedFriends.flatMap { friend -> [DictionaryEntry] in
            let parts = friend.displayName.split(separator: " ").map(String.init)
            return [DictionaryEntry(written: friend.displayName)] + (parts.count > 1 ? parts.map { DictionaryEntry(written: $0) } : [])
        }
    }

    // MARK: Erasing

    /// Settings → Erase this iPhone's weeks: every entry, file, word and scheduled reminder.
    func eraseLocalData() {
        for entry in (try? context.fetch(FetchDescriptor<Entry>())) ?? [] { context.delete(entry) }
        try? context.save()
        EntryStore.deleteAllFiles()
        words.eraseLocal()
        LocalReminders.cancelAll()
    }

    static func resetPreferences() {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
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
