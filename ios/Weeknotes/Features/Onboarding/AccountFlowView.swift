import AuthenticationServices
import SwiftData
import SwiftUI
import WeeknotesCore

/// Creating an account (or signing in) to connect with friends: Sign in with Apple, a name,
/// backing up the weeks already on this iPhone, then the optional phone number and contacts.
/// Opened from the Friends tab, Settings, or a share link.
struct AccountFlowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Step: Hashable {
        case signIn, profile, backup, phone, contacts
    }

    @State private var step: Step = .signIn
    @State private var suggestedName = ""

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .signIn:
                    SignInStep(suggestedName: $suggestedName) { Task { await afterSignIn() } }
                case .profile:
                    ProfileStep(suggestedName: suggestedName) { step = .backup }
                case .backup:
                    BackupStep { step = .phone }
                case .phone:
                    PhoneStep { step = .contacts }
                case .contacts:
                    ContactsStep { dismiss() }
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .animation(.smooth, value: step)
            .paperBackground()
            .toolbar {
                if step == .signIn {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Not now") { dismiss() }.accessibilityIdentifier("accountNotNow")
                    }
                }
            }
        }
        .interactiveDismissDisabled(step == .profile)
        .onAppear {
            if model.account == .needsProfile { step = .profile }
        }
    }

    private func afterSignIn() async {
        await model.loadProfile()
        switch model.account {
        case .needsProfile: step = .profile
        case .signedIn: step = .backup
        case .signedOut: break
        }
    }
}

// MARK: - Sign in

private struct SignInStep: View {
    @Environment(AppModel.self) private var model
    @Binding var suggestedName: String
    let onSignedIn: () -> Void
    @State private var nonce = Nonce.make()
    @State private var error: String?
    @State private var working = false
    @State private var showDevSignIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: "person.2.wave.2").font(.system(size: 46, weight: .light)).foregroundStyle(Theme.accent)
            Text("Connect with friends").font(Theme.titleFont).foregroundStyle(Theme.ink)
            Text("An account lets you find friends, put them in circles, and share your weeks with the circles you pick. Your weeks stay private unless you share them, and they're backed up to your account.")
                .foregroundStyle(Theme.secondaryInk)
            Spacer()
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
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
                .accessibilityIdentifier("devSignIn")
            #endif
            Link("Privacy policy", destination: AppEnvironment.privacyPolicyURL)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryInk)
                .frame(maxWidth: .infinity)
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

#if DEBUG
/// Signs in the seeded local accounts (`scripts/seed-local.ts`). Not in Release builds.
struct DevSignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onSignedIn: () -> Void
    @State private var email = "ana@weeknotes.test"
    @State private var error: String?

    static let seeded = ["ana@weeknotes.test", "ben@weeknotes.test", "cal@weeknotes.test", "new@weeknotes.test", "nora@weeknotes.test", "writer@weeknotes.test"]

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

// MARK: - Profile

private struct ProfileStep: View {
    @Environment(AppModel.self) private var model
    let suggestedName: String
    let onDone: () -> Void
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What should friends call you?").font(Theme.headingFont)
                    Text("This shows on the weeks you share.").font(.subheadline).foregroundStyle(Theme.secondaryInk)
                }
                .listRowBackground(Color.clear)
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .focused($nameFocused)
                    .accessibilityIdentifier("nameField")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Your name")
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
        let reminder = LocalReminders.settings
        Task {
            defer { saving = false }
            do {
                try await model.api?.createProfile(
                    name: name.trimmingCharacters(in: .whitespaces),
                    timezone: TimeZone.current.identifier,
                    reminderWeekday: reminder.weekday,
                    reminderTime: String(format: "%02d:%02d", reminder.hour, reminder.minute)
                )
                await model.loadProfile()
                onDone()
            } catch {
                self.error = friendlyMessage(error)
            }
        }
    }
}

// MARK: - Backup

/// The weeks already on this iPhone go to the account, privately.
private struct BackupStep: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void
    @State private var done = false

    var count: Int { EntryStore.saved(in: model.context).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: done ? "checkmark.icloud" : "icloud.and.arrow.up")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accent)
                .contentTransition(.symbolEffect(.replace))
            Text(done ? "You're all set" : "Backing up your weeks").font(Theme.titleFont).foregroundStyle(Theme.ink)
            Text(count == 0
                 ? "Weeks you write from now on are backed up to your account, privately."
                 : "Your \(count == 1 ? "week" : "\(count) weeks") on this iPhone \(done ? "are" : "are being") backed up to your account. Nobody sees them unless you share them.")
                .foregroundStyle(Theme.secondaryInk)
            if !done { ProgressView() }
            Spacer()
            Button {
                onDone()
            } label: {
                Text("Next: find friends").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .glassProminentButton()
            .disabled(!done)
            .accessibilityIdentifier("backupNext")
        }
        .padding(28)
        .task {
            await model.syncWeeks()
            withAnimation { done = true }
        }
    }
}

// MARK: - Phone and contacts

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
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Find your friends").font(Theme.titleFont).foregroundStyle(Theme.ink)
                Text("Weeknotes can check your contacts for friends who are already here. Numbers are scrambled on your phone before anything is sent, and nothing is stored.")
                    .foregroundStyle(Theme.secondaryInk)
                FindFriendsView(compact: true)
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone).accessibilityIdentifier("contactsNext")
            }
        }
    }
}

// MARK: - Shared pickers

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
