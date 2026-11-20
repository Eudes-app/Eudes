import AVFoundation
import Foundation

/// A session owns one real microphone stream from prepare() until stop().
/// Only listen() retains audio; speech output and model waiting discard it.
@MainActor
protocol BackgroundVoiceAudioService: AnyObject {
    func preflight() throws
    func prepare(onInterruption: @escaping @MainActor () -> Void) async throws
    func speak(_ text: String) async throws
    func listen() async throws -> String
    func listen(onLevel: @escaping @MainActor (Float) -> Void) async throws -> String
    func setVisualFeedbackEnabled(_ enabled: Bool)
    func startThinkingSound() async
    func stopThinkingSound()
    func stop()
}

extension BackgroundVoiceAudioService {
    func listen(onLevel: @escaping @MainActor (Float) -> Void) async throws -> String {
        try await listen()
    }
    func setVisualFeedbackEnabled(_ enabled: Bool) {}
}

@MainActor
final class SystemBackgroundVoiceAudio: NSObject, BackgroundVoiceAudioService, AVSpeechSynthesizerDelegate {
    private struct Playback {
        let id: UUID
        let utteranceID: ObjectIdentifier
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct Listening {
        let id: UUID
        let continuation: CheckedContinuation<String, Error>
        var ending = false
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let thinkingSound = VoiceThinkingSound()
    private let router = BackgroundVoiceCaptureRouter()
    private var engine: AVAudioEngine?
    private var sessionID: UUID?
    private var sampleRate: Double = 0
    private var playback: Playback?
    private var listening: Listening?
    private var playbackTimer: Task<Void, Never>?
    private var listeningTimer: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var transcription: LocalVoiceTranscription?
    private var meterUpdate: (@MainActor (Float) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var interruption: (@MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func preflight() throws {
        // A background launch must never try to present a permission prompt.
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw VoiceAssistantError.microphoneDenied
        }
        try LocalVoiceTranscription().preflight()
    }

    func prepare(onInterruption: @escaping @MainActor () -> Void) async throws {
        try preflight()
        guard sessionID == nil else { throw VoiceAssistantError.interrupted }
        let selected = LocalVoiceTranscription()
        transcription = selected
        let id = UUID()
        sessionID = id
        interruption = onInterruption
        do {
            // Siri can still be releasing its audio session when perform() starts.
            // This short retry never changes permissions or tries another audio category.
            for attempt in 0..<4 {
                do {
                    try await BackgroundVoiceAudioSession.shared.activate(id: id)
                    break
                } catch {
                    guard attempt < 3 else { throw VoiceAssistantError.audioUnavailable }
                    try await Task.sleep(for: .milliseconds(350))
                    try ensureSession(id)
                }
            }
            try ensureSession(id)
            let audioEngine = AVAudioEngine()
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceAssistantError.audioUnavailable
            }
            sampleRate = format.sampleRate
            let captureRouter = router
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                captureRouter.append(buffer)
            }
            engine = audioEngine
            audioEngine.prepare()
            try audioEngine.start()
            installObservers(sessionID: id)
            // Background launches only use models already installed on this iPhone.
            try await selected.prepareForBackgroundUse()
            try ensureSession(id)
        } catch {
            if sessionID == id { stop() }
            await BackgroundVoiceAudioSession.shared.deactivate(id: id)
            if error is CancellationError || error is VoiceAssistantError || error is AppleSpeechError { throw error }
            throw VoiceAssistantError.audioUnavailable
        }
    }

    func speak(_ text: String) async throws {
        stopThinkingSound()
        guard let session = sessionID, engine?.isRunning == true,
              playback == nil, listening == nil else { throw VoiceAssistantError.audioUnavailable }
        try Task.checkCancellation()
        router.discard()
        if SpeechOutputEngine.selected() == .pocketTTS {
            do {
                try await withTaskCancellationHandler {
                    try await PocketTTSModelManager.shared.speak(text, rate: VoiceOutputSettings.storedRate(), executionMode: .background)
                } onCancel: {
                    Task { @MainActor in PocketTTSModelManager.shared.cancelSpeak() }
                }
                return
            } catch {
                guard PocketTTSModelManager.permitsSystemFallback(for: error) else { throw error }
                PocketTTSModelManager.shared.recordSpeechFailure(error)
            }
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled, sessionID == session else {
                    continuation.resume(throwing: CancellationError()); return
                }
                let utterance = VoiceOutputSettings.makeUtterance(text: text)
                playback = Playback(id: id, utteranceID: ObjectIdentifier(utterance), continuation: continuation)
                synthesizer.speak(utterance)
                let speedFactor = Double(AVSpeechUtteranceDefaultSpeechRate / utterance.rate)
                let timeout = min(600.0, max(12.0, 12.0 + Double(text.count) / 6 * speedFactor))
                playbackTimer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.completePlayback(id: id, result: .failure(VoiceAssistantError.audioUnavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.completePlayback(id: id, result: .failure(CancellationError()))
            }
        }
    }

    func listen() async throws -> String {
        try await listen(onLevel: { _ in })
    }

    func setVisualFeedbackEnabled(_ enabled: Bool) {
        router.setMeteringEnabled(enabled)
    }

    func listen(onLevel: @escaping @MainActor (Float) -> Void) async throws -> String {
        stopThinkingSound()
        guard let session = sessionID, engine?.isRunning == true,
              playback == nil, listening == nil else { throw VoiceAssistantError.audioUnavailable }
        // Let the final output buffers drain before retaining microphone samples.
        try await Task.sleep(for: .milliseconds(250))
        try ensureSession(session)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                guard !Task.isCancelled, sessionID == session else {
                    continuation.resume(throwing: CancellationError()); return
                }
                listening = Listening(id: id, continuation: continuation)
                meterUpdate = onLevel
                router.begin(id: id, sampleRate: sampleRate, onLevel: { [weak self] measuredID, level in
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == session,
                              self.listening?.id == measuredID, self.listening?.ending == false else { return }
                        onLevel(level)
                    }
                }) { [weak self] completedID in
                    Task { @MainActor [weak self] in self?.finishListening(id: completedID) }
                }
                listeningTimer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    guard let self, self.listening?.id == id else { return }
                    if !self.router.heardSpeech(id: id) {
                        self.completeListening(id: id, result: .failure(VoiceAssistantError.noSpeech))
                        return
                    }
                    do { try await Task.sleep(for: .seconds(33)) } catch { return }
                    self.finishListening(id: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.completeListening(id: id, result: .failure(CancellationError()))
            }
        }
    }

    func startThinkingSound() async {
        guard !Task.isCancelled, sessionID != nil, engine?.isRunning == true,
              playback == nil, listening == nil else { return }
        // Reuse the live recording session and its selected output route.
        router.discard()
        thinkingSound.start()
    }

    func stopThinkingSound() { thinkingSound.stop() }

    func stop() {
        transcription = nil
        stopThinkingSound()
        let oldSession = sessionID
        sessionID = nil
        interruption = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        router.discard()
        if let active = listening { completeListening(id: active.id, result: .failure(CancellationError())) }
        if let active = playback { completePlayback(id: active.id, result: .failure(CancellationError())) }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        sampleRate = 0
        if let oldSession {
            Task { await BackgroundVoiceAudioSession.shared.deactivate(id: oldSession) }
        }
    }

    private func finishListening(id: UUID) {
        guard var active = listening, active.id == id, !active.ending else { return }
        active.ending = true
        listening = active
        meterUpdate?(0)
        listeningTimer?.cancel(); listeningTimer = nil
        guard let capture = router.take(id: id), capture.heardSpeech,
              let buffer = capture.finish() else {
            completeListening(id: id, result: .failure(VoiceAssistantError.noSpeech)); return
        }
        guard let transcription else {
            completeListening(id: id, result: .failure(VoiceAssistantError.localRecognitionUnavailable)); return
        }
        transcriptionTask = Task { @MainActor [weak self] in
            do {
                let text = try await transcription.transcribe(buffer)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard !text.isEmpty else { throw VoiceAssistantError.noSpeech }
                self?.completeListening(id: id, result: .success(text))
            } catch is CancellationError {
                self?.completeListening(id: id, result: .failure(CancellationError()))
            } catch let error as VoiceAssistantError {
                self?.completeListening(id: id, result: .failure(error))
            } catch let error as AppleSpeechError {
                self?.completeListening(id: id, result: .failure(error))
            } catch {
                self?.completeListening(id: id, result: .failure(VoiceAssistantError.recognitionFailed))
            }
        }
    }

    private func completeListening(id: UUID, result: Result<String, Error>) {
        guard let active = listening, active.id == id else { return }
        listening = nil
        meterUpdate?(0)
        meterUpdate = nil
        router.discard(id: id)
        listeningTimer?.cancel(); listeningTimer = nil
        transcriptionTask?.cancel(); transcriptionTask = nil
        active.continuation.resume(with: result)
    }

    private func completePlayback(id: UUID, result: Result<Void, Error>) {
        guard let active = playback, active.id == id else { return }
        playback = nil
        playbackTimer?.cancel(); playbackTimer = nil
        synthesizer.stopSpeaking(at: .immediate)
        active.continuation.resume(with: result)
    }

    private func ensureSession(_ id: UUID) throws {
        try Task.checkCancellation()
        guard sessionID == id else { throw CancellationError() }
    }

    private func installObservers(sessionID id: UUID) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: value) == .began else { return }
            Task { @MainActor [weak self] in self?.interrupt(id: id) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            guard let value = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: value),
                  reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory else { return }
            Task { @MainActor [weak self] in self?.interrupt(id: id) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }
                if self.engine?.isRunning != true || self.engine?.inputNode.outputFormat(forBus: 0).sampleRate != self.sampleRate {
                    self.interrupt(id: id)
                }
            }
        })
    }

    private func interrupt(id: UUID) {
        guard sessionID == id else { return }
        let callback = interruption
        stop()
        callback?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let active = self.playback, active.utteranceID == utteranceID else { return }
            self.completePlayback(id: active.id, result: .success(()))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let active = self.playback, active.utteranceID == utteranceID else { return }
            self.completePlayback(id: active.id, result: .failure(CancellationError()))
        }
    }
}

/// Serializes driver calls without blocking MainActor; an old stop cannot deactivate a new session.
private actor BackgroundVoiceAudioSession {
    static let shared = BackgroundVoiceAudioSession()
    private var owner: UUID?

    func activate(id: UUID) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        owner = id
    }

    func deactivate(id: UUID) {
        guard owner == id else { return }
        owner = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// The realtime tap only touches this lock-protected buffer router, never actor state.
/// A closed or previous turn cannot receive samples or signal completion for the next turn.
final class BackgroundVoiceCaptureRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UUID?
    private var capture: LocalVoiceCapture?
    private var ended = false
    private var onEnd: (@Sendable (UUID) -> Void)?
    private var onLevel: (@Sendable (UUID, Float) -> Void)?
    private var meteringEnabled = false

    func begin(id: UUID, sampleRate: Double,
               onLevel: (@Sendable (UUID, Float) -> Void)? = nil,
               onEnd: @escaping @Sendable (UUID) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.id = id
        capture = LocalVoiceCapture(sampleRate: sampleRate)
        ended = false
        self.onEnd = onEnd
        self.onLevel = onLevel
    }

    func setMeteringEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        meteringEnabled = enabled
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let id, let capture, !ended else { lock.unlock(); return }
        let update = meteringEnabled ? capture.appendAndMeasure(buffer) : .init(shouldFinish: capture.append(buffer), level: nil)
        let completed = update.shouldFinish
        if completed { ended = true }
        let callback = completed ? onEnd : nil
        let meterCallback = onLevel
        lock.unlock()
        if let level = update.level { meterCallback?(id, level) }
        callback?(id)
    }

    func heardSpeech(id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.id == id else { return false }
        return capture?.heardSpeech == true
    }

    func take(id: UUID) -> LocalVoiceCapture? {
        lock.lock(); defer { lock.unlock() }
        guard self.id == id else { return nil }
        let result = capture
        self.id = nil; capture = nil; ended = false; onEnd = nil; onLevel = nil
        return result
    }

    func discard(id: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let id, self.id != id { return }
        self.id = nil; capture = nil; ended = false; onEnd = nil; onLevel = nil
    }
}
