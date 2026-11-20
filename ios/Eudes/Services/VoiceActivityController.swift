import ActivityKit
import AppIntents
import Foundation

enum VoiceActivityError: Error, CustomLocalizedStringResourceConvertible {
    case disabled, unavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .disabled: "Autorise les activités en direct d'Eudes dans les réglages de l’iPhone pour démarrer l’assistant sans ouvrir l’app."
        case .unavailable: "iOS n’a pas autorisé le démarrage de l’assistant vocal en arrière-plan. Ouvre Eudes lorsque tu es disponible."
        }
    }
}

@MainActor
protocol VoiceActivityManaging: AnyObject {
    func start(sessionID: UUID, onDismissed: @escaping @MainActor () -> Void) async throws
    func update(phase: VoiceActivityPhase) async
    func end() async
}

@MainActor
final class VoiceActivityController: VoiceActivityManaging {
    private var activity: Activity<VoiceActivityAttributes>?
    private var monitor: Task<Void, Never>?
    private var onDismissed: (@MainActor () -> Void)?

    func start(sessionID: UUID, onDismissed: @escaping @MainActor () -> Void) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw VoiceActivityError.disabled }
        await end()
        // A killed process must not leave a second, misleading recording indicator.
        for orphan in Activity<VoiceActivityAttributes>.activities {
            await orphan.end(nil, dismissalPolicy: .immediate)
        }
        try Task.checkCancellation()
        let created: Activity<VoiceActivityAttributes>
        do {
            created = try Activity.request(attributes: VoiceActivityAttributes(sessionID: sessionID),
                content: ActivityContent(state: .init(phase: .preparing), staleDate: nil), pushType: nil)
        } catch {
            throw VoiceActivityError.unavailable
        }
        activity = created
        self.onDismissed = onDismissed
        monitor = Task { @MainActor [weak self] in
            for await state in created.activityStateUpdates {
                guard !Task.isCancelled, let self, self.activity?.id == created.id else { return }
                if state == .dismissed || state == .ended {
                    let callback = self.onDismissed
                    self.activity = nil
                    self.onDismissed = nil
                    self.monitor = nil
                    callback?()
                    return
                }
            }
        }
    }

    func update(phase: VoiceActivityPhase) async {
        guard let activity else { return }
        await activity.update(ActivityContent(state: .init(phase: phase), staleDate: nil))
    }

    func end() async {
        monitor?.cancel()
        monitor = nil
        onDismissed = nil
        let ending = activity
        activity = nil
        await ending?.end(nil, dismissalPolicy: .immediate)
    }
}
