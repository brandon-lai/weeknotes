import SwiftData
import SwiftUI
import WeeknotesCore

/// This week (PRD §11, screen 2): your own week at the top, then one card per friend who
/// posted, unread first, and "You're caught up" at the end.
struct FeedView: View {
    @Environment(AppModel.self) private var model
    @Query private var entries: [Entry]
    @State private var cards: [FeedCard] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var path = NavigationPath()

    var week: LocalDate { model.currentWeek }
    var mine: Entry? { entries.first { $0.weekStart == week.iso } }
    var unread: [FeedCard] { cards.filter(\.isUnread) }
    var lockedUntilPosted: Bool { model.flags.requirePostToRead && mine?.isSaved != true }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    header
                    MyWeekCard(entry: mine, onWrite: { model.composerRequested = true })
                    if model.isSignedIn {
                        if let error {
                            ErrorBanner(message: error) { Task { await load() } }
                        }
                        if lockedUntilPosted && !cards.isEmpty {
                            EmptyStateView(
                                title: "\(cards.count) \(cards.count == 1 ? "friend has" : "friends have") posted",
                                message: "Write your week to read theirs.",
                                systemImage: "lock.open"
                            )
                            .card()
                        } else {
                            friendCards
                        }
                    } else if model.accountsAvailable {
                        ConnectCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .paperBackground()
            .refreshable { await load() }
            .navigationDestination(for: UUID.self) { id in
                UpdateDetailView(updateID: id, card: cards.first { $0.updateId == id })
            }
            .navigationDestination(for: String.self) { iso in
                if let entry = entries.first(where: { $0.weekStart == iso }) { EntryDetailView(entry: entry) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .task(id: model.isSignedIn) { await load() }
            .onChange(of: model.composerRequested) { _, open in
                if !open { Task { await load() } }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("This week")
                .font(Theme.titleFont)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(Week.label(for: week))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var friendCards: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity).padding(40)
        } else if cards.isEmpty {
            EmptyStateView(
                title: model.acceptedFriends.isEmpty ? "Bring your friends" : "Nobody's posted yet",
                message: model.acceptedFriends.isEmpty
                    ? "Weeknotes is better with the people you'd text anyway. Share a week, then send its link to your group chat."
                    : "Friends' weeks will show up here.",
                systemImage: model.acceptedFriends.isEmpty ? "person.2.wave.2" : "cup.and.saucer",
                actionTitle: model.acceptedFriends.isEmpty ? "Find friends" : nil,
                action: { model.selectedTab = .people }
            )
            .card()
        } else {
            if !unread.isEmpty {
                Text(unread.count == 1 ? "1 new update" : "\(unread.count) new updates")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .textCase(.uppercase)
                    .padding(.top, 8)
            }
            ForEach(cards) { card in
                NavigationLink(value: card.updateId) {
                    UpdateCardView(card: card)
                }
                .buttonStyle(.plain)
            }
            if unread.isEmpty {
                CaughtUpView(count: cards.count)
            }
        }
    }

    func load() async {
        guard model.isSignedIn, let api = model.api else {
            cards = []
            loaded = true
            return
        }
        do {
            let feed = try await api.feed()
            withAnimation {
                cards = feed
                error = nil
            }
        } catch {
            self.error = friendlyMessage(error)
        }
        loaded = true
        await model.refreshUnread()
    }
}

/// Signed out: friends are one tap away, not a requirement.
private struct ConnectCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Share your weeks with friends", systemImage: "person.2.wave.2")
                .font(Theme.headingFont)
                .foregroundStyle(Theme.ink)
            Text("Create a free account to connect with friends, share weeks with the circles you choose, and read theirs. Your weeks stay private unless you share them.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
            Button(model.account == .needsProfile ? "Finish setting up" : "Connect with friends") { model.accountFlowRequested = true }
                .glassProminentButton()
                .padding(.top, 2)
                .accessibilityIdentifier("connectCard")
        }
        .card()
    }
}

struct CaughtUpView: View {
    let count: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal").font(.title).foregroundStyle(Theme.accent)
            Text("You're caught up").font(Theme.headingFont).foregroundStyle(Theme.ink)
            Text(count == 1 ? "You've read the one update this week." : "You've read all \(count) updates this week.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("caughtUp")
    }
}

/// The top card: write your week, continue the draft, or see what you wrote.
private struct MyWeekCard: View {
    @Environment(AppModel.self) private var model
    let entry: Entry?
    let onWrite: () -> Void

    var sharedWith: String {
        let names = model.circles.filter { (entry?.circleIDs ?? []).contains($0.id) }.map(\.name)
        if !model.isSignedIn { return "Just for you" }
        return names.isEmpty ? "Only you" : "Shared with \(names.formatted(.list(type: .and)))"
    }

    var body: some View {
        if let entry, entry.isSaved {
            NavigationLink(value: entry.weekStart) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("You wrote your week \((entry.savedAt ?? Date()).friendlyPosted)", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    if let preview = entry.preview {
                        Text(preview).font(Theme.body(16)).foregroundStyle(Theme.ink).lineLimit(2)
                    }
                    Text(sharedWith).font(.caption).foregroundStyle(Theme.secondaryInk)
                }
                .card()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("myUpdateCard")
        } else {
            Button(action: onWrite) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry?.hasContent == true ? "Continue your week" : "Your week is ready to write")
                        .font(Theme.headingFont)
                        .foregroundStyle(Theme.ink)
                    if let entry, entry.hasContent {
                        Text(entry.preview ?? "Voice memo recorded")
                            .font(Theme.body(15)).foregroundStyle(Theme.secondaryInk).lineLimit(2)
                    } else {
                        Text(Prompts.suggestions(for: model.currentWeek, count: 1).first ?? "")
                            .font(Theme.body(15)).italic().foregroundStyle(Theme.secondaryInk)
                    }
                    HStack(spacing: 18) {
                        Label("Write", systemImage: "square.and.pencil")
                        Label("Dictate", systemImage: "mic")
                        Label("Memo", systemImage: "waveform")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
                }
                .card()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("writeWeek")
        }
    }
}

/// A friend's update in the feed: preview text, or a player and the first lines of the transcript.
struct UpdateCardView: View {
    let card: FeedCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AvatarView(name: card.authorName, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.authorName).font(.headline).foregroundStyle(Theme.ink)
                    Text(card.isCurrentWeek ? card.postedAt.friendlyPosted : "Last week · \(card.postedAt.friendlyPosted)")
                        .font(.caption).foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                if card.isUnread {
                    Circle().fill(Theme.unread).frame(width: 9, height: 9).accessibilityLabel("Unread")
                }
                if let reaction = card.myReaction {
                    Text(reaction).accessibilityLabel("You reacted \(reaction)")
                }
            }
            if let prompt = card.prompt {
                Text(prompt).font(Theme.body(15)).italic().foregroundStyle(Theme.secondaryInk)
            }
            if let body = card.bodyText, !body.isEmpty {
                Text(body).font(Theme.bodyFont).foregroundStyle(Theme.ink).lineLimit(5).multilineTextAlignment(.leading)
            }
            if let memo = card.memo {
                MemoPlayerView(updateID: card.updateId, memo: memo, authorName: card.authorName)
                if let transcript = memo.transcript, card.bodyText?.isEmpty ?? true {
                    Text(transcript).font(Theme.body(15)).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(3)
                }
            }
            if !card.photos.isEmpty {
                PhotoStrip(photos: card.photos)
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-\(card.authorName)")
    }
}

struct PhotoStrip: View {
    let photos: [PhotoInfo]
    var height: CGFloat = 110

    var body: some View {
        HStack(spacing: 6) {
            ForEach(photos, id: \.storagePath) { photo in
                StoredPhoto(photo: photo)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(.rect(cornerRadius: 12))
            }
        }
    }
}
