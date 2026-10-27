import Foundation
import SwiftData
import WeeknotesCore

/// The in-progress update for a week, saved on every change so it survives the app being
/// closed or killed (PRD §12). Audio and photos live as files next to the store; the row keeps
/// their names. One draft per week; posting deletes it.
@Model
final class Draft {
    @Attribute(.unique) var weekStart: String
    var updateID: UUID
    var body: String
    /// Raw dictation transcripts, appended in order: what "Show original" shows.
    var rawTranscript: String?
    var prompt: String?
    var composedWith: [String]
    var startedAt: Date
    var updatedAt: Date
    /// nil = not chosen yet (the picker preselects last week's circles)
    var circleIDs: [UUID]?

    var memoFileName: String?
    var memoRemotePath: String?
    var memoDurationMs: Int
    var memoWaveform: [Float]
    var memoTranscriptRaw: String?
    var memoTranscriptClean: String?
    var memoEngineID: String?

    /// Local photo files, in order; existing remote photos are kept as "remote:<path>".
    var photoItems: [String]

    /// True when this draft edits an update that's already posted.
    var isEditingPosted: Bool

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
        isEditingPosted = false
    }

    var hasContent: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memoFileName != nil || memoRemotePath != nil
    }

    var folder: URL { DraftStore.folder(for: updateID) }
    var memoFileURL: URL? { memoFileName.map { folder.appending(path: $0) } }
}

nonisolated enum DraftStore {
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Drafts", directoryHint: .isDirectory)
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

    static func container() -> ModelContainer {
        let url = URL.applicationSupportDirectory.appending(path: "Drafts.store")
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        if LaunchOptions.arguments.contains("-resetState") {
            for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(filePath: url.path(percentEncoded: false) + suffix)) }
        }
        let configuration = ModelConfiguration(url: url)
        do {
            return try ModelContainer(for: Draft.self, configurations: configuration)
        } catch {
            // A store we can't open shouldn't keep the app from launching; drafts start fresh
            for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(filePath: url.path(percentEncoded: false) + suffix)) }
            return try! ModelContainer(for: Draft.self, configurations: configuration)
        }
    }

    @MainActor
    static func draft(for week: LocalDate, in context: ModelContext) -> Draft? {
        let iso = week.iso
        let descriptor = FetchDescriptor<Draft>(predicate: #Predicate { $0.weekStart == iso })
        return try? context.fetch(descriptor).first
    }
}

/// Counts dictation corrections so the second identical fix is learned (PRD §8, "Learning
/// from edits"). Kept on the device; the learned entries themselves sync as dictionary rows.
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
