import Foundation
import SwiftData
import WeeknotesCore

/// A week you've written. It lives on the phone first: the app works with no account, and the
/// archive is these rows. While `savedAt` is nil it's a draft (saved on every keystroke, so it
/// survives the app being killed). With an account, saved entries are backed up to the server
/// and can be shared with circles; `updateID` is then also the server update's id.
@Model
final class Entry {
    @Attribute(.unique) var weekStart: String
    var updateID: UUID
    var body: String
    /// Raw dictation transcripts, appended in order: what "Show original" shows.
    var rawTranscript: String?
    var prompt: String?
    var composedWith: [String]
    var startedAt: Date
    var updatedAt: Date
    /// When it was first saved (nil while it's a draft).
    var savedAt: Date?
    /// Circles it's shared with. nil = not chosen yet (the picker preselects last week's).
    var circleIDs: [UUID]?

    var memoFileName: String?
    var memoRemotePath: String?
    var memoDurationMs: Int
    var memoWaveform: [Float]
    var memoTranscriptRaw: String?
    var memoTranscriptClean: String?
    var memoEngineID: String?

    /// Local photo files, in order; uploaded ones are "remote:<path>".
    var photoItems: [String]

    /// The account it's backed up to. nil until the first upload.
    var ownerID: UUID?
    /// Saved changes not uploaded yet (only meaningful with an account).
    var needsSync: Bool
    var syncedAt: Date?

    init(weekStart: LocalDate, updateID: UUID = UUID()) {
        self.weekStart = weekStart.iso
        self.updateID = updateID
        body = ""
        composedWith = []
        startedAt = Date()
        updatedAt = Date()
        memoDurationMs = 0
        memoWaveform = []
        photoItems = []
        needsSync = false
    }

    var week: LocalDate { LocalDate(weekStart) ?? LocalDate(Date(), in: .current) }
    var isSaved: Bool { savedAt != nil }

    var hasContent: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memoFileName != nil || memoRemotePath != nil
    }

    var hasMemo: Bool { memoFileName != nil || memoRemotePath != nil }
    var folder: URL { EntryStore.folder(for: updateID) }
    var memoFileURL: URL? { memoFileName.map { folder.appending(path: $0) } }

    var memoInfo: MemoInfo? {
        guard hasMemo else { return nil }
        return MemoInfo(storagePath: memoRemotePath ?? "", durationMs: memoDurationMs, waveform: memoWaveform,
                        transcriptClean: memoTranscriptClean, transcriptRaw: memoTranscriptRaw)
    }

    /// The text to preview: what was written, else the memo transcript.
    var preview: String? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? (memoTranscriptClean ?? memoTranscriptRaw) : text
    }

    /// Marks a saved change so it uploads (with an account).
    func touch() {
        updatedAt = Date()
        if isSaved { needsSync = true }
    }
}

nonisolated enum EntryStore {
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Entries", directoryHint: .isDirectory)
    }

    static func folder(for updateID: UUID) -> URL {
        let url = root.appending(path: updateID.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func deleteFiles(for updateID: UUID) {
        try? FileManager.default.removeItem(at: root.appending(path: updateID.uuidString))
    }

    static func deleteAllFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    static var storeURL: URL { URL.applicationSupportDirectory.appending(path: "Weeks.store") }

    static func deleteStore() {
        let path = storeURL.path(percentEncoded: false)
        for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    static func container() -> ModelContainer {
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        if LaunchOptions.arguments.contains("-resetState") {
            deleteStore()
            deleteAllFiles()
        }
        let configuration = ModelConfiguration(url: storeURL)
        do {
            return try ModelContainer(for: Entry.self, configurations: configuration)
        } catch {
            // Never ship a schema change without a migration (README). This keeps a dev build
            // that can't open an old store from refusing to launch.
            deleteStore()
            return try! ModelContainer(for: Entry.self, configurations: configuration)
        }
    }

    @MainActor
    static func entry(for week: LocalDate, in context: ModelContext) -> Entry? {
        let iso = week.iso
        return try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.weekStart == iso })).first
    }

    @MainActor
    static func saved(in context: ModelContext) -> [Entry] {
        let descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.savedAt != nil }, sortBy: [SortDescriptor(\.weekStart, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Weeks with a saved entry, for the reminder planner.
    @MainActor
    static func loggedWeeks(in context: ModelContext) -> Set<LocalDate> {
        Set(saved(in: context).compactMap { LocalDate($0.weekStart) })
    }

    @MainActor
    static func delete(_ entry: Entry, in context: ModelContext) {
        deleteFiles(for: entry.updateID)
        context.delete(entry)
        try? context.save()
    }
}

/// Counts dictation corrections so the second identical fix is learned (PRD §8, "Learning
/// from edits"). Kept on the device.
@Observable
final class LearningStore {
    private static let key = "learningLedger"
    private(set) var ledger: LearningLedger

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode(LearningLedger.self, from: data) {
            ledger = saved
        } else {
            ledger = LearningLedger()
        }
    }

    func record(_ corrections: [Correction], existing: [DictionaryEntry]) -> [LearningAction] {
        let actions = ledger.record(corrections, existing: existing)
        save()
        return actions
    }

    func decline(_ correction: Correction) {
        ledger.decline(correction)
        save()
    }

    func markLearned(_ correction: Correction) {
        ledger.markLearned(correction)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
