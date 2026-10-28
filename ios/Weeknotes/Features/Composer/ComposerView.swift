import PhotosUI
import SwiftData
import SwiftUI
import WeeknotesCore

/// The composer (PRD §11, screen 4): type, dictate, record a memo, add up to 4 photos, pick an
/// optional prompt, then save. Everything is kept on the phone as you go; with an account you can
/// also choose circles to share the week with.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// The week to write or edit; the current week when nil.
    var editingWeek: LocalDate?

    @State private var draft: Entry?
    @State private var editor = EditorController()
    @State private var dictation = DictationSession()
    @State private var lastDictation: Insertion?
    @State private var offer: Correction?
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showRecorder = false
    @State private var showAudience = false
    @State private var posting = false
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var lastAudience: [UUID]?
    /// True while the composer itself changes the text (dictation, show original), so the
    /// change doesn't count as typing.
    @State private var programmaticEdit = false

    /// A dictation just inserted: what was said (raw) and what was inserted (formatted).
    struct Insertion: Equatable {
        var range: NSRange
        let formatted: String
        let raw: String
        var showingOriginal = false
        let skipped: Bool
    }

    var week: LocalDate { editingWeek ?? model.currentWeek }
    var isEditingSaved: Bool { draft?.isSaved == true }

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    editorScreen(draft)
                } else {
                    ProgressView()
                }
            }
            .paperBackground()
            .navigationTitle(week == model.currentWeek ? "Your week" : "Week of \(Week.label(for: week))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .task { await loadDraft() }
        .sheet(isPresented: $showAudience) {
            if let draft {
                AudiencePickerView(selection: Binding(
                    get: { Set(draft.circleIDs ?? lastAudience ?? []) },
                    set: { draft.circleIDs = Array($0); save() }
                ))
            }
        }
        .fullScreenCover(isPresented: $showRecorder) {
            if let draft { MemoRecorderView(draft: draft) { save() } }
        }
        .onChange(of: photoSelection) { _, items in addPhotos(items) }
        .interactiveDismissDisabled(posting)
    }

    // MARK: Layout

    private func editorScreen(_ draft: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            audienceRow(draft)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    promptArea(draft)
                    ComposerTextView(
                        text: Binding(get: { draft.body }, set: { newValue in
                            if newValue != draft.body {
                                if !programmaticEdit && !draft.composedWith.contains("typed") {
                                    draft.composedWith.append("typed")
                                }
                                draft.body = newValue
                                save()
                            }
                        }),
                        controller: editor,
                        placeholder: draft.prompt == nil ? "How was your week?" : "Write, or tap the mic and talk."
                    )
                    .frame(minHeight: 260)
                    if let lastDictation { dictationBar(lastDictation) }
                    if let offer { learningOffer(offer) }
                    attachments(draft)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) { bottomBar(draft) }
        .overlay(alignment: .bottom) {
            if dictation.isActive { liveDictationPanel.padding(.bottom, 86) }
        }
        .confirmationDialog("Discard this draft?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard draft", role: .destructive) { discardDraft() }
            Button("Keep for later") { dismiss() }
        } message: {
            Text("Your draft is saved. Keep it to come back later, or discard it.")
        }
    }

    @ViewBuilder
    private func audienceRow(_ draft: Entry) -> some View {
        if model.isSignedIn {
            Button { showAudience = true } label: {
                HStack(spacing: 8) {
                    Text("Share with").foregroundStyle(Theme.secondaryInk)
                    Text(audienceSummary(draft)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondaryInk)
                }
                .font(.subheadline)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("audienceRow")
            .accessibilityLabel("Audience: \(audienceSummary(draft))")
        } else {
            HStack(spacing: 8) {
                Label("Just for you, on this iPhone", systemImage: "lock")
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                if model.accountsAvailable {
                    Button("Share with friends") { model.accountFlowRequested = true }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("composerConnect")
                }
            }
            .font(.subheadline)
        }
    }

    private func audienceSummary(_ draft: Entry) -> String {
        let ids = Set(draft.circleIDs ?? lastAudience ?? [])
        let names = model.circles.filter { ids.contains($0.id) }.map(\.name)
        if names.isEmpty { return model.circles.isEmpty ? "Only you" : "Only you · choose circles" }
        return names.formatted(.list(type: .and))
    }

    @ViewBuilder
    private func promptArea(_ draft: Entry) -> some View {
        if let prompt = draft.prompt {
            HStack {
                Text(prompt).font(Theme.body(18)).italic().foregroundStyle(Theme.secondaryInk)
                Spacer()
                Button {
                    draft.prompt = nil
                    save()
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryInk) }
                .accessibilityLabel("Remove prompt")
            }
        } else if draft.body.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Prompts.suggestions(for: week), id: \.self) { prompt in
                        Button(prompt) {
                            draft.prompt = prompt
                            save()
                            editor.focus()
                        }
                        .font(.subheadline)
                        .glassButton()
                    }
                }
            }
            .scrollClipDisabled()
            .accessibilityLabel("Optional prompts")
        }
    }

    private func dictationBar(_ insertion: Insertion) -> some View {
        HStack(spacing: 10) {
            if insertion.skipped {
                Label("Formatting skipped.", systemImage: "text.badge.xmark")
                    .font(.caption).foregroundStyle(Theme.secondaryInk)
            } else {
                Label("Cleaned up: fillers and punctuation", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(Theme.secondaryInk)
            }
            Spacer()
            if !insertion.skipped {
                Button(insertion.showingOriginal ? "Show cleaned" : "Show original") { toggleOriginal() }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("showOriginal")
                Button("Undo") { undoFormatting() }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("undoFormatting")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.card, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private func learningOffer(_ correction: Correction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "character.book.closed").foregroundStyle(Theme.accent)
            Text("Add “\(correction.written)” to your dictionary?").font(.subheadline)
            Spacer()
            Button("Add") { learn(correction) }.font(.subheadline.weight(.semibold))
            Button("Not now") {
                model.learning.decline(correction)
                offer = nil
            }
            .font(.subheadline)
        }
        .card(padding: 12)
    }

    @ViewBuilder
    private func attachments(_ draft: Entry) -> some View {
        if draft.memoFileName != nil || draft.memoRemotePath != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Voice memo", systemImage: "waveform").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Re-record") { showRecorder = true }.font(.subheadline)
                    Button(role: .destructive) {
                        if let url = draft.memoFileURL { try? FileManager.default.removeItem(at: url) }
                        draft.memoFileName = nil
                        draft.memoRemotePath = nil
                        draft.memoTranscriptRaw = nil
                        draft.memoTranscriptClean = nil
                        draft.composedWith.removeAll { $0 == "memo" }
                        save()
                    } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Remove memo")
                }
                MemoPlayerView(
                    updateID: draft.updateID,
                    memo: MemoInfo(storagePath: draft.memoRemotePath ?? "", durationMs: draft.memoDurationMs, waveform: draft.memoWaveform, transcriptClean: draft.memoTranscriptClean, transcriptRaw: draft.memoTranscriptRaw),
                    authorName: model.profile?.displayName ?? "You",
                    localURL: draft.memoFileURL
                )
                if let transcript = draft.memoTranscriptClean ?? draft.memoTranscriptRaw {
                    TranscriptView(text: transcript)
                }
            }
            .card()
        }
        if !draft.photoItems.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(draft.photoItems, id: \.self) { item in
                        EntryPhoto(entry: draft, item: item)
                            .frame(width: 96, height: 96)
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    draft.photoItems.removeAll { $0 == item }
                                    save()
                                } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .padding(4)
                                .accessibilityLabel("Remove photo")
                            }
                    }
                }
            }
        }
    }

    private func bottomBar(_ draft: Entry) -> some View {
        GlassGroup(spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    Task { await toggleDictation(draft) }
                } label: {
                    Image(systemName: dictation.state == .listening ? "stop.fill" : "mic.fill")
                        .font(.title2)
                        .frame(width: 60, height: 60)
                        .contentTransition(.symbolEffect(.replace))
                }
                .glassProminentButton()
                .buttonBorderShape(.circle)
                .disabled(dictation.state == .preparing || dictation.state == .finishing)
                .accessibilityLabel(dictation.state == .listening ? "Stop dictating" : "Dictate")
                .accessibilityIdentifier("dictateButton")

                Button { showRecorder = true } label: {
                    Image(systemName: "waveform.badge.mic").font(.title3).frame(width: 50, height: 50)
                }
                .glassButton()
                .buttonBorderShape(.circle)
                .disabled(dictation.isActive)
                .accessibilityLabel("Record a voice memo")
                .accessibilityIdentifier("memoButton")

                PhotosPicker(selection: $photoSelection, maxSelectionCount: max(1, AppConfig.maxPhotos - draft.photoItems.count), matching: .images) {
                    Image(systemName: "photo.on.rectangle").font(.title3).frame(width: 50, height: 50)
                }
                .glassButton()
                .buttonBorderShape(.circle)
                .disabled(draft.photoItems.count >= AppConfig.maxPhotos || dictation.isActive)
                .accessibilityLabel("Add photos")

                Spacer()
                Text("\(draft.photoItems.count)/\(AppConfig.maxPhotos) photos")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
                    .opacity(draft.photoItems.isEmpty ? 0 : 1)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    private var liveDictationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                    .opacity(dictation.state == .listening ? 1 : 0.3)
                Text(dictation.state == .finishing ? "Cleaning up…" : dictation.state == .preparing ? "Getting ready…" : "Listening")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                LevelMeter(level: dictation.level)
            }
            Text(dictation.liveText.isEmpty ? "Start talking. Say “new paragraph” or “comma” when you want one." : dictation.liveText)
                .font(Theme.body(17))
                .foregroundStyle(dictation.liveText.isEmpty ? Theme.secondaryInk : Theme.ink)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .phaseAnimator([false, true], trigger: dictation.state == .finishing) { content, phase in
                    // A subtle shimmer while the formatted version is on its way
                    content.opacity(dictation.state == .finishing && phase ? 0.55 : 1)
                }
                .accessibilityIdentifier("liveDictation")
        }
        .padding(16)
        .glassSurface(.rect(cornerRadius: 22))
        .padding(.horizontal, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dictation.cancel()
                MemoPlayer.shared.stopAll()
                // A draft with writing in it asks; a saved week keeps its changes as a draft edit
                if draft?.hasContent == true && !isEditingSaved { confirmDiscard = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("closeComposer")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(saveTitle) { saveEntry() }
                .glassProminentButton()
                .disabled(!(draft?.hasContent ?? false) || posting || dictation.isActive)
                .accessibilityIdentifier("postButton")
        }
    }

    // MARK: Entry

    private var saveTitle: String {
        guard model.isSignedIn, let draft else { return "Save" }
        return (draft.circleIDs ?? lastAudience ?? []).isEmpty ? "Save" : "Share"
    }

    private func loadDraft() async {
        if let existing = EntryStore.entry(for: week, in: context) {
            draft = existing
        } else {
            let new = Entry(weekStart: week)
            context.insert(new)
            save()
            draft = new
        }
        if model.isSignedIn, draft?.circleIDs == nil, let lastAudience = try? await model.api?.lastAudience() {
            self.lastAudience = lastAudience
        }
    }

    /// Every change is kept immediately, so nothing is lost if the app is closed.
    private func save() {
        draft?.touch()
        try? context.save()
    }

    private func discardDraft() {
        if let draft { EntryStore.delete(draft, in: context) }
        dismiss()
    }

    // MARK: Dictation

    private func toggleDictation(_ draft: Entry) async {
        if dictation.state == .listening {
            guard let result = await dictation.stop() else {
                if case .failed(let message) = dictation.state { error = message }
                return
            }
            insert(result, into: draft)
            return
        }
        checkForCorrections()
        error = nil
        editor.dismissKeyboard()
        let api = model.api
        let context = FormattingContext(vocabulary: model.vocabulary, dictionary: model.dictionaryEntries, isDictation: true)
        let engine = await model.engines.availableTranscriptionEngine(api: api)
        await dictation.start(engine: engine, pipeline: model.engines.pipeline(api: api), context: context)
        if case .failed(let message) = dictation.state {
            error = message
            dictation.clearError()
        }
    }

    private func insert(_ result: FormattedResult, into draft: Entry) {
        let text = result.formatted.isEmpty ? result.raw : result.formatted
        programmaticEdit = true
        defer { programmaticEdit = false }
        guard let range = editor.insertAtCursor(text) else { return }
        draft.rawTranscript = [draft.rawTranscript, result.raw].compactMap { $0 }.joined(separator: "\n\n")
        if !draft.composedWith.contains("dictated") { draft.composedWith.append("dictated") }
        lastDictation = Insertion(range: range, formatted: text, raw: result.raw, skipped: result.formattingSkipped)
        save()
    }

    /// "Show original" swaps the inserted text for exactly what was said, and back.
    private func toggleOriginal() {
        guard var insertion = lastDictation else { return }
        let replacement = insertion.showingOriginal ? insertion.formatted : insertion.raw
        programmaticEdit = true
        defer { programmaticEdit = false }
        if let range = editor.replace(insertion.range, with: replacement) {
            insertion.range = range
            insertion.showingOriginal.toggle()
            lastDictation = insertion
        }
    }

    /// Undo restores the raw transcript and ends the cleanup for this dictation.
    private func undoFormatting() {
        guard let insertion = lastDictation else { return }
        programmaticEdit = true
        defer { programmaticEdit = false }
        if !insertion.showingOriginal { editor.replace(insertion.range, with: insertion.raw) }
        lastDictation = nil
    }

    /// Learning from edits: compare what dictation inserted with what's there now.
    private func checkForCorrections() {
        guard let insertion = lastDictation, !insertion.showingOriginal, let draft else { return }
        lastDictation = nil
        let corrections = EditLearner.corrections(formatted: insertion.formatted, final: draft.body, knownNames: Set(model.acceptedFriends.map(\.displayName)))
        handle(model.learning.record(corrections, existing: model.words.entries))
    }

    private func handle(_ actions: [LearningAction]) {
        for action in actions {
            switch action {
            case .offer(let correction):
                offer = correction
            case .autoAdd(let entry):
                model.words.upsert(entry, source: "learned", api: model.api)
                model.show("Added “\(entry.written)” to your dictionary", systemImage: "character.book.closed.fill")
            }
        }
    }

    private func learn(_ correction: Correction) {
        let entry = LearningLedger.entry(for: correction, existing: model.words.entries)
        offer = nil
        model.learning.markLearned(correction)
        model.words.upsert(entry, source: "learned", api: model.api)
    }

    // MARK: Photos

    private func addPhotos(_ items: [PhotosPickerItem]) {
        guard let draft, !items.isEmpty else { return }
        photoSelection = []
        Task {
            for item in items.prefix(AppConfig.maxPhotos - draft.photoItems.count) {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let processed = await Task.detached(operation: { PhotoProcessor.process(data) }).value else { continue }
                let name = "photo-\(UUID().uuidString.prefix(8)).jpg"
                try? processed.data.write(to: draft.folder.appending(path: name))
                draft.photoItems.append(name)
                save()
            }
        }
    }

    // MARK: Saving

    private func saveEntry() {
        guard let draft else { return }
        checkForCorrections()
        posting = true
        error = nil
        if draft.savedAt == nil { draft.savedAt = Date() }
        if model.isSignedIn && draft.circleIDs == nil { draft.circleIDs = lastAudience ?? [] }
        if draft.composedWith.isEmpty { draft.composedWith = ["typed"] }
        draft.touch()
        try? context.save()
        MemoPlayer.shared.stopAll()
        Task {
            let message = await model.didSave(draft)
            posting = false
            model.show(message)
            dismiss()
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { index in
                Capsule()
                    .fill(Theme.accent.opacity(Float(index) / 5 < level ? 1 : 0.25))
                    .frame(width: 4, height: CGFloat(6 + index * 3))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}
