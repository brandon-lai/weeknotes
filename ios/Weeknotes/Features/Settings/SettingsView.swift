import SwiftUI
import WeeknotesCore

/// Settings (PRD §11, screen 10): name, reminder day and time, time zone, phone, Dictionary,
/// privacy, account deletion. The bake-off screen is reachable from here (internal).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var timezone = TimeZone.current.identifier
    @State private var weekday = 0
    @State private var time = Date()
    @State private var remindersOn = true
    @State private var loaded = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var error: String?
    @State private var versionTaps = 0

    var body: some View {
        Form {
            Section("You") {
                TextField("Name", text: $name)
                    .onSubmit { save(.init(displayName: name.trimmingCharacters(in: .whitespaces))) }
                    .accessibilityIdentifier("settingsName")
                TimeZonePicker(identifier: $timezone)
                NavigationLink {
                    PhoneSettingsView()
                } label: {
                    LabeledContent("Phone number", value: model.profile?.hasVerifiedPhone == true ? "Verified" : "Not added")
                }
            }

            Section {
                Toggle("Weekly reminder", isOn: $remindersOn)
                if remindersOn {
                    ReminderPicker(weekday: $weekday, time: $time)
                }
            } header: {
                Text("Reminder")
            } footer: {
                Text("Sent only if you haven't posted that week.")
            }

            Section {
                NavigationLink("Dictionary") { DictionaryView() }
                LabeledContent("On-device cleanup", value: model.engines.onDeviceFormattingStatus)
            } header: {
                Text("Dictation")
            } footer: {
                Text("Names and words you teach Weeknotes, so dictation spells them right. Your friends' names are included automatically.")
            }

            Section("About") {
                Link("Privacy policy", destination: AppEnvironment.privacyPolicyURL)
                Link("Help and feedback", destination: AppEnvironment.supportURL)
                LabeledContent("Version", value: AppEnvironment.version)
                    .contentShape(.rect)
                    .onTapGesture { versionTaps += 1 }
                if versionTaps >= 7 || isDebug {
                    NavigationLink("Transcription bake-off (internal)") { BakeOffView() }
                }
            }

            Section {
                Button("Sign out") { Task { await model.signOut() } }
                Button("Delete account", role: .destructive) { confirmDelete = true }
                    .disabled(deleting)
            } footer: {
                Text("Deleting your account removes your profile, every update, memo, photo, reply and reaction, permanently.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("Settings")
        .onAppear(perform: load)
        .onChange(of: timezone) { if loaded { save(.init(timezone: timezone)) } }
        .onChange(of: weekday) { if loaded { save(.init(reminderWeekday: weekday)) } }
        .onChange(of: time) { if loaded { save(.init(reminderTime: Self.timeString(time))) } }
        .onChange(of: remindersOn) { _, on in
            if loaded { save(.init(remindersEnabled: on)) }
            if on { Task { _ = await PushService.shared.requestPermission() } }
        }
        .onDisappear {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if loaded, !trimmed.isEmpty, trimmed != model.profile?.displayName { save(.init(displayName: trimmed)) }
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { deleteAccount() }
        } message: {
            Text("This can't be undone. Your updates disappear from your friends' feeds too.")
        }
    }

    private var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private func load() {
        guard let profile = model.profile else { return }
        name = profile.displayName
        timezone = profile.timezone
        weekday = profile.reminderWeekday
        time = Calendar.current.date(from: profile.reminderComponents) ?? Date()
        remindersOn = profile.remindersEnabled
        DispatchQueue.main.async { loaded = true }
    }

    static func timeString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 18, c.minute ?? 0)
    }

    private func save(_ changes: API.ProfileChanges) {
        Task {
            do {
                try await model.api?.updateProfile(changes)
                await model.refreshProfile()
                error = nil
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }

    private func deleteAccount() {
        deleting = true
        Task {
            defer { deleting = false }
            do {
                try await model.api?.deleteAccount()
                AppModel.resetLocalState()
                await model.signOut()
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }
}

private struct PhoneSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var number = ""
    @State private var code = ""
    @State private var sentTo: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if model.profile?.hasVerifiedPhone == true {
                    Label("Your number is verified. Friends with it in their contacts can find you.", systemImage: "checkmark.seal")
                }
                TextField("Phone number", text: $number).keyboardType(.phonePad)
                if let sentTo {
                    TextField("Code sent to \(sentTo)", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    Button("Verify") {
                        Task {
                            do {
                                try await model.api?.confirmPhone(e164: sentTo, code: code)
                                await model.refreshProfile()
                                self.sentTo = nil
                            } catch { self.error = friendlyMessage(error) }
                        }
                    }
                } else {
                    Button(model.profile?.hasVerifiedPhone == true ? "Change number" : "Send code") {
                        guard let e164 = PhoneNumber.e164(number, region: Locale.current.region?.identifier) else {
                            error = "Include the area code."
                            return
                        }
                        Task {
                            do {
                                try await model.api?.startPhoneVerification(e164: e164)
                                sentTo = e164
                            } catch { self.error = friendlyMessage(error) }
                        }
                    }
                }
            } footer: {
                Text("Weeknotes stores only a scrambled (hashed) version of your number for matching. It's never shown to anyone.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Phone number")
    }
}

/// Settings → Dictionary: names, nicknames, places, inside jokes, and how they get misheard.
struct DictionaryView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: DictionaryRow?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(model.dictionary) { row in
                    Button { editing = row } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(row.written).foregroundStyle(Theme.ink)
                                if row.source == "learned" {
                                    Text("Learned").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                                }
                            }
                            if !row.soundsLike.isEmpty {
                                Text("Sounds like: \(row.soundsLike.joined(separator: ", "))").font(.caption).foregroundStyle(Theme.secondaryInk)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let rows = offsets.map { model.dictionary[$0] }
                    Task {
                        for row in rows { try? await model.api?.deleteDictionaryEntry(row.id) }
                        await model.refreshDictionary()
                    }
                }
                Button("Add a word", systemImage: "plus") { adding = true }
                    .accessibilityIdentifier("addWord")
            } footer: {
                Text("When you fix the same name twice after dictating, Weeknotes adds it here for you.")
            }
            let friends = model.acceptedFriends
            if !friends.isEmpty {
                Section("From your friends") {
                    ForEach(friends) { Text($0.displayName).foregroundStyle(Theme.secondaryInk) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("Dictionary")
        .task { await model.refreshDictionary() }
        .sheet(item: $editing) { row in DictionaryEntryEditor(row: row) }
        .sheet(isPresented: $adding) { DictionaryEntryEditor(row: nil) }
    }
}

private struct DictionaryEntryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let row: DictionaryRow?
    @State private var written = ""
    @State private var soundsLike = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Spelled", text: $written).autocorrectionDisabled().accessibilityIdentifier("wordWritten")
                } header: { Text("Exact spelling") } footer: { Text("For example: Jaylen") }
                Section {
                    TextField("Jalen, Jay Lynn", text: $soundsLike).autocorrectionDisabled().accessibilityIdentifier("wordSoundsLike")
                } header: { Text("Sounds like (optional)") } footer: { Text("Ways dictation gets it wrong, separated by commas.") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(row == nil ? "Add a word" : "Edit word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(written.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                written = row?.written ?? ""
                soundsLike = row?.soundsLike.joined(separator: ", ") ?? ""
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let entry = DictionaryEntry(
            written: written.trimmingCharacters(in: .whitespaces),
            soundsLike: soundsLike.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
        Task {
            do {
                if let row, row.written != entry.written { try await model.api?.deleteDictionaryEntry(row.id) }
                try await model.api?.saveDictionaryEntry(entry, source: row?.source ?? "manual")
                await model.refreshDictionary()
                dismiss()
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }
}
