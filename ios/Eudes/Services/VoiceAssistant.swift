import AVFoundation
import Foundation
import Observation

/// A separate preference for spoken replies; server instructions remain unchanged.
enum VoiceResponseInstruction {
    static let preferenceKey = "voice.reply.instruction"
    static let defaultText = """
    You are Eudes, a voice assistant.

    Reply in the language of the user's request, unless they ask for another language.

    Answer directly in 1–2 short sentences, ideally under 30 words.

    Use natural spoken language. No emojis, Markdown, bullet points or tables.

    Add detail only when explicitly requested or essential for accuracy.
    """

    static func effectiveText(_ stored: String) -> String {
        let text = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? defaultText : text
    }

    static func selected(defaults: UserDefaults = .standard) -> String {
        effectiveText(defaults.string(forKey: preferenceKey) ?? "")
    }

    static func appending(to instructions: String, voiceInstruction: String) -> String {
        let voice = effectiveText(voiceInstruction)
        return instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? voice : instructions + "\n\n" + voice
    }
}

@MainActor
protocol LocalSpeechTranscribing: AnyObject {
    func preflight() throws
    func prepare(allowDownload: Bool) async throws
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String
}

/// Transcription is always Apple's on-device model; only foreground preparation
/// may fetch Apple's public language model.
@MainActor
final class LocalVoiceTranscription {
    private let backend: any LocalSpeechTranscribing

    init(apple: () -> any LocalSpeechTranscribing = { AppleSpeechModelManager.shared }) {
        backend = apple()
    }

    func preflight() throws { try backend.preflight() }

    func prepareForForegroundUse() async throws {
        try Task.checkCancellation()
        try await backend.prepare(allowDownload: true)
        try Task.checkCancellation()
    }

    func prepareForBackgroundUse() async throws {
        try Task.checkCancellation()
        try await backend.prepare(allowDownload: false)
        try Task.checkCancellation()
    }

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        try Task.checkCancellation()
        let text = try await backend.transcribe(buffer)
        try Task.checkCancellation()
        return text
    }
}

/// Shared by the assistant and the voice preview in settings.
enum VoiceOutputSettings {
    static let voiceIdentifierKey = "voice.reply.identifier"
    static let rateKey = "voice.reply.rate"
    static let minRate = 0.35
    static let maxRate = 0.6

    static func normalizedRate(_ rate: Double) -> Float {
        guard rate.isFinite else { return AVSpeechUtteranceDefaultSpeechRate }
        return Float(min(max(rate, minRate), maxRate))
    }

    static func makeUtterance(text: String, voiceIdentifier: String, rate: Double) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        let selectedVoice = voiceIdentifier.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        utterance.voice = selectedVoice ?? AVSpeechSynthesisVoice(language: "fr-FR")
        utterance.rate = normalizedRate(rate)
        return utterance
    }

    static func storedRate(defaults: UserDefaults = .standard) -> Double {
        (defaults.object(forKey: rateKey) as? NSNumber)?.doubleValue
            ?? Double(AVSpeechUtteranceDefaultSpeechRate)
    }

    static func makeUtterance(text: String, defaults: UserDefaults = .standard) -> AVSpeechUtterance {
        let identifier = defaults.string(forKey: voiceIdentifierKey) ?? ""
        let storedRate = (defaults.object(forKey: rateKey) as? NSNumber)?.doubleValue
            ?? Double(AVSpeechUtteranceDefaultSpeechRate)
        return makeUtterance(text: text, voiceIdentifier: identifier, rate: storedRate)
    }
}

@MainActor
protocol VoiceAudioService: AnyObject {
    var reportsListeningReadiness: Bool { get }
    func setListeningReadyHandler(_ handler: (@MainActor (Bool) -> Void)?)
    func requestPermissions() async throws
    func speak(_ text: String) async throws
    func listen(onPartial: @escaping @MainActor (String) -> Void) async throws -> String
    func setLevelHandler(_ handler: (@MainActor (Float) -> Void)?)
    func startThinkingSound() async
    func stopThinkingSound()
    func finishListening()
    func cancel()
}

extension VoiceAudioService {
    var reportsListeningReadiness: Bool { false }
    func setListeningReadyHandler(_ handler: (@MainActor (Bool) -> Void)?) { }

    // Services without microphone input can ignore level updates.
    func setLevelHandler(_ handler: (@MainActor (Float) -> Void)?) { }
}

enum VoiceAssistantError: LocalizedError {
    case microphoneDenied, speechDenied, recognitionUnavailable, localRecognitionUnavailable
    case noSpeech, recognitionFailed, audioUnavailable, interrupted, synthesisUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Autorise le microphone dans les réglages d'Eudes pour parler."
        case .speechDenied: "Autorise la reconnaissance vocale dans les réglages d'Eudes."
        case .recognitionUnavailable: "La reconnaissance vocale en français est indisponible. Réessaie plus tard."
        case .localRecognitionUnavailable: "La reconnaissance vocale locale en français n’est pas disponible sur cet iPhone."
        case .noSpeech: "Je n’ai pas entendu ta demande. Réessaie."
        case .recognitionFailed: "Je n’ai pas pu transcrire ta demande. Réessaie."
        case .audioUnavailable: "Le son ou le microphone est indisponible. Réessaie."
        case .interrupted: "L’assistant vocal a été interrompu. Réessaie quand tu es disponible."
        case .synthesisUnavailable: "La synthèse vocale locale n’est pas disponible. Télécharge le modèle PocketTTS dans Réglages → Assistant vocal."
        }
    }
}

@MainActor
@Observable
final class VoiceAssistantModel {
    enum Phase: Equatable {
        case idle, preparing, asking, listening, thinking, speaking, complete
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var response = ""
    private(set) var audioLevel: Float = 0
    private(set) var isMicrophoneReady = false
    @ObservationIgnored private let audio: any VoiceAudioService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var turnID: UUID?

    init(audio: any VoiceAudioService) {
        self.audio = audio
    }

    convenience init() {
        self.init(audio: SystemVoiceAudio())
    }

    func start(continuous: Bool = false,
               shouldContinue: @escaping @MainActor () -> Bool = { true },
               answer: @escaping @MainActor (String) async throws -> String) {
        cancel()
        let id = UUID()
        turnID = id
        transcript = ""
        response = ""
        phase = .preparing
        audio.setLevelHandler { [weak self] level in
            guard let self, self.turnID == id, self.phase == .listening else { return }
            self.audioLevel = min(1, max(0, level))
        }
        audio.setListeningReadyHandler { [weak self] ready in
            guard let self, self.turnID == id else { return }
            self.isMicrophoneReady = ready
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await audio.requestPermissions()
                try checkTurn(id)
                phase = .asking
                try await audio.speak("Que souhaites-tu faire ?")
                try checkTurn(id)
                repeat {
                    transcript = ""
                    isMicrophoneReady = !audio.reportsListeningReadiness
                    phase = .listening
                    let question: String
                    do {
                        question = try await audio.listen { [weak self] text in
                            guard let self, self.turnID == id else { return }
                            self.transcript = text
                        }.trimmingCharacters(in: .whitespacesAndNewlines)
                    } catch VoiceAssistantError.noSpeech where continuous {
                        try checkTurn(id)
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    audioLevel = 0
                    isMicrophoneReady = false
                    try checkTurn(id)
                    guard !question.isEmpty else { throw VoiceAssistantError.noSpeech }
                    transcript = question
                    if BackgroundVoiceSession.isStopCommand(question) {
                        response = "L’assistant vocal est arrêté."
                        try await audio.speak(response)
                        try checkTurn(id)
                        break
                    }
                    phase = .thinking
                    await audio.startThinkingSound()
                    try checkTurn(id)
                    let reply = try await answer(question)
                    try checkTurn(id)
                    audio.stopThinkingSound()
                    response = reply
                    phase = .speaking
                    try await audio.speak(reply)
                    try checkTurn(id)
                    if !continuous || !shouldContinue() { break }
                } while turnID == id
                audio.cancel()
                phase = .complete
                turnID = nil
                task = nil
            } catch is CancellationError {
                if turnID == id { cancel() }
            } catch {
                guard turnID == id, !Task.isCancelled else { return }
                DiagnosticLog.record(error, context: "reconnaissance vocale")
                audioLevel = 0
                audio.stopThinkingSound()
                let message: String
                if let shortcut = error as? EudesShortcutError {
                    message = String(localized: shortcut.localizedStringResource)
                } else if let voice = error as? VoiceAssistantError {
                    message = voice.localizedDescription
                } else if let apple = error as? AppleSpeechError {
                    message = apple.localizedDescription
                } else {
                    message = "Eudes n’a pas pu terminer la demande. Réessaie."
                }
                phase = .failed(message)
                // Audio errors and denied permissions can also prevent this explanation.
                try? await audio.speak(message)
                if turnID == id { turnID = nil; task = nil }
            }
        }
    }

    func finishListening() {
        guard phase == .listening else { return }
        audioLevel = 0
        audio.finishListening()
    }

    func cancel() {
        turnID = nil
        audioLevel = 0
        audio.setLevelHandler(nil)
        audio.setListeningReadyHandler(nil)
        isMicrophoneReady = false
        task?.cancel()
        task = nil
        audio.cancel()
        phase = .idle
    }

    func interrupt() {
        guard turnID != nil else { return }
        cancel()
        phase = .failed(VoiceAssistantError.interrupted.localizedDescription)
    }

    private func checkTurn(_ id: UUID) throws {
        try Task.checkCancellation()
        guard turnID == id else { throw CancellationError() }
    }
}

/// The audio never leaves the device for recognition. Network model requests
/// are made only after a final, non-empty transcription has been received.
@MainActor
final class SystemVoiceAudio: NSObject, VoiceAudioService, AVSpeechSynthesizerDelegate {
    private struct Playback {
        let id: UUID
        let utteranceID: ObjectIdentifier
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct Listening {
        let id: UUID
        let continuation: CheckedContinuation<String, Error>
        let onPartial: @MainActor (String) -> Void
        var latest = ""
        var ending = false
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let thinkingSound = VoiceThinkingSound()
    private var thinkingAudioID: UUID?
    private var engine: AVAudioEngine?
    private var capture: LocalVoiceCapture?
    private var transcriptionTask: Task<Void, Never>?
    private var playback: Playback?
    private var listening: Listening?
    private var playbackTimer: Task<Void, Never>?
    private var silenceTimer: Task<Void, Never>?
    private var deadlineTimer: Task<Void, Never>?
    private var hasTap = false
    private var levelHandler: (@MainActor (Float) -> Void)?
    private var transcription: LocalVoiceTranscription?
    private var heldPlaybackAudioID: UUID?
    private var listeningReadyHandler: (@MainActor (Bool) -> Void)?
    var reportsListeningReadiness: Bool { true }
    func setListeningReadyHandler(_ handler: (@MainActor (Bool) -> Void)?) { listeningReadyHandler = handler }


    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func setLevelHandler(_ handler: (@MainActor (Float) -> Void)?) {
        levelHandler = handler
    }

    func requestPermissions() async throws {
        let selected = LocalVoiceTranscription()
        try selected.preflight()
        guard await AVAudioApplication.requestRecordPermission() else { throw VoiceAssistantError.microphoneDenied }
        try Task.checkCancellation()
        try await selected.prepareForForegroundUse()
        try Task.checkCancellation()
        transcription = selected
    }

    func speak(_ text: String) async throws {
        stopThinkingSound()
        let id = UUID()
        do {
            try await VoiceAudioSession.shared.activate(id: id)
            try Task.checkCancellation()
            if SpeechOutputEngine.selected() == .pocketTTS {
                do {
                    try await withTaskCancellationHandler {
                        try await PocketTTSModelManager.shared.speak(text, rate: VoiceOutputSettings.storedRate())
                    } onCancel: {
                        Task { @MainActor in PocketTTSModelManager.shared.cancelSpeak() }
                    }
                    return
                } catch {
                    guard PocketTTSModelManager.permitsSystemFallback(for: error) else { throw error }
                    PocketTTSModelManager.shared.recordSpeechFailure(error)
                }
            }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    let utterance = VoiceOutputSettings.makeUtterance(text: text)
                    playback = Playback(id: id, utteranceID: ObjectIdentifier(utterance), continuation: continuation)
                    voiceQATrace("Demande de synthèse")
                    synthesizer.speak(utterance)
                    let speedFactor = Double(AVSpeechUtteranceDefaultSpeechRate / utterance.rate)
                    let timeout = min(600.0, max(12.0, 12.0 + Double(text.count) / 6 * speedFactor))
                    playbackTimer = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                        self?.expirePlayback(id: id)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelPlayback(id: id) }
            }
        } catch {
            await VoiceAudioSession.shared.deactivate(id: id)
            if error is CancellationError { throw error }
            throw VoiceAssistantError.audioUnavailable
        }
    }

    func listen(onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        stopThinkingSound()
        let id = UUID()
        do {
            try await VoiceAudioSession.shared.activate(id: id)
            try Task.checkCancellation()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    guard transcription != nil else {
                        continuation.resume(throwing: VoiceAssistantError.localRecognitionUnavailable); return
                    }
                    listening = Listening(id: id, continuation: continuation, onPartial: onPartial)
                    do {
                        let audioEngine = AVAudioEngine()
                        let input = audioEngine.inputNode
                        let format = input.outputFormat(forBus: 0)
                        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceAssistantError.audioUnavailable }
                        let recording = LocalVoiceCapture(sampleRate: format.sampleRate)
                        capture = recording
                        engine = audioEngine
                        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                            let update = recording.appendAndMeasure(buffer)
                            if let level = update.level {
                                Task { @MainActor [weak self] in
                                    guard let self, self.listening?.id == id, self.listening?.ending == false else { return }
                                    self.levelHandler?(level)
                                }
                            }
                            if update.shouldFinish {
                                Task { @MainActor [weak self] in
                                    guard self?.listening?.id == id else { return }
                                    self?.finishListening()
                                }
                            }
                        }
                        hasTap = true
                        audioEngine.prepare()
                        try audioEngine.start()
                        heldPlaybackAudioID = nil
                        listeningReadyHandler?(true)
                        scheduleListeningDeadline(id: id)
                    } catch {
                        completeListening(id: id, result: .failure(VoiceAssistantError.audioUnavailable))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelListening(id: id) }
            }
        } catch {
            await VoiceAudioSession.shared.deactivate(id: id)
            if error is CancellationError || error is VoiceAssistantError || error is AppleSpeechError { throw error }
            throw VoiceAssistantError.audioUnavailable
        }
    }

    func finishListening() {
        guard var active = listening, !active.ending else { return }
        active.ending = true
        listening = active
        levelHandler?(0)
        stopMicrophone()
        deadlineTimer?.cancel(); deadlineTimer = nil
        guard let capture, let buffer = capture.finish(), capture.heardSpeech else {
            completeListening(id: active.id, result: .failure(VoiceAssistantError.noSpeech))
            return
        }
        self.capture = nil
        guard let transcription else {
            completeListening(id: active.id, result: .failure(VoiceAssistantError.localRecognitionUnavailable))
            return
        }
        let id = active.id
        transcriptionTask = Task { @MainActor [weak self] in
            do {
                let text = try await transcription.transcribe(buffer)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard let self, self.listening?.id == id else { return }
                if text.isEmpty { self.completeListening(id: id, result: .failure(VoiceAssistantError.noSpeech)) }
                else {
                    self.listening?.onPartial(text)
                    self.completeListening(id: id, result: .success(text))
                }
            } catch is CancellationError {
                self?.completeListening(id: id, result: .failure(CancellationError()))
            } catch let error as AppleSpeechError {
                self?.completeListening(id: id, result: .failure(error))
            } catch {
                self?.completeListening(id: id, result: .failure(VoiceAssistantError.recognitionFailed))
            }
        }
    }

    func startThinkingSound() async {
        stopThinkingSound()
        let id = UUID()
        thinkingAudioID = id
        do {
            try Task.checkCancellation()
            try await VoiceAudioSession.shared.activate(id: id)
            try Task.checkCancellation()
            guard thinkingAudioID == id else {
                await VoiceAudioSession.shared.deactivate(id: id)
                return
            }
            thinkingSound.start()
        } catch {
            // Feedback is optional: an unavailable sound must not fail the API request.
            if thinkingAudioID == id { thinkingAudioID = nil }
            await VoiceAudioSession.shared.deactivate(id: id)
        }
    }

    func stopThinkingSound() {
        thinkingSound.stop()
        if let id = thinkingAudioID {
            thinkingAudioID = nil
            Task { await VoiceAudioSession.shared.deactivate(id: id) }
        }
    }

    func cancel() {
        listeningReadyHandler?(false)
        if let id = heldPlaybackAudioID {
            heldPlaybackAudioID = nil
            Task { await VoiceAudioSession.shared.deactivate(id: id) }
        }
        stopThinkingSound()
        transcription = nil
        if let active = playback { cancelPlayback(id: active.id) }
        if let active = listening { cancelListening(id: active.id) }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func scheduleListeningDeadline(id: UUID) {
        deadlineTimer?.cancel()
        deadlineTimer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.listening?.id == id else { return }
            if self.capture?.heardSpeech != true {
                self.completeListening(id: id, result: .failure(VoiceAssistantError.noSpeech))
                return
            }
            do { try await Task.sleep(for: .seconds(33)) } catch { return }
            guard self.listening?.id == id else { return }
            self.finishListening()
        }
    }

    private func stopMicrophone() {
        listeningReadyHandler?(false)
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
    }

    private func completeListening(id: UUID, result: Result<String, Error>) {
        guard let active = listening, active.id == id else { return }
        listening = nil
        levelHandler?(0)
        silenceTimer?.cancel(); silenceTimer = nil
        deadlineTimer?.cancel(); deadlineTimer = nil
        stopMicrophone()
        transcriptionTask?.cancel(); transcriptionTask = nil
        capture = nil; engine = nil
        Task {
            await VoiceAudioSession.shared.deactivate(id: id)
            active.continuation.resume(with: result)
        }
    }

    private func cancelListening(id: UUID) {
        completeListening(id: id, result: .failure(CancellationError()))
    }

    private func cancelPlayback(id: UUID) {
        guard let active = playback, active.id == id else { return }
        playback = nil
        playbackTimer?.cancel(); playbackTimer = nil
        synthesizer.stopSpeaking(at: .immediate)
        Task {
            await VoiceAudioSession.shared.deactivate(id: id)
            active.continuation.resume(throwing: CancellationError())
        }
    }

    private func finishPlayback(utteranceID: ObjectIdentifier, cancelled: Bool) {
        guard let active = playback, active.utteranceID == utteranceID else { return }
        playback = nil
        playbackTimer?.cancel(); playbackTimer = nil
        if cancelled {
            Task {
                await VoiceAudioSession.shared.deactivate(id: active.id)
                active.continuation.resume(throwing: CancellationError())
            }
        } else {
            // Keep the audio route warm until listen() takes ownership or cancel() releases it.
            heldPlaybackAudioID = active.id
            active.continuation.resume()
        }
    }

    private func expirePlayback(id: UUID) {
        guard let active = playback, active.id == id else { return }
        playback = nil
        playbackTimer?.cancel(); playbackTimer = nil
        synthesizer.stopSpeaking(at: .immediate)
        Task {
            await VoiceAudioSession.shared.deactivate(id: id)
            active.continuation.resume(throwing: VoiceAssistantError.audioUnavailable)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        voiceQATrace("Synthèse terminée")
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishPlayback(utteranceID: id, cancelled: false) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        voiceQATrace("Synthèse annulée")
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishPlayback(utteranceID: id, cancelled: true) }
    }

}

/// Short, spaced feedback for model waiting; never a continuous background audio loop.
@MainActor
protocol VoiceThinkingSoundOutput: AnyObject {
    func playPulse()
    func stop()
}

@MainActor
final class VoiceThinkingSound {
    private let output: any VoiceThinkingSoundOutput
    private let initialDelay: Duration
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(output: (any VoiceThinkingSoundOutput)? = nil,
         initialDelay: Duration = .milliseconds(400), interval: Duration = .seconds(4)) {
        self.output = output ?? VoiceThinkingTonePlayer()
        self.initialDelay = initialDelay
        self.interval = interval
    }

    func start() {
        stop()
        task = Task { @MainActor [output, initialDelay, interval] in
            do {
                try await Task.sleep(for: initialDelay)
                while !Task.isCancelled {
                    output.playPulse()
                    try await Task.sleep(for: interval)
                }
            } catch { /* stop() cancels both the pending pulse and current playback. */ }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        output.stop()
    }

    deinit { task?.cancel() }
}

@MainActor
private final class VoiceThinkingTonePlayer: VoiceThinkingSoundOutput {
    private var player: AVAudioPlayer?

    func playPulse() {
        if player == nil {
            player = try? AVAudioPlayer(data: VoiceThinkingTone.wavData)
            player?.volume = 0.3
        }
        player?.currentTime = 0
        player?.play()
    }

    func stop() { player?.stop() }
}

/// Original two-note PCM sound, generated in memory: no download or external audio asset.
enum VoiceThinkingTone {
    static let wavData: Data = {
        let sampleRate = 22_050
        let count = Int(Double(sampleRate) * 0.36)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func word(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func long(_ value: UInt32) {
            word(UInt16(truncatingIfNeeded: value))
            word(UInt16(truncatingIfNeeded: value >> 16))
        }
        text("RIFF"); long(UInt32(36 + count * 2)); text("WAVEfmt ")
        long(16); word(1); word(1); long(UInt32(sampleRate))
        long(UInt32(sampleRate * 2)); word(2); word(16)
        text("data"); long(UInt32(count * 2))
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let localTime = time < 0.18 ? time : time - 0.18
            let frequency = time < 0.18 ? 440.0 : 660.0
            let envelope = localTime < 0.12 ? pow(sin(.pi * localTime / 0.12), 2) : 0
            let value = Int16(0.22 * envelope * sin(2 * .pi * frequency * localTime) * Double(Int16.max))
            word(UInt16(bitPattern: value))
        }
        return data
    }()
}

/// Serialize audio-session changes off the main actor. The owner token prevents
/// a late cancellation from deactivating a newer voice session.
actor VoiceAudioSession {
    static let shared = VoiceAudioSession()
    private var owner: UUID?

    func activate(id: UUID) throws {
        if owner == id { return }
        let session = AVAudioSession.sharedInstance()
        voiceQATrace("Configuration de la session audio")
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        voiceQATrace("Activation de la session audio")
        try session.setActive(true)
        voiceQATrace("Session audio activée")
        owner = id
    }

    func activatePlayback(id: UUID) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        owner = id
    }

    func deactivate(id: UUID) {
        guard owner == id else { return }
        owner = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private func voiceQATrace(_ message: String) {
    #if DEBUG
    if ProcessInfo.processInfo.environment["EUDES_QA_VOICE"] == "speech" {
        NSLog("EUDES_VOICE_QA: %@", message)
    }
    #endif
}

/// One in-memory recording, without writing audio or transcript to disk.
final class LocalVoiceCapture: @unchecked Sendable {
    struct LevelUpdate {
        let shouldFinish: Bool
        let level: Float?
    }
    private let lock = NSLock()
    private let sampleRate: Double
    private var samples: [Float] = []
    private var speechDetected = false
    private var silentFrames = 0
    private var finished = false
    private var framesSinceLevel = 0
    private var smoothLevel: Float = 0

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    var heardSpeech: Bool {
        lock.lock(); defer { lock.unlock() }
        return speechDetected
    }

    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        append(buffer, measureLevel: false).shouldFinish
    }

    func appendAndMeasure(_ buffer: AVAudioPCMBuffer) -> LevelUpdate {
        append(buffer, measureLevel: true)
    }

    private func append(_ buffer: AVAudioPCMBuffer, measureLevel: Bool) -> LevelUpdate {
        guard let channel = buffer.floatChannelData?[0] else { return LevelUpdate(shouldFinish: false, level: nil) }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return LevelUpdate(shouldFinish: false, level: nil) }
        let chunk = UnsafeBufferPointer(start: channel, count: count)
        var energy: Float = 0
        for sample in chunk { energy += sample * sample }
        let rms = sqrt(energy / Float(count))
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return LevelUpdate(shouldFinish: false, level: nil) }
        // Bound memory even if the MainActor timer is delayed by model work.
        let maximumSamples = max(1, Int(sampleRate * 45))
        let remaining = max(0, maximumSamples - samples.count)
        samples.append(contentsOf: chunk.prefix(remaining))
        if rms > 0.012 {
            speechDetected = true
            silentFrames = 0
        } else if speechDetected {
            silentFrames += count
        }
        var level: Float?
        if measureLevel {
            // Report only a scalar at ~12 Hz. The captured PCM stays on device.
            // The same threshold controls the existing speech-end detection.
            framesSinceLevel += count
            if Double(framesSinceLevel) >= sampleRate / 12 {
                framesSinceLevel = 0
                let target = rms > 0.012 ? sqrt(min(1, max(0, (rms - 0.012) / 0.11))) : 0
                let factor: Float = target > smoothLevel ? 0.72 : 0.35
                smoothLevel += (target - smoothLevel) * factor
                if smoothLevel < 0.005 { smoothLevel = 0 }
                level = smoothLevel
            }
        }
        let shouldFinish = samples.count >= maximumSamples || (speechDetected && Double(silentFrames) >= sampleRate * 2.5)
        return LevelUpdate(shouldFinish: shouldFinish, level: level)
    }

    func finish() -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        finished = true
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { destination.update(from: base, count: source.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.removeAll(keepingCapacity: false)
        return buffer
    }
}

