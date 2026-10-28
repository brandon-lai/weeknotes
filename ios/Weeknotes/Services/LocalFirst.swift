import Foundation
import UIKit
import SwiftData
import UserNotifications
import WeeknotesCore

/// Backs up saved weeks to the account and brings down weeks written elsewhere. The phone is
/// the source of truth for your own weeks; the server holds a private copy, plus the audience
/// for anything shared.
enum EntrySync {
    /// Uploads one saved entry: files first, then the row with its week and circles.
    /// Entries that belong to a different account (signed in as someone else) are left alone.
    static func upload(_ entry: Entry, api: API, context: ModelContext) async throws {
        guard entry.isSaved, let me = api.accountID else { return }
        if let owner = entry.ownerID, owner != me { return }

        if entry.memoRemotePath == nil, let file = entry.memoFileURL, FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            entry.memoRemotePath = try await api.uploadMemo(updateID: entry.updateID, fileURL: file)
            try? context.save()
        }
        var photos: [API.PublishRequest.Photo] = []
        for (index, item) in entry.photoItems.enumerated() {
            if item.hasPrefix("remote:") {
                photos.append(.init(storagePath: String(item.dropFirst(7)), position: index, width: nil, height: nil))
                continue
            }
            let url = entry.folder.appending(path: item)
            let data = try Data(contentsOf: url)
            let size = UIImage(data: data)?.size
            let path = try await api.uploadPhoto(updateID: entry.updateID, data: data, index: index)
            // The local file stays (the archive works offline); the item now points at both
            entry.photoItems[index] = "remote:\(path)"
            try? FileManager.default.moveItem(at: url, to: entry.folder.appending(path: Self.cacheName(for: path)))
            try? context.save()
            photos.append(.init(storagePath: path, position: index, width: size.map { Int($0.width) }, height: size.map { Int($0.height) }))
        }
        let memo = entry.memoRemotePath.map {
            API.PublishRequest.Memo(storagePath: $0, durationMs: entry.memoDurationMs, waveform: entry.memoWaveform,
                                    transcriptRaw: entry.memoTranscriptRaw, transcriptClean: entry.memoTranscriptClean, engineId: entry.memoEngineID)
        }
        let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
        try await api.publish(.init(
            pId: entry.updateID,
            pPrompt: entry.prompt,
            pBody: body.isEmpty ? nil : body,
            pRawTranscript: entry.rawTranscript,
            pComposedWith: entry.composedWith.isEmpty ? ["typed"] : entry.composedWith,
            pComposeMs: entry.savedAt.map { max(0, Int($0.timeIntervalSince(entry.startedAt) * 1000)) },
            pCircles: entry.circleIDs ?? [],
            pMemo: memo,
            pPhotos: photos,
            pWeekStart: entry.week,
            pPostedAt: entry.savedAt
        ))
        entry.ownerID = me
        entry.needsSync = false
        entry.syncedAt = Date()
        try? context.save()
    }

    /// Uploads every saved entry with changes. Returns how many failed (offline, say).
    @discardableResult
    static func uploadPending(api: API, context: ModelContext) async -> Int {
        guard let me = api.accountID else { return 0 }
        var failed = 0
        for entry in EntryStore.saved(in: context) where (entry.needsSync || entry.ownerID == nil) && (entry.ownerID == nil || entry.ownerID == me) {
            do { try await upload(entry, api: api, context: context) } catch { failed += 1 }
        }
        return failed
    }

    /// Weeks written on another device (or before a reinstall) come down as entries. Media
    /// stays on the server and plays through signed URLs.
    static func downloadOwn(api: API, context: ModelContext) async throws {
        guard let me = api.accountID else { return }
        for row in try await api.myUpdates() {
            if let local = EntryStore.entry(for: row.weekStart, in: context) {
                if local.updateID != row.id && local.ownerID == nil {
                    // Written here while signed out, and that week already exists on the account:
                    // this phone's version becomes that update (it's the newer writing)
                    local.updateID = row.id
                    local.circleIDs = local.circleIDs ?? row.audienceIDs
                    local.needsSync = true
                }
                continue
            }
            let entry = Entry(weekStart: row.weekStart, updateID: row.id)
            entry.body = row.bodyText ?? ""
            entry.rawTranscript = row.bodyRawTranscript
            entry.prompt = row.prompt
            entry.composedWith = row.composedWith
            entry.startedAt = row.postedAt
            entry.savedAt = row.postedAt
            entry.updatedAt = row.editedAt ?? row.postedAt
            entry.circleIDs = row.audienceIDs
            if let memo = row.voiceMemos {
                entry.memoRemotePath = memo.storagePath
                entry.memoDurationMs = memo.durationMs
                entry.memoWaveform = memo.waveform
                entry.memoTranscriptRaw = memo.transcriptRaw
                entry.memoTranscriptClean = memo.transcriptClean
            }
            entry.photoItems = row.photos.map { "remote:\($0.storagePath)" }
            entry.ownerID = me
            entry.syncedAt = Date()
            context.insert(entry)
        }
        try? context.save()
    }

    /// Removes the server copy of a deleted entry (its files are swept by the server too).
    static func deleteRemote(_ entry: Entry, api: API) async {
        guard entry.ownerID != nil, entry.ownerID == api.accountID else { return }
        let photos = entry.photoItems.filter { $0.hasPrefix("remote:") }.map { String($0.dropFirst(7)) }
        try? await api.deleteUpdate(id: entry.updateID, memoPath: entry.memoRemotePath, photoPaths: photos)
    }

    /// Where an uploaded photo's local copy is kept.
    static func cacheName(for remotePath: String) -> String {
        "cache-" + (remotePath.split(separator: "/").last.map(String.init) ?? UUID().uuidString)
    }
}

/// Weekly reminders as local notifications: no account, no server, works offline. The next
/// eight are scheduled, skipping weeks already logged, and planned again on every save.
enum LocalReminders {
    private static let key = "reminderSettings"
    static let identifierPrefix = "weekly-reminder-"

    static var settings: ReminderPlan.Settings {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let saved = try? JSONDecoder().decode(ReminderPlan.Settings.self, from: data) else { return ReminderPlan.Settings() }
            return saved
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    static func reschedule(context: ModelContext) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let dates = ReminderPlan.dates(settings, after: Date(), in: .current, logged: EntryStore.loggedWeeks(in: context))
        let calendar = Calendar.current
        for (index, date) in dates.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "Weeknotes"
            content.body = "Your week is ready to write."
            content.sound = .default
            content.threadIdentifier = "weekly-reminder"
            content.userInfo = ["link": "weeknotes://compose"]
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let request = UNNotificationRequest(identifier: identifierPrefix + String(index), content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try? await center.add(request)
        }
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}

/// The personal dictionary (Settings → Dictionary). Kept on the phone so dictation learns names
/// without an account; with an account it merges with the account's copy.
@Observable
final class DictionaryStore {
    struct Word: Codable, Hashable, Identifiable {
        var id = UUID()
        var written: String
        var soundsLike: [String]
        var source: String

        var entry: DictionaryEntry { DictionaryEntry(written: written, soundsLike: soundsLike) }
    }

    private static let key = "dictionary"
    private(set) var words: [Word]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Word].self, from: data) {
            words = saved
        } else {
            words = []
        }
    }

    var entries: [DictionaryEntry] { words.map(\.entry) }

    func upsert(_ entry: DictionaryEntry, source: String, replacing old: String? = nil, api: API?) {
        words.removeAll { $0.written == entry.written || (old != nil && $0.written == old) }
        words.append(Word(written: entry.written, soundsLike: entry.soundsLike, source: source))
        words.sort { $0.written.localizedCaseInsensitiveCompare($1.written) == .orderedAscending }
        save()
        guard let api, api.accountID != nil else { return }
        Task {
            if let old, old != entry.written, let row = try? await api.dictionary().first(where: { $0.written == old }) {
                try? await api.deleteDictionaryEntry(row.id)
            }
            try? await api.saveDictionaryEntry(entry, source: source)
        }
    }

    func delete(_ word: Word, api: API?) {
        words.removeAll { $0.id == word.id }
        save()
        guard let api, api.accountID != nil else { return }
        Task {
            if let row = try? await api.dictionary().first(where: { $0.written == word.written }) {
                try? await api.deleteDictionaryEntry(row.id)
            }
        }
    }

    /// Union of this phone's words and the account's.
    func sync(api: API) async {
        guard api.accountID != nil, let remote = try? await api.dictionary() else { return }
        for row in remote where !words.contains(where: { $0.written == row.written }) {
            words.append(Word(written: row.written, soundsLike: row.soundsLike, source: row.source))
        }
        for word in words where !remote.contains(where: { $0.written == word.written }) {
            try? await api.saveDictionaryEntry(word.entry, source: word.source)
        }
        words.sort { $0.written.localizedCaseInsensitiveCompare($1.written) == .orderedAscending }
        save()
    }

    func eraseLocal() {
        words = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(words) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
