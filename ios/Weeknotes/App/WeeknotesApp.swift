import SwiftData
import SwiftUI

@main
struct WeeknotesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    private let container = DraftStore.container()

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

    var body: some View {
        ZStack {
            switch model.phase {
            case .launching:
                LaunchView()
            case .notConfigured:
                NotConfiguredView()
            case .signedOut, .needsProfile:
                OnboardingView()
            case .ready:
                MainView()
            }
        }
        .animation(.smooth, value: model.phase)
        .overlay(alignment: .top) { ToastView() }
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

/// A Release build with no backend configured (see README) says so instead of failing oddly.
struct NotConfiguredView: View {
    var body: some View {
        ContentUnavailableView(
            "Weeknotes isn't set up",
            systemImage: "wrench.and.screwdriver",
            description: Text("This build has no server address. Set SUPABASE_URL and SUPABASE_ANON_KEY for the Release configuration.")
        )
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
                .glassEffect(.regular, in: .capsule)
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
            Tab("Replies", systemImage: "bubble.left.and.bubble.right", value: AppModel.Tab.inbox) {
                InboxView()
            }
            .badge(model.unreadReplies)
            Tab("People", systemImage: "person.2", value: AppModel.Tab.people) {
                PeopleView()
            }
            .badge(model.incomingRequests.count)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .fullScreenCover(isPresented: $model.composerRequested) {
            ComposerView()
        }
    }
}
