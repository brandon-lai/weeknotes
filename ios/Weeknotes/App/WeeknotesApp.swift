import SwiftData
import SwiftUI

@main
struct WeeknotesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    private let container: ModelContainer

    init() {
        let container = EntryStore.container()
        self.container = container
        _model = State(initialValue: AppModel(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(container)
                .tint(Theme.accent)
                .onOpenURL { model.handle(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { model.handle(url: url) }
                }
                .task {
                    PushService.shared.start()
                    PushService.shared.onOpenCompose = { [model] in
                        model.selectedTab = .week
                        model.composerRequested = true
                    }
                    MemoPlayer.shared.onProgress = { [model] id, listened in
                        Task { await model.api?.markRead(id, listenedMs: listened) }
                    }
                    await model.start()
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        ZStack {
            switch model.phase {
            case .launching:
                LaunchView()
            case .welcome:
                WelcomeView()
            case .ready:
                MainView()
            }
        }
        .animation(.smooth, value: model.phase)
        .overlay(alignment: .top) { ToastView() }
        .sheet(isPresented: $model.accountFlowRequested) {
            AccountFlowView()
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back: upload anything saved offline, refresh reminders
            if phase == .active && model.phase == .ready {
                Task { await model.syncWeeks() }
            }
        }
    }
}

struct LaunchView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.pages")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Weeknotes").font(Theme.titleFont).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperBackground()
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            Label(toast.text, systemImage: toast.systemImage)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassSurface(.capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { model.toast = nil }
                }
                .onTapGesture { withAnimation { model.toast = nil } }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("This week", systemImage: "sun.max", value: AppModel.Tab.week) {
                FeedView()
            }
            Tab("Archive", systemImage: "books.vertical", value: AppModel.Tab.archive) {
                ArchiveView()
            }
            if model.isSignedIn {
                Tab("Replies", systemImage: "bubble.left.and.bubble.right", value: AppModel.Tab.inbox) {
                    InboxView()
                }
                .badge(model.unreadReplies)
                Tab("People", systemImage: "person.2", value: AppModel.Tab.people) {
                    PeopleView()
                }
                .badge(model.incomingRequests.count)
            } else {
                // Signed out: what an account adds, and the way in
                Tab("Friends", systemImage: "person.2", value: AppModel.Tab.people) {
                    FriendsPitchView()
                }
            }
        }
        .minimizeTabBarOnScroll()
        .fullScreenCover(isPresented: $model.composerRequested) {
            ComposerView()
        }
    }
}
