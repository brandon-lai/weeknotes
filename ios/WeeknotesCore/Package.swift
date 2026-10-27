// swift-tools-version: 6.2
import PackageDescription

// Everything in here is plain logic that the app, its tests, and `swift test` on a Mac share:
// the dictation pipeline (stages 2 to 5), week math, phone hashing, waveform summaries.
// The engines that need hardware (microphone, Apple Intelligence) sit behind protocols
// declared here, so tests can swap them for fakes.
let package = Package(
    name: "WeeknotesCore",
    // iOS 18 is the floor; SpeechAnalyzer and Foundation Models engines are marked iOS 26 and the
    // app falls back without them. Package tests run on macOS 26, where everything is available.
    platforms: [.iOS(.v18), .macOS(.v26)],
    products: [
        .library(name: "WeeknotesCore", targets: ["WeeknotesCore"]),
    ],
    targets: [
        .target(
            name: "WeeknotesCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "WeeknotesCoreTests",
            dependencies: ["WeeknotesCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
