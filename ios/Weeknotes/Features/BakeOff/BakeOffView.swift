import SwiftUI
import UniformTypeIdentifiers
import WeeknotesCore

/// Internal: the transcription bake-off (PRD §7, M3). Record or import real weekly updates,
/// run each through every engine and both formatters, compare side by side, export.
struct BakeOffView: View {
    @Environment(AppModel.self) private var model
    @State private var recordings: [Recording] = []
    @State private var runs: [String: BakeOffRun] = [:]
    @State private var running: String?
    @State private var importing = false
    @State private var recordingNew = false
    @State private var exportURL: URL?

    struct Recording: Codable, Identifiable, Hashable {
        var file: String
        var label: String
        var kind: String           // "dictation" | "memo"
        var room: String           // "quiet" | "noisy"
        var reference: String?
        var id: String { file }
    }

    static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "BakeOff", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var body: some View {
        @Bindable var engines = model.engines
        List {
            Section("Engines in use") {
                Picker("Transcription", selection: $engines.transcriptionID) {
                    ForEach(EngineSettings.transcriptionIDs, id: \.self) { Text(EngineSettings.name($0)).tag($0) }
                }
                Picker("Formatting (primary)", selection: $engines.primaryFormatterID) {
                    ForEach(EngineSettings.formattingIDs, id: \.self) { Text(EngineSettings.name($0)).tag($0) }
                }
                LabeledContent("On-device formatting", value: model.engines.onDeviceFormattingStatus)
            }

            Section {
                Button("Record a test update", systemImage: "mic") { recordingNew = true }
                Button("Import audio files", systemImage: "square.and.arrow.down") { importing = true }
                if !recordings.isEmpty {
                    Button(running == nil ? "Run every recording (\(recordings.count))" : "Running…", systemImage: "play.circle") {
                        Task { for recording in recordings { await run(recording) } }
                    }
                    .disabled(running != nil)
                }
                if !runs.isEmpty {
                    Button("Export results", systemImage: "square.and.arrow.up") { export() }
                }
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share \(exportURL.lastPathComponent)", systemImage: "doc") }
                }
            } footer: {
                Text("The plan: 20 real updates, dictation and memos, quiet and noisy rooms. Add a reference transcript to score accuracy.")
            }

            ForEach($recordings) { $recording in
                Section(recording.label) {
                    Picker("Kind", selection: $recording.kind) {
                        Text("Dictation").tag("dictation")
                        Text("Memo").tag("memo")
                    }
                    Picker("Room", selection: $recording.room) {
                        Text("Quiet").tag("quiet")
                        Text("Noisy").tag("noisy")
                    }
                    TextField("Reference transcript (what was actually said)", text: Binding(
                        get: { recording.reference ?? "" }, set: { recording.reference = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                    .lineLimit(2...6)
                    Button(running == recording.id ? "Running…" : "Run all engines") { Task { await run(recording) } }
                        .disabled(running != nil)
                    if let run = runs[recording.id] {
                        ForEach(run.results, id: \.engineID) { result in
                            EngineResultView(result: result)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("Bake-off")
        .onAppear(perform: load)
        .onChange(of: recordings) { save() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { importFile(url) }
        }
        .fullScreenCover(isPresented: $recordingNew, onDismiss: load) {
            BakeOffRecorder()
        }
    }

    private func load() {
        let index = Self.folder.appending(path: "recordings.json")
        if let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([Recording].self, from: data) {
            recordings = saved
        }
        // Recordings made with the recorder but not yet indexed
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path(percentEncoded: false))) ?? []
        for file in files where file.hasSuffix(".m4a") && !recordings.contains(where: { $0.file == file }) {
            recordings.append(Recording(file: file, label: "Recording \(recordings.count + 1)", kind: "dictation", room: "quiet"))
        }
        let resultsFile = Self.folder.appending(path: "runs.json")
        if let data = try? Data(contentsOf: resultsFile), let saved = try? JSONDecoder().decode([String: BakeOffRun].self, from: data) {
            runs = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(recordings) { try? data.write(to: Self.folder.appending(path: "recordings.json")) }
        if let data = try? JSONEncoder().encode(runs) { try? data.write(to: Self.folder.appending(path: "runs.json")) }
    }

    private func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = "import-\(UUID().uuidString.prefix(6))-\(url.lastPathComponent)"
        try? FileManager.default.copyItem(at: url, to: Self.folder.appending(path: name))
        recordings.append(Recording(file: name, label: url.deletingPathExtension().lastPathComponent, kind: "memo", room: "quiet"))
    }

    private func run(_ recording: Recording) async {
        running = recording.id
        defer { running = nil; save() }
        let url = Self.folder.appending(path: recording.file)
        let api = model.api
        let vocabulary = model.vocabulary
        var run = BakeOffRun(recording: recording.file, label: recording.label, durationMs: Int(MemoRecorder.duration(of: url) * 1000), reference: recording.reference)
        var formatters: [(String, DictationPipeline)] = [
            ("hosted-small", DictationPipeline(primary: model.engines.hostedFormatter(api: api), fallback: nil)),
        ]
        if let onDevice = EngineSettings.onDeviceFormatter {
            formatters.insert(("apple-foundation", DictationPipeline(primary: onDevice, fallback: nil)), at: 0)
        }
        for id in EngineSettings.transcriptionIDs {
            var result = BakeOffRun.EngineResult(engineID: id)
            let engine = EngineSettings.makeEngine(id, api: api)
            do {
                try await engine.prepare(vocabulary: vocabulary)
                let started = ContinuousClock.now
                let transcript = try await engine.transcribeFile(at: url)
                result.transcribeMs = Int((ContinuousClock.now - started) / .milliseconds(1))
                result.raw = transcript.text
                let context = FormattingContext(vocabulary: vocabulary, dictionary: model.dictionaryEntries, isDictation: recording.kind == "dictation")
                for (formatterID, pipeline) in formatters {
                    let formatted = await pipeline.run(transcript, context: context)
                    result.formatted[formatterID] = formatted.formattingSkipped ? "[skipped] \(formatted.formatted)" : formatted.formatted
                    result.formattingMs[formatterID] = formatted.durationMs
                }
                if let reference = recording.reference {
                    result.wordErrorRate = BakeOffScore.wordErrorRate(reference: reference, hypothesis: transcript.text)
                    let names = BakeOffScore.names(vocabulary, reference: reference, hypothesis: result.formatted["apple-foundation"] ?? transcript.text)
                    result.namesExpected = names.expected
                    result.namesCorrect = names.correct
                }
            } catch {
                result.error = error.localizedDescription
            }
            run.results.append(result)
            runs[recording.id] = run
        }
    }

    private func export() {
        let ordered = recordings.compactMap { runs[$0.id] }
        let stamp = Date().formatted(.iso8601.year().month().day())
        let csvURL = FileManager.default.temporaryDirectory.appending(path: "bakeoff-\(stamp).csv")
        let jsonURL = FileManager.default.temporaryDirectory.appending(path: "bakeoff-\(stamp).json")
        try? BakeOffRun.csv(ordered, formatters: EngineSettings.formattingIDs).write(to: csvURL, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(ordered).write(to: jsonURL)
        exportURL = csvURL
    }
}

private struct EngineResultView: View {
    let result: BakeOffRun.EngineResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(EngineSettings.name(result.engineID)).font(.subheadline.weight(.semibold))
                Spacer()
                if let ms = result.transcribeMs { Text("\(ms) ms").font(.caption).monospacedDigit() }
            }
            if let error = result.error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                if let wer = result.wordErrorRate {
                    Text("WER \(String(format: "%.1f%%", wer * 100)) · names \(result.namesCorrect ?? 0)/\(result.namesExpected ?? 0)")
                        .font(.caption).foregroundStyle(Theme.secondaryInk)
                }
                Text(result.raw ?? "").font(.caption).foregroundStyle(Theme.secondaryInk)
                ForEach(EngineSettings.formattingIDs, id: \.self) { id in
                    if let text = result.formatted[id] {
                        Text("\(id) (\(result.formattingMs[id] ?? 0) ms)").font(.caption2.weight(.semibold))
                        Text(text).font(.callout)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct BakeOffRecorder: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = MemoRecorder()

    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()
                Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: 52, weight: .light, design: .rounded)).monospacedDigit()
                LiveWaveform(levels: recorder.levels).frame(height: 80)
                Spacer()
                Button(recorder.state == .recording ? "Stop" : "Record") {
                    if recorder.state == .recording {
                        recorder.stop()
                        dismiss()
                    } else {
                        Task {
                            guard await AudioPermission.requestMicrophone() else { return }
                            try? recorder.start(into: BakeOffView.folder)
                        }
                    }
                }
                .glassProminentButton()
                .controlSize(.large)
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.discard()
                        dismiss()
                    }
                }
            }
        }
    }
}
