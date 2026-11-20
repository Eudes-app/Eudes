import AppIntents
import Foundation
import Security

/// Siri speaks these errors without exposing server responses, prompts, or credentials.
enum SiriAssistantError: Error, CustomLocalizedStringResourceConvertible, Equatable {
    case disabled, unlockFirst, busy, noModel, emptyQuestion, tooLong, timeout, sendFailed, storage, queueFull, configurationChanged
    case voiceConversationEnded, voiceContextFull, voiceTimeout
    case webSearchBlocked, webSearchFailed
    case localWebPlanningFailed, localSynthesisFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .disabled: "Active d’abord Siri écran verrouillé dans les réglages d'Eudes."
        case .unlockFirst: "Déverrouille ton iPhone une première fois après son redémarrage pour utiliser Eudes avec Siri."
        case .busy: "Eudes répond déjà à une demande Siri. Réessaie dans un instant."
        case .noModel: "Choisis un serveur et un modèle dans Eudes, puis active Siri écran verrouillé."
        case .emptyQuestion: "Pose une question à Eudes."
        case .tooLong: "Cette demande ou cette réponse est trop longue pour Siri. Essaie une question plus courte dans Eudes."
        case .timeout: "Le modèle n’a pas répondu assez vite pour Siri. Choisis un modèle plus rapide ou réduis son raisonnement dans Eudes."
        case .sendFailed: "Eudes n’a pas pu obtenir de réponse. Vérifie le serveur et le modèle dans Eudes lorsque tu es disponible."
        case .storage: "Eudes n’a pas pu enregistrer cet échange Siri. Ouvre Eudes lorsque tu es disponible."
        case .queueFull: "Ouvre Eudes pour récupérer tes échanges Siri avant de poser une autre question."
        case .configurationChanged: "Les réglages Siri d'Eudes ont changé. Relance ta demande."
        case .voiceConversationEnded: "Cette session vocale est terminée. Relance l’assistant Eudes."
        case .voiceContextFull: "Cette session atteint sa limite de contexte estimée. Les échanges terminés sont enregistrés. Relance l’assistant pour une nouvelle conversation."
        case .voiceTimeout: "Le modèle met trop de temps à répondre. Relance l’assistant ou choisis un modèle plus rapide dans Eudes."
        case .webSearchBlocked: "Le moteur de recherche demande une vérification ou limite les requêtes. Aucun résultat Web n’a été utilisé. Réessaie plus tard."
        case .webSearchFailed: "La recherche Web n’a pas abouti. Aucun résultat Web n’a été utilisé. Vérifie ta connexion ou réessaie plus tard."
        case .localWebPlanningFailed: "Le modèle local n’a pas pu préparer la recherche Web. Ouvre Eudes et réessaie."
        case .localSynthesisFailed: "Le modèle local n’a pas pu produire la réponse. Ouvre Eudes et réessaie."
        }
    }
}

/// Dedicated items: the ordinary conversation store and API-key accessibility are unchanged.
/// No synchronization or backup migration to another device is allowed.
struct SiriAssistantKeychain {
    let service: String
    static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    init(service: String = "fr.eudes.app.siri-assistant") { self.service = service }

    func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func read(_ account: String) throws -> Data? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw SiriAssistantError.storage }
        return data
    }

    func write(_ account: String, data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibility]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        if status == errSecInteractionNotAllowed || status == errSecNotAvailable {
            throw SiriAssistantError.unlockFirst
        }
        guard status == errSecSuccess else { throw SiriAssistantError.storage }
    }
}

@MainActor
struct SiriAssistantPersistence {
    var read: (String) throws -> Data?
    var write: (String, Data) throws -> Void
    var delete: (String) throws -> Void
    var isRevoked: () -> Bool = { false }
    var setRevoked: (Bool) -> Void = { _ in }

    static func keychain(_ keychain: SiriAssistantKeychain = SiriAssistantKeychain()) -> Self {
        Self(read: keychain.read, write: { try keychain.write($0, data: $1) }, delete: keychain.delete,
             isRevoked: { UserDefaults.standard.bool(forKey: "voice.siri.revoked.\(keychain.service)") },
             setRevoked: { UserDefaults.standard.set($0, forKey: "voice.siri.revoked.\(keychain.service)") })
    }
}

/// Headless Siri requests and local voice sessions. Never reads protected chat history or UI state.
/// Only the explicitly enabled configuration and completed Siri exchanges are available
/// while locked, after the first unlock since boot. The UI imports the queue on unlock.
@MainActor
final class SiriAssistantService {
    static let shared = SiriAssistantService()
    static let configurationAccount = "configuration"
    static let pendingAccount = "pending-conversations"
    static let maximumPending = 10
    static let maximumQuestionBytes = 16_384
    static let maximumReplyBytes = 32_768
    static let maximumVoiceConversationBytes = 131_072
    static let maximumVoiceTurns = 20
    private static let maximumStoredBytes = 524_288

    private struct Configuration: Codable, Equatable {
        let profile: ServerProfile
        let model: String
        let key: String
        let maxTokens: Int?
        // Optional so existing enabled configurations keep working after an upgrade.
        let voiceInstruction: String?
    }
    private struct VoiceConversation {
        let configuration: Configuration
        var conversation: Conversation
    }
    private struct ActiveRequest {
        let id: UUID
        let voiceSession: VoiceConversation?
        let question: String
        let webMode: VoiceWebSearchMode
        let continuation: CheckedContinuation<String, Error>
        let onWebSearchProgress: @MainActor (Bool) -> Void
        let onWebResearchTrace: @MainActor (WebResearchTrace) -> Void
        var webResearchTrace: WebResearchTrace?
        var isSearchingWeb = false
        var generation: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    private let persistence: SiriAssistantPersistence
    private let client: (any EudesAPIClient)?
    private let timeout: Duration
    private let voiceTimeout: Duration
    private let webResearch: HybridWebResearch
    private let voiceWebSearchMode: @MainActor () -> VoiceWebSearchMode
    private let webToolCallLimit: @MainActor () -> Int
    private var active: ActiveRequest?
    private var voiceConversation: VoiceConversation?
    private(set) var lastWebResearchTrace: WebResearchTrace?

    init(persistence: SiriAssistantPersistence? = nil,
         client: (any EudesAPIClient)? = nil, timeout: Duration = .seconds(25),
         voiceTimeout: Duration = .seconds(120),
         webSearch: any WebSearching = WebSearchClient(),
         webResearchModel: (any WebResearchModelClient)? = nil,
         localWebResearchModel: (any WebResearchModelClient)? = nil,
         webPageReader: any WebPageReading = DirectWebPageReader(),
         appleWebResearchSession: any AppleWebResearchSession = NativeAppleWebResearchSession(),
         voiceWebSearchMode: @escaping @MainActor () -> VoiceWebSearchMode = {
             VoiceWebSearchMode(rawValue: UserDefaults.standard.string(forKey: "voiceWebSearchMode") ?? "") ?? .disabled
         },
         webToolCallLimit: @escaping @MainActor () -> Int = { WebResearchBudget.selected() }) {
        self.persistence = persistence ?? .keychain()
        self.client = client
        self.timeout = timeout
        self.voiceTimeout = voiceTimeout
        let researchModel: (any WebResearchModelClient)? = webResearchModel
            ?? ((client == nil || client is LocalAPIClient) ? LocalWebResearchModelClient() : nil)
        self.webResearch = HybridWebResearch(search: webSearch, modelClient: researchModel,
                                             localModelClient: localWebResearchModel ?? LocalLFMWebResearchModelClient(),
                                             pageReader: webPageReader, appleSession: appleWebResearchSession)
        self.voiceWebSearchMode = voiceWebSearchMode
        self.webToolCallLimit = webToolCallLimit
    }

    var isEnabled: Bool { (try? configuration()) != nil }

    func configure(profile: ServerProfile, model: String, key: String, maxTokens: Int?,
                   voiceInstruction: String = VoiceResponseInstruction.selected()) throws {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw SiriAssistantError.noModel }
        if !profile.isOnDevice { _ = try LocalEndpoint(profile.baseURL, allowsHTTP: profile.allowsHTTP) }
        var selected = profile
        let modelKey = profile.visionKey(model)
        selected.model = model
        selected.availableModels = nil
        selected.imageCompatibility = nil
        selected.reasoningDisplay = nil
        selected.modelLimits = profile.modelLimits?.filter { $0.key == modelKey }
        selected.contextBudgets = profile.contextBudgets?.filter { $0.key == modelKey }
        selected.modelCapabilities = profile.modelCapabilities?.filter { $0.key == modelKey }
        selected.thinkingModes = profile.thinkingModes?.filter { $0.key == modelKey }
        selected.thinkingFormats = profile.thinkingFormats?.filter { $0.key == modelKey }
        let value = Configuration(profile: selected, model: model, key: profile.isOnDevice ? "" : key,
                                  maxTokens: maxTokens,
                                  voiceInstruction: VoiceResponseInstruction.effectiveText(voiceInstruction))
        if (try? configuration()) == value { return }
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= Self.maximumStoredBytes else { throw SiriAssistantError.storage }
        try persistence.write(Self.configurationAccount, encoded)
        persistence.setRevoked(false)
        voiceConversation = nil
        if let id = active?.id { finish(id: id, result: .failure(SiriAssistantError.configurationChanged)) }
    }

    func disable() throws {
        // Revoke before touching Keychain: a storage error must never leave Siri enabled.
        // This non-secret latch survives process termination and is cleared only by configure().
        persistence.setRevoked(true)
        voiceConversation = nil
        if let id = active?.id { finish(id: id, result: .failure(SiriAssistantError.disabled)) }
        try persistence.delete(Self.configurationAccount)
    }

    func pendingConversations() throws -> [Conversation] {
        guard let bytes = try persistence.read(Self.pendingAccount) else { return [] }
        guard bytes.count <= Self.maximumStoredBytes,
              let values = try? JSONDecoder().decode([Conversation].self, from: bytes),
              values.count <= Self.maximumPending else { throw SiriAssistantError.storage }
        return values
    }

    /// An active voice conversation is persisted after every completed turn, but imported
    /// only after the session ends. A process restart naturally releases the in-memory hold.
    func pendingConversationsForImport() throws -> [Conversation] {
        let heldID = voiceConversation?.conversation.id
        return try pendingConversations().filter { $0.id != heldID }
    }

    /// The UI calls this only after its protected conversation save succeeds.
    /// Stable IDs make retries safe if the app stops between save and acknowledgement.
    func acknowledge(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let heldID = voiceConversation?.conversation.id
        let remaining = try pendingConversations().filter { !ids.contains($0.id) || $0.id == heldID }
        if remaining.isEmpty { try persistence.delete(Self.pendingAccount) }
        else { try savePending(remaining) }
    }

    /// Starts a new, independent conversation using the explicitly enabled snapshot.
    /// Existing private conversations and drafts are never read or modified here.
    func beginVoiceConversation() throws -> UUID {
        guard active == nil, voiceConversation == nil else { throw SiriAssistantError.busy }
        guard let configuration = try configuration() else { throw SiriAssistantError.disabled }
        guard try pendingConversations().count < Self.maximumPending else { throw SiriAssistantError.queueFull }
        let conversation = Conversation(serverID: configuration.profile.id, model: configuration.model)
        voiceConversation = VoiceConversation(configuration: configuration, conversation: conversation)
        return conversation.id
    }

    func isVoiceConversationValid(_ id: UUID) -> Bool {
        guard let session = voiceConversation, session.conversation.id == id else { return false }
        return (try? configuration()) == session.configuration
    }

    /// Late replies are never persisted. If Web research started, a cancelled turn
    /// may retain a diagnostic record excluded from subsequent model context.
    func endVoiceConversation(_ id: UUID) {
        guard voiceConversation?.conversation.id == id else { return }
        voiceConversation = nil
        if let request = active, request.voiceSession?.conversation.id == id {
            finish(id: request.id, result: .failure(CancellationError()))
        }
    }

    func answerVoice(_ question: String, conversationID: UUID,
                     onWebSearchProgress: @escaping @MainActor (Bool) -> Void = { _ in },
                     onWebResearchTrace: @escaping @MainActor (WebResearchTrace) -> Void = { _ in }) async throws -> String {
        try Task.checkCancellation()
        guard let session = voiceConversation, session.conversation.id == conversationID else {
            throw SiriAssistantError.voiceConversationEnded
        }
        guard let current = try configuration() else { throw SiriAssistantError.disabled }
        guard current == session.configuration else { throw SiriAssistantError.configurationChanged }
        let text = try validatedQuestion(question)
        guard active == nil else { throw SiriAssistantError.busy }
        // Opening apps or presenting confirmation requires the unlocked foreground UI.
        // Never let a background model pretend that it performed these operations.
        if VoiceAction.requiresForeground(text) {
            return VoiceActionError.foreground.localizedDescription
        }
        try validateVoiceContext(question: text, session: session)
        return try await request(question: text, configuration: current, voiceSession: session,
                                 deadline: voiceTimeout, timeoutError: .voiceTimeout,
                                 onWebSearchProgress: onWebSearchProgress,
                                 onWebResearchTrace: onWebResearchTrace)
    }

    func answer(_ question: String) async throws -> String {
        try Task.checkCancellation()
        let text = try validatedQuestion(question)
        guard active == nil, voiceConversation == nil else { throw SiriAssistantError.busy }
        guard let configuration = try configuration() else { throw SiriAssistantError.disabled }
        guard try pendingConversations().count < Self.maximumPending else { throw SiriAssistantError.queueFull }
        return try await request(question: text, configuration: configuration, voiceSession: nil,
                                 deadline: timeout, timeoutError: .timeout)
    }

    private func validatedQuestion(_ question: String) throws -> String {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SiriAssistantError.emptyQuestion }
        guard text.utf8.count <= Self.maximumQuestionBytes else { throw SiriAssistantError.tooLong }
        return text
    }

    private func validateVoiceContext(question: String, session: VoiceConversation,
                                      webContext: WebSearchContext? = nil,
                                      webResearchTrace: WebResearchTrace? = nil) throws {
        let messages = modelMessages(question: question, conversation: session.conversation, webContext: webContext)
        let bytes = messages.reduce(0) { $0 + $1.text.utf8.count }
        var prospective = session.conversation
        var pendingReply = ChatMessage(role: .assistant, text: "")
        pendingReply.webContext = webContext
        pendingReply.webResearchTrace = webResearchTrace
        prospective.messages += [ChatMessage(role: .user, text: question), pendingReply]
        let storedBytes = try JSONEncoder().encode(prospective).count
        // Reserve enough room for the largest accepted reply before starting the request.
        guard session.conversation.messages.count / 2 < Self.maximumVoiceTurns,
              bytes + Self.maximumReplyBytes <= Self.maximumVoiceConversationBytes,
              storedBytes + Self.maximumReplyBytes <= Self.maximumVoiceConversationBytes else {
            throw SiriAssistantError.voiceContextFull
        }
        let configuration = session.configuration
        let assessment = ContextAssessment.make(profile: configuration.profile, model: configuration.model,
            messages: messages, instructions: modelInstructions(configuration: configuration,
                conversation: session.conversation, webContext: webContext),
            requestedOutput: configuration.maxTokens)
        if !configuration.profile.isLocalLFM, let budget = assessment.budget,
           assessment.estimatedInput + (assessment.output ?? 0) + assessment.margin > budget {
            // This is the app's conservative estimate, not a provider tokenizer.
            // Unknown provider limits are not invented, and history is never truncated.
            throw SiriAssistantError.voiceContextFull
        }
    }

    private func request(question: String, configuration: Configuration, voiceSession: VoiceConversation?,
                         deadline: Duration, timeoutError: SiriAssistantError,
                         onWebSearchProgress: @escaping @MainActor (Bool) -> Void = { _ in },
                         onWebResearchTrace: @escaping @MainActor (WebResearchTrace) -> Void = { _ in }) async throws -> String {
        let id = UUID()
        // A policy snapshot applies to this turn only. The separate text-only Siri action
        // intentionally retains its original behavior, including when voice search is Always.
        let webMode = voiceSession == nil ? VoiceWebSearchMode.disabled : voiceWebSearchMode()
        let maximumToolCalls = WebResearchBudget.normalized(webToolCallLimit())
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lastWebResearchTrace = nil
                active = ActiveRequest(id: id, voiceSession: voiceSession, question: question, webMode: webMode,
                                       continuation: continuation, onWebSearchProgress: onWebSearchProgress,
                                       onWebResearchTrace: onWebResearchTrace)
                active?.generation = Task { @MainActor [weak self] in
                    await self?.generate(id: id, question: question, configuration: configuration,
                                         voiceSession: voiceSession, webMode: webMode, maximumToolCalls: maximumToolCalls)
                }
                active?.timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: deadline) } catch { return }
                    self?.finish(id: id, result: .failure(timeoutError))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, result: .failure(CancellationError())) }
        }
    }

    private func configuration() throws -> Configuration? {
        guard !persistence.isRevoked() else { return nil }
        guard let bytes = try persistence.read(Self.configurationAccount) else { return nil }
        guard bytes.count <= Self.maximumStoredBytes,
              let value = try? JSONDecoder().decode(Configuration.self, from: bytes),
              !value.model.isEmpty else { throw SiriAssistantError.storage }
        return value
    }

    private func modelMessages(question: String, conversation: Conversation?, webContext: WebSearchContext?) -> [ChatMessage] {
        HybridWebResearch.appending(webContext, to:
            (conversation?.modelMessages.filter { $0.state == .complete } ?? []) + [ChatMessage(role: .user, text: question)])
    }

    private func modelInstructions(configuration: Configuration, conversation: Conversation?, webContext: WebSearchContext?) -> String {
        var instructions = configuration.profile.effectiveInstruction
        if webContext != nil || conversation?.messages.contains(where: { $0.webContext != nil }) == true {
            instructions += "\n\n" + HybridWebResearch.evidenceInstructions
        }
        if conversation != nil {
            instructions = VoiceResponseInstruction.appending(to: instructions,
                voiceInstruction: configuration.voiceInstruction ?? VoiceResponseInstruction.defaultText)
        }
        return instructions
    }

    private func generate(id: UUID, question: String, configuration: Configuration,
                          voiceSession: VoiceConversation?, webMode: VoiceWebSearchMode, maximumToolCalls: Int) async {
        let transport: any EudesAPIClient
        if let client { transport = client }
        else if configuration.profile.isApple { transport = AppleModelClient() }
        else if configuration.profile.isLocalLFM { transport = LocalModelClient(directVoiceResponse: voiceSession != nil) }
        else { transport = LocalAPIClient() }
        var userMessage = ChatMessage(role: .user, text: question)
        if voiceSession != nil { userMessage.isVoiceRequest = true }
        let needsWeb = voiceSession != nil && webMode.shouldSearch(for: question)
        if needsWeb { userMessage.webSearchRequested = true }
        var webContext: WebSearchContext?
        var text = ""
        var usage: TokenUsage?
        var tooLong = false
        do {
            try Task.checkCancellation()
            if needsWeb {
                setWebSearchProgress(true, id: id)
                do {
                    webContext = try await webResearch.prepare(profile: configuration.profile,
                        key: configuration.key, model: configuration.model,
                        messages: modelMessages(question: question, conversation: voiceSession?.conversation, webContext: nil),
                        systemPrompt: modelInstructions(configuration: configuration,
                            conversation: voiceSession?.conversation, webContext: nil),
                        temperature: configuration.profile.effectiveCreativity, maxTokens: configuration.maxTokens,
                        maximumToolCalls: maximumToolCalls,
                        onTrace: { [weak self] trace in self?.setWebResearchTrace(trace, id: id) })
                }
                catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    if let modelError = error as? EudesError, case .contextExceeded = modelError {
                        throw SiriAssistantError.voiceContextFull
                    }
                    if (error as? WebSearchError) == .blocked { throw SiriAssistantError.webSearchBlocked }
                    if error is WebSearchError { throw SiriAssistantError.webSearchFailed }
                    if configuration.profile.isLocalLFM,
                       error is LocalLlamaEngine.EngineError || error is LocalModelPrompt.PromptError || error is LocalModelFileStore.StoreError {
                        throw SiriAssistantError.localWebPlanningFailed
                    }
                    throw error
                }
                try Task.checkCancellation()
                guard active?.id == id else { return }
                guard voiceWebSearchMode() == webMode else { throw SiriAssistantError.configurationChanged }
                guard try self.configuration() == configuration else { throw SiriAssistantError.configurationChanged }
                if let voiceSession {
                    try validateVoiceContext(question: question, session: voiceSession, webContext: webContext,
                                             webResearchTrace: active?.webResearchTrace)
                }
                setWebSearchProgress(false, id: id)
            }
            // Existing transport preserves each server's protocol and thinking choices.
            // Reasoning callbacks are intentionally discarded and never spoken by Siri.
            try await transport.streamWithReasoning(profile: configuration.profile, key: configuration.key,
                model: configuration.model,
                messages: modelMessages(question: question, conversation: voiceSession?.conversation, webContext: webContext),
                systemPrompt: modelInstructions(configuration: configuration, conversation: voiceSession?.conversation, webContext: webContext),
                temperature: configuration.profile.effectiveCreativity, maxTokens: configuration.maxTokens,
                onText: { [weak self] update in
                    guard self?.active?.id == id else { return }
                    if update.utf8.count > Self.maximumReplyBytes {
                        tooLong = true
                        self?.finish(id: id, result: .failure(SiriAssistantError.tooLong))
                    } else { text = update }
                }, onReasoning: { _ in }, onUsage: { reported in usage = reported })
            try Task.checkCancellation()
            guard active?.id == id else { return }
            guard !tooLong else { throw SiriAssistantError.tooLong }
            let response = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !response.isEmpty else { throw SiriAssistantError.sendFailed }
            // Recheck consent before persisting a response, even after a late callback.
            guard try self.configuration() == configuration else { throw SiriAssistantError.configurationChanged }
            if needsWeb, voiceWebSearchMode() != webMode { throw SiriAssistantError.configurationChanged }
            var pending = try pendingConversations()
            var conversation: Conversation
            if let voiceSession {
                guard voiceConversation?.conversation.id == voiceSession.conversation.id else {
                    throw SiriAssistantError.voiceConversationEnded
                }
                conversation = voiceSession.conversation
            } else {
                conversation = Conversation(serverID: configuration.profile.id, model: configuration.model)
            }
            if conversation.messages.isEmpty {
                conversation.title = String(question.replacingOccurrences(of: "\n", with: " ").prefix(55))
            }
            var replyMessage = ChatMessage(role: .assistant, text: response)
            replyMessage.usage = usage
            replyMessage.reasoningServerID = configuration.profile.id
            replyMessage.reasoningModel = configuration.model
            replyMessage.webContext = webContext
            replyMessage.webResearchTrace = active?.webResearchTrace
            conversation.messages += [userMessage, replyMessage]
            conversation.updatedAt = Date()
            if let index = pending.firstIndex(where: { $0.id == conversation.id }) {
                pending[index] = conversation
            } else {
                guard pending.count < Self.maximumPending else { throw SiriAssistantError.queueFull }
                pending.append(conversation)
            }
            try savePending(pending)
            // Publish in-memory context only after the durable save succeeds.
            if voiceSession != nil { voiceConversation?.conversation = conversation }
            finish(id: id, result: .success(response))
        } catch is CancellationError {
            finish(id: id, result: .failure(CancellationError()))
        } catch let error as SiriAssistantError {
            finish(id: id, result: .failure(error))
        } catch let error as LocalLlamaEngine.EngineError where configuration.profile.isLocalLFM {
            if case .contextLimit = error { finish(id: id, result: .failure(SiriAssistantError.voiceContextFull)) }
            else { finish(id: id, result: .failure(SiriAssistantError.localSynthesisFailed)) }
        } catch where configuration.profile.isLocalLFM && (error is LocalModelPrompt.PromptError || error is LocalModelFileStore.StoreError) {
            finish(id: id, result: .failure(SiriAssistantError.localSynthesisFailed))
        } catch {
            finish(id: id, result: .failure(SiriAssistantError.sendFailed))
        }
    }

    private func savePending(_ values: [Conversation]) throws {
        let bytes = try JSONEncoder().encode(values)
        guard bytes.count <= Self.maximumStoredBytes else { throw SiriAssistantError.queueFull }
        do { try persistence.write(Self.pendingAccount, bytes) }
        catch let error as SiriAssistantError { throw error }
        catch { throw SiriAssistantError.storage }
    }

    private func setWebSearchProgress(_ searching: Bool, id: UUID) {
        guard active?.id == id, active?.isSearchingWeb != searching else { return }
        active?.isSearchingWeb = searching
        active?.onWebSearchProgress(searching)
    }

    private func setWebResearchTrace(_ trace: WebResearchTrace, id: UUID) {
        guard active?.id == id else { return }
        active?.webResearchTrace = trace
        lastWebResearchTrace = trace
        active?.onWebResearchTrace(trace)
    }

    private func finish(id: UUID, result: Result<String, Error>) {
        guard var request = active, request.id == id else { return }
        active = nil
        request.timer?.cancel()
        request.generation?.cancel()
        if case .failure(let error) = result, var trace = request.webResearchTrace {
            if error is CancellationError {
                trace.cancelUnfinished()
            } else {
                let now = Date()
                if trace.state == .preparing { trace.state = .failed; trace.finishedAt = now }
                for index in trace.calls.indices where [.requested, .running].contains(trace.calls[index].state) {
                    trace.calls[index].state = .failed
                    trace.calls[index].finishedAt = now
                    trace.calls[index].detail = "L’opération n’a pas pu aboutir."
                }
            }
            if trace != request.webResearchTrace {
                request.webResearchTrace = trace
                lastWebResearchTrace = trace
                request.onWebResearchTrace(trace)
            }
            // Best effort diagnostics must not replace the actual error or weaken storage limits.
            try? saveFailedVoiceTurn(request, error: error, trace: trace)
        }
        if request.isSearchingWeb { request.onWebSearchProgress(false) }
        request.continuation.resume(with: result)
    }

    private func saveFailedVoiceTurn(_ request: ActiveRequest, error: Error, trace: WebResearchTrace) throws {
        guard let session = request.voiceSession,
              try configuration() == session.configuration,
              voiceWebSearchMode() == request.webMode else { return }
        var conversation = session.conversation
        guard conversation.messages.count / 2 < Self.maximumVoiceTurns else { return }
        let state: MessageState = error is CancellationError ? .interrupted : .failed
        var question = ChatMessage(role: .user, text: request.question)
        question.state = state
        question.isVoiceRequest = true
        question.webSearchRequested = true
        let message = error is CancellationError ? String(localized: "Réponse vocale interrompue.")
            : String(localized: ((error as? SiriAssistantError) ?? .sendFailed).localizedStringResource)
        var reply = ChatMessage(role: .assistant, text: message)
        reply.state = state
        reply.webResearchTrace = trace
        conversation.messages += [question, reply]
        conversation.updatedAt = Date()
        if session.conversation.messages.isEmpty {
            conversation.title = String(request.question.replacingOccurrences(of: "\n", with: " ").prefix(55))
        }
        guard try JSONEncoder().encode(conversation).count <= Self.maximumVoiceConversationBytes else { return }
        var pending = try pendingConversations()
        if let index = pending.firstIndex(where: { $0.id == conversation.id }) {
            pending[index] = conversation
        } else {
            guard pending.count < Self.maximumPending else { return }
            pending.append(conversation)
        }
        try savePending(pending)
        if voiceConversation?.conversation.id == conversation.id { voiceConversation?.conversation = conversation }
    }
}
