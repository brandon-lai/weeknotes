import SwiftUI
import WeeknotesCore

/// One of your own weeks, from this iPhone: the writing, memo and photos, who it's shared with,
/// reactions from friends, a share link, edit and delete.
struct EntryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: Entry
    @State private var showOriginal = false
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var reactions: [ReactionRow] = []
    @State private var viewerIndex: Int?

    var circleNames: [String] { model.circles.filter { (entry.circleIDs ?? []).contains($0.id) }.map(\.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Week of \(Week.label(for: entry.week))").font(Theme.headingFont).foregroundStyle(Theme.ink)
                    if let saved = entry.savedAt {
                        Text("Written \(saved.friendlyPosted)").font(.caption).foregroundStyle(Theme.secondaryInk)
                    }
                }
                if let prompt = entry.prompt {
                    Text(prompt).font(Theme.body(17)).italic().foregroundStyle(Theme.secondaryInk)
                }
                if !entry.body.isEmpty {
                    Text(showOriginal ? (entry.rawTranscript ?? entry.body) : entry.body)
                        .font(Theme.body(19))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("updateBody")
                    if let raw = entry.rawTranscript, !raw.isEmpty {
                        Toggle(isOn: $showOriginal.animation()) {
                            Label("Show original dictation", systemImage: "text.badge.checkmark").font(.footnote)
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                if let memo = entry.memoInfo {
                    VStack(alignment: .leading, spacing: 12) {
                        MemoPlayerView(updateID: entry.updateID, memo: memo, authorName: "Your", localURL: entry.memoFileURL)
                        if let transcript = showOriginal ? (memo.transcriptRaw ?? memo.transcript) : memo.transcript {
                            TranscriptView(text: transcript)
                        }
                    }
                    .card()
                }
                if !entry.photoItems.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(Array(entry.photoItems.enumerated()), id: \.element) { index, item in
                            Button { viewerIndex = index } label: {
                                EntryPhoto(entry: entry, item: item)
                                    .frame(height: entry.photoItems.count == 1 ? 260 : 170)
                                    .clipShape(.rect(cornerRadius: 14))
                            }
                            .gridCellColumns(entry.photoItems.count == 1 ? 2 : 1)
                        }
                    }
                }
                sharingCard
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        .paperBackground()
        .navigationTitle("Your week")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit", systemImage: "pencil") { editing = true }
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .task(id: entry.syncedAt) {
            if model.isSignedIn, entry.ownerID != nil {
                reactions = (try? await model.api?.reactions(for: entry.updateID)) ?? []
            }
        }
        .confirmationDialog("Delete this week?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete week", role: .destructive) {
                Task {
                    await model.delete(entry)
                    model.show("Week deleted", systemImage: "trash")
                    dismiss()
                }
            }
        } message: {
            Text(entry.ownerID == nil
                 ? "It's deleted from this iPhone, with its memo and photos."
                 : "It's deleted from this iPhone and your account, and from friends' feeds if you shared it.")
        }
        .fullScreenCover(isPresented: $editing) {
            ComposerView(editingWeek: entry.week)
        }
        .fullScreenCover(item: Binding(get: { viewerIndex.map { PhotoIndex(value: $0) } }, set: { viewerIndex = $0?.value })) { start in
            EntryPhotoViewer(entry: entry, start: start.value)
        }
    }

    @ViewBuilder
    private var sharingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.isSignedIn {
                Label("Just for you, on this iPhone", systemImage: "lock").font(.subheadline).foregroundStyle(Theme.secondaryInk)
                if model.accountsAvailable {
                    Button("Share your weeks with friends") { model.accountFlowRequested = true }
                        .font(.subheadline.weight(.semibold))
                }
            } else {
                Label(circleNames.isEmpty ? "Only you (backed up to your account)" : "Shared with \(circleNames.formatted(.list(type: .and)))",
                      systemImage: circleNames.isEmpty ? "lock" : "person.3")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .accessibilityIdentifier("sharingSummary")
                if entry.needsSync || entry.ownerID == nil {
                    Label("Waiting to upload", systemImage: "icloud.slash").font(.caption).foregroundStyle(Theme.secondaryInk)
                }
                if !reactions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Reactions").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondaryInk)
                        ForEach(reactions, id: \.userId) { row in
                            Text("\(row.emoji)  \(row.profiles?.displayName ?? "A friend")").font(.subheadline)
                        }
                    }
                }
                if entry.ownerID != nil && !(entry.circleIDs ?? []).isEmpty {
                    ShareLinkButton(updateID: entry.updateID, audienceIDs: entry.circleIDs ?? [])
                } else if entry.ownerID != nil {
                    Button("Share with circles") { editing = true }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .card()
    }
}

private struct PhotoIndex: Identifiable {
    let value: Int
    var id: Int { value }
}

private struct EntryPhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let entry: Entry
    @State var start: Int

    var body: some View {
        NavigationStack {
            TabView(selection: $start) {
                ForEach(Array(entry.photoItems.enumerated()), id: \.offset) { index, item in
                    EntryPhoto(entry: entry, item: item, contentMode: .fit).tag(index)
                }
            }
            .tabViewStyle(.page)
            .background(.black)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
