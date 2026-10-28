import SwiftUI
import UserNotifications
import WeeknotesCore

/// First launch. No account: the app is a private weekly journal from the first tap. The only
/// question is whether you want a weekly nudge. Signing in is offered, not required.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0

    var body: some View {
        NavigationStack {
            Group {
                if step == 0 {
                    intro
                } else {
                    ReminderSetupView { model.finishWelcome() }
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .animation(.smooth, value: step)
            .paperBackground()
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Image(systemName: "book.pages")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 20)
            Text("Weeknotes")
                .font(.system(size: 44, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.ink)
            Text("Once a week, write down how it went.")
                .font(Theme.body(22))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 16) {
                Principle(systemImage: "square.and.pencil", text: "Type it, dictate it, or record a voice memo. About five minutes.")
                Principle(systemImage: "books.vertical", text: "Every week saves to your own archive, on this iPhone. No account needed.")
                Principle(systemImage: "person.2", text: "When you want to, connect with friends and share your weeks with the circles you choose.")
            }
            .padding(.top, 36)
            Spacer()

            Button {
                step = 1
            } label: {
                Text("Start writing").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .glassProminentButton()
            .accessibilityIdentifier("startWriting")
            if model.accountsAvailable {
                Button("I already have an account") { model.finishWelcome(signIn: true) }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                    .accessibilityIdentifier("haveAccount")
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
    }
}

struct Principle: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: systemImage).foregroundStyle(Theme.accent).frame(width: 24)
            Text(text).font(.body).foregroundStyle(Theme.ink)
        }
    }
}

/// The weekly nudge: a local notification, so it works without an account.
struct ReminderSetupView: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void
    @State private var weekday = AppConfig.defaultReminderWeekday
    @State private var time = Calendar.current.date(from: DateComponents(hour: 18, minute: 0)) ?? Date()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "bell.badge").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.accent)
                    Text("A nudge, once a week")
                        .font(.system(.title, design: .serif).weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Pick when your week usually winds down. We'll remind you then, and skip weeks you've already written.")
                        .foregroundStyle(Theme.secondaryInk)
                }
                .listRowBackground(Color.clear)
            }
            Section {
                ReminderPicker(weekday: $weekday, time: $time)
            }
            Section {
                Button {
                    Task {
                        save(enabled: true)
                        _ = await PushService.shared.requestPermission()
                        await LocalReminders.reschedule(context: model.context)
                        onDone()
                    }
                } label: {
                    Text("Remind me").font(.headline).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("enableReminders")
                Button("Not now") {
                    save(enabled: false)
                    onDone()
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("remindersNotNow")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func save(enabled: Bool) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        LocalReminders.settings = ReminderPlan.Settings(enabled: enabled, weekday: weekday, hour: c.hour ?? 18, minute: c.minute ?? 0)
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

/// The Friends tab before signing in: what an account adds, and the way in.
struct FriendsPitchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "person.2.wave.2")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 24)
                    Text("Share your weeks with friends")
                        .font(Theme.titleFont)
                        .foregroundStyle(Theme.ink)
                    VStack(alignment: .leading, spacing: 16) {
                        Principle(systemImage: "person.crop.circle.badge.plus", text: "Find friends from your contacts, or join from a link someone shares.")
                        Principle(systemImage: "circle.hexagongrid", text: "Group them into circles: college friends, family, the book club.")
                        Principle(systemImage: "paperplane", text: "Share a week with the circles you pick, and read theirs. Post once, instead of in five group chats.")
                        Principle(systemImage: "lock", text: "Your weeks stay private unless you share them. They're also backed up to your account.")
                    }
                    if model.accountsAvailable {
                        Button {
                            model.accountFlowRequested = true
                        } label: {
                            Text(model.account == .needsProfile ? "Finish setting up" : "Create an account or sign in")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .glassProminentButton()
                        .padding(.top, 8)
                        .accessibilityIdentifier("connectFriends")
                        Text("Free. Sign in with Apple; we never see your email if you hide it.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryInk)
                    } else {
                        Text("Sharing isn't available in this build.").foregroundStyle(Theme.secondaryInk)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .paperBackground()
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
