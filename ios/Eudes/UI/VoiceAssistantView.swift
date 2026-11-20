import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct VoiceAssistantView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: VoiceAssistantModel
    @State private var proposedAction: VoiceAction?
    @State private var presentedAction: VoiceAction?
    @State private var automaticAction: VoiceAction?
    @State private var actionResult = ""
    @State private var clarificationContext = ""
    @State private var voiceConversationID: UUID?
    @State private var turnStartedAt = Date()
    private let apple = AppleSpeechModelManager.shared

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--lue-isolated-qa"),
           let scenario = ProcessInfo.processInfo.environment["EUDES_QA_VOICE"], scenario != "native" {
            let audio: any VoiceAudioService = scenario == "speech" ? VoiceSpeechDemoAudio() : VoiceAssistantDemoAudio(levels: scenario == "levels")
            _model = State(initialValue: VoiceAssistantModel(audio: audio))
            return
        }
        #endif
        _model = State(initialValue: VoiceAssistantModel())
    }

    var body: some View {
        ZStack {
            ThemeBackground()
            VStack(spacing: 0) {
                HStack {
                    Text("Assistant vocal").font(.headline)
                    Spacer()
                    Button {
                        model.cancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(Palette.surface, in: Circle())
                    }
                    .accessibilityLabel("Fermer l’assistant vocal")
                    .accessibilityIdentifier("voice.close")
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)

                ScrollView {
                    VStack(spacing: 24) {
                        VoiceAssistantStatus(
                                model: model,
                                phase: model.phase,
                                isTranscribing: model.phase == .listening && isTranscribing,
                                isSearchingWeb: model.phase == .thinking && store.isSearchingWeb,
                                webResearchTrace: currentWebResearchTrace,
                                isActive: scenePhase == .active
                            )
                                .padding(.top, 36)
                            Text("Modèle : \(store.currentModel.isEmpty ? "non sélectionné" : store.currentModel)")
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityIdentifier("voice.currentModel")
                            VoiceWebSearchIndicator(mode: store.voiceWebSearchMode)
                            if !model.transcript.isEmpty, currentWebResearchTrace != nil,
                               model.phase == .thinking || model.phase == .speaking || model.phase == .complete || model.phase.isFailure {
                                WebResearchActivityView(trace: currentWebResearchTrace)
                                    .accessibilityIdentifier("voice.webResearchActivity")
                            }
                            if !model.transcript.isEmpty {
                                VoiceAssistantText(label: "Ta demande", text: model.transcript, identifier: "voice.transcript")
                            }
                            if !model.response.isEmpty {
                                VoiceAssistantText(label: "Réponse d'Eudes", text: model.response, identifier: "voice.response")
                            }
                            if !actionResult.isEmpty { Text(actionResult).accessibilityIdentifier("voice.action.result") }
                            if let proposedAction, model.phase == .complete {
                                Button("Vérifier l’action") { presentedAction = proposedAction }
                                    .buttonStyle(PrimaryButtonStyle())
                                    .accessibilityIdentifier("voice.action.review")
                            }
                            if model.phase == .listening && !isTranscribing {
                                Button("J’ai terminé") { model.finishListening() }
                                    .buttonStyle(PrimaryButtonStyle())
                                    .accessibilityIdentifier("voice.finishListening")
                            }
                            if model.phase == .complete || model.phase.isFailure {
                                Button(model.phase == .complete ? "Poser une autre question" : "Réessayer") { start() }
                                    .buttonStyle(PrimaryButtonStyle())
                                    .accessibilityIdentifier("voice.retry")
                            }
                    }
                    .frame(maxWidth: 540)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 30)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .task(id: scenePhase) {
            if scenePhase == .active, model.phase == .idle { start() }
        }
        .sheet(item: $presentedAction, onDismiss: { proposedAction = nil }) { action in
            VoiceActionView(action: action) { actionResult = $0; proposedAction = nil }
        }
        .task(id: model.phase == .complete) {
            if model.phase == .complete, let action = automaticAction {
                automaticAction = nil
                do { actionResult = try await VoiceActionOpening.open(action) }
                catch is CancellationError { }
                catch { actionResult = error.localizedDescription }
            }
        }
        .onDisappear { model.cancel(); automaticAction = nil; proposedAction = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.interrupt() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: value) == .began else { return }
            model.interrupt()
        }
    }

    private func start() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--lue-isolated-qa"),
           let fixture = ProcessInfo.processInfo.environment["EUDES_QA_ACTION"] {
            presentedAction = VoiceAction(kind: fixture == "sms" ? .sms : fixture == "event" ? .event : .reminder,
                value: fixture == "sms" ? "Paul" : "Appeler le dentiste", body: "J’arrive dans dix minutes.",
                date: "2026-11-06T09:00:00Z", endDate: "2026-11-06T10:00:00Z")
            return
        }
        #endif
        turnStartedAt = Date()
        proposedAction = nil
        automaticAction = nil
        actionResult = ""
        model.start(continuous: true, shouldContinue: {
            scenePhase == .active && proposedAction == nil && automaticAction == nil
        }) { question in
            do {
                if ["annule", "annuler", "abandonne"].contains(VoiceAction.normalized(question).trimmingCharacters(in: .punctuationCharacters)) {
                    clarificationContext = ""
                    return "Action annulée."
                }
                if !VoiceAction.shouldInterpretAction(question, hasClarification: !clarificationContext.isEmpty,
                                                      voiceWebMode: store.voiceWebSearchMode) {
                    return try await answerInVoiceConversation(question)
                }
                let direct = VoiceAction.direct(question)
                let request = clarificationContext.isEmpty ? question : clarificationContext + "\nPrécision de l’utilisateur : " + question
                let action: VoiceAction
                if let direct { action = try direct.validated() }
                else { action = try await store.planVoiceAction(request) }
                try Task.checkCancellation()
                if action.kind == .none {
                    clarificationContext = ""
                    return try await answerInVoiceConversation(question)
                }
                if action.kind == .clarification {
                    clarificationContext = request + "\nQuestion d'Eudes : " + action.value
                    return action.value
                }
                clarificationContext = ""
                if direct != nil, action.url != nil {
                    automaticAction = action
                    return "Je vais ouvrir \(action.value)."
                }
                proposedAction = action
                return "L’action est prête. Touche Vérifier l’action pour la confirmer."
            } catch is CancellationError { throw CancellationError() }
            catch let error as VoiceActionError { return error.localizedDescription }
            catch is DecodingError { return VoiceActionError.invalid.localizedDescription }
        }
    }

    private func answerInVoiceConversation(_ question: String) async throws -> String {
        let reply = try await store.answerShortcut(question, continuing: voiceConversationID)
        voiceConversationID = store.current?.id
        return reply
    }

    private var currentWebResearchTrace: WebResearchTrace? {
        guard let trace = store.webResearchTrace, trace.startedAt >= turnStartedAt else { return nil }
        return trace
    }

    private var isTranscribing: Bool {
        apple.isTranscribing
    }

}

private extension VoiceAssistantModel.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .idle, .preparing: "Préparation de l’assistant…"
        case .asking: "Que souhaites-tu faire ?"
        case .listening: "Je t’écoute…"
        case .thinking: "Eudes réfléchit…"
        case .speaking: "Eudes te répond…"
        case .complete: "Réponse terminée"
        case .failed(let message): message
        }
    }

    var symbol: String {
        switch self {
        case .listening: "waveform"
        case .asking, .speaking: "speaker.wave.2"
        case .failed: "exclamationmark.circle"
        case .complete: "checkmark.circle"
        default: "sparkles"
        }
    }
}

private struct VoiceAssistantStatus: View {
    let model: VoiceAssistantModel
    let phase: VoiceAssistantModel.Phase
    let isTranscribing: Bool
    let isSearchingWeb: Bool
    let webResearchTrace: WebResearchTrace?
    let isActive: Bool

    var body: some View {
        VStack(spacing: 20) {
            if phase == .listening && !isTranscribing && model.isMicrophoneReady {
                // The frequently changing meter is read only inside this small subtree.
                VoiceLevelBars(level: CGFloat(model.audioLevel), isActive: isActive)
                    .accessibilityElement()
                    .accessibilityLabel("Microphone actif. L’animation réagit au son capté.")
                    .accessibilityIdentifier("voice.bars")
            } else {
                Image(systemName: isSearchingWeb ? "globe" : phase.symbol)
                    .font(.system(size: 38, weight: .medium))
                    .frame(width: 108, height: 108)
                    .background(Palette.surface, in: Circle())
                    .accessibilityHidden(true)
            }
            if isSearchingWeb {
                ProgressView {
                    Text(WebResearchActivityPresentation.progressLabel(trace: webResearchTrace))
                }
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("voice.webSearchProgress")
            } else {
                Text(isTranscribing ? "Transcription en cours…" : phase == .listening && !model.isMicrophoneReady ? "Préparation du microphone…" : phase.message)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("voice.status")
            }
        }
    }
}

/// Five audio-driven bars: fast attack, slow release, no idle oscillation.
struct VoiceLevelBars: View {
    let level: CGFloat
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var envelope = VoiceParticleEnvelope()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive || reduceMotion)) { _ in
            let value = reduceMotion ? VoiceParticleEnvelope.intensity(for: Double(level))
                : envelope.value(at: ProcessInfo.processInfo.systemUptime)
            Canvas { context, size in
                let weights: [Double] = [0.35, 0.70, 1, 0.70, 0.35]
                for index in weights.indices {
                    let height = 14 + (isActive ? value : 0) * weights[index] * 90
                    let rect = CGRect(x: 18 + Double(index) * 32, y: (size.height - height) / 2,
                                      width: 16, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .foreground)
                }
            }
        }
        .frame(width: 180, height: 140)
        .onAppear { envelope.reset(level: Double(level), at: ProcessInfo.processInfo.systemUptime) }
        .onChange(of: level) { _, value in
            envelope.retarget(level: Double(value), at: ProcessInfo.processInfo.systemUptime)
        }
        .onChange(of: isActive) { _, active in
            envelope.reset(level: active ? Double(level) : 0, at: ProcessInfo.processInfo.systemUptime)
        }
    }
}

/// The audio meter intentionally updates at about 12 Hz. Sample this visual-only
/// envelope at display cadence without changing microphone or silence detection.
/// Retargeting starts at the currently displayed value, so it never jumps.
struct VoiceParticleEnvelope {
    private var start: Double
    private var target: Double
    private var startedAt: TimeInterval

    init(level: Double = 0, at time: TimeInterval = 0) {
        start = Self.intensity(for: level)
        target = start
        startedAt = time
    }

    static func intensity(for level: Double) -> Double {
        guard level.isFinite else { return 0 }
        return min(1, max(0, (level - 0.035) * 2.7))
    }

    func value(at time: TimeInterval) -> Double {
        let duration = target > start ? 0.08 : 0.20
        let elapsed = max(0, time - startedAt)
        return target + (start - target) * exp(-elapsed / duration)
    }

    mutating func retarget(level: Double, at time: TimeInterval) {
        start = value(at: time)
        target = Self.intensity(for: level)
        startedAt = time
    }

    mutating func reset(level: Double, at time: TimeInterval) {
        self = Self(level: level, at: time)
    }
}

private struct VoiceWebSearchIndicator: View {
    let mode: VoiceWebSearchMode

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Label("Web", systemImage: "globe")
                Text(mode.title)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("voice.webSearchMode")
            if mode == .onRequest {
                Text("Pour cette demande : « Cherche sur Internet… »")
                    .font(.caption2).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(Palette.muted)
    }
}

private struct VoiceAssistantText: View {
    let label: String
    let text: String
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
    }
}

#if DEBUG
/// Explicit simulator-only fixture: no microphone, real transcript or network access.
@MainActor
private final class VoiceAssistantDemoAudio: VoiceAudioService {
    private let levels: Bool
    private var levelHandler: (@MainActor (Float) -> Void)?
    private var pending: CheckedContinuation<String, Error>?
    private var timer: Task<Void, Never>?
    init(levels: Bool = false) { self.levels = levels }
    func setLevelHandler(_ handler: (@MainActor (Float) -> Void)?) { levelHandler = handler }
    func requestPermissions() async throws { try await Task.sleep(for: .milliseconds(300)) }
    func startThinkingSound() async {}
    func stopThinkingSound() {}
    func speak(_ text: String) async throws { try await Task.sleep(for: .milliseconds(700)) }
    func listen(onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        onPartial("Question fictive")
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                timer = Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.levels {
                        // Stable low/high windows allow repeatable screenshots with no real audio.
                        while !Task.isCancelled {
                            self.levelHandler?(0)
                            do { try await Task.sleep(for: .seconds(3)) } catch { return }
                            self.levelHandler?(0.65)
                            do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        }
                    } else {
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        self.finishListening()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }
    func finishListening() {
        guard let pending else { return }
        self.pending = nil
        timer?.cancel(); timer = nil
        levelHandler?(0)
        pending.resume(returning: "Question fictive")
    }
    func cancel() {
        guard let pending else { return }
        self.pending = nil
        timer?.cancel(); timer = nil
        levelHandler?(0)
        pending.resume(throwing: CancellationError())
    }
}

/// Runs real iOS speech synthesis with a fictitious transcript and model response.
@MainActor
private final class VoiceSpeechDemoAudio: VoiceAudioService {
    private let audio = SystemVoiceAudio()
    func requestPermissions() async throws { }
    func startThinkingSound() async { await audio.startThinkingSound() }
    func stopThinkingSound() { audio.stopThinkingSound() }
    func speak(_ text: String) async throws { try await audio.speak(text) }
    func listen(onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        onPartial("Question fictive")
        return "Question fictive"
    }
    func finishListening() { }
    func cancel() { audio.cancel() }
}
#endif
