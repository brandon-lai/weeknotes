import SwiftData
import SwiftUI
import WeeknotesCore

/// Your past weeks, newest first (PRD §11, screen 8), from this iPhone. Works offline and
/// without an account; with one, weeks from your other devices come down too.
struct ArchiveView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Entry> { $0.savedAt != nil }, sort: \Entry.weekStart, order: .reverse)
    private var entries: [Entry]

    var byYear: [(year: Int, entries: [Entry])] {
        Dictionary(grouping: entries, by: { $0.week.year })
            .map { ($0.key, $0.value) }
            .sorted { $0.year > $1.year }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if entries.isEmpty {
                        EmptyStateView(
                            title: "Your weeks will live here",
                            message: "Every week you write saves here, even ones you never share.",
                            systemImage: "books.vertical",
                            actionTitle: "Write this week",
                            action: {
                                model.selectedTab = .week
                                model.composerRequested = true
                            }
                        )
                        .card()
                    } else {
                        Text("\(entries.count) \(entries.count == 1 ? "week" : "weeks") written")
                            .font(.subheadline).foregroundStyle(Theme.secondaryInk)
                    }
                    ForEach(byYear, id: \.year) { group in
                        Text(String(group.year)).font(Theme.headingFont).foregroundStyle(Theme.ink).padding(.top, 8)
                        ForEach(group.entries) { entry in
                            NavigationLink(value: entry.weekStart) {
                                ArchiveRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .paperBackground()
            .navigationTitle("Archive")
            .navigationDestination(for: String.self) { week in
                if let entry = entries.first(where: { $0.weekStart == week }) {
                    EntryDetailView(entry: entry)
                }
            }
            .refreshable { await model.syncWeeks() }
        }
    }
}

private struct ArchiveRow: View {
    @Environment(AppModel.self) private var model
    let entry: Entry

    var shared: Bool { !(entry.circleIDs ?? []).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Week.label(for: entry.week)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer()
                if entry.hasMemo { Image(systemName: "waveform").foregroundStyle(Theme.accent).accessibilityLabel("Voice memo") }
                if !entry.photoItems.isEmpty {
                    Label("\(entry.photoItems.count)", systemImage: "photo").font(.caption).foregroundStyle(Theme.secondaryInk)
                }
                Image(systemName: shared ? "person.2" : "lock")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
                    .accessibilityLabel(shared ? "Shared" : "Private")
            }
            if let prompt = entry.prompt {
                Text(prompt).font(Theme.body(14)).italic().foregroundStyle(Theme.secondaryInk)
            }
            Text(entry.preview ?? "Voice memo")
                .font(Theme.body(16))
                .foregroundStyle(Theme.ink)
                .lineLimit(3)
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("archive-\(entry.weekStart)")
    }
}
