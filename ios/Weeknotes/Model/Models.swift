import Foundation
import WeeknotesCore

// Rows and RPC results from Supabase. Property names are camelCase versions of the
// snake_case columns (the API's decoder converts them).

nonisolated struct MyProfile: Codable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var timezone: String
    var reminderWeekday: Int
    var reminderTime: String          // "18:00:00"
    var remindersEnabled: Bool
    var hasVerifiedPhone: Bool
    var weekStart: LocalDate
    var createdAt: Date

    var reminderComponents: DateComponents {
        let parts = reminderTime.split(separator: ":").compactMap { Int($0) }
        return DateComponents(hour: parts.first ?? 18, minute: parts.count > 1 ? parts[1] : 0)
    }
}

nonisolated struct Friend: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    var status: String                // "pending" | "accepted"
    var requestedByMe: Bool
    var since: Date

    var isAccepted: Bool { status == "accepted" }
    var isIncomingRequest: Bool { status == "pending" && !requestedByMe }
    var isOutgoingRequest: Bool { status == "pending" && requestedByMe }
}

nonisolated struct ContactMatch: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    var status: String?
    var requestedByMe: Bool?
}

nonisolated struct CircleRow: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var ownerId: UUID
    var name: String
    var createdAt: Date
    var circleMembers: [Member]?

    nonisolated struct Member: Codable, Hashable, Sendable {
        var userId: UUID
    }

    var memberIDs: Set<UUID> { Set((circleMembers ?? []).map(\.userId)) }
}

nonisolated struct MemoInfo: Codable, Hashable, Sendable {
    var id: UUID?
    var storagePath: String
    var durationMs: Int
    var waveform: [Float]
    var transcriptClean: String?
    var transcriptRaw: String?

    var transcript: String? { transcriptClean ?? transcriptRaw }
}

nonisolated struct PhotoInfo: Codable, Hashable, Sendable, Identifiable {
    var id: UUID?
    var storagePath: String
    var position: Int
    var width: Int?
    var height: Int?

    var stableID: String { storagePath }
}

/// One card in the feed: a friend's update for this week.
nonisolated struct FeedCard: Codable, Identifiable, Hashable, Sendable {
    var updateId: UUID
    var authorId: UUID
    var authorName: String
    var weekStart: LocalDate
    var isCurrentWeek: Bool
    var prompt: String?
    var bodyText: String?
    var postedAt: Date
    var editedAt: Date?
    var memo: MemoInfo?
    var photos: [PhotoInfo]
    var readAt: Date?
    var listenedMs: Int
    var myReaction: String?

    var id: UUID { updateId }
    var isUnread: Bool { readAt == nil }
}

/// An update with everything the detail view shows. Built from the `updates` table with
/// embedded media (RLS decides whether it comes back at all).
nonisolated struct UpdateRow: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var authorId: UUID
    var weekStart: LocalDate
    var prompt: String?
    var bodyText: String?
    var bodyRawTranscript: String?
    var composedWith: [String]
    var postedAt: Date
    var editedAt: Date?
    var voiceMemos: MemoInfo?
    var updatePhotos: [PhotoInfo]?
    var updateAudiences: [Audience]?
    var profiles: Author?

    nonisolated struct Audience: Codable, Hashable, Sendable { var circleId: UUID }
    nonisolated struct Author: Codable, Hashable, Sendable { var displayName: String }

    var photos: [PhotoInfo] { (updatePhotos ?? []).sorted { $0.position < $1.position } }
    var audienceIDs: [UUID] { (updateAudiences ?? []).map(\.circleId) }
    var authorName: String { profiles?.displayName ?? "" }
}

nonisolated struct ReactionRow: Codable, Hashable, Sendable {
    var userId: UUID
    var emoji: String
    var profiles: UpdateRow.Author?
}

nonisolated struct ThreadSummary: Codable, Identifiable, Hashable, Sendable {
    var threadId: UUID
    var otherId: UUID
    var otherName: String
    var lastBody: String
    var lastAt: Date
    var lastFromMe: Bool
    var unread: Int

    var id: UUID { threadId }
}

nonisolated struct Message: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var threadId: UUID
    var senderId: UUID
    var updateId: UUID?
    var body: String
    var createdAt: Date
}

nonisolated struct ShareLink: Codable, Hashable, Sendable {
    var token: String
    var updateId: UUID
    var circleId: UUID?
    var expiresAt: Date

    var url: URL { AppEnvironment.webReaderURL.appending(path: "u/\(token)") }
}

nonisolated struct InviteResult: Codable, Sendable {
    var inviterId: UUID
    var inviterName: String
    var joinedCircle: Bool
}

nonisolated struct DictionaryRow: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var written: String
    var soundsLike: [String]
    var source: String

    var entry: DictionaryEntry { DictionaryEntry(written: written, soundsLike: soundsLike) }
}

nonisolated struct AppFlags: Codable, Sendable {
    var requirePostToRead: Bool
    var mondayCutoffHour: Int
    var shareLinkDays: Int
    var appStoreUrl: String?
}

/// The optional prompts the composer offers. Small moments, not achievements (PRD §14).
enum Prompts {
    static let all = [
        "Best part of your week?",
        "What made you laugh?",
        "Something small you noticed?",
        "What did you eat that was good?",
        "Who did you see?",
        "What's on your mind?",
        "What are you looking forward to?",
        "Hardest part of the week?",
        "Something you learned?",
        "What would you do again?",
    ]

    /// A stable pick per week, so the suggestion doesn't change every time the composer opens.
    static func suggestions(for week: LocalDate, count: Int = 3) -> [String] {
        let seed = abs(week.iso.hashValue == 0 ? 1 : week.year * 400 + week.month * 31 + week.day)
        return (0..<count).map { all[(seed + $0 * 3) % all.count] }
    }
}
