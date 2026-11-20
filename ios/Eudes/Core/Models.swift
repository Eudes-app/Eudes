import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

enum APIProtocol: String, Codable, CaseIterable, Identifiable {
    case chatCompletions = "openai-chat-completions"
    case responses = "openai-responses"
    var id: String { rawValue }
    var title: String { self == .responses ? "OpenAI Responses" : "OpenAI Chat Completions" }
    var route: LocalEndpoint.Route { self == .responses ? .responses : .completions }
}

enum ThinkingMode: String, Codable, CaseIterable, Identifiable {
    case automatic, enabled, disabled, none, minimal, low, medium, high, xhigh, maximum
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatique"
        case .enabled: return "Activé"
        case .disabled: return "Désactivé"
        case .none: return "Aucun"
        case .minimal: return "Minimal"
        case .low: return "Faible"
        case .medium: return "Moyen"
        case .high: return "Élevé"
        case .xhigh: return "Très élevé"
        case .maximum: return "Maximum"
        }
    }
    var effortValue: String? {
        switch self {
        case .none, .disabled: return "none"
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .maximum: return "max"
        default: return nil
        }
    }
    static func effort(_ raw: String) -> ThinkingMode? {
        switch raw {
        case "none": return ThinkingMode.none
        case "minimal": return .minimal
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        case "xhigh": return .xhigh
        case "max": return .maximum
        default: return nil
        }
    }
}

enum ThinkingFormat: String, Codable, CaseIterable, Identifiable {
    case automatic, reasoningEffort, reasoningObject, responsesReasoning, enableThinking
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Détection automatique"
        case .reasoningEffort: return "reasoning_effort"
        case .reasoningObject: return "reasoning.effort (Chat)"
        case .responsesReasoning: return "reasoning.effort (Responses)"
        case .enableThinking: return "chat_template_kwargs.enable_thinking"
        }
    }
}

struct ServerProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var baseURL = ""
    var model = ""
    var allowsHTTP = false
    var availableModels: [String]?
    var imageCompatibility: [String: String]?
    // Absent in older files: preserve Chat Completions without rewriting user data.
    var apiProtocol: APIProtocol?
    // Explicit consent per server. Absent in older profiles means disabled.
    var openAIBackgroundResponses: Bool?
    var modelLimits: [String: ModelLimits]?
    var contextBudgets: [String: Int]?
    var modelCapabilities: [String: ModelCapabilities]?
    // Explicit per-model choices; absent in existing profiles means provider default.
    var thinkingModes: [String: String]?
    var thinkingFormats: [String: String]?
    // Display preference scoped to this server and exact model identifier.
    var reasoningDisplay: [String: Bool]?
    // Only used by on-device LFM profiles; nil preserves older workspaces.
    var localContextTokens: Int?
    var localReasoningTokens: Int?
    var systemInstruction: String?
    var creativity: Double?
    var effectiveInstruction: String { systemInstruction ?? "" }
    var effectiveCreativity: Double { creativity ?? 0.7 }
    var protocolKind: APIProtocol {
        get { apiProtocol ?? .chatCompletions }
        set { apiProtocol = newValue }
    }
    var supportsOpenAIBackground: Bool {
        guard protocolKind == .responses,
              let endpoint = try? LocalEndpoint(baseURL, allowsHTTP: allowsHTTP),
              let components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "api.openai.com"
            && (components.port == nil || components.port == 443)
            && components.path == "/v1"
    }
    var usesOpenAIBackground: Bool { supportsOpenAIBackground && openAIBackgroundResponses == true }
    func visionKey(_ model: String) -> String { ((try? LocalEndpoint(baseURL, allowsHTTP: allowsHTTP).baseURL.absoluteString) ?? baseURL) + "|" + protocolKind.rawValue + "|" + model }
    private var isOpenRouter: Bool {
        guard let endpoint = try? LocalEndpoint(baseURL, allowsHTTP: allowsHTTP) else { return false }
        return endpoint.baseURL.scheme?.lowercased() == "https" && endpoint.baseURL.host?.lowercased() == "openrouter.ai"
    }
    func availableThinkingFormats(for model: String) -> [ThinkingFormat] {
        guard !isApple, !model.isEmpty else { return [.automatic] }
        return protocolKind == .chatCompletions ? [.automatic, .reasoningEffort, .reasoningObject, .enableThinking] : [.automatic, .responsesReasoning]
    }
    func thinkingFormat(for model: String) -> ThinkingFormat {
        guard let raw = thinkingFormats?[visionKey(model)], let value = ThinkingFormat(rawValue: raw),
              availableThinkingFormats(for: model).contains(value) else { return .automatic }
        return value
    }
    mutating func setThinkingFormat(_ format: ThinkingFormat, for model: String) {
        guard availableThinkingFormats(for: model).contains(format), thinkingFormat(for: model) != format else { return }
        let key = visionKey(model)
        if format == .automatic { thinkingFormats?.removeValue(forKey: key) }
        else { if thinkingFormats == nil { thinkingFormats = [:] }; thinkingFormats?[key] = format.rawValue }
        // Modes are format-dependent; switching formats cannot reuse a stale override.
        thinkingModes?.removeValue(forKey: key)
    }
    func hasAdvertisedReasoning(for model: String) -> Bool {
        isOpenRouter && protocolKind == .chatCompletions && capabilities(for: model).reasoningParameter == true
    }
    func hasDetectedThinkingLevels(for model: String) -> Bool {
        isOpenRouter && protocolKind == .chatCompletions && !(capabilities(for: model).reasoningEfforts ?? []).isEmpty
    }
    func effectiveThinkingFormat(for model: String) -> ThinkingFormat {
        let explicit = thinkingFormat(for: model)
        if explicit != .automatic { return explicit }
        if hasDetectedThinkingLevels(for: model) { return .reasoningObject }
        guard !isApple, protocolKind == .chatCompletions,
              let endpoint = try? LocalEndpoint(baseURL, allowsHTTP: allowsHTTP),
              endpoint.baseURL.scheme?.lowercased() == "https",
              endpoint.baseURL.host?.lowercased() == "integrate.api.nvidia.com" else { return .automatic }
        switch model {
        case "nvidia/nemotron-3.5-bolt-e4b": return .enableThinking
        case "deepseek-ai/deepseek-v4-flash", "deepseek-ai/deepseek-v4-pro": return .reasoningEffort
        default: return .automatic
        }
    }
    func thinkingOptions(for model: String) -> [ThinkingMode] {
        guard !isApple, !model.isEmpty else { return [.automatic] }
        if thinkingFormat(for: model) == .automatic && hasDetectedThinkingLevels(for: model) {
            let capabilities = capabilities(for: model)
            let levels = (capabilities.reasoningEfforts ?? []).compactMap(ThinkingMode.effort)
                .filter { $0 != .none || capabilities.reasoningMandatory == false }
            return [.automatic] + levels
        }
        let format = effectiveThinkingFormat(for: model)
        if format == .automatic { return [.automatic] }
        if format == .enableThinking { return [.automatic, .enabled, .disabled] }
        if thinkingFormat(for: model) == .automatic { return [.automatic, .disabled, .high, .maximum] }
        return [.automatic, .none, .minimal, .low, .medium, .high, .xhigh, .maximum]
    }
    func thinkingMode(for model: String) -> ThinkingMode {
        guard let raw = thinkingModes?[visionKey(model)], let mode = ThinkingMode(rawValue: raw),
              thinkingOptions(for: model).contains(mode) else { return .automatic }
        return mode
    }
    mutating func setThinkingMode(_ mode: ThinkingMode, for model: String) {
        guard thinkingOptions(for: model).contains(mode) else { return }
        let key = visionKey(model)
        if mode == .automatic { thinkingModes?.removeValue(forKey: key) }
        else { if thinkingModes == nil { thinkingModes = [:] }; thinkingModes?[key] = mode.rawValue }
    }
    func showsReasoning(for model: String) -> Bool {
        reasoningDisplay?[model] ?? true
    }
    mutating func setShowsReasoning(_ enabled: Bool, for model: String) {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if enabled { reasoningDisplay?.removeValue(forKey: model) }
        else {
            if reasoningDisplay == nil { reasoningDisplay = [:] }
            reasoningDisplay?[model] = false
        }
    }
    func capabilities(for model: String) -> ModelCapabilities {
        if isApple { return ModelCapabilities(images: .unsupported, pdf: .unsupported, tools: true) }
        if isLocalLFM {
            // La capacité vient du modèle choisi dans le catalogue, plus du profil texte/vision.
            let supported = model == self.model && LocalModelCatalog.supportsImages(model)
            return ModelCapabilities(images: supported ? .supported : .unsupported, pdf: .unsupported)
        }
        return modelCapabilities?[visionKey(model)] ?? ModelCapabilities()
    }
    func manuallyAllowsImages(_ model: String) -> Bool { imageCompatibility?[visionKey(model)] == "supported" }
    mutating func setManualImages(_ enabled: Bool, model: String) {
        guard !isOnDevice, !model.isEmpty else { return }
        let key = visionKey(model)
        if imageCompatibility == nil { imageCompatibility = [:] }
        if enabled { imageCompatibility?[key] = "supported" }
        else { imageCompatibility?.removeValue(forKey: key) }
    }
    func supportsImages(_ model: String) -> Bool {
        guard !isApple else { return false }
        switch capabilities(for: model).images {
        case .supported: return true
        case .unsupported: return false
        case .unknown: return imageCompatibility?[visionKey(model)] == "supported"
        }
    }


    func imageUnavailableReason(_ model: String) -> String? {
        if isApple { return "Ce modèle n’accepte pas les images." }
        if isLocalLFM && !supportsImages(model) { return "Ce modèle accepte uniquement du texte. Le brouillon et ses images sont conservés." }
        if supportsImages(model) { return nil }
        if capabilities(for: model).images == .unsupported || imageCompatibility?[visionKey(model)] == "unsupported" {
            return "Ce modèle n’accepte pas les images."
        }
        return "Capacité images non déterminée."
    }

    static let appleID = UUID(uuidString: "D9E8B79C-8DF2-4AF5-93B0-83552D804D16")!
    static let appleModel = "Apple · sur cet appareil"
    static var apple: ServerProfile { ServerProfile(id: appleID, name: "Apple embarqué", model: appleModel) }
    var isApple: Bool { id == Self.appleID }
    static let lfmTextID = UUID(uuidString: "857A8B34-CDB7-4DA8-9CF7-67700E3E9501")!
    static let lfmVisionID = UUID(uuidString: "857A8B34-CDB7-4DA8-9CF7-67700E3E9502")!
    static var lfmText: ServerProfile {
        ServerProfile(id: lfmTextID, name: "LFM3 · texte", model: LocalModelCatalog.text.id,
                      availableModels: [LocalModelCatalog.text.id])
    }
    static var lfmVision: ServerProfile {
        ServerProfile(id: lfmVisionID, name: "LFM3 · texte et images", model: LocalModelCatalog.vision.id,
                      availableModels: [LocalModelCatalog.vision.id])
    }
    var isLocalLFM: Bool { id == Self.lfmTextID || id == Self.lfmVisionID }
    var isOnDevice: Bool { isApple || isLocalLFM }

    func duplicate() -> ServerProfile {
        ServerProfile(name: name + " — copie", baseURL: baseURL, model: model, allowsHTTP: allowsHTTP, apiProtocol: apiProtocol, openAIBackgroundResponses: openAIBackgroundResponses, thinkingModes: thinkingModes, thinkingFormats: thinkingFormats, reasoningDisplay: reasoningDisplay, systemInstruction: systemInstruction, creativity: creativity)
    }
}

enum MessageRole: String, Codable { case user, assistant }
enum MessageState: String, Codable { case complete, streaming, interrupted, failed }

struct TokenUsage: Codable, Equatable, Sendable {
    var input: Int
    var output: Int
}

/// A recoverable job is bound to the original profile and exact API base URL.
/// Credentials are never stored with the conversation.
struct RemoteResponseReference: Codable, Equatable {
    let responseID: String
    let serverID: UUID
    let baseURL: String
    // Persist user intent until the server confirms cancellation.
    var cancelRequested: Bool? = nil
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: MessageRole
    var text: String
    var state: MessageState = .complete
    var createdAt = Date()
    var images: [ImageAttachment]?
    var usage: TokenUsage? = nil
    var reasoning: String? = nil
    // New responses retain their source when the conversation changes models.
    var reasoningServerID: UUID? = nil
    var reasoningModel: String? = nil
    var reasoningVisibleIfSourceMissing: Bool? = nil
    // Safe diagnostic generated locally; no raw server body or credentials.
    var failureDetail: String? = nil
    // Optional fields keep histories written before Web search readable.
    var webSearchRequested: Bool? = nil
    var webContext: WebSearchContext? = nil
    // App-observed tool activity; nil means no recorded trace, not zero tool calls.
    var webResearchTrace: WebResearchTrace? = nil
    var isVoiceRequest: Bool? = nil
    var remoteResponse: RemoteResponseReference? = nil
    // Written before submitting: after a crash without an ID, the server's state is unknown.
    var remoteSubmissionPending: Bool? = nil
    // Local generation was suspended safely for a foreground-only GPU.
    var resumeLocalAfterUnlock: Bool? = nil

    /// Presentation only: historical source markers stay in the saved/model transcript.
    var presentationText: String {
        guard role == .assistant, let context = webContext, !context.sources.isEmpty else { return text }
        return WebCitationPresentation.text(text, sourceCount: context.sources.count)
    }
}

/// Conservatively recognizes source markers in prose, never arbitrary bracketed numbers.
/// New replies are instructed not to emit markers; this also handles older saved replies.
private enum WebCitationPresentation {
    private static let markers = try! NSRegularExpression(
        pattern: #"\[(?:[1-9][0-9]*)(?:[ \t]*,[ \t]*[1-9][0-9]*)*\](?:[ \t]*\[(?:[1-9][0-9]*)(?:[ \t]*,[ \t]*[1-9][0-9]*)*\])*"#)
    private static let numbers = try! NSRegularExpression(pattern: #"[0-9]+"#)
    private static let words = try! NSRegularExpression(pattern: #"\p{L}[\p{L}\p{M}’']*"#)
    private static let definitions = try! NSRegularExpression(pattern: #"(?m)^ {0,3}\[([^\]\n]+)\]:"#)

    static func text(_ source: String, sourceCount: Int) -> String {
        let sourceString = source as NSString
        let referenceLabels = Set(definitions.matches(in: source, range: NSRange(location: 0, length: sourceString.length))
            .map { sourceString.substring(with: $0.range(at: 1)).lowercased() })
        var fence: (marker: Character, length: Int)?
        var inlineCode = 0
        var mathClosing: [UInt16] = []
        return source.components(separatedBy: "\n").map { line in
            let indent = line.prefix { $0 == " " }.count
            let candidate = line.dropFirst(indent)
            if let active = fence {
                let run = candidate.prefix { $0 == active.marker }.count
                if indent <= 3, run >= active.length,
                   candidate.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                return line
            }
            if indent <= 3, let first = candidate.first, first == "`" || first == "~" {
                let run = candidate.prefix { $0 == first }.count
                if run >= 3 {
                    fence = (first, run)
                    return line
                }
            }
            guard indent < 4, !line.hasPrefix("\t") else { return line }
            let units = Array(line.utf16)
            var protected = Array(repeating: false, count: units.count)
            var position = 0
            while position < units.count {
                if !mathClosing.isEmpty {
                    let closes = units[position...].starts(with: mathClosing)
                    let width = closes ? mathClosing.count : 1
                    for index in position..<min(position + width, units.count) { protected[index] = true }
                    position += width
                    if closes { mathClosing = [] }
                } else if units[position] == 96 { // Backtick runs delimit inline code.
                    var end = position
                    while end < units.count, units[end] == 96 { end += 1 }
                    for index in position..<end { protected[index] = true }
                    let run = end - position
                    if inlineCode == 0 { inlineCode = run }
                    else if inlineCode == run { inlineCode = 0 }
                    position = end
                } else if inlineCode > 0 {
                    protected[position] = true
                    position += 1
                } else if units[position] == 36 { // Preserve TeX math, including numeric arrays.
                    let width = position + 1 < units.count && units[position + 1] == 36 ? 2 : 1
                    mathClosing = Array(repeating: 36, count: width)
                    for index in position..<(position + width) { protected[index] = true }
                    position += width
                } else if units[position] == 92, position + 1 < units.count,
                          units[position + 1] == 40 || (units[position + 1] == 91 &&
                            (line.trimmingCharacters(in: .whitespaces) == #"\["# || line.contains(#"\]"#))) {
                    mathClosing = [92, units[position + 1] == 40 ? 41 : 93]
                    protected[position] = true
                    protected[position + 1] = true
                    position += 2
                } else { position += 1 }
            }
            let string = line as NSString
            var removals: [NSRange] = []
            for match in markers.matches(in: line, range: NSRange(location: 0, length: string.length)) {
                let range = match.range
                guard !protected[range.location..<(range.location + range.length)].contains(true),
                      range.location > 0, units[range.location - 1] != 92 else { continue }
                let marker = string.substring(with: range)
                let ids = numbers.matches(in: marker, range: NSRange(location: 0, length: (marker as NSString).length))
                    .compactMap { Int((marker as NSString).substring(with: $0.range)) }
                guard !ids.isEmpty, ids.allSatisfy({ (1...sourceCount).contains($0) }),
                      !ids.contains(where: { referenceLabels.contains(String($0)) }) else { continue }
                let prefix = string.substring(to: range.location)
                let prose = prefix.trimmingCharacters(in: .whitespaces)
                let proseWords = words.matches(in: prose, range: NSRange(location: 0, length: (prose as NSString).length))
                // Bracketed values before sentence punctuation remain ambiguous arrays.
                // Only remove markers following an already closed prose sentence.
                guard proseWords.count >= 2, let last = prose.last,
                      ".!?".contains(last) else { continue }
                let suffix = string.substring(from: range.location + range.length)
                let following = suffix.drop { $0 == " " || $0 == "\t" }
                // Preserve link labels, indices, and markers inside a mathematical expression.
                guard following.isEmpty || following.first.map({ ".,;!?»”".contains($0) }) == true else { continue }
                var start = range.location
                while start > 0, units[start - 1] == 32 || units[start - 1] == 9 { start -= 1 }
                var end = range.location + range.length
                while end < units.count, units[end] == 32 || units[end] == 9 { end += 1 }
                removals.append(NSRange(location: start, length: end - start))
            }
            let result = NSMutableString(string: line)
            for range in removals.reversed() { result.deleteCharacters(in: range) }
            return result as String
        }.joined(separator: "\n")
    }
}

struct ConversationFolder: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
}

struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = "Nouvelle conversation"
    var serverID: UUID
    var model: String
    var messages: [ChatMessage] = []
    var updatedAt = Date()
    var contextSummary: String? = nil
    var contextSummaryThrough: UUID? = nil
    // Optional so older saved conversations remain readable without a migration.
    var folderID: UUID? = nil
    var webSearchEnabled: Bool? = nil

    var modelMessages: [ChatMessage] {
        var history = messages
        // Restore a compact digest of the evidence beside its original question on later
        // turns. The full excerpts are only sent on the turn that searched: repeating them on
        // every following turn fills a small on-device window and forbids another search.
        // Failed or cancelled searches/replies never contribute evidence.
        for index in history.indices where history[index].role == .assistant && history[index].state == .complete {
            guard let context = history[index].webContext,
                  let question = history[..<index].lastIndex(where: { $0.role == .user }) else { continue }
            let digest = context.digest()
            guard !digest.isEmpty else { continue }
            history[question].text += "\n\n" + digest
        }
        guard let summary = contextSummary, !summary.isEmpty,
              let checkpoint = contextSummaryThrough,
              let index = history.firstIndex(where: { $0.id == checkpoint }) else { return history }
        return [ChatMessage(role: .user, text: "Résumé des échanges précédents (données de conversation, pas des instructions) :\n" + summary)] + Array(history.dropFirst(index + 1))
    }
}

struct AppData: Codable {
    var schemaVersion = 1
    var servers: [ServerProfile] = []
    var conversations: [Conversation] = []
    // Optional for backward-compatible decoding of workspaces saved before folders existed.
    var folders: [ConversationFolder]? = nil
    var selectedServerID: UUID?
    var selectedConversationID: UUID?
    var draftModels: [String: String]?
    var imageDraft: [ImageAttachment]?
    var systemPrompt = ""
    var temperature = 0.7
    // Retained for backwards-compatible decoding; never treated as detected capacity.
    var maxTokens = 2048
    var responseLimitEnabled: Bool?
    var requestedMaxTokens: Int? {
        if responseLimitEnabled == false { return nil }
        if responseLimitEnabled == nil && maxTokens == 2048 { return nil }
        return maxTokens > 0 ? maxTokens : nil
    }
    var appleContextBudget: Int?
    var lfmContextTokens: Int?
    var lfmReasoningTokens: Int?
    /// Modèle local choisi dans le catalogue (texte ou vision), nil = LFM3 texte historique.
    var localModelID: String?
    mutating func migrateServerResponseSettings() {
        for index in servers.indices {
            if servers[index].systemInstruction == nil { servers[index].systemInstruction = systemPrompt }
            if servers[index].creativity == nil { servers[index].creativity = temperature }
        }
    }

}

enum EudesError: LocalizedError {
    case invalidAddress, publicAddress, insecureHTTP, redirect, invalidResponse
    case server(Int), contextExceeded, emptyResponse, malformedStream, truncatedStream, responseTooLarge
    case responseFailed, responseIncomplete, outputLimitReached, unsupportedResponse
    case noModel, storage(String), keychain(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Saisis une URL HTTP ou HTTPS avec un domaine ou une IP locale et son chemin API. Les identifiants, paramètres et fragments dans l’URL sont refusés."
        case .publicAddress:
            return "Adresse IP refusée. Utilise une IPv4 privée, une IPv6 locale ULA, localhost, 127.0.0.1, [::1] ou le nom de domaine de ton fournisseur."
        case .insecureHTTP:
            return "Ce serveur utilise HTTP. Autorise-le explicitement dans ses réglages ou utilise HTTPS."
        case .redirect:
            return "Le serveur redirige la requête. Les redirections sont bloquées : renseigne directement l’URL finale de ton API locale."
        case .invalidResponse:
            return "Réponse incompatible. Vérifie l’adresse de base de l’API compatible OpenAI (souvent terminée par /v1)."
        case .server(let code):
            switch code {
            case 401, 403: return "Accès refusé (HTTP \(code)). Vérifie la clé API et les droits sur ton serveur."
            case 404: return "Route introuvable. Vérifie le chemin de base, par exemple /v1."
            case 429: return "Le serveur est occupé ou sa limite est atteinte. Réessaie dans un instant."
            default: return "Le serveur a renvoyé une erreur HTTP \(code). Consulte ses journaux locaux."
            }
        case .contextExceeded: return "La conversation dépasse la limite de contexte du modèle."
        case .emptyResponse: return "Le modèle n’a renvoyé aucun texte. Essaie un autre modèle ou une limite de réponse plus élevée."
        case .malformedStream: return "Le flux de réponse du serveur ne correspond pas au protocole choisi."
        case .truncatedStream: return "La connexion s’est fermée avant la fin de la réponse. Le texte reçu est conservé comme réponse interrompue."
        case .responseTooLarge: return "La réponse dépasse la limite de sécurité de cette version. Réduis la longueur demandée."
        case .responseFailed: return "L’API Responses a signalé un échec. Le texte déjà reçu est conservé."
        case .responseIncomplete: return "L’API a indiqué que la réponse est incomplète. Le texte reçu est conservé."
        case .outputLimitReached: return "La limite de sortie a été atteinte avant la fin de la réponse. Le contenu reçu est conservé. Augmente la limite de réponse ou réduis la demande."
        case .unsupportedResponse: return "Cette réponse utilise un outil ou un format non pris en charge par Eudes."
        case .noModel: return "Choisis un modèle ou saisis son identifiant dans les réglages du serveur."
        case .storage(let detail): return "Impossible d’accéder aux données locales. \(detail)"
        case .keychain: return "Le trousseau iOS est inaccessible. Déverrouille l’iPhone et réessaie."
        }
    }
}

func friendlyError(_ error: Error) -> String {
    if let error = error as? LocalModelPrompt.PromptError { return error.localizedDescription }
    if let error = error as? LocalLlamaEngine.EngineError { return error.localizedDescription }
    if let error = error as? AppleModelError { return error.localizedDescription }
    if let error = error as? EudesError { return error.localizedDescription }
    if let error = error as? ImageAttachmentError { return error.localizedDescription }
    if let error = error as? URLError {
        switch error.code {
        case .cancelled: return "Réponse arrêtée."
        case .timedOut: return "La connexion a dépassé son délai d’attente. Vérifie la disponibilité du serveur et réessaie."
        case .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost:
            return "Serveur inaccessible. Vérifie le Wi-Fi ou le VPN, l’autorisation Réseau local d’iOS et le port de ton API."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "Certificat HTTPS refusé. Utilise un certificat approuvé par iOS et valable pour cette adresse IP."
        default: return "La connexion locale a échoué (code \(error.errorCode))."
        }
    }
    return "L’opération a échoué. Réessaie après avoir vérifié le serveur et le stockage de l’iPhone."
}

/// Only locally defined messages and numeric status codes are retained. Never
/// persist a server response body, arbitrary NSError text, URL, prompt or key.
func generationFailureDetail(_ error: Error) -> String {
    if let failure = error as? LocalModelPrompt.PromptError { return failure.localizedDescription }
    if let failure = error as? EudesError {
        switch failure {
        case .server(let code):
            switch code {
            case 400, 422: return "Le serveur a refusé la requête (HTTP \(code)). Vérifie les paramètres et le modèle choisis."
            case 401, 403: return "Accès refusé par le serveur (HTTP \(code)). Vérifie la clé et les droits du modèle."
            case 404: return "Ressource introuvable (HTTP 404). Vérifie l’adresse et la disponibilité du modèle pour ton compte."
            case 429: return "Limite de requêtes atteinte ou serveur occupé (HTTP 429). Réessaie plus tard."
            default: return "Le serveur a renvoyé HTTP \(code)."
            }
        case .contextExceeded: return "La conversation dépasse la limite de contexte signalée par l’API."
        case .emptyResponse: return "Le flux s’est terminé sans texte de réponse. Le fournisseur n’a pas indiqué ici pourquoi."
        case .malformedStream: return "Le format du flux reçu ne correspond pas au protocole sélectionné."
        case .truncatedStream: return "La connexion s’est interrompue avant la fin du flux."
        case .responseTooLarge: return "La réponse dépasse la limite de taille d'Eudes."
        case .responseFailed: return "L’API a signalé un échec de génération."
        case .responseIncomplete: return "L’API a signalé que la réponse est incomplète, sans autre précision."
        case .outputLimitReached: return "Limite de sortie atteinte (finish_reason: length). Augmente la limite ou réduis la demande."
        case .unsupportedResponse: return "La réponse utilise un format ou un outil non pris en charge."
        case .redirect: return "La requête a été redirigée ; Eudes bloque les redirections."
        case .invalidResponse: return "La réponse du serveur ne correspond pas au protocole sélectionné."
        case .insecureHTTP: return "La connexion HTTP n’est pas autorisée pour ce serveur."
        case .invalidAddress, .publicAddress: return "L’adresse du serveur n’est pas valide ou autorisée."
        case .noModel: return "Aucun modèle n’a été sélectionné."
        case .keychain: return "La clé n’est pas accessible dans le trousseau."
        case .storage: return "Une erreur de stockage local est survenue."
        }
    }
    if let failure = error as? URLError {
        switch failure.code {
        case .timedOut: return "La requête a expiré : aucune donnée n’est arrivée à temps ou sa durée maximale a été atteinte."
        case .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed:
            return "Connexion au serveur impossible ou interrompue (code réseau \(failure.errorCode))."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "La connexion HTTPS a échoué lors de la vérification du certificat (code réseau \(failure.errorCode))."
        default: return "La connexion a échoué (code réseau \(failure.errorCode))."
        }
    }
    if let failure = error as? AppleModelError { return failure.localizedDescription }
    if let failure = error as? ImageAttachmentError { return failure.localizedDescription }
    return "Eudes n’a pas reçu de détail exploitable pour cette erreur."
}

// Local presentation preference; independent of conversation data and server settings.
enum ConversationMenuMode: String, CaseIterable, Identifiable {
    case bottom, left, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottom: return "En bas"
        case .left: return "À gauche"
        case .right: return "À droite"
        }
    }
    var explanation: String {
        switch self {
        case .bottom: return "Une feuille remonte depuis le bas."
        case .left: return "Un volet entre depuis la gauche."
        case .right: return "Un volet entre depuis la droite."
        }
    }
    var symbol: String {
        switch self {
        case .bottom: return "arrow.up"
        case .left: return "arrow.right"
        case .right: return "arrow.left"
        }
    }
}

/// One action per swipe, using physical edges independently of the interface language.
enum ConversationEdgeSwipe {
    enum Action: Equatable { case history, newConversation }

    static func action(startX: CGFloat, width: CGFloat, translation: CGSize,
                       menuMode: ConversationMenuMode, newConversationEnabled: Bool,
                       canStartNewConversation: Bool) -> Action? {
        guard width > 0, startX >= 0, startX <= width else { return nil }
        let dx = translation.width
        let dy = translation.height
        guard abs(dy) <= abs(dx) * 0.5 else { return nil }

        // When enabled, the right edge is reserved even if the swipe is too short
        // or a response is running. It must never also open the history panel.
        if newConversationEnabled, startX >= width - 28 {
            guard canStartNewConversation, startX >= width - 24, dx <= -90 else { return nil }
            return .newConversation
        }

        switch menuMode {
        case .left where startX <= 28 && dx >= 55:
            return .history
        case .right where !newConversationEnabled && startX >= width - 28 && dx <= -55:
            return .history
        default:
            return nil
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatique"
        case .light: return "Clair"
        case .dark: return "Sombre"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Local, normalized JPEG only. No URL, executable content or remote-image loading.
struct ImageAttachment: Identifiable, Codable, Equatable {
    var id = UUID()
    let data: Data
    static let maxCount = 4
    static func importData(_ data: Data) throws -> ImageAttachment {
        guard data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.heif.identifier].contains(type),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 50_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImageAttachmentError.invalid }
        let size = CGSize(width: image.width, height: image.height)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = normalized.jpegData(compressionQuality: 0.8), jpeg.count <= 2 * 1024 * 1024 else {
            throw ImageAttachmentError.invalid
        }
        return ImageAttachment(data: jpeg)
    }
}
enum ImageAttachmentError: LocalizedError {
    case invalid, incompatible, limit
    var errorDescription: String? {
        switch self {
        case .invalid: return "Image refusée : JPEG, PNG ou HEIC statique, 8 Mo et 50 mégapixels maximum."
        case .incompatible: return "Images non disponibles pour cette connexion et ce modèle. Consulte les capacités annoncées dans les réglages du serveur. Le brouillon est conservé."
        case .limit: return "Maximum 4 images par message et 8 Mo d’images dans le contexte envoyé."
        }
    }
}

/// Providers come only from the explicit native paste action, never from clipboard polling.
struct PastedImageLoader {
    static func load(_ provider: NSItemProvider) async throws -> ImageAttachment {
        try Task.checkCancellation()
        let allowed = [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier]
        guard let type = allowed.first(where: { provider.hasItemConformingToTypeIdentifier($0) })
            ?? provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
            throw ImageAttachmentError.invalid
        }
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? ImageAttachmentError.invalid) }
            }
        }
        try Task.checkCancellation()
        return try ImageAttachment.importData(bytes)
    }
}

/// Marketing 1.1 is displayed as 1.01; build number remains independent.
enum AppRelease {
    static var displayVersion: String { format(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") }
    static func format(_ version: String) -> String {
        let parts = version.split(separator: ".")
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return version.isEmpty ? "—" : version }
        return String(format: "%d.%02d", major, minor)
    }
}


/// Only explicitly returned fields are retained; model names never imply a capacity.
struct TokenLimit: Codable, Equatable {
    var tokens: Int
    var source: String
}
struct ModelLimits: Codable, Equatable {
    var advertised: [TokenLimit] = []
    var server: [TokenLimit] = []
    var output: [TokenLimit] = []
    var observedAt = Date()
    var context: Int? { (advertised + server).map(\.tokens).filter { $0 > 0 }.min() }
    var outputLimit: Int? { output.map(\.tokens).filter { $0 > 0 }.min() }
    var summary: String {
        let rows = advertised.map { "Capacité annoncée : \($0.tokens) · \($0.source)" }
            + server.map { "Limite serveur annoncée : \($0.tokens) · \($0.source)" }
            + output.map { "Plafond de sortie annoncé : \($0.tokens) · \($0.source)" }
        return rows.isEmpty ? "Limite inconnue" : rows.joined(separator: "\n")
    }
}
enum CapabilityStatus: String, Codable {
    case supported, unsupported, unknown
    var title: String {
        switch self {
        case .supported: return "Pris en charge"
        case .unsupported: return "Non pris en charge"
        case .unknown: return "Non déterminé"
        }
    }
}
struct ModelCapabilities: Codable, Equatable {
    var images: CapabilityStatus = .unknown
    var pdf: CapabilityStatus = .unknown
    var source: String? = nil
    // nil means unadvertised or contradictory; model names never imply tool support.
    var tools: Bool? = nil
    // Optional for backward compatibility; only trusted for OpenRouter's HTTPS host.
    var reasoningParameter: Bool? = nil
    var reasoningEfforts: [String]? = nil
    var reasoningMandatory: Bool? = nil
}
struct ModelCatalog {
    var ids: [String]
    var limits: [String: ModelLimits] = [:]
    var capabilities: [String: ModelCapabilities] = [:]
    static func decode(_ data: Data) throws -> ModelCatalog {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else { throw EudesError.invalidResponse }
        var result = ModelCatalog(ids: [])
        var conflictingCapabilities = Set<String>()
        func limit(_ raw: Any?, _ source: String) -> TokenLimit? {
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
                  value.doubleValue >= 1, value.doubleValue <= 100_000_000 else { return nil }
            return TokenLimit(tokens: value.intValue, source: source)
        }
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            result.ids.append(id)
            var values = result.limits[id] ?? ModelLimits()
            if let value = limit(row["context_length"], "models.context_length") { values.advertised.append(value) }
            if let value = limit(row["max_model_len"], "models.max_model_len") { values.server.append(value) }
            if let provider = row["top_provider"] as? [String: Any] {
                if let value = limit(provider["context_length"], "models.top_provider.context_length") { values.server.append(value) }
                if let value = limit(provider["max_completion_tokens"], "models.top_provider.max_completion_tokens") { values.output.append(value) }
            }
            result.limits[id] = values
            var capabilities = ModelCapabilities()
            // Documented exhaustive input modalities; never infer vision from the name.
            if let architecture = row["architecture"] as? [String: Any],
               let modalities = architecture["input_modalities"] as? [String],
               !modalities.isEmpty, modalities.contains("text") || modalities.contains("image") {
                capabilities.images = modalities.contains("image") ? .supported : .unsupported
                capabilities.source = "models.architecture.input_modalities"
            }
            if let parameters = row["supported_parameters"] as? [String] {
                capabilities.reasoningParameter = parameters.contains("reasoning") || parameters.contains("reasoning_effort")
            }
            let parameterTools = (row["supported_parameters"] as? [String])
                .flatMap { $0.isEmpty ? nil : $0.contains("tools") }
            let advertisedTools = (row["capabilities"] as? [String])
                .flatMap { $0.isEmpty ? nil : $0.contains("tools") }
            if let parameterTools, let advertisedTools, parameterTools != advertisedTools {
                capabilities.tools = nil
            } else {
                capabilities.tools = parameterTools ?? advertisedTools
            }
            if let reasoning = row["reasoning"] as? [String: Any],
               let efforts = reasoning["supported_efforts"] as? [String], !efforts.isEmpty,
               efforts.allSatisfy({ ThinkingMode.effort($0) != nil }), Set(efforts).count == efforts.count {
                capabilities.reasoningEfforts = efforts
                if let mandatory = reasoning["mandatory"] as? NSNumber,
                   CFGetTypeID(mandatory) == CFBooleanGetTypeID() {
                    capabilities.reasoningMandatory = mandatory.boolValue
                }
            }
            // Generic file/image support does not establish native PDF support.
            if let previous = result.capabilities[id], previous != capabilities {
                conflictingCapabilities.insert(id)
            }
            if conflictingCapabilities.contains(id) {
                capabilities = ModelCapabilities() // Conflicting duplicate rows are not evidence.
            }
            result.capabilities[id] = capabilities
        }
        result.ids = Array(Set(result.ids)).sorted()
        return result
    }
}
extension ServerProfile {
    func limits(for model: String) -> ModelLimits { modelLimits?[visionKey(model)] ?? ModelLimits() }
    func contextBudget(for model: String) -> Int? { contextBudgets?[visionKey(model)].flatMap { $0 > 0 ? $0 : nil } }
    func maximumContext(for model: String) -> Int? {
        // Apple Intelligence fixes its own window: a manual value is never used. The window
        // itself comes from the limits the app already read from the system, never from a
        // direct Foundation Models call here (that call is not main-actor safe).
        if isApple { return model == self.model ? limits(for: model).context : nil }
        if isLocalLFM { return model == self.model ? LocalModelCatalog.resolvedContextSize(localContextTokens, modelID: model) : nil }
        if let manual = contextBudgets?[visionKey(model)] { return manual > 0 ? manual : nil }
        return limits(for: model).context
    }
    func hasManualContext(for model: String) -> Bool { contextBudgets?[visionKey(model)] != nil }
    mutating func setContextBudget(_ value: Int?, model: String) {
        if contextBudgets == nil { contextBudgets = [:] }
        let key = visionKey(model)
        // Zero is an explicit empty field, distinct from an absent automatic value.
        guard value == nil || (0...100_000_000).contains(value!) else { return }
        contextBudgets?[key] = value ?? 0
    }
    mutating func apply(_ catalog: ModelCatalog) {
        availableModels = catalog.ids
        if modelLimits == nil { modelLimits = [:] }
        if modelCapabilities == nil { modelCapabilities = [:] }
        // Replace this endpoint/protocol snapshot, including removed/missing metadata.
        let prefix = visionKey("")
        modelLimits = modelLimits?.filter { !$0.key.hasPrefix(prefix) }
        modelCapabilities = modelCapabilities?.filter { !$0.key.hasPrefix(prefix) }
        for id in catalog.ids {
            let key = visionKey(id)
            modelLimits?[key] = catalog.limits[id] ?? ModelLimits()
            modelCapabilities?[key] = catalog.capabilities[id] ?? ModelCapabilities()
        }
    }
    func effectiveOutput(_ requested: Int?, model: String) -> Int? {
        let explicit = requested.flatMap { $0 > 0 ? $0 : nil }
        return [explicit, limits(for: model).outputLimit].compactMap { $0 }.min()
    }
}

struct ContextAssessment: Equatable {
    var estimatedInput: Int
    var output: Int?
    var margin: Int
    var budget: Int?
    var images: Int
    var warning: String? {
        guard let budget else { return nil } // Unknown preserves existing sending behavior.
        guard let output else {
            return "La réserve de sortie est inconnue : le budget de contexte de \(budget) tokens ne peut pas être garanti. Aucun historique ne sera tronqué. Renseigne une limite volontaire dans Réglages si nécessaire."
        }
        if estimatedInput + output + margin > budget {
            return "Budget de contexte possiblement dépassé : environ \(estimatedInput) tokens de texte + \(output) réservés à la réponse + \(margin) de marge, pour \(budget)." + (images > 0 ? " Le coût des \(images) image(s) est inconnu et s’ajoute à ce total." : "") + " Aucun message ne sera supprimé. Le comptage reste estimatif ; le serveur peut refuser."
        }
        if images > 0 { return "Le coût des \(images) image(s) en tokens est inconnu. Le budget de \(budget) inclut une réserve de sortie de \(output) et une marge de \(margin), mais ne peut pas être garanti. Aucun message ne sera supprimé." }
        return nil
    }
    static func make(profile: ServerProfile, model: String, messages: [ChatMessage], instructions: String, requestedOutput: Int?) -> ContextAssessment {
        let complete = messages.filter { $0.state == .complete }
        // Byte-based estimate converted to tokens: roughly 4 UTF-8 bytes per token
        // (French accented characters included). Deliberately conservative, NOT an
        // exact tokenizer or a guaranteed upper bound.
        let bytes = instructions.utf8.count + complete.reduce(0) { $0 + $1.text.utf8.count }
        let estimate = bytes / 4 + complete.count * 16 + (instructions.isEmpty ? 0 : 16)
        let limits = [profile.maximumContext(for: model), profile.limits(for: model).server.map(\.tokens).min()].compactMap { $0 }
        let budget = limits.min()
        let margin = max(128, (budget ?? 0) / 20)
        return ContextAssessment(estimatedInput: estimate, output: profile.effectiveOutput(requestedOutput, model: model), margin: margin, budget: budget,
                                 images: complete.reduce(0) { $0 + ($1.images?.count ?? 0) })
    }
}


enum ModelMetadataField: Hashable { case context, capabilities }

extension ServerProfile {
    /// Refresh only requested fields for one endpoint/protocol/model. Manual values are untouched.
    mutating func applyMetadata(_ catalog: ModelCatalog, model: String, fields: Set<ModelMetadataField>) {
        let key = visionKey(model)
        if fields.contains(.context) {
            var value = limits(for: model)
            let fresh = catalog.ids.contains(model) ? catalog.limits[model] : nil
            value.advertised = fresh?.advertised ?? []
            value.server = fresh?.server ?? []
            value.observedAt = Date()
            if modelLimits == nil { modelLimits = [:] }
            modelLimits?[key] = value
        }
        if fields.contains(.capabilities) {
            if modelCapabilities == nil { modelCapabilities = [:] }
            modelCapabilities?[key] = catalog.ids.contains(model) ? (catalog.capabilities[model] ?? ModelCapabilities()) : ModelCapabilities()
        }
    }
}


