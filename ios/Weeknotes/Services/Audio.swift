@preconcurrency import AVFoundation
import MediaPlayer
import WeeknotesCore

enum AudioPermission {
    static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static var microphoneDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }
}

/// Records a voice memo: AAC, mono, 64 kbps, at most 5 minutes, with pause and resume and a
/// live level for the waveform (PRD §8, "Voice memo spec").
@Observable
final class MemoRecorder: NSObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle, recording, paused, finished
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Float] = []
    private(set) var fileURL: URL?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    var remaining: TimeInterval { max(0, AppConfig.memoMaxDuration - elapsed) }

    nonisolated static var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AppConfig.memoSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: AppConfig.memoBitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }

    func start(into folder: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let url = folder.appending(path: "memo-\(UUID().uuidString.prefix(8)).m4a")
        #if DEBUG
        // UI tests and the simulator: "record" a known file instead of the microphone
        if let fixture = LaunchOptions.value(after: "-memoFixture") {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: URL(filePath: fixture), to: url)
            fileURL = url
            elapsed = (try? AVAudioPlayer(contentsOf: url).duration) ?? 30
            levels = Waveform.summarize((try? Self.samples(of: url)) ?? [], buckets: 60)
            state = .finished
            return
        }
        #endif
        let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw TranscriptionError.failed("Couldn't start recording") }
        self.recorder = recorder
        fileURL = url
        elapsed = 0
        levels = []
        state = .recording
        startTimer()
    }

    func pause() {
        recorder?.pause()
        state = .paused
        timer?.invalidate()
    }

    func resume() {
        guard recorder?.record() == true else { return }
        state = .recording
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        if let recorder {
            elapsed = recorder.currentTime > 0 ? recorder.currentTime : elapsed
            recorder.stop()
        }
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .finished
    }

    /// Re-record: throw this take away.
    func discard() {
        timer?.invalidate()
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        elapsed = 0
        levels = []
        state = .idle
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        levels.append(Waveform.level(fromDecibels: recorder.averagePower(forChannel: 0)))
        if levels.count > 400 { levels.removeFirst(levels.count - 400) }
        if elapsed >= AppConfig.memoMaxDuration { stop() }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {}

    /// Mono float samples of an audio file, for the waveform summary.
    nonisolated static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return [] }
        _ = format
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    nonisolated static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

/// One memo plays at a time, app-wide, and keeps playing with the screen locked. Tracks how
/// far each listener got (read coverage metrics, PRD §8).
@Observable
final class MemoPlayer {
    static let shared = MemoPlayer()

    private(set) var currentID: UUID?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var rate: Float = 1 {
        didSet { if isPlaying { player?.rate = rate } }
    }

    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var furthest: [UUID: TimeInterval] = [:]
    /// Called with (update, furthest ms) when listening stops, to record progress.
    var onProgress: ((UUID, Int) -> Void)?

    static let rates: [Float] = [1, 1.5, 2]

    init() {
        configureRemoteCommands()
    }

    func progress(for id: UUID) -> Double {
        guard id == currentID, duration > 0 else { return 0 }
        return position / duration
    }

    func toggle(id: UUID, url: @escaping () async throws -> URL, duration: TimeInterval, title: String) async {
        if currentID == id, let player {
            if isPlaying { pause() } else {
                try? AVAudioSession.sharedInstance().setActive(true)
                player.playImmediately(atRate: rate)
                isPlaying = true
                updateNowPlaying()
            }
            return
        }
        reportProgress()
        do {
            let source = try await url()
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            load(source, id: id, duration: duration, title: title)
            player?.playImmediately(atRate: rate)
            isPlaying = true
            updateNowPlaying()
        } catch {
            isPlaying = false
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        reportProgress()
        updateNowPlaying()
    }

    func seek(to fraction: Double, id: UUID) {
        guard id == currentID, duration > 0 else { return }
        let target = max(0, min(1, fraction)) * duration
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        position = target
        updateNowPlaying()
    }

    func stopAll() {
        reportProgress()
        player?.pause()
        isPlaying = false
        currentID = nil
    }

    private func load(_ url: URL, id: UUID, duration: TimeInterval, title: String) {
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        currentID = id
        self.duration = duration
        position = 0
        nowPlayingTitle = title
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds
                if let id = self.currentID { self.furthest[id] = max(self.furthest[id] ?? 0, time.seconds) }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let id = self.currentID { self.furthest[id] = self.duration }
                self.isPlaying = false
                self.reportProgress()
                self.player?.seek(to: .zero)
                self.position = 0
            }
        }
    }

    private func reportProgress() {
        guard let id = currentID, let reached = furthest[id] else { return }
        onProgress?(id, Int(reached * 1000))
    }

    // MARK: Lock screen

    private var nowPlayingTitle = ""

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: "Weeknotes",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = currentID == nil ? nil : info
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return .commandFailed }
                player.playImmediately(atRate: self.rate)
                self.isPlaying = true
                self.updateNowPlaying()
                return .success
            }
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pause()
                return .success
            }
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let event = event as? MPChangePlaybackPositionCommandEvent, let id = self.currentID, self.duration > 0 else { return .commandFailed }
                self.seek(to: event.positionTime / self.duration, id: id)
                return .success
            }
        }
    }
}

/// Captures the microphone as a stream of buffers for live transcription. In DEBUG, a
/// `-dictationFixture` file plays in real time instead.
///
/// nonisolated on purpose: the tap block runs on the audio thread, and a closure formed in a
/// main-actor context would be main-actor isolated and trap there.
nonisolated final class MicrophoneStream: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var fixtureTask: Task<Void, Never>?

    /// Called on the main actor with a 0...1 level, for the live meter.
    func start(onLevel: @escaping @MainActor @Sendable (Float) -> Void) throws -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        lock.withLock { self.continuation = continuation }
        if let fixture = LaunchOptions.dictationFixture {
            let file = UnsafeTransfer(try AudioFileStream.buffers(from: fixture, realTime: true))
            fixtureTask = Task {
                for await buffer in file.value {
                    let handoff = UnsafeTransfer(buffer)
                    continuation.yield(handoff.value)
                    Task { @MainActor in onLevel(0.4) }
                }
                continuation.finish()
            }
            return stream
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            var sum: Float = 0
            if let data = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            }
            let rms = (sum / Float(max(1, buffer.frameLength))).squareRoot()
            let level = Waveform.level(fromDecibels: 20 * log10(max(rms, 0.000_01)))
            continuation.yield(buffer)
            Task { @MainActor in onLevel(level) }
        }
        engine.prepare()
        try engine.start()
        return stream
    }

    func stop() {
        fixtureTask?.cancel()
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
