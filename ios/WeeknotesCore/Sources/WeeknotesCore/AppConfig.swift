import Foundation

/// Product constants the PRD calls out as tunable. Server-side flags (`require_post_to_read`,
/// the Monday cutoff) also live in the `app_config` table so they can change without a release;
/// these are the defaults the app uses until it has read them.
public enum AppConfig {
    /// Stage 2: a spoken command needs at least this much silence after it.
    public static let spokenCommandPause: TimeInterval = 0.3
    /// Stage 5: reject output that keeps less than this share of the speaker's non-filler words.
    public static let minimumRetention = 0.6
    /// Stage 4: chunk size for the 4K-token on-device model.
    public static let formattingChunkWords = 600
    /// Stage 1: at most this many names and terms go to the speech engine.
    public static let vocabularyLimit = 100
    /// Posts made before this hour on Monday (author's time) count toward the previous week.
    public static let mondayCutoffHour = 12
    /// Voice memos: AAC, mono, 64 kbps, at most 5 minutes, ~100 waveform values.
    public static let memoMaxDuration: TimeInterval = 300
    public static let memoBitRate = 64_000
    public static let memoSampleRate: Double = 44_100
    public static let waveformBuckets = 100
    public static let maxPhotos = 4
    /// Default weekly reminder: Sunday 18:00 local. 0 = Sunday, matching `profiles.reminder_weekday`.
    public static let defaultReminderWeekday = 0
    public static let defaultReminderTime = "18:00"
    /// New share links stay readable this long.
    public static let shareLinkLifetimeDays = 30
    /// Feature flag default: reading friends' updates does not require posting first.
    public static let requirePostToReadDefault = false
}
