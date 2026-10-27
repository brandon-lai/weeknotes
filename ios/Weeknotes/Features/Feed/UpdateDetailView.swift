import SwiftUI
import WeeknotesCore

/// One update in full (PRD §11, screen 3): text, photos, memo player and transcript,
/// reactions and a private reply. The author also gets share, edit and delete.
struct UpdateDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let updateID: UUID
    var card: FeedCard?
    var ownUpdate: UpdateRow?

    @State private var update: UpdateRow?
    @State private var reaction: String?
    @State private var reactions: [ReactionRow] = []
    @State private var showOriginal = false
    @State private var reply = ""
    @State private var sending = false
    @State private var error: String?
    @State private var shareLink: ShareLinkInfo?
    @State private var confirmDelete = false
    @State private var editing = false
    @State private var viewerPhoto: PhotoInfo?

    static let reactionChoices = ["❤️", "😂", "🥹", "🔥", "👏", "🫶"]

    var isMine: Bool { (update?.authorId ?? card?.authorId) == model.profile?.id }
    var authorName: String { update?.authorName.nilIfEmpty ?? card?.authorName ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let update {
                    content(update)
                } else if let error {
                    ErrorBanner(message: error) { Task { await load() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(60)
                }
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        .paperBackground()
        .navigationTitle(isMine ? "Your week" : authorName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if isMine { ownerMenu } }
        .task { await load() }
        .confirmationDialog("Delete this update?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete update", role: .destructive) { delete() }
        } message: {
            Text("It disappears from your archive and your friends' feeds, and its memo and photos are deleted.")
        }
        .fullScreenCover(isPresented: $editing, onDismiss: { Task { await load() } }) {
            if let update { ComposerView(editing: update) }
        }
        .fullScreenCover(item: $viewerPhoto) { photo in
            PhotoViewer(photos: update?.photos ?? [], start: photo)
        }
    }

    @ViewBuilder
    private func content(_ update: UpdateRow) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: authorName, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(authorName).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("Week of \(Week.label(for: update.weekStart)) · \(update.postedAt.friendlyPosted)\(update.editedAt == nil ? "" : " · edited")")
                    .font(.caption).foregroundStyle(Theme.secondaryInk)
            }
        }

        if let prompt = update.prompt {
            Text(prompt).font(Theme.body(17)).italic().foregroundStyle(Theme.secondaryInk)
        }

        if let body = update.bodyText, !body.isEmpty {
            Text(showOriginal ? (update.bodyRawTranscript ?? body) : body)
                .font(Theme.body(19))
                .lineSpacing(4)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .accessibilityIdentifier("updateBody")
            if let raw = update.bodyRawTranscript, !raw.isEmpty {
                // The words as dictated, before any cleanup: always one tap away
                Toggle(isOn: $showOriginal.animation()) {
                    Label("Show original dictation", systemImage: "text.badge.checkmark")
                        .font(.footnote)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }

        if let memo = update.voiceMemos {
            VStack(alignment: .leading, spacing: 12) {
                MemoPlayerView(updateID: update.id, memo: memo, authorName: authorName)
                if let transcript = showOriginal ? (memo.transcriptRaw ?? memo.transcript) : memo.transcript {
                    TranscriptView(text: transcript)
                }
            }
            .card()
        }

        if !update.photos.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(update.photos, id: \.storagePath) { photo in
                    Button { viewerPhoto = photo } label: {
                        StoredPhoto(photo: photo)
                            .frame(height: update.photos.count == 1 ? 260 : 170)
                            .clipShape(.rect(cornerRadius: 14))
                    }
                    .gridCellColumns(update.photos.count == 1 ? 2 : 1)
                }
            }
        }

        if isMine {
            ownerFooter(update)
        } else {
            reactionsBar(update)
            replyBox
        }
    }

    private func reactionsBar(_ update: UpdateRow) -> some View {
        // Fixed 44 pt circles: six always fit, even on the narrowest iPhone
        HStack(spacing: 10) {
            ForEach(Self.reactionChoices, id: \.self) { emoji in
                Button {
                    let next = reaction == emoji ? nil : emoji
                    reaction = next
                    Task { try? await model.api?.react(to: update.id, with: next) }
                } label: {
                    Text(emoji)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .glassSurface(.circle, interactive: true, tint: reaction == emoji ? Theme.accent.opacity(0.35) : nil)
                }
                .buttonStyle(.plain)
                .opacity(reaction == nil || reaction == emoji ? 1 : 0.45)
                .accessibilityLabel(reaction == emoji ? "Remove \(emoji) reaction" : "React \(emoji)")
            }
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: reaction)
    }

    private var replyBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reply privately to \(authorName.split(separator: " ").first.map(String.init) ?? authorName)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryInk)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Say something nice", text: $reply, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(12)
                    .background(Theme.card, in: .rect(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline))
                    .accessibilityIdentifier("replyField")
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up").font(.headline).frame(width: 40, height: 40)
                }
                .glassProminentButton()
                .buttonBorderShape(.circle)
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .accessibilityLabel("Send reply")
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(.top, 6)
    }

    private func ownerFooter(_ update: UpdateRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            let names = model.circles.filter { update.audienceIDs.contains($0.id) }.map(\.name)
            Label(names.isEmpty ? "Only you can see this (archive)" : "Shared with \(names.formatted(.list(type: .and)))", systemImage: names.isEmpty ? "lock" : "person.3")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
            if !reactions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reactions").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondaryInk)
                    ForEach(reactions, id: \.userId) { row in
                        Text("\(row.emoji)  \(row.profiles?.displayName ?? "A friend")").font(.subheadline)
                    }
                }
            }
            ShareLinkButton(update: update)
        }
        .card()
    }

    @ToolbarContentBuilder
    private var ownerMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if update?.weekStart == model.currentWeek {
                    Button("Edit", systemImage: "pencil") { editing = true }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let row = try await api.update(updateID)
            guard let row else {
                error = "This update isn't available anymore."
                return
            }
            update = row
            reaction = card?.myReaction
            if row.authorId == model.profile?.id {
                reactions = (try? await api.reactions(for: row.id)) ?? []
            } else if card?.readAt == nil {
                await api.markRead(row.id)
            }
        } catch {
            self.error = friendlyMessage(error)
        }
    }

    private func send() {
        guard let update, let api = model.api else { return }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        Task {
            defer { sending = false }
            do {
                let thread = try await api.openThread(with: update.authorId)
                try await api.send(text, in: thread, about: update.id)
                reply = ""
                error = nil
                model.show("Sent to \(authorName)", systemImage: "paperplane.fill")
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }

    private func delete() {
        guard let update, let api = model.api else { return }
        Task {
            do {
                try await api.deleteUpdate(update)
                model.show("Update deleted", systemImage: "trash")
                dismiss()
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }
}

/// Makes (or reuses) a share link for one of my updates and opens the share sheet. The link
/// works without an account, and people who join from it are added to the chosen circle.
struct ShareLinkButton: View {
    @Environment(AppModel.self) private var model
    let update: UpdateRow
    @State private var link: ShareLinkInfo?
    @State private var circle: UUID?
    @State private var error: String?
    @State private var loading = false

    var audienceCircles: [CircleRow] { model.circles.filter { update.audienceIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if audienceCircles.count > 1 {
                Picker("People who join from the link go to", selection: $circle) {
                    ForEach(audienceCircles) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                .font(.subheadline)
            }
            if let link {
                ShareLink(item: link.url, subject: Text("My week"), message: Text("Here's my week. Read or listen, no app needed.")) {
                    Label("Share link", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .accessibilityIdentifier("shareLink")
                Text("Anyone with the link can read this update until \(link.expiresAt.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.caption).foregroundStyle(Theme.secondaryInk)
            } else {
                Button {
                    makeLink()
                } label: {
                    Label(loading ? "Making link…" : "Get a share link", systemImage: "link").frame(maxWidth: .infinity)
                }
                .glassButton()
                .disabled(loading)
                .accessibilityIdentifier("makeShareLink")
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .onAppear { circle = circle ?? audienceCircles.first?.id }
        .onChange(of: circle) { link = nil }
    }

    private func makeLink() {
        loading = true
        Task {
            defer { loading = false }
            do {
                link = try await model.api?.shareLink(for: update.id, circle: circle ?? audienceCircles.first?.id)
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }
}

struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let photos: [PhotoInfo]
    @State var start: PhotoInfo

    var body: some View {
        NavigationStack {
            TabView(selection: $start) {
                ForEach(photos, id: \.self) { photo in
                    StoredPhoto(photo: photo, contentMode: .fit).tag(photo)
                }
            }
            .tabViewStyle(.page)
            .background(.black)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
