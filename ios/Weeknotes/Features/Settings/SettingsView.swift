import SwiftData
import SwiftUI
import WeeknotesCore

/// Settings (PRD §11, screen 10): the weekly reminder, the dictionary, your account (optional),
/// privacy, and erasing data. The bake-off screen is reachable from here (internal).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var reminder = LocalReminders.settings
    @State private var reminderTime = Date()
    @State private var loaded = false
    @State private var confirmDelete = false
    @State private var confirmErase = false
    @State private var deleting = false
    @State private var error: String?
    @State private var versionTaps = 0

    var body: some View {
        Form {
            accountSection

            Section {
                Toggle("Weekly reminder", isOn: $reminder.enabled)
                    .accessibilityIdentifier("reminderToggle")
                if reminder.enabled {
                    ReminderPicker(weekday: $reminder.weekday, time: $reminderTime)
                }
            } header: {
                Text("Reminder")
            } footer: {
                Text("A notification on this iPhone, skipped for weeks you've already written.")
            }

            Section {
                NavigationLink("Dictionary") { DictionaryView() }
                LabeledContent("On-device cleanup", value: model.engines.onDeviceFormattingStatus)
            } header: {
                Text("Dictation")
            } footer: {
                Text("Names and words you teach Weeknotes, so dictation spells them right.\(model.isSignedIn ? " Your friends' names are included automatically." : "")")
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
                Button("Erase this iPhone's weeks", role: .destructive) { confirmErase = true }
                    .accessibilityIdentifier("eraseLocal")
            } footer: {
                Text(model.isSignedIn
                     ? "Removes your weeks, memos, photos and dictionary from this iPhone. Your account keeps its backup."
                     : "Removes your weeks, memos, photos and dictionary from this iPhone. Without an account there's no other copy.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("Settings")
        .onAppear(perform: load)
        .onChange(of: reminder) { _, value in saveReminder(value) }
        .onChange(of: reminderTime) { _, time in
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            reminder.hour = c.hour ?? 18
            reminder.minute = c.minute ?? 0
        }
        .onDisappear {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if model.isSignedIn, !trimmed.isEmpty, trimmed != model.profile?.displayName {
                Task {
                    try? await model.api?.updateProfile(.init(displayName: trimmed))
                    await model.refreshProfile()
                }
            }
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { deleteAccount() }
        } message: {
            Text("Your account, friends, circles, replies and every shared week are deleted, and disappear from your friends' feeds. Your weeks on this iPhone stay.")
        }
        .confirmationDialog("Erase this iPhone's weeks?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) {
                model.eraseLocalData()
                model.show("Erased from this iPhone", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        switch model.account {
        case .signedIn:
            Section("Account") {
                TextField("Name", text: $name).accessibilityIdentifier("settingsName")
                NavigationLink {
                    PhoneSettingsView()
                } label: {
                    LabeledContent("Phone number", value: model.profile?.hasVerifiedPhone == true ? "Verified" : "Not added")
                }
                Button("Sign out") { Task { await model.signOut() } }
                Button("Delete account", role: .destructive) { confirmDelete = true }
                    .disabled(deleting)
            }
        case .needsProfile:
            Section("Account") {
                Button("Finish setting up your account") { model.accountFlowRequested = true }
                Button("Sign out") { Task { await model.signOut() } }
            }
        case .signedOut:
            if model.accountsAvailable {
                Section {
                    Button("Create an account or sign in") { model.accountFlowRequested = true }
                        .accessibilityIdentifier("settingsSignIn")
                } header: {
                    Text("Account")
                } footer: {
                    Text("Optional. An account lets you connect with friends and share weeks, and backs up your weeks.")
                }
            }
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
        name = model.profile?.displayName ?? ""
        reminder = LocalReminders.settings
        reminderTime = Calendar.current.date(from: DateComponents(hour: reminder.hour, minute: reminder.minute)) ?? Date()
        DispatchQueue.main.async { loaded = true }
    }

    private func saveReminder(_ value: ReminderPlan.Settings) {
        guard loaded else { return }
        LocalReminders.settings = value
        Task {
            if value.enabled { _ = await PushService.shared.requestPermission() }
            await LocalReminders.reschedule(context: model.context)
        }
    }

    private func deleteAccount() {
        deleting = true
        Task {
            defer { deleting = false }
            do {
                try await model.api?.deleteAccount()
                // This iPhone's weeks stay, as the user's own; they're no longer tied to an account
                for entry in EntryStore.saved(in: model.context) {
                    entry.ownerID = nil
                    entry.circleIDs = nil
                    entry.needsSync = false
                }
                try? model.context.save()
                await model.signOut()
                model.show("Account deleted", systemImage: "trash")
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
/// Kept on this iPhone; with an account it's backed up too.
struct DictionaryView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: DictionaryStore.Word?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(model.words.words) { word in
                    Button { editing = word } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(word.written).foregroundStyle(Theme.ink)
                                if word.source == "learned" {
                                    Text("Learned").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                                }
                            }
                            if !word.soundsLike.isEmpty {
                                Text("Sounds like: \(word.soundsLike.joined(separator: ", "))").font(.caption).foregroundStyle(Theme.secondaryInk)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for word in offsets.map({ model.words.words[$0] }) { model.words.delete(word, api: model.api) }
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
        .task { if let api = model.api { await model.words.sync(api: api) } }
        .sheet(item: $editing) { word in DictionaryEntryEditor(word: word) }
        .sheet(isPresented: $adding) { DictionaryEntryEditor(word: nil) }
    }
}

private struct DictionaryEntryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let word: DictionaryStore.Word?
    @State private var written = ""
    @State private var soundsLike = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Spelled", text: $written).autocorrectionDisabled().accessibilityIdentifier("wordWritten")
                } header: { Text("Exact spelling") } footer: { Text("For example: Jaylen") }
                Section {
                    TextField("Jalen, Jay Lynn", text: $soundsLike).autocorrectionDisabled().accessibilityIdentifier("wordSoundsLike")
                } header: { Text("Sounds like (optional)") } footer: { Text("Ways dictation gets it wrong, separated by commas.") }
            }
            .navigationTitle(word == nil ? "Add a word" : "Edit word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(written.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("saveWord")
                }
            }
            .onAppear {
                written = word?.written ?? ""
                soundsLike = word?.soundsLike.joined(separator: ", ") ?? ""
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let entry = DictionaryEntry(
            written: written.trimmingCharacters(in: .whitespaces),
            soundsLike: soundsLike.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
        model.words.upsert(entry, source: word?.source ?? "manual", replacing: word?.written, api: model.api)
        dismiss()
    }
}
