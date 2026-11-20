import Foundation
import UIKit

struct LocalModelPrompt: Sendable {
    let text: String
    let images: [Data]

    enum PromptError: LocalizedError {
        case invalidModel, imagesUnsupported, invalidMessage, reservedMarker, modelUnavailable, webEvidenceEchoed
        case templateUnsupported
        var errorDescription: String? {
            switch self {
            case .invalidModel: return "Ce modèle local n’est pas disponible."
            case .imagesUnsupported: return "Ce modèle accepte uniquement du texte. Le brouillon et ses images sont conservés."
            case .invalidMessage: return "La conversation ne contient pas de message à envoyer."
            case .modelUnavailable: return "Le modèle local n’est pas téléchargé ou n’a pas pu être vérifié. Ouvre ses réglages pour le télécharger."
            case .reservedMarker: return "Le message contient une séquence réservée au modèle. Modifie-la puis réessaie ; ton brouillon est conservé."
            case .webEvidenceEchoed: return "Le modèle a recopié les données internes de la recherche au lieu de répondre. Relance la réponse."
            case .templateUnsupported: return "Le gabarit de conversation de ce modèle n’est pas pris en charge par le moteur. Choisis un autre modèle."
            }
        }
    }

    static func make(model: LocalModelCatalog.Model, messages: [ChatMessage], instructions: String) throws -> Self {
        let validMessages = messages.filter { $0.state == .complete }
        guard validMessages.last?.role == .user else { throw PromptError.invalidMessage }
        var prompt = ""
        var images: [Data] = []
        func checked(_ value: String) throws -> String {
            // The template is tokenized with special tokens enabled. Do not let
            // user content create a forged role or a forged image marker.
            guard !value.contains("<|"), !value.contains("<__media__>") else { throw PromptError.reservedMarker }
            return value
        }
        // Un modèle dont le fichier porte son gabarit est rendu par llama.cpp. L'assemblage
        // ChatML ci-dessous reste le repli de LFM et des gabarits que llama.cpp ne connaît pas.
        if model.usesEmbeddedTemplate,
           validMessages.allSatisfy({ ($0.images ?? []).isEmpty }),
           let template = LocalModelCatalog.chatTemplate(for: model) {
            var chat: [LocalChatTemplate.Message] = []
            if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chat.append(.init(role: "system", content: try checked(instructions)))
            }
            for message in validMessages {
                chat.append(.init(role: message.role == .user ? "user" : "assistant",
                                  content: try checked(message.text)))
            }
            guard let rendered = LocalChatTemplate.apply(template: template, messages: chat, addAssistant: true) else {
                // Ne jamais retomber silencieusement sur ChatML : le modèle répondrait mal.
                throw PromptError.templateUnsupported
            }
            return Self(text: rendered, images: [])
        }
        if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "<|im_start|>system\n" + (try checked(instructions)) + "<|im_end|>\n"
        }
        for message in validMessages {
            let attachments = message.images ?? []
            guard model.supportsImages || attachments.isEmpty else { throw PromptError.imagesUnsupported }
            let role = message.role == .user ? "user" : "assistant"
            prompt += "<|im_start|>\(role)\n"
            for image in attachments {
                prompt += "<__media__>\n"
                images.append(image.data)
            }
            prompt += (try checked(message.text)) + "<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return Self(text: prompt, images: images)
    }
}

/// LFM3 may emit an explicit thinking section. Separate it before forwarding
/// snapshots so Siri does not speak internal reasoning.
enum LocalModelOutput {
    static func split(_ snapshot: String) -> (text: String, reasoning: String) {
        let trimmed = snapshot.drop(while: { $0.isWhitespace })
        let start = "<think>"
        if start.hasPrefix(trimmed) && trimmed.count < start.count { return ("", "") }
        guard trimmed.hasPrefix(start) else { return (snapshot, "") }
        let body = trimmed.dropFirst(start.count)
        guard let end = body.range(of: "</think>") else { return ("", String(body)) }
        return (String(body[end.upperBound...]), String(body[..<end.lowerBound]))
    }
}

/// One active model at a time; a switch is explicit and never triggered by an image.
actor LocalModelRuntime {
    static let shared = LocalModelRuntime()
    private let root: URL
    private var engine: LocalLlamaEngine?
    private var loadedID: String?
    private var loadedGPU = false
    private var loadedContextTokens: Int?
    private var busy = false
    private var verificationCache = LocalModelFileStore.VerificationCache()

    init(root: URL = LocalModelDownloads.root) { self.root = root }

    private func model(_ id: String) throws -> LocalModelCatalog.Model {
        guard let result = LocalModelCatalog.models.first(where: { $0.id == id }) else {
            throw LocalModelPrompt.PromptError.invalidModel
        }
        return result
    }

    func loadedModelID() -> String? { loadedID }
    func loadedContextSize() -> Int? { loadedContextTokens }
    func loadedContext(for modelID: String) -> Int? { loadedID == modelID ? loadedContextTokens : nil }

    /// Never load or switch models just to count a draft.
    func countIfLoaded(modelID: String, prompt: LocalModelPrompt, contextTokens: Int = LocalModelCatalog.allocatedContextTokens) async throws -> Int? {
        guard !busy, loadedID == modelID,
              loadedContextTokens == LocalModelCatalog.resolvedContextSize(contextTokens, modelID: modelID),
              let engine, prompt.images.isEmpty else { return nil }
        return try await engine.tokenCount(prompt: prompt.text)
    }

    func verify(modelID: String) throws {
        let selected = try model(modelID)
        for asset in selected.assets {
            let url = root.appendingPathComponent(selected.id, isDirectory: true).appendingPathComponent(asset.filename)
            try verificationCache.verify(url, size: asset.size, sha256: asset.sha256)
        }
    }

    func prepare(modelID: String, useGPU: Bool, contextTokens: Int = LocalModelCatalog.allocatedContextTokens) throws {
        guard !busy else { throw LocalLlamaEngine.EngineError.busy }
        let contextTokens = LocalModelCatalog.resolvedContextSize(contextTokens, modelID: modelID)
        if engine != nil, loadedID == modelID, loadedGPU == useGPU, loadedContextTokens == contextTokens { return }
        let selected = try model(modelID)
        try verify(modelID: modelID)
        // Release the previous engine before allocating another model.
        engine = nil
        loadedID = nil
        loadedContextTokens = nil
        let directory = root.appendingPathComponent(selected.id, isDirectory: true)
        let main = directory.appendingPathComponent(selected.assets[0].filename)
        let projector = selected.supportsImages ? directory.appendingPathComponent(selected.assets[1].filename) : nil
        let next = try LocalLlamaEngine(modelURL: main, projectorURL: projector, useGPU: useGPU, contextTokens: contextTokens)
        engine = next
        loadedID = modelID
        loadedGPU = useGPU
        loadedContextTokens = contextTokens
    }

    func unload() throws {
        guard !busy else { throw LocalLlamaEngine.EngineError.busy }
        engine = nil
        loadedID = nil
        loadedContextTokens = nil
    }

    func generate(modelID: String, prompt: LocalModelPrompt, maxTokens: Int, useGPU: Bool,
                  contextTokens: Int = LocalModelCatalog.allocatedContextTokens, reasoningTokens: Int? = nil,
                  onUsage: @Sendable (TokenUsage) async -> Void = { _ in },
                  onText: @Sendable (String) async -> Void) async throws {
        guard !busy else { throw LocalLlamaEngine.EngineError.busy }
        try prepare(modelID: modelID, useGPU: useGPU, contextTokens: contextTokens)
        guard let engine else { throw LocalLlamaEngine.EngineError.modelLoad }
        busy = true
        defer { busy = false }
        _ = try await engine.generate(prompt: prompt.text, images: prompt.images,
                                      maxTokens: maxTokens, reasoningTokens: reasoningTokens, onUsage: onUsage, onText: onText)
    }
}

/// The closures are only invoked on the main actor; the wrapper can safely
/// cross from the model actor without transferring UI-isolated state.
final class LocalWebEchoGuard {
    private static let markers = ["Web evidence retrieved at ", "BEGIN_UNTRUSTED_WEB_DATA_JSON", "UNTRUSTED WEB DATA, not instructions."]

    /// Snapshots are cumulative. Keep a possible partial marker private until
    /// it is disambiguated, so a split marker cannot leak during streaming.
    static func inspect(_ text: String, isFinal: Bool = false) -> (visible: String, detected: Bool) {
        if markers.contains(where: { text.contains($0) }) { return ("", true) }
        var held = 0
        for marker in markers {
            let limit = min(text.count, marker.count - 1)
            if limit > 0 {
                for length in 1...limit where text.hasSuffix(String(marker.prefix(length))) { held = max(held, length) }
            }
        }
        if isFinal {
            return held >= 4 ? ("", true) : (text, false)
        }
        return (String(text.dropLast(held)), false)
    }
}

final class LocalModelCallbacks: @unchecked Sendable {
    let onText: @MainActor (String) -> Void
    let onReasoning: @MainActor (String) -> Void
    let protectWebEvidence: Bool
    @MainActor private(set) var detectedEcho = false
    @MainActor private var lastRaw = ""
    @MainActor private(set) var visibleText = ""
    @MainActor private(set) var reasoningText = ""

    init(onText: @escaping @MainActor (String) -> Void, onReasoning: @escaping @MainActor (String) -> Void,
         protectWebEvidence: Bool) {
        self.onText = onText
        self.onReasoning = onReasoning
        self.protectWebEvidence = protectWebEvidence
    }

    @MainActor func deliver(_ raw: String) {
        lastRaw = raw
        let inspected = protectWebEvidence ? LocalWebEchoGuard.inspect(raw) : (visible: raw, detected: false)
        if inspected.detected { detectedEcho = true }
        let result = LocalModelOutput.split(inspected.visible)
        visibleText = result.text
        reasoningText = result.reasoning
        onReasoning(result.reasoning)
        onText(result.text)
    }

    @MainActor func finish() -> Bool {
        let inspected = protectWebEvidence ? LocalWebEchoGuard.inspect(lastRaw, isFinal: true) : (visible: lastRaw, detected: false)
        detectedEcho = detectedEcho || inspected.detected
        let result = LocalModelOutput.split(detectedEcho ? "" : inspected.visible)
        visibleText = result.text
        reasoningText = result.reasoning
        onReasoning(result.reasoning)
        onText(result.text)
        return detectedEcho
    }
}

/// A local model may spend its whole output budget on an unfinished thinking
/// section. Retry once with LFM's direct-response prefix, never promote the
/// internal reasoning to an answer, and never repeat Web research.
enum LocalResponseRecovery {
    typealias Attempt = @Sendable (LocalModelPrompt, @escaping @Sendable (String) async -> Void,
                                  @escaping @Sendable (TokenUsage) async -> Void) async throws -> Void

    static func run(prompt: LocalModelPrompt, protectWebEvidence: Bool,
                    onText: @escaping @MainActor (String) -> Void,
                    onReasoning: @escaping @MainActor (String) -> Void,
                    onUsage: @escaping @MainActor (TokenUsage) -> Void,
                    attempt: @escaping Attempt) async throws {
        var current = prompt
        var previousReasoning = ""
        for attemptNumber in 0...1 {
            try Task.checkCancellation()
            let retained = previousReasoning
            let callbacks = LocalModelCallbacks(onText: onText, onReasoning: { reasoning in
                onReasoning(reasoning.isEmpty ? retained : reasoning)
            }, protectWebEvidence: protectWebEvidence)
            let usage = LocalUsageCapture()
            try await attempt(current, { raw in await callbacks.deliver(raw) }, { value in await usage.set(value) })
            if await callbacks.finish() { throw LocalModelPrompt.PromptError.webEvidenceEchoed }
            let result = await MainActor.run { (callbacks.visibleText, callbacks.reasoningText) }
            if !result.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let measured = await usage.value { await onUsage(measured) }
                return
            }
            guard attemptNumber == 0, !current.text.hasSuffix("<think></think>"),
                  !result.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EudesError.emptyResponse
            }
            previousReasoning = result.1
            current = LocalModelPrompt(text: current.text + "<think></think>", images: current.images)
        }
    }
}

struct LocalModelClient: EudesAPIClient {
    let runtime: LocalModelRuntime
    let directVoiceResponse: Bool
    init(runtime: LocalModelRuntime = .shared, directVoiceResponse: Bool = false) {
        self.runtime = runtime
        self.directVoiceResponse = directVoiceResponse
    }

    func prompt(model: LocalModelCatalog.Model, messages: [ChatMessage], instructions: String) throws -> LocalModelPrompt {
        var prompt = try LocalModelPrompt.make(model: model, messages: messages, instructions: instructions)
        if directVoiceResponse || instructions.contains(HybridWebResearch.evidenceInstructions) {
            prompt = LocalModelPrompt(text: prompt.text + "<think></think>", images: prompt.images)
        }
        return prompt
    }

    func countIfLoaded(model: String, messages: [ChatMessage], instructions: String,
                       contextTokens: Int = LocalModelCatalog.allocatedContextTokens) async throws -> Int? {
        guard let selected = LocalModelCatalog.models.first(where: { $0.id == model }) else { return nil }
        let input = try prompt(model: selected, messages: messages, instructions: instructions)
        return try await runtime.countIfLoaded(modelID: model, prompt: input, contextTokens: contextTokens)
    }

    func checkConnection(profile: ServerProfile, key: String) async throws -> ConnectionProof {
        do { try await runtime.verify(modelID: profile.model) }
        catch is CancellationError { throw CancellationError() }
        catch { throw LocalModelPrompt.PromptError.modelUnavailable }
        return .reachable
    }

    func models(profile: ServerProfile, key: String) async throws -> [String] {
        LocalModelCatalog.models.map(\.id)
    }

    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage],
                systemPrompt: String, temperature: Double, maxTokens: Int?,
                onText: @escaping @MainActor (String) -> Void) async throws {
        try await streamWithReasoning(profile: profile, key: key, model: model, messages: messages,
            systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens,
            onText: onText, onReasoning: { _ in }, onUsage: { _ in })
    }

    func streamWithReasoning(profile: ServerProfile, key: String, model: String,
                messages: [ChatMessage], systemPrompt: String, temperature: Double,
                maxTokens: Int?, onText: @escaping @MainActor (String) -> Void,
                onReasoning: @escaping @MainActor (String) -> Void,
                onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws {
        guard let selected = LocalModelCatalog.models.first(where: { $0.id == model }) else {
            throw LocalModelPrompt.PromptError.invalidModel
        }
        // Vocal replies and Web synthesis need visible text within the output
        // budget; LFM's no-thinking prefix avoids an unfinished internal trace.
        let prompt = try prompt(model: selected, messages: messages, instructions: systemPrompt)
        // Metal work in background is restricted by iOS. Reload on CPU when
        // the assistant is running without an active foreground scene.
        let useGPU = await MainActor.run { UIApplication.shared.applicationState == .active }
        try await LocalResponseRecovery.run(prompt: prompt,
            protectWebEvidence: systemPrompt.contains(HybridWebResearch.evidenceInstructions),
            onText: onText, onReasoning: onReasoning, onUsage: onUsage) { prompt, receiveText, receiveUsage in
            try await runtime.generate(modelID: model, prompt: prompt, maxTokens: maxTokens ?? 512, useGPU: useGPU,
                                       contextTokens: LocalModelCatalog.resolvedContextSize(profile.localContextTokens, modelID: model),
                                       reasoningTokens: LocalModelCatalog.reasoningSize(profile.localReasoningTokens),
                                       onUsage: receiveUsage, onText: receiveText)
        }
    }
}

private actor LocalUsageCapture {
    private(set) var value: TokenUsage?
    func set(_ usage: TokenUsage) { value = usage }
}

/// Implements the LFM3 XML tool-call template; Web work remains in the
/// existing bounded and validated HybridWebResearch executor.
struct LocalLFMWebResearchModelClient: WebResearchModelClient {
    var runtime: LocalModelRuntime = .shared
    private static let toolDefinitions = """
    <tools>
    {"name":"web_search","description":"Search the public web using a concise query.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}
    {"name":"web_fetch","description":"Read a source returned by web_search using its source number.","parameters":{"type":"object","properties":{"source":{"type":"integer"}},"required":["source"]}}
    </tools>
    """

    func turn(profile: ServerProfile, key: String, model: String, messages: [ChatMessage],
              systemPrompt: String, temperature: Double, maxTokens: Int?,
              exchanges: [WebToolExchange]) async throws -> WebResearchTurn {
        guard profile.isLocalLFM, profile.model == model,
              let selected = LocalModelCatalog.models.first(where: { $0.id == model }) else {
            throw LocalModelPrompt.PromptError.invalidModel
        }
        let base = try LocalModelPrompt.make(model: selected, messages: messages,
                                             instructions: systemPrompt + "\n\n" + Self.toolDefinitions)
        let suffix = "<|im_start|>assistant\n"
        guard base.text.hasSuffix(suffix) else { throw EudesError.invalidResponse }
        var prompt = String(base.text.dropLast(suffix.count))
        for exchange in exchanges {
            guard let replay = exchange.assistant.replay, let assistant = String(data: replay, encoding: .utf8),
                  !assistant.contains("<|") && !assistant.contains("<__media__>") else { throw EudesError.invalidResponse }
            prompt += suffix + assistant + "<|im_end|>\n"
            for output in exchange.outputs {
                // Tool outputs are untrusted; they cannot terminate the template or inject roles.
                let safe = output.text.replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
                prompt += "<|im_start|>tool\n<tool_response>\n" + safe + "\n</tool_response><|im_end|>\n"
            }
        }
        // Follow the model's template for a tool-planning turn without a
        // lengthy reasoning preamble; preserve the prefix when replaying it.
        prompt += suffix + "<think></think>"
        let captured = LFMResearchOutput()
        let useGPU = await MainActor.run { UIApplication.shared.applicationState == .active }
        do {
            try await runtime.generate(modelID: model, prompt: LocalModelPrompt(text: prompt, images: base.images),
                                       maxTokens: 512, useGPU: useGPU,
                                       contextTokens: LocalModelCatalog.resolvedContextSize(profile.localContextTokens, modelID: model)) { value in
                await captured.set(value)
            }
        } catch LocalLlamaEngine.EngineError.contextLimit {
            throw EudesError.contextExceeded
        }
        let raw = await captured.value
        var result = try Self.parse(raw)
        result.replay = Data(("<think></think>" + raw).utf8)
        return result
    }

    static func parse(_ raw: String) throws -> WebResearchTurn {
        guard raw.utf8.count <= 65_536, !raw.contains("<|"), !raw.contains("<__media__>") else {
            throw WebResearchModelError.unsupportedTools
        }
        let expression = try NSRegularExpression(pattern: #"(?s)<tool_call>\s*<function=([a-z_]+)>\s*<parameter=([a-z_]+)>\s*(.*?)\s*</parameter>\s*</function>\s*</tool_call>"#)
        let ns = raw as NSString
        let matches = expression.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard matches.count <= 8 else { throw WebResearchModelError.unsupportedTools }
        guard raw.components(separatedBy: "<tool_call>").count - 1 == matches.count else {
            throw WebResearchModelError.unsupportedTools
        }
        var calls: [WebToolCall] = []
        for match in matches {
            let name = ns.substring(with: match.range(at: 1))
            let parameter = ns.substring(with: match.range(at: 2))
            let value = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            let argument: Any
            if name == "web_search", parameter == "query", !value.isEmpty { argument = value }
            else if name == "web_fetch", parameter == "source", let number = Int(value), number > 0 { argument = number }
            else { throw WebResearchModelError.unsupportedTools }
            let data = try JSONSerialization.data(withJSONObject: [parameter: argument], options: [.sortedKeys])
            guard let json = String(data: data, encoding: .utf8) else { throw EudesError.invalidResponse }
            calls.append(WebToolCall(id: UUID().uuidString, name: name, arguments: json))
        }
        return WebResearchTurn(calls: calls, text: calls.isEmpty ? LocalModelOutput.split(raw).text : nil,
                               replay: Data(raw.utf8))
    }
}

private actor LFMResearchOutput {
    private(set) var value = ""
    func set(_ text: String) { value = text }
}
