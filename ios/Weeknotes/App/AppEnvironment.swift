import Foundation

/// Where the app's backend lives, read from Info.plist (set per build configuration: Debug
/// points at the local Supabase stack, Release at production; see README).
nonisolated enum AppEnvironment {
    static let supabaseURL: URL? = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }()

    static let supabaseAnonKey: String = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String ?? ""

    static var isConfigured: Bool { supabaseURL != nil && !supabaseAnonKey.isEmpty }

    static var functionsURL: URL? { supabaseURL?.appending(path: "functions/v1") }

    /// The web reader that serves share links (`/u/{token}`).
    static let webReaderURL: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "WebReaderURL") as? String ?? "https://weeknotes-app.vercel.app"
        return URL(string: raw)!
    }()

    static let privacyPolicyURL = webReaderURL.appending(path: "privacy")
    static let supportURL = webReaderURL.appending(path: "support")

    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Debug launch arguments. `-uiTesting` clears local state at launch; `-signInAs <email>`
/// signs in a seeded local account with the shared dev password; `-dictationFixture <path>`
/// feeds an audio file to the dictation pipeline in real time instead of the microphone.
nonisolated enum LaunchOptions {
    static let arguments = ProcessInfo.processInfo.arguments

    static var isUITesting: Bool { arguments.contains("-uiTesting") }

    static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var signInAs: String? {
        #if DEBUG
        return value(after: "-signInAs")
        #else
        return nil
        #endif
    }

    static var dictationFixture: URL? {
        #if DEBUG
        return value(after: "-dictationFixture").map { URL(filePath: $0) }
        #else
        return nil
        #endif
    }

    /// Forces the on-device formatter off, to exercise the hosted fallback.
    static var disableOnDeviceFormatting: Bool {
        #if DEBUG
        return arguments.contains("-noOnDeviceFormatting")
        #else
        return false
        #endif
    }

    static let devPassword = "weeknotes-dev-password"
}
