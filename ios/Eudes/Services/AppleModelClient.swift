import Foundation
import FoundationModels

/// Availability is a local capability check, never a test generation or network request.
enum AppleModelAvailability: Equatable {
    case available, unsupportedOS, ineligible, disabled, notReady, unknown
    var message: String {
        switch self {
        case .available: return "Modèle Apple disponible sur cet appareil."
        case .unsupportedOS: return "Le modèle Apple nécessite iOS 26 ou ultérieur. Les serveurs existants restent utilisables."
        case .ineligible: return "Cet appareil ou cet environnement ne permet pas le modèle Apple. Vérifie la compatibilité Apple Intelligence de l’appareil et de sa région."
        case .disabled: return "Apple Intelligence n’est pas activé. Tu peux l’activer dans les Réglages iOS si tu souhaites utiliser le modèle local."
        case .notReady: return "Le modèle Apple n’est pas encore prêt. Vérifie Apple Intelligence dans les Réglages iOS et attends la fin de sa préparation, puis réessaie."
        case .unknown: return "Le modèle Apple est actuellement indisponible. Vérifie Apple Intelligence dans les Réglages iOS, puis réessaie."
        }
    }
}

enum AppleModelError: LocalizedError {
    case unavailable(AppleModelAvailability), images, context, refusal, language, busy, failed
    var errorDescription: String? {
        switch self {
        case .unavailable(let status): return status.message
        case .images: return "Le moteur Apple d'Eudes accepte uniquement du texte. Retire les images ou choisis une connexion compatible ; le brouillon est conservé."
        case .context: return "Le contexte du modèle Apple est plein. Ouvre une nouvelle conversation ou raccourcis les instructions. L’historique est conservé ; rien n’a été supprimé ni renvoyé automatiquement."
        case .refusal: return "Le modèle Apple ne peut pas répondre à cette demande avec ses règles de sécurité. Reformule ta demande."
        case .language: return "Cette langue ou région n’est pas prise en charge par le modèle Apple."
        case .busy: return "Le modèle Apple est occupé. Attends un instant puis réessaie."
        case .failed: return "La génération Apple a échoué. Le texte déjà reçu est conservé. Vérifie sa disponibilité et réessaie."
        }
    }
}

struct AppleModelClient: EudesAPIClient {
    static func availability() -> AppleModelAvailability {
        guard #available(iOS 26.0, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .ineligible
            case .appleIntelligenceNotEnabled: return .disabled
            case .modelNotReady: return .notReady
            @unknown default: return .unknown
            }
        @unknown default: return .unknown
        }
    }

    func checkConnection(profile: ServerProfile, key: String) async throws -> ConnectionProof {
        try Task.checkCancellation()
        let status = Self.availability()
        guard status == .available else { throw AppleModelError.unavailable(status) }
        return .reachable
    }
    func models(profile: ServerProfile, key: String) async throws -> [String] {
        _ = try await checkConnection(profile: profile, key: "")
        return [ServerProfile.appleModel]
    }
    static func contextLimits() -> ModelLimits {
        guard #available(iOS 26.0, *), availability() == .available else { return ModelLimits() }
        return ModelLimits(advertised: [TokenLimit(tokens: SystemLanguageModel.default.contextSize, source: "Foundation Models · contextSize")])
    }
    static func validate(model: String, messages: [ChatMessage]) throws {
        guard model == ServerProfile.appleModel else { throw EudesError.noModel }
        guard messages.allSatisfy({ ($0.images ?? []).isEmpty }) else { throw AppleModelError.images }
    }

    /// Rehydrate roles explicitly. No summary, hidden instruction, or silent history truncation.
    @available(iOS 26.0, *)
    static func transcript(messages: [ChatMessage], instructions: String) -> Transcript {
        var entries: [Transcript.Entry] = []
        if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.append(.instructions(.init(segments: [.text(.init(content: instructions))], toolDefinitions: [])))
        }
        for message in messages where message.state == .complete {
            let text: [Transcript.Segment] = [.text(.init(content: message.text))]
            switch message.role {
            case .user: entries.append(.prompt(.init(segments: text)))
            case .assistant: entries.append(.response(.init(assetIDs: [], segments: text)))
            }
        }
        return Transcript(entries: entries)
    }

    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage],
                systemPrompt: String, temperature: Double, maxTokens: Int?,
                onText: @escaping @MainActor (String) -> Void) async throws {
        try Self.validate(model: model, messages: messages)
        _ = try await checkConnection(profile: profile, key: "")
        guard #available(iOS 26.0, *) else { throw AppleModelError.unavailable(.unsupportedOS) }
        guard let last = messages.last, last.role == .user, last.state == .complete else { throw EudesError.emptyResponse }
        // A fresh local session per reply avoids retaining an interrupted generation or duplicating a turn.
        let session = LanguageModelSession(model: SystemLanguageModel.default,
            transcript: Self.transcript(messages: Array(messages.dropLast()), instructions: systemPrompt))
        do {
            let options = GenerationOptions(temperature: min(1, max(0, temperature)), maximumResponseTokens: profile.effectiveOutput(maxTokens, model: model))
            var received = false
            for try await snapshot in session.streamResponse(to: last.text, options: options) {
                try Task.checkCancellation()
                received = received || !snapshot.content.isEmpty
                // Foundation Models emits cumulative snapshots, unlike network token deltas.
                await onText(snapshot.content)
            }
            try Task.checkCancellation()
            guard received else { throw EudesError.emptyResponse }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw Self.generationError(error)
        }
    }

    @available(iOS 26.0, *)
    static func generationError(_ error: Error) -> Error {
        DiagnosticLog.record(error, context: "génération Apple")
        if error is EudesError { return error }
        if #available(iOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return AppleModelError.context
            case .guardrailViolation, .refusal: return AppleModelError.refusal
            case .unsupportedLanguageOrLocale: return AppleModelError.language
            case .rateLimited: return AppleModelError.busy
            default: return AppleModelError.failed
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return AppleModelError.context
            case .assetsUnavailable: return AppleModelError.unavailable(.notReady)
            case .guardrailViolation, .refusal: return AppleModelError.refusal
            case .unsupportedLanguageOrLocale: return AppleModelError.language
            case .rateLimited, .concurrentRequests: return AppleModelError.busy
            default: return AppleModelError.failed
            }
        }
        let status = availability()
        return status == .available ? AppleModelError.failed : AppleModelError.unavailable(status)
    }
}
