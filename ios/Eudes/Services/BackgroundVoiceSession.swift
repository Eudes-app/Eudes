import AppIntents
import Foundation
import Observation

enum BackgroundVoiceError: Error, CustomLocalizedStringResourceConvertible {
    case alreadyRunning, needsNewerSystem, couldNotStart

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .alreadyRunning: "L’assistant vocal Eudes est déjà en cours. Utilise Arrêter avant de le relancer."
        case .needsNewerSystem: "Le lancement vocal en arrière-plan nécessite iOS 18 ou une version ultérieure."
        case .couldNotStart: "iOS n’a pas permis de démarrer l’assistant vocal en arrière-plan. Consulte les réglages vocaux d'Eudes lorsque tu es disponible."
        }
    }
}

private struct BackgroundVoiceLaunchError: Error, CustomLocalizedStringResourceConvertible {
    let explanation: String
    var localizedStringResource: LocalizedStringResource { "\(explanation)" }
}

/// A conversation independent from SwiftUI and from the protected chat store.
/// Only the explicit Siri opt-in snapshot can be used while the phone is locked.
@MainActor
@Observable
final class BackgroundVoiceSession {
    static let shared: BackgroundVoiceSession = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--lue-isolated-qa"),
           ProcessInfo.processInfo.environment["EUDES_QA_BACKGROUND_VOICE"] == "1" {
            let id = UUID()
            return BackgroundVoiceSession(audio: BackgroundVoicePreviewAudio(), activity: VoiceActivityController(),
                backend: .init(begin: { id }, answer: { _, _, _ in "Réponse fictive hors ligne" }, end: { _ in }, isValid: { $0 == id }),
                defaults: UserDefaults(suiteName: "EudesBackgroundVoiceQA")!)
        }
        #endif
        return BackgroundVoiceSession(audio: SystemBackgroundVoiceAudio(), activity: VoiceActivityController(), backend: .live)
    }()
    static let didEnd = Notification.Name("EudesBackgroundVoiceSessionDidEnd")
    static let lastErrorKey = "voice.background.lastError"

    struct Backend {
        var begin: @MainActor () throws -> UUID
        var answer: @MainActor (String, UUID, @escaping @MainActor (Bool) -> Void) async throws -> String
        var end: @MainActor (UUID) -> Void
        var isValid: @MainActor (UUID) -> Bool
        // Optional keeps lightweight and older backends source-compatible.
        var answerWithTrace: (@MainActor (String, UUID, @escaping @MainActor (Bool) -> Void,
            @escaping @MainActor (WebResearchTrace) -> Void) async throws -> String)? = nil

        static var live: Self {
            let service = SiriAssistantService.shared
            return Self(begin: service.beginVoiceConversation,
                        answer: { try await service.answerVoice($0, conversationID: $1, onWebSearchProgress: $2) },
                        end: service.endVoiceConversation,
                        isValid: service.isVoiceConversationValid,
                        answerWithTrace: { try await service.answerVoice($0, conversationID: $1,
                            onWebSearchProgress: $2, onWebResearchTrace: $3) })
        }
    }

    private(set) var sessionID: UUID?
    private(set) var phase: VoiceActivityPhase = .preparing
    private(set) var lastError: String?
    private(set) var audioLevel: Float = 0
    private(set) var isSearchingWeb = false
    private(set) var webResearchTrace: WebResearchTrace?
    private(set) var transcript = ""
    private(set) var response = ""
    private(set) var pendingQuestion: String?
    private(set) var pendingAction: VoiceAction?
    private(set) var actionNeedsConfirmation = true
    private(set) var isWaitingForAction = false
    private(set) var actionExecutionClaimed = false
    @ObservationIgnored private var actionResolutionID: UUID?
    @ObservationIgnored private var foregroundActionHandler: (@MainActor (String) async throws -> String?)?

    func setActionHandler(for id: UUID, _ handler: (@MainActor (String) async throws -> String?)?) {
        guard sessionID == id else { return }
        foregroundActionHandler = handler
    }

    func propose(_ action: VoiceAction, confirmation: Bool, for id: UUID) throws {
        try check(id)
        pendingAction = try action.validated()
        actionExecutionClaimed = false
        actionNeedsConfirmation = confirmation
    }

    func claimAutomaticAction(for id: UUID) -> VoiceAction? {
        guard sessionID == id, isWaitingForAction, pendingQuestion == nil,
              !actionNeedsConfirmation, !actionExecutionClaimed, let action = pendingAction else { return nil }
        actionExecutionClaimed = true
        return action
    }

    func releaseAutomaticAction(for id: UUID) {
        guard sessionID == id else { return }
        actionExecutionClaimed = false
        actionNeedsConfirmation = true
    }

    func completeAction(for id: UUID, result: String) {
        guard sessionID == id else { return }
        pendingAction = nil
        pendingQuestion = nil
        actionExecutionClaimed = false
        response = result
    }

    func resolvePendingAction(for id: UUID) async {
        guard sessionID == id, isWaitingForAction, actionResolutionID == nil,
              let question = pendingQuestion, let handler = foregroundActionHandler else { return }
        let resolutionID = UUID()
        actionResolutionID = resolutionID
        defer { if actionResolutionID == resolutionID { actionResolutionID = nil } }
        do {
            let result = try await handler(question)
            try check(id)
            pendingQuestion = nil
            response = result ?? "Reformule ta demande d’action."
        } catch is CancellationError { }
        catch VoiceActionError.foreground { }
        catch {
            guard sessionID == id else { return }
            pendingQuestion = nil
            response = error.localizedDescription
        }
    }

    var isRunning: Bool { sessionID != nil }

    @ObservationIgnored private let audio: any BackgroundVoiceAudioService
    @ObservationIgnored private let activity: any VoiceActivityManaging
    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let maximumDuration: Duration
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var consentMonitor: Task<Void, Never>?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var visualFeedbackVisible = false
    @ObservationIgnored private var activeAnswerID: UUID?

    init(audio: any BackgroundVoiceAudioService, activity: any VoiceActivityManaging,
         backend: Backend, maximumDuration: Duration = .seconds(600),
         defaults: UserDefaults = .standard) {
        self.audio = audio; self.activity = activity; self.backend = backend
        self.maximumDuration = maximumDuration; self.defaults = defaults
        lastError = defaults.string(forKey: Self.lastErrorKey)
    }

    func start() async throws {
        guard sessionID == nil, !stopping, !starting else { throw BackgroundVoiceError.alreadyRunning }
        starting = true
        defer { starting = false }
        let id: UUID
        do {
            try audio.preflight()
            id = try backend.begin()
        } catch {
            let message = Self.message(for: error)
            if !(error is CancellationError) { recordError(message) }
            if error is CancellationError { throw error }
            throw BackgroundVoiceLaunchError(explanation: message)
        }
        sessionID = id
        transcript = ""
        response = ""
        pendingQuestion = nil
        pendingAction = nil
        isWaitingForAction = false
        actionExecutionClaimed = false
        actionResolutionID = nil
        phase = .preparing
        isSearchingWeb = false
        webResearchTrace = nil
        clearError()
        installGuards(id)
        do {
            try await activity.start(sessionID: id) { [weak self] in
                Task { await self?.stop(sessionID: id) }
            }
            try check(id)
            try await audio.prepare { [weak self] in
                Task { await self?.interrupted(sessionID: id) }
            }
            try check(id)
            runner = Task { [weak self] in await self?.run(id) }
        } catch {
            let message = Self.message(for: error)
            if !(error is CancellationError) { recordError(message) }
            if sessionID == id {
                await stop(sessionID: id)
            } else {
                // stop() may run while Activity.request or audio preparation is awaiting.
                // New starts are gated until this cleanup is complete.
                audio.stop()
                backend.end(id)
                await activity.end()
            }
            if error is CancellationError { throw error }
            throw BackgroundVoiceLaunchError(explanation: message)
        }
    }

    private func installGuards(_ id: UUID) {
        deadline = Task { [weak self, maximumDuration] in
            do { try await Task.sleep(for: maximumDuration) } catch { return }
            await self?.stop(sessionID: id)
        }
        consentMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.sessionID == id else { return }
                if !self.backend.isValid(id) {
                    self.recordError(String(localized: SiriAssistantError.configurationChanged.localizedStringResource))
                    await self.stop(sessionID: id)
                    return
                }
            }
        }
    }

    func stop() async {
        guard let id = sessionID else { return }
        await stop(sessionID: id)
    }

    /// A stale Live Activity must never stop a newer session.
    func stop(sessionID id: UUID) async {
        guard sessionID == id, !stopping else { return }
        stopping = true
        webResearchTrace?.cancelUnfinished()
        sessionID = nil
        foregroundActionHandler = nil
        pendingAction = nil
        pendingQuestion = nil
        isWaitingForAction = false
        actionExecutionClaimed = false
        actionResolutionID = nil
        audioLevel = 0
        isSearchingWeb = false
        activeAnswerID = nil
        visualFeedbackVisible = false
        audio.setVisualFeedbackEnabled(false)
        runner?.cancel(); runner = nil
        deadline?.cancel(); deadline = nil
        consentMonitor?.cancel(); consentMonitor = nil
        audio.stop()
        backend.end(id)
        await activity.end()
        stopping = false
        NotificationCenter.default.post(name: Self.didEnd, object: nil)
    }

    private func interrupted(sessionID id: UUID) async {
        guard sessionID == id else { return }
        recordError(String(localized: "La session vocale a été interrompue par iOS ou par un changement de sortie audio."))
        await stop(sessionID: id)
    }

    private func run(_ id: UUID) async {
        do {
            try check(id)
            await setPhase(.speaking)
            try check(id)
            try await audio.speak(String(localized: "Je t’écoute. Pour terminer, dis : arrête Eudes."))
            while sessionID == id {
                try check(id)
                await setPhase(.listening)
                try check(id)
                let question: String
                do {
                    question = try await audio.listen(onLevel: { [weak self] level in
                    guard let self, self.sessionID == id, self.phase == .listening,
                          self.visualFeedbackVisible else { return }
                    self.audioLevel = level
                }).trimmingCharacters(in: .whitespacesAndNewlines)
                } catch VoiceAssistantError.noSpeech {
                    try check(id)
                    continue
                }
                try check(id)
                transcript = question
                if Self.isStopCommand(question) { break }
                guard !question.isEmpty else { continue }
                await setPhase(.thinking)
                try check(id)
                await audio.startThinkingSound()
                try check(id)
                let reply = try await answer(question, sessionID: id)
                try check(id)
                response = reply
                audio.stopThinkingSound()
                await setPhase(.speaking)
                try check(id)
                try await audio.speak(reply)
                if pendingQuestion != nil || pendingAction != nil {
                    isWaitingForAction = true
                    await setPhase(.waiting)
                    while pendingQuestion != nil || pendingAction != nil {
                        try check(id)
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    isWaitingForAction = false
                }
            }
        } catch is CancellationError {
            // stop() tears down the microphone, network request and activity together.
        } catch {
            guard sessionID == id else { return }
            audio.stopThinkingSound()
            let message = Self.message(for: error)
            if (error as? VoiceAssistantError) != .noSpeech { recordError(message) }
            // Only speak an error while consent is still valid.
            if backend.isValid(id) {
                await setPhase(.speaking)
                try? await audio.speak(message)
            }
        }
        await stop(sessionID: id)
    }

    private func answer(_ question: String, sessionID id: UUID) async throws -> String {
        if let handler = foregroundActionHandler {
            do {
                if let reply = try await handler(question) { return reply }
            } catch VoiceActionError.foreground {
                try check(id)
                pendingQuestion = question
                return "Touche l’activité Eudes pour continuer cette action."
            } catch let error as VoiceActionError { return error.localizedDescription }
            catch is DecodingError { return VoiceActionError.invalid.localizedDescription }
        }
        try check(id)
        if VoiceAction.requiresForeground(question) {
            pendingQuestion = question
            return "Touche l’activité Eudes pour ouvrir l’interface et continuer cette action."
        }
        let answerID = UUID()
        activeAnswerID = answerID
        webResearchTrace = nil
        defer {
            // A cancelled backend may resume after another session or turn has begun.
            if sessionID == id, activeAnswerID == answerID {
                activeAnswerID = nil
                isSearchingWeb = false
            }
        }
        let onProgress: @MainActor (Bool) -> Void = { [weak self] searching in
            guard let self, self.sessionID == id, self.activeAnswerID == answerID,
                  self.phase == .thinking else { return }
            self.isSearchingWeb = searching
        }
        if let answerWithTrace = backend.answerWithTrace {
            return try await answerWithTrace(question, id, onProgress) { [weak self] trace in
                guard let self, self.sessionID == id, self.activeAnswerID == answerID,
                      self.phase == .thinking else { return }
                self.webResearchTrace = trace
            }
        }
        return try await backend.answer(question, id, onProgress)
    }

    private func setPhase(_ value: VoiceActivityPhase) async {
        phase = value
        if value != .listening { audioLevel = 0 }
        if value != .thinking { isSearchingWeb = false }
        await activity.update(phase: value)
    }

    /// The audio stream is already running; this toggles only optional visual metering.
    func setVisualFeedbackVisible(_ visible: Bool, for id: UUID) {
        guard sessionID == id else { return }
        visualFeedbackVisible = visible
        audio.setVisualFeedbackEnabled(visualFeedbackVisible)
        if !visualFeedbackVisible { audioLevel = 0 }
    }

    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard sessionID == id else { throw CancellationError() }
        guard backend.isValid(id) else { throw SiriAssistantError.configurationChanged }
    }

    static func isStopCommand(_ text: String) -> Bool {
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return ["stop", "arrete", "arrete eudes", "stop eudes", "arrete l assistant", "arrete l assistant vocal", "ferme l assistant"].contains(normalized)
    }

    private func clearError() {
        lastError = nil
        defaults.removeObject(forKey: Self.lastErrorKey)
    }

    private func recordError(_ text: String) {
        lastError = text
        defaults.set(text, forKey: Self.lastErrorKey)
    }

    static func message(for error: Error) -> String {
        if let error = error as? any CustomLocalizedStringResourceConvertible { return String(localized: error.localizedStringResource) }
        if let error = error as? VoiceAssistantError { return error.localizedDescription }
        if let error = error as? AppleSpeechError { return error.localizedDescription }
        return String(localized: "L’assistant vocal n’a pas pu continuer. Réessaie depuis Eudes lorsque tu es disponible.")
    }
}

#if DEBUG
/// Isolated UI fixture: no microphone, audio output, model or network access.
@MainActor
private final class BackgroundVoicePreviewAudio: BackgroundVoiceAudioService {
    private var waiting: CheckedContinuation<String, Error>?
    private var previewMeter: Task<Void, Never>?
    private var previewLevel: (@MainActor (Float) -> Void)?
    private var visualFeedbackEnabled = false
    func preflight() throws {}
    func prepare(onInterruption: @escaping @MainActor () -> Void) async throws {}
    func speak(_ text: String) async throws { try Task.checkCancellation() }
    func startThinkingSound() async {}
    func stopThinkingSound() {}
    func listen() async throws -> String {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func listen(onLevel: @escaping @MainActor (Float) -> Void) async throws -> String {
        previewLevel = onLevel
        updatePreviewMeter()
        defer { previewMeter?.cancel(); previewMeter = nil; previewLevel = nil }
        return try await listen()
    }
    func setVisualFeedbackEnabled(_ enabled: Bool) {
        visualFeedbackEnabled = enabled
        updatePreviewMeter()
    }
    private func updatePreviewMeter() {
        previewMeter?.cancel(); previewMeter = nil
        guard visualFeedbackEnabled, previewLevel != nil else { return }
        previewMeter = Task { @MainActor [weak self] in
            var tick = 0.0
            while !Task.isCancelled, let self, self.visualFeedbackEnabled {
                // Synthetic level for isolated UI QA; never opens the microphone or network.
                self.previewLevel?(Float(0.55 + 0.35 * sin(tick)))
                tick += 0.17
                do { try await Task.sleep(for: .milliseconds(85)) } catch { return }
            }
        }
    }
    func stop() {
        previewMeter?.cancel(); previewMeter = nil; previewLevel = nil
        let old = waiting; waiting = nil
        old?.resume(throwing: CancellationError())
    }
}
#endif
