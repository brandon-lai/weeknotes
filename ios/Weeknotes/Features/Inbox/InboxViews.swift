import SwiftUI
import WeeknotesCore

/// Replies inbox and one-to-one threads (PRD §11, screen 9). Replies are private and text only.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var threads: [ThreadSummary] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    ErrorBanner(message: error) { Task { await load() } }.listRowBackground(Color.clear)
                }
                if loaded && threads.isEmpty {
                    EmptyStateView(
                        title: "No replies yet",
                        message: "When a friend replies to your update, or you reply to theirs, it lands here. Only the two of you see it.",
                        systemImage: "bubble.left.and.bubble.right"
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(threads) { thread in
                    NavigationLink(value: thread) {
                        HStack(spacing: 12) {
                            AvatarView(name: thread.otherName, size: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(thread.otherName).font(.headline)
                                    Spacer()
                                    Text(thread.lastAt.friendlyPosted).font(.caption).foregroundStyle(Theme.secondaryInk)
                                }
                                Text((thread.lastFromMe ? "You: " : "") + thread.lastBody)
                                    .font(.subheadline)
                                    .foregroundStyle(thread.unread > 0 ? Theme.ink : Theme.secondaryInk)
                                    .lineLimit(2)
                            }
                            if thread.unread > 0 {
                                Circle().fill(Theme.unread).frame(width: 9, height: 9).accessibilityLabel("\(thread.unread) unread")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Theme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Replies")
            .navigationDestination(for: ThreadSummary.self) { thread in
                ThreadView(threadID: thread.threadId, otherName: thread.otherName)
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            threads = try await api.inbox()
            model.unreadReplies = threads.reduce(0) { $0 + $1.unread }
            error = nil
        } catch {
            self.error = friendlyMessage(error)
        }
        loaded = true
    }
}

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let threadID: UUID
    let otherName: String
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var error: String?
    @State private var sending = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        MessageBubble(message: message, isMine: message.senderId == model.profile?.id)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: messages.count) {
                if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .paperBackground()
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(12)
                    .background(Theme.card, in: .rect(cornerRadius: 20))
                    .accessibilityIdentifier("threadField")
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.headline).frame(width: 40, height: 40)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(otherName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        messages = (try? await api.messages(in: threadID)) ?? []
        await api.markThreadRead(threadID)
        await model.refreshUnread()
    }

    private func send() {
        guard let api = model.api else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        Task {
            defer { sending = false }
            do {
                try await api.send(text, in: threadID, about: nil)
                draft = ""
                await load()
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: Message
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 48) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                if message.updateId != nil {
                    Label("Replied to an update", systemImage: "arrowshape.turn.up.left")
                        .font(.caption2)
                        .foregroundStyle(isMine ? .white.opacity(0.8) : Theme.secondaryInk)
                }
                Text(message.body)
                    .font(.body)
                    .foregroundStyle(isMine ? .white : Theme.ink)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isMine ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.card), in: .rect(cornerRadius: 18))
            if !isMine { Spacer(minLength: 48) }
        }
    }
}
