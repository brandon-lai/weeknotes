import SwiftUI
import WeeknotesCore

/// Initials on a warm color picked from the name, so each friend keeps the same color.
struct AvatarView: View {
    let name: String
    var size: CGFloat = 40

    static let palette: [Color] = [
        Color(red: 0.89, green: 0.45, blue: 0.29), Color(red: 0.36, green: 0.55, blue: 0.47),
        Color(red: 0.42, green: 0.47, blue: 0.70), Color(red: 0.78, green: 0.56, blue: 0.24),
        Color(red: 0.63, green: 0.40, blue: 0.56), Color(red: 0.31, green: 0.56, blue: 0.67),
    ]

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var color: Color {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.palette[abs(sum) % Self.palette.count]
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

/// The memo waveform: ~100 bars, the played part in the accent color. Drag to scrub.
struct WaveformView: View {
    let values: [Float]
    var progress: Double = 0
    var height: CGFloat = 36
    var onScrub: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let bars = Self.resample(values, to: max(12, Int(geometry.size.width / 4.5)))
            HStack(alignment: .center, spacing: 2) {
                ForEach(bars.indices, id: \.self) { index in
                    let played = Double(index) / Double(max(1, bars.count)) < progress
                    Capsule()
                        .fill(played ? Theme.accent : Theme.secondaryInk.opacity(0.35))
                        .frame(height: max(3, CGFloat(bars[index]) * geometry.size.height))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in onScrub?(max(0, min(1, value.location.x / geometry.size.width))) }
            )
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue("\(Int(progress * 100)) percent played")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onScrub?(min(1, progress + 0.1))
            case .decrement: onScrub?(max(0, progress - 0.1))
            @unknown default: break
            }
        }
    }

    static func resample(_ values: [Float], to count: Int) -> [Float] {
        guard !values.isEmpty, count > 0 else { return [Float](repeating: 0.15, count: max(count, 0)) }
        return (0..<count).map { i in
            let start = i * values.count / count
            let end = max(start + 1, (i + 1) * values.count / count)
            let slice = values[start..<min(end, values.count)]
            return max(0.08, slice.max() ?? 0)
        }
    }
}

/// Inline memo player for feed cards and the detail view: play/pause, scrub on the
/// waveform, 1x / 1.5x / 2x.
struct MemoPlayerView: View {
    @Environment(AppModel.self) private var model
    let updateID: UUID
    let memo: MemoInfo
    let authorName: String
    /// A local file (the composer's own recording) instead of a signed URL.
    var localURL: URL?
    private let player = MemoPlayer.shared

    var isCurrent: Bool { player.currentID == updateID }
    var isPlaying: Bool { isCurrent && player.isPlaying }
    var duration: TimeInterval { TimeInterval(memo.durationMs) / 1000 }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await player.toggle(id: updateID, url: {
                        if let localURL { return localURL }
                        guard let api = model.api else { throw APIError.signedOut }
                        return try await api.signedURL(bucket: "memos", path: memo.storagePath)
                    }, duration: duration, title: "\(authorName)'s week")
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .glassProminentButton()
            .buttonBorderShape(.circle)
            .accessibilityLabel(isPlaying ? "Pause \(authorName)'s memo" : "Play \(authorName)'s memo")

            VStack(alignment: .leading, spacing: 4) {
                WaveformView(values: memo.waveform, progress: player.progress(for: updateID), height: 30) { fraction in
                    player.seek(to: fraction, id: updateID)
                }
                HStack {
                    Text(timeLabel).monospacedDigit()
                    Spacer()
                    if isCurrent {
                        Button(rateLabel) {
                            let rates = MemoPlayer.rates
                            let next = rates[((rates.firstIndex(of: player.rate) ?? 0) + 1) % rates.count]
                            player.rate = next
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityLabel("Playback speed \(rateLabel)")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    var timeLabel: String {
        let shown = isCurrent && player.position > 0 ? player.position : duration
        return Duration.seconds(shown).formatted(.time(pattern: .minuteSecond))
    }

    var rateLabel: String {
        player.rate == 1 ? "1×" : player.rate == 1.5 ? "1.5×" : "2×"
    }
}

/// A private photo, loaded through a short-lived signed URL.
struct StoredPhoto: View {
    @Environment(AppModel.self) private var model
    let photo: PhotoInfo
    var contentMode: ContentMode = .fill
    @State private var url: URL?

    var body: some View {
        // The image draws in an overlay so its natural size never widens the layout
        Theme.hairline.opacity(0.4)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .overlay {
                if let url {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                        switch phase {
                        case .success(let image): image.resizable().aspectRatio(contentMode: contentMode)
                        case .failure: Image(systemName: "photo").foregroundStyle(Theme.secondaryInk)
                        default: ProgressView()
                        }
                    }
                }
            }
            .clipped()
        .task(id: photo.storagePath) {
            url = try? await model.api?.signedURL(bucket: "photos", path: photo.storagePath)
        }
        .accessibilityLabel("Photo")
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(title).font(Theme.headingFont).foregroundStyle(Theme.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .glassProminentButton()
                    .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.subheadline).foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
            if let retry {
                Button("Retry", action: retry).font(.subheadline.weight(.semibold))
            }
        }
        .card(padding: 14)
    }
}

/// Up to three lines of a transcript with "Show full transcript".
struct TranscriptView: View {
    let text: String
    var collapsedLines = 3
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(Theme.body(15))
                .foregroundStyle(Theme.ink.opacity(0.85))
                .lineLimit(expanded ? nil : collapsedLines)
            if !expanded && text.count > 140 {
                Button("Show full transcript") { withAnimation { expanded = true } }
                    .font(.caption.weight(.semibold))
            }
        }
    }
}

extension Date {
    /// "Sunday 6:12 pm" this week, "Oct 19" older.
    var friendlyPosted: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today " + formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: self, to: Date()).day, days < 6 {
            return formatted(.dateTime.weekday(.wide))
        }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}
