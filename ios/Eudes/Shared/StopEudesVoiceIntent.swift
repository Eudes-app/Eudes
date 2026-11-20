import AppIntents
import Foundation

/// LiveActivityIntent runs in the containing app, including from its widget.
/// The ID prevents an old activity from stopping a newer voice session.
struct StopEudesVoiceIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Arrêter l’assistant vocal Eudes"
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Session")
    var sessionID: String

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    func perform() async throws -> some IntentResult {
        #if EUDES_WIDGET_EXTENSION
        // The extension carries the intent metadata, not microphone ownership.
        // Never report success if the system unexpectedly executes it here.
        try requireContainingApp()
        #else
        if let id = UUID(uuidString: sessionID) {
            await BackgroundVoiceSession.shared.stop(sessionID: id)
        }
        #endif
        return .result()
    }

    private func requireContainingApp() throws { throw VoiceStopUnavailable() }
}

private struct VoiceStopUnavailable: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        "Ouvre Eudes pour arrêter l’assistant vocal."
    }
}
