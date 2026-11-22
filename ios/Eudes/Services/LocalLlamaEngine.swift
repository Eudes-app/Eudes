import Foundation
import llama

/// Rend un prompt avec le gabarit de conversation embarqué dans le fichier GGUF.
/// llama.cpp ne parse pas de Jinja : il reconnaît une liste de gabarits connus et renvoie
/// nil pour les autres, auquel cas l'appelant garde son gabarit de repli.
enum LocalChatTemplate {
    struct Message: Equatable, Sendable {
        let role: String
        let content: String
    }

    static func apply(template: String, messages: [Message], addAssistant: Bool = true) -> String? {
        guard !template.isEmpty, !messages.isEmpty else { return nil }
        var storage: [UnsafeMutablePointer<CChar>] = []
        defer { storage.forEach { free($0) } }
        var chat: [llama_chat_message] = []
        for message in messages {
            guard let role = strdup(message.role), let content = strdup(message.content) else { return nil }
            storage.append(role)
            storage.append(content)
            chat.append(llama_chat_message(role: UnsafePointer(role), content: UnsafePointer(content)))
        }
        let needed = template.withCString { templatePointer in
            chat.withUnsafeBufferPointer { buffer in
                llama_chat_apply_template(templatePointer, buffer.baseAddress, chat.count, addAssistant, nil, 0)
            }
        }
        guard needed > 0 else { return nil }
        var output = [CChar](repeating: 0, count: Int(needed) + 1)
        let written = template.withCString { templatePointer in
            chat.withUnsafeBufferPointer { buffer in
                llama_chat_apply_template(templatePointer, buffer.baseAddress, chat.count, addAssistant,
                                          &output, Int32(output.count))
            }
        }
        guard written > 0, Int(written) <= output.count else { return nil }
        return String(cString: output)
    }
}

enum LocalReasoningBoundary {
    static func containsPartialClosingTag(_ text: String) -> Bool {
        let marker = "</think>"
        return (1..<marker.count).contains { text.hasSuffix(String(marker.prefix($0))) }
    }
}

/// Réutilise le contexte déjà décodé quand deux prompts partagent leur début.
enum LocalPromptCache {
    /// Plus long préfixe commun. Les tokens conservés sont identiques à ceux du
    /// nouveau prompt, donc la réponse ne dépend pas du cache : un contexte neuf
    /// produirait le même résultat, seulement plus lentement.
    static func reusablePrefix(cached: [Int32], prompt: [Int32]) -> Int {
        let limit = min(cached.count, prompt.count)
        var count = 0
        while count < limit, cached[count] == prompt[count] { count += 1 }
        return count
    }
}

/// A single engine owns the model, context and optional vision projector.
/// Its callers must not retain native pointers beyond its lifetime.
actor LocalLlamaEngine {
    enum EngineError: LocalizedError {
        case modelLoad, contextLoad, visionLoad, busy, tokenization, contextLimit, decoding, emptyResponse, imagesUnsupported, invalidImage
        var errorDescription: String? {
            switch self {
            case .modelLoad: return "Impossible de charger le modèle local."
            case .contextLoad: return "Impossible de préparer le contexte du modèle local."
            case .visionLoad: return "Impossible de charger le composant de vision du modèle local."
            case .busy: return "Le modèle local est déjà utilisé."
            case .tokenization: return "Impossible de préparer le texte pour le modèle local."
            case .contextLimit: return "Le contexte du modèle local est trop long. Ouvre une nouvelle conversation ou raccourcis le message."
            case .decoding: return "La génération du modèle local a échoué."
            case .emptyResponse: return "Le modèle local n’a pas produit de réponse."
            case .imagesUnsupported: return "Ce modèle local n’accepte pas les images."
            case .invalidImage: return "Impossible de préparer les images pour le modèle local."
            }
        }
    }

    private static let backend: Void = { llama_backend_init() }()
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vision: OpaquePointer?
    let supportsImages: Bool
    private var generating = false
    /// Tokens réellement présents dans le contexte, dans l'ordre : c'est la
    /// référence pour savoir quelle partie d'un nouveau prompt est déjà décodée.
    private var cacheTokens: [llama_token] = []
    /// Nombre de tokens envoyés au décodeur au dernier appel : 0 après une
    /// réutilisation intégrale, la longueur du prompt après un contexte vidé.
    private(set) var lastPrefillTokenCount = 0
    /// Tokens de prompt déjà présents dans le contexte au dernier appel.
    private(set) var lastCachedTokenCount = 0
    /// Identifiant du catalogue, utilisé pour nommer les mesures dans le diagnostic.
    private let modelID: String

    private var modelTitle: String {
        LocalModelCatalog.models.first { $0.id == modelID }?.title ?? modelID
    }

    static func contextParameters(useGPU: Bool, contextTokens: Int = LocalModelCatalog.allocatedContextTokens) -> llama_context_params {
        var parameters = llama_context_default_params()
        if !useGPU {
            parameters.offload_kqv = false
            parameters.op_offload = false
        }
        parameters.n_ctx = UInt32(LocalModelCatalog.contextSize(contextTokens))
        parameters.n_batch = 512
        parameters.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.processorCount - 1)))
        parameters.n_threads_batch = parameters.n_threads
        return parameters
    }

    init(modelURL: URL, projectorURL: URL?, useGPU: Bool, contextTokens: Int = LocalModelCatalog.allocatedContextTokens,
         modelID: String = "") throws {
        self.modelID = modelID
        _ = Self.backend
        var modelParameters = llama_model_default_params()
        #if targetEnvironment(simulator)
        let effectiveGPU = false
        #else
        let effectiveGPU = useGPU
        #endif
        modelParameters.n_gpu_layers = effectiveGPU ? 99 : 0
        let loadedModel: OpaquePointer?
        if effectiveGPU {
            loadedModel = llama_model_load_from_file(modelURL.path, modelParameters)
        } else {
            // A nil devices pointer means all devices, even with zero GPU
            // layers. An empty list prevents Metal backend initialization.
            var noDevices: [OpaquePointer?] = [nil]
            loadedModel = noDevices.withUnsafeMutableBufferPointer { devices in
                modelParameters.devices = devices.baseAddress
                return llama_model_load_from_file(modelURL.path, modelParameters)
            }
        }
        guard let model = loadedModel else {
            throw EngineError.modelLoad
        }
        let expectedContext = LocalModelCatalog.contextSize(contextTokens)
        let contextParameters = Self.contextParameters(useGPU: effectiveGPU, contextTokens: expectedContext)
        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model)
            throw EngineError.contextLoad
        }
        guard llama_n_ctx(context) == UInt32(expectedContext) else {
            llama_free(context)
            llama_model_free(model)
            throw EngineError.contextLoad
        }
        var vision: OpaquePointer?
        if let projectorURL {
            var parameters = mtmd_context_params_default()
            #if targetEnvironment(simulator)
            parameters.use_gpu = false
            #else
            parameters.use_gpu = useGPU
            #endif
            parameters.n_threads = contextParameters.n_threads
            guard let loaded = mtmd_init_from_file(projectorURL.path, model, parameters) else {
                llama_free(context)
                llama_model_free(model)
                throw EngineError.visionLoad
            }
            guard mtmd_support_vision(loaded) else {
                mtmd_free(loaded)
                llama_free(context)
                llama_model_free(model)
                throw EngineError.visionLoad
            }
            vision = loaded
        }
        self.model = model
        self.context = context
        self.vision = vision
        self.supportsImages = vision != nil
    }


    /// A fresh context per response prevents previous or interrupted requests
    /// from silently leaking into another conversation. The prompt must already
    /// be formatted using the model's conversation template.
    func tokenCount(prompt: String) throws -> Int {
        let bytes = Array(prompt.utf8)
        guard bytes.count < Int(Int32.max) else { throw EngineError.contextLimit }
        var chars = bytes.map { CChar(bitPattern: $0) }
        chars.append(0)
        let needed = chars.withUnsafeBufferPointer { buffer in
            llama_tokenize(llama_model_get_vocab(model), buffer.baseAddress, Int32(bytes.count), nil, 0, true, true)
        }
        guard needed < 0, needed != Int32.min else { throw EngineError.tokenization }
        return Int(-needed)
    }

    /// The prompt must already be formatted using the model's conversation template.
    /// Le contexte n'est plus vidé à chaque réponse : la partie du prompt déjà
    /// décodée est conservée, et seuls les tokens qui suivent sont envoyés au
    /// décodeur. Ce qui reste décodé est toujours une suite de tokens identiques,
    /// donc une autre conversation (préfixe différent, voire inverse) repart d'un
    /// contexte vide et aucune réponse d'une requête interrompue ne peut se
    /// retrouver dans une autre : la garantie ne venait pas de l'effacement, mais
    /// de l'identité des tokens conservés.
    func generate(prompt: String, images: [Data] = [], maxTokens: Int, reasoningTokens: Int? = nil,
                  onUsage: @Sendable (TokenUsage) async -> Void = { _ in },
                  onText: @Sendable (String) async -> Void) async throws -> String {
        guard !generating else { throw EngineError.busy }
        generating = true
        defer { generating = false }
        try Task.checkCancellation()
        let vocab = llama_model_get_vocab(model)
        let answerLimit = max(1, min(maxTokens, 1024))
        let prefillStart = Date()
        let inputTokens: Int
        if !images.isEmpty {
            guard let vision else { throw EngineError.imagesUnsupported }
            // Les tokens d'une évaluation multimodale ne sont pas comparables à
            // ceux d'un prompt texte : le contexte repart vide.
            cacheTokens.removeAll(keepingCapacity: true)
            lastPrefillTokenCount = 0
            lastCachedTokenCount = 0
            llama_memory_clear(llama_get_memory(context), true)
            inputTokens = try prepareVision(prompt: prompt, images: images, vision: vision, outputLimit: answerLimit + (reasoningTokens == nil ? 0 : 16))
        } else {
            let bytes = Array(prompt.utf8)
            guard bytes.count < Int(Int32.max) else { throw EngineError.contextLimit }
            var chars = bytes.map { CChar(bitPattern: $0) }
            chars.append(0)
            let needed = chars.withUnsafeBufferPointer { buffer in
                llama_tokenize(vocab, buffer.baseAddress, Int32(bytes.count), nil, 0, true, true)
            }
            guard needed < 0, needed != Int32.min else { throw EngineError.tokenization }
            var tokens = [llama_token](repeating: 0, count: Int(-needed))
            let count = chars.withUnsafeBufferPointer { source in
                tokens.withUnsafeMutableBufferPointer { output in
                    llama_tokenize(vocab, source.baseAddress, Int32(bytes.count), output.baseAddress,
                                   Int32(output.count), true, true)
                }
            }
            guard count > 0 else { throw EngineError.tokenization }
            inputTokens = Int(count)
            guard Int(count) + answerLimit + (reasoningTokens == nil ? 0 : 16) <= Int(llama_n_ctx(context)) else { throw EngineError.contextLimit }
            try primeContext(tokens: &tokens, count: Int(count))
        }
        let prefillSeconds = Date().timeIntervalSince(prefillStart)
        let remaining = Int(llama_n_ctx(context)) - inputTokens
        let reasoningLimit = reasoningTokens.map { LocalModelCatalog.reasoningSize($0) }
        // Leave space for an answer and the forced closing tag when a long
        // conversation has already consumed most of the allocated context.
        let effectiveReasoning = reasoningLimit.map { min($0, max(0, remaining - answerLimit - 16)) }
        let outputLimit = min(remaining, answerLimit + (effectiveReasoning ?? 0) + (effectiveReasoning == nil ? 0 : 16))
        guard let sampler = llama_sampler_init_greedy() else { throw EngineError.decoding }
        defer { llama_sampler_free(sampler) }
        var output = ""
        var pending = [UInt8]()
        var outputTokens = 0
        var thinkingTokens = 0
        var closedThinking = false
        let decodeStart = Date()
        for _ in 0..<outputLimit {
            try Task.checkCancellation()
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            outputTokens += 1
            llama_sampler_accept(sampler, token)
            var piece = [CChar](repeating: 0, count: 256)
            var written = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if written < 0 {
                guard written != Int32.min else { throw EngineError.decoding }
                piece = [CChar](repeating: 0, count: Int(-written))
                written = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            }
            guard written >= 0 else { throw EngineError.decoding }
            pending.append(contentsOf: piece.prefix(Int(written)).map { UInt8(bitPattern: $0) })
            if let part = String(bytes: pending, encoding: .utf8) {
                pending.removeAll(keepingCapacity: true)
                output += part
                await onText(output)
            }
            // Cancellation can arrive while the UI consumes a token, especially
            // as the scene becomes inactive. Do not submit another GPU decode
            // after the foreground-loss handler has requested a pause.
            try Task.checkCancellation()
            var next = token
            guard llama_decode(context, llama_batch_get_one(&next, 1)) == 0 else { throw EngineError.decoding }
            cacheTokens.append(next)
            if let limit = effectiveReasoning, !closedThinking {
                let trimmed = output.drop(while: { $0.isWhitespace })
                if trimmed.hasPrefix("<think>") {
                    thinkingTokens += 1
                    if trimmed.contains("</think>") {
                        closedThinking = true
                    } else if thinkingTokens >= limit && pending.isEmpty && !LocalReasoningBoundary.containsPartialClosingTag(output) {
                        // Feed the actual closing tokens back into llama, so
                        // generation continues in the model's answer phase.
                        let marker = "</think>"
                        let bytes = Array(marker.utf8)
                        let chars = bytes.map { CChar(bitPattern: $0) } + [0]
                        var forced = [llama_token](repeating: 0, count: 16)
                        let count = chars.withUnsafeBufferPointer { source in
                            forced.withUnsafeMutableBufferPointer { target in
                                llama_tokenize(vocab, source.baseAddress, Int32(bytes.count), target.baseAddress,
                                               Int32(target.count), false, true)
                            }
                        }
                        guard count > 0, Int(count) <= 16, outputTokens + Int(count) < remaining else { throw EngineError.contextLimit }
                        for forcedToken in forced.prefix(Int(count)) {
                            try Task.checkCancellation()
                            var nextForced = forcedToken
                            llama_sampler_accept(sampler, forcedToken)
                            guard llama_decode(context, llama_batch_get_one(&nextForced, 1)) == 0 else { throw EngineError.decoding }
                            cacheTokens.append(nextForced)
                        }
                        outputTokens += Int(count)
                        output += marker
                        closedThinking = true
                        await onText(output)
                    }
                } else if !"<think>".hasPrefix(trimmed) {
                    closedThinking = true
                }
            }
            if outputTokens >= remaining { break }
        }
        let decodeSeconds = Date().timeIntervalSince(decodeStart)
        if !pending.isEmpty {
            output += String(decoding: pending, as: UTF8.self)
            await onText(output)
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError.emptyResponse }
        await onUsage(TokenUsage(input: inputTokens, output: outputTokens))
        await record(metricsForGeneration: LocalGenerationMetrics(
            modelID: modelID,
            modelTitle: modelTitle,
            promptTokens: inputTokens,
            cachedTokens: lastCachedTokenCount,
            prefillSeconds: prefillSeconds,
            answerTokens: outputTokens,
            decodeSeconds: decodeSeconds,
            thermal: ProcessInfo.processInfo.thermalState.localLabel,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            date: Date()))
        return output
    }

    /// Publie les mesures de la dernière réponse. Le journal ne reçoit une ligne que
    /// si quelque chose sort de la normale, ou si le traçage complet est activé :
    /// le tampon du journal est plafonné et ne doit pas être saturé par des mesures.
    private func record(metricsForGeneration metrics: LocalGenerationMetrics) async {
        await MainActor.run { LocalEngineReport.shared.record(generation: metrics) }
        guard metrics.needsAttention || LocalEngineDiagnostics.tracesEveryGeneration else { return }
        DiagnosticStore.shared.append(category: .model,
                                      level: metrics.needsAttention ? .warning : .info,
                                      message: metrics.journalMessage)
    }

    /// Alimente le contexte du prompt, en réutilisant le préfixe déjà décodé.
    /// La fin du cache est libérée puis seul le suffixe est envoyé au décodeur :
    /// `llama_batch_get_one` reprend les positions après la dernière conservée.
    private func primeContext(tokens: inout [llama_token], count: Int) throws {
        let memory = llama_get_memory(context)
        var reused = LocalPromptCache.reusablePrefix(cached: cacheTokens, prompt: tokens)
        if reused > 0, reused < cacheTokens.count {
            if !llama_memory_seq_rm(memory, 0, llama_pos(reused), -1) {
                // Troncature refusée : on repart d'un contexte vide plutôt que
                // de décoder par-dessus un état incertain.
                reused = 0
            }
        }
        if reused == 0 {
            llama_memory_clear(memory, true)
        }
        if reused < cacheTokens.count {
            cacheTokens.removeSubrange(reused...)
        }
        lastPrefillTokenCount = count - reused
        lastCachedTokenCount = reused
        var offset = reused
        while offset < count {
            try Task.checkCancellation()
            let length = min(512, count - offset)
            let result = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress!.advanced(by: offset), Int32(length)))
            }
            guard result == 0 else {
                cacheTokens.removeAll(keepingCapacity: true)
                llama_memory_clear(memory, true)
                throw EngineError.decoding
            }
            cacheTokens.append(contentsOf: tokens[offset..<(offset + length)])
            offset += length
        }
    }

    private func prepareVision(prompt: String, images: [Data], vision: OpaquePointer,
                               outputLimit: Int) throws -> Int {
        guard images.count <= 4, images.reduce(0, { $0 + $1.count }) <= 8_388_608,
              let chunks = mtmd_input_chunks_init() else { throw EngineError.invalidImage }
        defer { mtmd_input_chunks_free(chunks) }
        var bitmaps: [OpaquePointer?] = []
        defer { for bitmap in bitmaps { if let bitmap { mtmd_bitmap_free(bitmap) } } }
        for image in images {
            try Task.checkCancellation()
            let wrapper = image.withUnsafeBytes { bytes in
                mtmd_helper_bitmap_init_from_buf(vision, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                 bytes.count, false, mtmd_helper_init_opt_default())
            }
            if let video = wrapper.video_ctx { mtmd_helper_video_free(video) }
            guard let bitmap = wrapper.bitmap else { throw EngineError.invalidImage }
            guard !mtmd_bitmap_is_audio(bitmap) else { mtmd_bitmap_free(bitmap); throw EngineError.invalidImage }
            bitmaps.append(bitmap)
        }
        let status = prompt.withCString { text in
            var input = mtmd_input_text(text: text, text_len: prompt.utf8.count,
                                        add_special: true, parse_special: true)
            return bitmaps.withUnsafeBufferPointer { values in
                mtmd_tokenize(vision, chunks, &input, values.baseAddress, values.count)
            }
        }
        guard status == 0 else { throw EngineError.invalidImage }
        let positions = mtmd_helper_get_n_pos(chunks)
        guard positions >= 0, Int(positions) + outputLimit <= Int(llama_n_ctx(context)) else {
            throw EngineError.contextLimit
        }
        try Task.checkCancellation()
        var nPast: llama_pos = 0
        guard mtmd_helper_eval_chunks(vision, context, chunks, 0, 0, 512, true, &nPast) == 0 else {
            throw EngineError.decoding
        }
        try Task.checkCancellation()
        return Int(positions)
    }

    deinit {
        if let vision { mtmd_free(vision) }
        llama_free(context)
        llama_model_free(model)
    }
}
