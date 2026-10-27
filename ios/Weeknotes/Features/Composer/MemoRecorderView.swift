import SwiftUI
import WeeknotesCore

/// The voice memo recorder (PRD §11, screen 5): big record button, pause and resume, a timer
/// toward 5 minutes, a live waveform. After stopping: play back, re-record, or keep. Keeping
/// transcribes on device (hosted as fallback) and lets you fix the transcript before posting.
struct MemoRecorderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: Draft
    let onSave: () -> Void

    @State private var recorder = MemoRecorder()
    @State private var stage: Stage = .recording
    @State private var transcriptRaw = ""
    @State private var transcriptClean = ""
    @State private var engineID: String?
    @State private var summary: [Float] = []
    @State private var error: String?

    enum Stage {
        case recording, review, transcribing, transcript
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch stage {
                case .recording, .review:
                    recordingScreen
                case .transcribing:
                    Spacer()
                    ProgressView("Writing down what you said…")
                    Spacer()
                case .transcript:
                    transcriptScreen
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .paperBackground()
            .navigationTitle("Voice memo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if stage != .transcript { recorder.discard() }
                        MemoPlayer.shared.stopAll()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(recorder.state == .recording || stage == .transcribing)
    }

    // MARK: Recording

    private var recordingScreen: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 6) {
                Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: 56, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("memoTimer")
                Text(recorder.state == .finished ? "Recorded" : "of 5:00")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }

            if stage == .review, let url = recorder.fileURL {
                MemoPlayerView(
                    updateID: draft.updateID,
                    memo: MemoInfo(storagePath: "", durationMs: Int(recorder.elapsed * 1000), waveform: summary, transcriptClean: nil, transcriptRaw: nil),
                    authorName: "Your",
                    localURL: url
                )
                .card()
            } else {
                LiveWaveform(levels: recorder.levels)
                    .frame(height: 90)
            }
            Spacer()
            controls
        }
    }

    @ViewBuilder
    private var controls: some View {
        if stage == .review {
            HStack(spacing: 16) {
                Button {
                    MemoPlayer.shared.stopAll()
                    recorder.discard()
                    stage = .recording
                } label: {
                    Label("Re-record", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .glassButton()
                .accessibilityIdentifier("reRecord")
                Button {
                    MemoPlayer.shared.stopAll()
                    Task { await keep() }
                } label: {
                    Label("Keep", systemImage: "checkmark").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .glassProminentButton()
                .accessibilityIdentifier("keepMemo")
            }
        } else {
            HStack(spacing: 36) {
                Button {
                    recorder.state == .paused ? recorder.resume() : recorder.pause()
                } label: {
                    Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill").font(.title2).frame(width: 60, height: 60)
                }
                .glassButton()
                .buttonBorderShape(.circle)
                .opacity(recorder.state == .recording || recorder.state == .paused ? 1 : 0)
                .disabled(!(recorder.state == .recording || recorder.state == .paused))
                .accessibilityLabel(recorder.state == .paused ? "Resume" : "Pause")

                Button {
                    toggleRecording()
                } label: {
                    ZStack {
                        Circle().fill(.red).frame(width: 84, height: 84)
                        if recorder.state == .recording || recorder.state == .paused {
                            RoundedRectangle(cornerRadius: 8).fill(.white).frame(width: 30, height: 30)
                        }
                    }
                    .padding(6)
                    .glassSurface(.circle, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.state == .idle ? "Start recording" : "Stop recording")
                .accessibilityIdentifier("recordButton")

                Color.clear.frame(width: 60, height: 60)
            }
            .sensoryFeedback(.impact, trigger: recorder.state)
            .onChange(of: recorder.state) { _, state in
                if state == .finished { finishRecording() }
            }
        }
    }

    private func toggleRecording() {
        error = nil
        switch recorder.state {
        case .idle:
            Task {
                if LaunchOptions.value(after: "-memoFixture") == nil {
                    guard await AudioPermission.requestMicrophone() else {
                        error = "Weeknotes needs the microphone to record. You can allow it in Settings."
                        return
                    }
                }
                MemoPlayer.shared.stopAll()
                do { try recorder.start(into: draft.folder) } catch { self.error = error.localizedDescription }
            }
        case .recording, .paused:
            recorder.stop()
        case .finished:
            break
        }
    }

    private func finishRecording() {
        guard let url = recorder.fileURL else { return }
        Task {
            summary = await Task.detached { Waveform.summarize((try? MemoRecorder.samples(of: url)) ?? []) }.value
            stage = .review
        }
    }

    // MARK: Transcript

    private var transcriptScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcript").font(Theme.headingFont)
            Text("Friends see this under your memo. Fix anything that came out wrong; your voice stays as it is.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
            TextEditor(text: $transcriptClean)
                .font(Theme.body(17))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Theme.card, in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline))
                .accessibilityIdentifier("memoTranscript")
            Button {
                save()
            } label: {
                Text("Use this memo").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .glassProminentButton()
            .accessibilityIdentifier("useMemo")
        }
    }

    private func keep() async {
        guard let url = recorder.fileURL else { return }
        stage = .transcribing
        let api = model.api
        let vocabulary = model.vocabulary
        var transcript: Transcript?
        // On device first; the hosted model is the fallback when that fails (PRD §7)
        let preferred = await model.engines.availableTranscriptionEngine(api: api)
        for engine in [preferred, EngineSettings.makeEngine("openai-hosted", api: api)] {
            do {
                try await engine.prepare(vocabulary: vocabulary)
                let result = try await engine.transcribeFile(at: url)
                if !result.text.isEmpty {
                    transcript = result
                    break
                }
            } catch {
                continue
            }
        }
        if let transcript {
            let context = FormattingContext(vocabulary: vocabulary, dictionary: model.dictionaryEntries, isDictation: false)
            let formatted = await model.engines.pipeline(api: api).run(transcript, context: context)
            transcriptRaw = transcript.text
            transcriptClean = formatted.formatted
            engineID = transcript.engineID
        } else {
            error = "Couldn't transcribe this memo. You can type a transcript, or post it without one."
        }
        stage = .transcript
    }

    private func save() {
        guard let url = recorder.fileURL else { return }
        if let old = draft.memoFileURL, old != url { try? FileManager.default.removeItem(at: old) }
        draft.memoFileName = url.lastPathComponent
        draft.memoRemotePath = nil
        draft.memoDurationMs = Int(recorder.elapsed * 1000)
        draft.memoWaveform = summary
        draft.memoTranscriptRaw = transcriptRaw.isEmpty ? nil : transcriptRaw
        let clean = transcriptClean.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.memoTranscriptClean = clean.isEmpty ? nil : clean
        draft.memoEngineID = engineID
        if !draft.composedWith.contains("memo") { draft.composedWith.append("memo") }
        onSave()
        dismiss()
    }
}

/// Scrolling bars of the live input level while recording.
struct LiveWaveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, Int(geometry.size.width / 5))
            let recent = Array(levels.suffix(count))
            let padded = [Float](repeating: 0.05, count: max(0, count - recent.count)) + recent
            HStack(spacing: 2) {
                ForEach(padded.indices, id: \.self) { index in
                    Capsule()
                        .fill(Theme.accent.opacity(0.85))
                        .frame(width: 3, height: max(3, CGFloat(padded[index]) * geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
