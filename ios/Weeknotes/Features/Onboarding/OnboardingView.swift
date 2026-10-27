import AuthenticationServices
import SwiftUI
import WeeknotesCore

/// Sign in with Apple, then name, time zone and reminder time (M0), then the optional steps:
/// phone number (for contact matching), contacts, notifications (PRD §11, screen 1).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    enum Step: Int, CaseIterable {
        case welcome, profile, phone, contacts, reminders
    }

    @State private var step: Step = .welcome
    @State private var suggestedName = ""

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .welcome:
                    WelcomeStep(suggestedName: $suggestedName) { advanceAfterSignIn() }
                case .profile:
                    ProfileStep(suggestedName: suggestedName) { step = .phone }
                case .phone:
                    PhoneStep { step = .contacts }
                case .contacts:
                    ContactsStep { step = .reminders }
                case .reminders:
                    RemindersStep { Task { await model.loadProfile() } }
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .animation(.smooth, value: step)
            .paperBackground()
        }
        .onAppear {
            if model.phase == .needsProfile { step = .profile }
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .needsProfile && step == .welcome { step = .profile }
        }
    }

    private func advanceAfterSignIn() {
        Task {
            await model.signedIn()
            if model.phase == .needsProfile { step = .profile }
        }
    }
}

private struct WelcomeStep: View {
    @Environment(AppModel.self) private var model
    @Binding var suggestedName: String
    let onSignedIn: () -> Void
    @State private var nonce = Nonce.make()
    @State private var error: String?
    @State private var working = false
    @State private var showDevSignIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Image(systemName: "book.pages")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 20)
            Text("Weeknotes")
                .font(.system(size: 44, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.ink)
            Text("Once a week, tell your friends how it went.")
                .font(Theme.body(22))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 16) {
                Principle(systemImage: "square.and.pencil", text: "Write, dictate or record a voice memo. About five minutes.")
                Principle(systemImage: "person.3", text: "Post once. It reaches every circle you choose.")
                Principle(systemImage: "books.vertical", text: "Every week saves to your own archive, even if you share it with no one.")
            }
            .padding(.top, 36)
            Spacer()

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.bottom, 10)
            }
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName]
                request.nonce = Nonce.sha256(nonce)
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 54)
            .clipShape(.capsule)
            .disabled(working)
            #if DEBUG
            Button("Developer sign-in") { showDevSignIn = true }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .accessibilityIdentifier("devSignIn")
            #endif
            Link("Privacy policy", destination: AppEnvironment.privacyPolicyURL)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryInk)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        #if DEBUG
        .sheet(isPresented: $showDevSignIn) {
            DevSignInView { onSignedIn() }
        }
        #endif
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code != .canceled { error = failure.localizedDescription }
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                error = "Apple didn't return a sign-in token. Try again."
                return
            }
            if let name = credential.fullName {
                suggestedName = PersonNameComponentsFormatter.localizedString(from: name, style: .default)
            }
            working = true
            Task {
                defer { working = false }
                do {
                    try await model.api?.signInWithApple(idToken: token, nonce: nonce)
                    nonce = Nonce.make()
                    onSignedIn()
                } catch {
                    self.error = friendlyMessage(error)
                }
            }
        }
    }
}

private struct Principle: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: systemImage).foregroundStyle(Theme.accent).frame(width: 24)
            Text(text).font(.body).foregroundStyle(Theme.ink)
        }
    }
}

#if DEBUG
/// Signs in the seeded local accounts (`scripts/seed-local.ts`). Not in Release builds.
struct DevSignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onSignedIn: () -> Void
    @State private var email = "ana@weeknotes.test"
    @State private var error: String?

    static let seeded = ["ana@weeknotes.test", "ben@weeknotes.test", "cal@weeknotes.test", "new@weeknotes.test", "nora@weeknotes.test"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Seeded accounts") {
                    ForEach(Self.seeded, id: \.self) { address in
                        Button(address) { signIn(address) }
                    }
                }
                Section("Other") {
                    TextField("Email", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    Button("Sign in or create") { signIn(email) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Developer sign-in")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func signIn(_ address: String) {
        Task {
            do {
                do {
                    try await model.api?.signIn(email: address, password: LaunchOptions.devPassword)
                } catch {
                    try await model.api?.signUp(email: address, password: LaunchOptions.devPassword)
                    try await model.api?.signIn(email: address, password: LaunchOptions.devPassword)
                }
                dismiss()
                onSignedIn()
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }
}
#endif

private struct ProfileStep: View {
    @Environment(AppModel.self) private var model
    let suggestedName: String
    let onDone: () -> Void
    @State private var name = ""
    @State private var timezone = TimeZone.current.identifier
    @State private var weekday = AppConfig.defaultReminderWeekday
    @State private var time = Calendar.current.date(from: DateComponents(hour: 18, minute: 0)) ?? Date()
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What should friends call you?")
                        .font(Theme.headingFont)
                    Text("This shows on your updates.").font(.subheadline).foregroundStyle(Theme.secondaryInk)
                }
                .listRowBackground(Color.clear)
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .focused($nameFocused)
                    .accessibilityIdentifier("nameField")
            }
            Section {
                TimeZonePicker(identifier: $timezone)
            } header: {
                Text("Time zone")
            } footer: {
                Text("Your week runs Monday to Sunday here. Posts before Monday noon still count for the week before.")
            }
            Section {
                ReminderPicker(weekday: $weekday, time: $time)
            } header: {
                Text("Weekly reminder")
            } footer: {
                Text("We'll nudge you once a week, only if you haven't posted yet.")
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Your profile")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                    .accessibilityIdentifier("profileContinue")
            }
        }
        .onAppear {
            if name.isEmpty { name = suggestedName }
            nameFocused = name.isEmpty
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let components = Calendar.current.dateComponents([.hour, .minute], from: time)
                try await model.api?.createProfile(
                    name: name.trimmingCharacters(in: .whitespaces),
                    timezone: timezone,
                    reminderWeekday: weekday,
                    reminderTime: String(format: "%02d:%02d", components.hour ?? 18, components.minute ?? 0)
                )
                await model.refreshProfile()
                onDone()
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }
}

struct TimeZonePicker: View {
    @Binding var identifier: String

    var body: some View {
        NavigationLink {
            TimeZoneList(selection: $identifier)
        } label: {
            LabeledContent("Time zone", value: Self.label(identifier))
        }
    }

    static func label(_ identifier: String) -> String {
        let city = identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
        let abbreviation = TimeZone(identifier: identifier)?.abbreviation() ?? ""
        return abbreviation.isEmpty ? city : "\(city) (\(abbreviation))"
    }
}

private struct TimeZoneList: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var zones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") }
        guard !search.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(search.replacingOccurrences(of: " ", with: "_")) }
    }

    var body: some View {
        List(zones, id: \.self) { zone in
            Button {
                selection = zone
                dismiss()
            } label: {
                HStack {
                    Text(TimeZonePicker.label(zone)).foregroundStyle(Theme.ink)
                    Spacer()
                    if zone == selection { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                }
            }
        }
        .searchable(text: $search, prompt: "City")
        .navigationTitle("Time zone")
    }
}

struct ReminderPicker: View {
    @Binding var weekday: Int
    @Binding var time: Date

    var body: some View {
        Picker("Day", selection: $weekday) {
            ForEach(0..<7, id: \.self) { day in
                Text(Calendar.current.weekdaySymbols[day]).tag(day)
            }
        }
        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
    }
}

private struct PhoneStep: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void
    @State private var number = ""
    @State private var code = ""
    @State private var sentTo: String?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add your phone number").font(Theme.headingFont)
                    Text("Friends who have your number in their contacts can find you. We keep only a scrambled (hashed) version, and your number is never shown to anyone.")
                        .font(.subheadline).foregroundStyle(Theme.secondaryInk)
                }
                .listRowBackground(Color.clear)
            }
            if let sentTo {
                Section("Code sent to \(sentTo)") {
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("codeField")
                    Button("Verify") { verify(sentTo) }.disabled(code.count < 6 || working)
                }
            } else {
                Section {
                    TextField("Phone number", text: $number)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .accessibilityIdentifier("phoneField")
                    Button("Send code") { send() }.disabled(number.filter(\.isNumber).count < 7 || working)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Phone")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Skip", action: onDone).accessibilityIdentifier("phoneSkip")
            }
        }
    }

    private func send() {
        guard let e164 = PhoneNumber.e164(number, region: Locale.current.region?.identifier) else {
            error = "That doesn't look like a full phone number. Include the area code."
            return
        }
        working = true
        Task {
            defer { working = false }
            do {
                try await model.api?.startPhoneVerification(e164: e164)
                sentTo = e164
                error = nil
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }

    private func verify(_ e164: String) {
        working = true
        Task {
            defer { working = false }
            do {
                try await model.api?.confirmPhone(e164: e164, code: code)
                await model.refreshProfile()
                onDone()
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }
}

private struct ContactsStep: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Find your friends").font(Theme.titleFont).foregroundStyle(Theme.ink)
            Text("Weeknotes can check your contacts for friends who are already here. Numbers are scrambled on your phone before anything is sent, and nothing is stored.")
                .foregroundStyle(Theme.secondaryInk)
            FindFriendsView(compact: true)
            Spacer()
        }
        .padding(24)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Next", action: onDone).accessibilityIdentifier("contactsNext")
            }
        }
    }
}

private struct RemindersStep: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void

    var reminderText: String {
        guard let profile = model.profile else { return "once a week" }
        let day = Calendar.current.weekdaySymbols[profile.reminderWeekday]
        let time = Calendar.current.date(from: profile.reminderComponents)?.formatted(date: .omitted, time: .shortened) ?? ""
        return "\(day) at \(time)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: "bell.badge").font(.system(size: 44, weight: .light)).foregroundStyle(Theme.accent)
            Text("A nudge, once a week").font(Theme.titleFont).foregroundStyle(Theme.ink)
            Text("On \(reminderText) we'll remind you that your week is ready to write, unless you've already posted.")
                .foregroundStyle(Theme.secondaryInk)
            Spacer()
            Button {
                Task {
                    _ = await PushService.shared.requestPermission()
                    onDone()
                }
            } label: {
                Text("Turn on reminders").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("enableReminders")
            Button("Not now", action: onDone)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("remindersNotNow")
        }
        .padding(28)
    }
}
