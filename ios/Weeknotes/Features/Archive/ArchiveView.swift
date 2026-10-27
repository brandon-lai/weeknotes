import SwiftUI
import WeeknotesCore

/// My past weeks, newest first (PRD §11, screen 8). Useful even when nobody reads.
struct ArchiveView: View {
    @Environment(AppModel.self) private var model
    @State private var updates: [UpdateRow] = []
    @State private var loaded = false
    @State private var error: String?

    var byYear: [(year: Int, updates: [UpdateRow])] {
        Dictionary(grouping: updates, by: \.weekStart.year)
            .map { ($0.key, $0.value) }
            .sorted { $0.year > $1.year }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let error {
                        ErrorBanner(message: error) { Task { await load() } }
                    }
                    if loaded && updates.isEmpty {
                        EmptyStateView(
                            title: "Your weeks will live here",
                            message: "Every update you write saves here, even ones you share with no one.",
                            systemImage: "books.vertical",
                            actionTitle: "Write this week",
                            action: {
                                model.selectedTab = .week
                                model.composerRequested = true
                            }
                        )
                        .card()
                    }
                    if !updates.isEmpty {
                        Text("\(updates.count) \(updates.count == 1 ? "week" : "weeks") written")
                            .font(.subheadline).foregroundStyle(Theme.secondaryInk)
                    }
                    ForEach(byYear, id: \.year) { group in
                        Text(String(group.year)).font(Theme.headingFont).foregroundStyle(Theme.ink).padding(.top, 8)
                        ForEach(group.updates) { update in
                            NavigationLink(value: update.id) {
                                ArchiveRow(update: update)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .paperBackground()
            .navigationTitle("Archive")
            .navigationDestination(for: UUID.self) { id in
                UpdateDetailView(updateID: id, ownUpdate: updates.first { $0.id == id })
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            updates = try await api.myUpdates()
            error = nil
        } catch {
            self.error = friendlyMessage(error)
        }
        loaded = true
    }
}

private struct ArchiveRow: View {
    @Environment(AppModel.self) private var model
    let update: UpdateRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Week.label(for: update.weekStart)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer()
                if update.voiceMemos != nil { Image(systemName: "waveform").foregroundStyle(Theme.accent) }
                if !update.photos.isEmpty {
                    Label("\(update.photos.count)", systemImage: "photo").font(.caption).foregroundStyle(Theme.secondaryInk)
                }
                if update.audienceIDs.isEmpty {
                    Image(systemName: "lock").font(.caption).foregroundStyle(Theme.secondaryInk).accessibilityLabel("Private")
                }
            }
            if let prompt = update.prompt {
                Text(prompt).font(Theme.body(14)).italic().foregroundStyle(Theme.secondaryInk)
            }
            Text(update.bodyText ?? update.voiceMemos?.transcript ?? "Voice memo")
                .font(Theme.body(16))
                .foregroundStyle(Theme.ink)
                .lineLimit(3)
        }
        .card()
    }
}
