import Foundation

/// A new ephemeral session is created per operation. No shared cookie jar,
/// disk cache, analytics or remote assets. Default TLS validation is retained.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Public NVIDIA Build catalogue; no user API credential is sent to this endpoint.
/// The catalogue labels describe trial endpoints, not an account's entitlement or quota.
enum NVIDIAFreeCatalog {
    private static let pageSize = 100
    private static let maxPages = 30
    private static let maxPageBytes = 2_097_152

    struct Page: Decodable {
        struct Group: Decodable {
            struct Resource: Decodable {
                struct Label: Decodable { let key: String; let values: [String] }
                let name: String
                let labels: [Label]
            }
            let groupValue: String
            let totalCount: Int
            let resources: [Resource]
        }
        let resultPageTotal: Int
        let resultTotal: Int
        let results: [Group]
    }

    struct ParsedPage {
        let ids: Set<String>
        let total: Int
        let pages: Int
        let count: Int
    }

    static func parse(_ data: Data, page: Int) throws -> ParsedPage {
        let response: Page
        do { response = try JSONDecoder().decode(Page.self, from: data) }
        catch { throw EudesError.invalidResponse }
        guard response.resultTotal > 0, response.resultTotal <= pageSize * maxPages,
              response.resultPageTotal > 0, response.resultPageTotal <= maxPages,
              response.resultPageTotal == (response.resultTotal + pageSize - 1) / pageSize,
              page >= 0, page < response.resultPageTotal,
              let group = response.results.first(where: { $0.groupValue == "ENDPOINT" }),
              group.totalCount == response.resultTotal,
              group.resources.count == min(pageSize, response.resultTotal - page * pageSize) else {
            throw EudesError.invalidResponse
        }
        var ids = Set<String>()
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for resource in group.resources {
            guard resource.labels.contains(where: { $0.key == "general" && $0.values.contains("Free Endpoint") }),
                  let publisherLabel = resource.labels.first(where: { $0.key == "publisher" }),
                  publisherLabel.values.count == 1 else { throw EudesError.invalidResponse }
            let publisher = publisherLabel.values[0]
            guard !publisher.isEmpty, !resource.name.isEmpty,
                  publisher.unicodeScalars.allSatisfy({ permitted.contains($0) }),
                  resource.name.unicodeScalars.allSatisfy({ permitted.contains($0) }) else {
                throw EudesError.invalidResponse
            }
            ids.insert(publisher + "/" + resource.name)
        }
        return ParsedPage(ids: ids, total: response.resultTotal, pages: response.resultPageTotal,
                          count: group.resources.count)
    }

    static func request(page: Int) throws -> URLRequest {
        let search: [String: Any] = ["filters": [["field": "label", "value": "nim_type_preview"]],
                                     "page": page, "pageSize": pageSize, "query": "*"]
        let encoded = try JSONSerialization.data(withJSONObject: search, options: [.sortedKeys])
        guard let query = String(data: encoded, encoding: .utf8),
              var components = URLComponents(string: "https://api.ngc.nvidia.com/v2/search/catalog/resources/ENDPOINT") else {
            throw EudesError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw EudesError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func fetch() async throws -> Set<String> {
        let config = LocalAPIClient.configuration()
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var ids = Set<String>()
        var page = 0
        var total: Int?
        var pages = 1
        var count = 0
        while page < pages {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request(page: page), delegate: delegate)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw EudesError.invalidResponse
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maxPageBytes else { throw EudesError.responseTooLarge }
                data.append(byte)
            }
            let parsed = try parse(data, page: page)
            if let total, total != parsed.total { throw EudesError.invalidResponse }
            if page > 0 && pages != parsed.pages { throw EudesError.invalidResponse }
            total = parsed.total
            pages = parsed.pages
            count += parsed.count
            ids.formUnion(parsed.ids)
            page += 1
        }
        guard count == total else { throw EudesError.invalidResponse }
        return ids
    }
}

enum ConnectionProof: Equatable { case reachable, unverified }

protocol EudesAPIClient {
    func checkConnection(profile: ServerProfile, key: String) async throws -> ConnectionProof
    func models(profile: ServerProfile, key: String) async throws -> [String]
    func catalog(profile: ServerProfile, key: String) async throws -> ModelCatalog
    func stream(profile: ServerProfile, key: String, model: String,
                messages: [ChatMessage], systemPrompt: String, temperature: Double,
                maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws
    func streamWithUsage(profile: ServerProfile, key: String, model: String,
                messages: [ChatMessage], systemPrompt: String, temperature: Double,
                maxTokens: Int?, onText: @escaping @MainActor (String) -> Void,
                onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws
    func streamWithReasoning(profile: ServerProfile, key: String, model: String,
                messages: [ChatMessage], systemPrompt: String, temperature: Double,
                maxTokens: Int?, onText: @escaping @MainActor (String) -> Void,
                onReasoning: @escaping @MainActor (String) -> Void,
                onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws
}

extension EudesAPIClient {
    func streamWithReasoning(profile: ServerProfile, key: String, model: String,
                messages: [ChatMessage], systemPrompt: String, temperature: Double,
                maxTokens: Int?, onText: @escaping @MainActor (String) -> Void,
                onReasoning: @escaping @MainActor (String) -> Void,
                onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws {
        try await streamWithUsage(profile: profile, key: key, model: model, messages: messages,
                                  systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens,
                                  onText: onText, onUsage: onUsage)
    }
    func streamWithUsage(profile: ServerProfile, key: String, model: String,
                messages: [ChatMessage], systemPrompt: String, temperature: Double,
                maxTokens: Int?, onText: @escaping @MainActor (String) -> Void,
                onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws {
        try await stream(profile: profile, key: key, model: model, messages: messages,
                         systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens, onText: onText)
    }
    func catalog(profile: ServerProfile, key: String) async throws -> ModelCatalog {
        ModelCatalog(ids: try await models(profile: profile, key: key))
    }
    func checkConnection(profile: ServerProfile, key: String) async throws -> ConnectionProof {
        _ = try await models(profile: profile, key: key)
        return .reachable
    }
}

struct LocalAPIClient: EudesAPIClient {
    // Injectable ephemeral transport for tests; never supplied by production UI.
    var controlConfiguration: URLSessionConfiguration? = nil
    private func controlConfig() -> URLSessionConfiguration {
        let config = controlConfiguration ?? Self.configuration()
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        return config
    }
    func checkConnection(profile: ServerProfile, key: String) async throws -> ConnectionProof {
        do {
            _ = try await models(profile: profile, key: key)
            return .reachable
        } catch EudesError.server(let status) where [404, 405, 501].contains(status) {
            // /models is optional on some compatible servers. Never POST a test generation.
            var request = try Self.request(profile: profile, key: key, route: profile.protocolKind.route)
            request.httpMethod = "OPTIONS"
            request.timeoutInterval = 5
            let delegate = NoRedirectDelegate()
            let session = URLSession(configuration: controlConfig(), delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.bytes(for: request, delegate: delegate)
            guard let response = response as? HTTPURLResponse else { throw EudesError.invalidResponse }
            if [404, 405, 501].contains(response.statusCode) { return .unverified }
            try Self.check(response)
            let methods = (response.value(forHTTPHeaderField: "Allow") ?? "").uppercased()
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return methods.contains("POST") ? .reachable : .unverified
        }
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        return config
    }

    // A streamed generation may take longer than a quick catalogue request.
    // Keep idle and total time bounded while allowing the user to cancel.
    static func generationConfiguration() -> URLSessionConfiguration {
        let config = configuration()
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return config
    }

    static func request(profile: ServerProfile, key: String, route: LocalEndpoint.Route) throws -> URLRequest {
        let endpoint = try LocalEndpoint(profile.baseURL, allowsHTTP: profile.allowsHTTP)
        var request = URLRequest(url: endpoint.url(for: route))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !key.isEmpty {
            // Inspect bytes: Swift treats CRLF as one grapheme cluster.
            guard !key.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) else {
                throw EudesError.invalidResponse
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func countInput(profile: ServerProfile, key: String, model: String, messages: [ChatMessage]) async throws -> Int? {
        guard profile.protocolKind == .chatCompletions, !model.isEmpty,
              messages.allSatisfy({ ($0.images ?? []).isEmpty }) else { return nil }
        var request = try Self.request(profile: profile, key: key, route: .countTokens)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        var body: [String: Any] = ["model": model, "messages": messages.filter { $0.state == .complete }.map { ["role": $0.role.rawValue, "content": $0.text] }]
        if !profile.effectiveInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["system"] = profile.effectiveInstruction }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: controlConfig(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        try Self.check(response)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16_384 else { throw EudesError.responseTooLarge }
            data.append(byte)
        }
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let value = payload?["input_tokens"] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
              value.doubleValue.rounded() == value.doubleValue,
              value.doubleValue >= 0, value.doubleValue <= 100_000_000 else { return nil }
        return value.intValue
    }

    func models(profile: ServerProfile, key: String) async throws -> [String] {
        try await catalog(profile: profile, key: key).ids
    }
    func catalog(profile: ServerProfile, key: String) async throws -> ModelCatalog {
        var request = try Self.request(profile: profile, key: key, route: .models)
        request.timeoutInterval = 5
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: controlConfig(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        try Self.check(response)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2_097_152 else { throw EudesError.responseTooLarge }
            data.append(byte)
        }
        return try ModelCatalog.decode(data)
    }

    /// Builds the payload without opening a session or performing any network I/O.
    static func completionRequest(profile: ServerProfile, key: String, model: String,
                                  messages: [ChatMessage], systemPrompt: String,
                                  temperature: Double, maxTokens: Int?, includeUsage: Bool = false) throws -> URLRequest {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EudesError.noModel }
        var request = try Self.request(profile: profile, key: key, route: profile.protocolKind.route)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var wireMessages: [[String: Any]] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { wireMessages.append(["role": "system", "content": systemPrompt]) }
        let complete = messages.filter { $0.state == .complete }
        let images = complete.flatMap { $0.images ?? [] }
        guard images.isEmpty || profile.supportsImages(model) else { throw ImageAttachmentError.incompatible }
        guard images.reduce(0, { $0 + $1.data.count }) <= 8 * 1024 * 1024 else { throw ImageAttachmentError.limit }
        for message in complete {
            let attachments = message.images ?? []
            guard attachments.count <= ImageAttachment.maxCount else { throw ImageAttachmentError.limit }
            if attachments.isEmpty {
                wireMessages.append(["role": message.role.rawValue, "content": message.text])
            } else {
                guard message.role == .user else { throw ImageAttachmentError.invalid }
                var content: [[String: Any]] = []
                if !message.text.isEmpty { content.append(["type": "text", "text": message.text]) }
                for image in attachments {
                    guard image.data.count <= 2 * 1024 * 1024,
                          image.data.starts(with: [0xff, 0xd8, 0xff]) else { throw ImageAttachmentError.invalid }
                    content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.data.base64EncodedString()]])
                }
                wireMessages.append(["role": "user", "content": content])
            }
        }
        var body: [String: Any]
        if profile.protocolKind == .responses {
            // Stateless, explicit history: no hosted conversation or implicit truncation.
            let input: [[String: Any]] = wireMessages.filter { ($0["role"] as? String) != "system" }.map { message in
                guard let content = message["content"] as? [[String: Any]] else { return message }
                let parts: [[String: Any]] = content.map { part in
                    if let text = part["text"] { return ["type": "input_text", "text": text] }
                    let image = part["image_url"] as? [String: String]
                    return ["type": "input_image", "image_url": image?["url"] ?? "", "detail": "auto"]
                }
                return ["role": message["role"] ?? "user", "content": parts]
            }
            body = ["model": model, "input": input, "stream": true, "store": false,
                    "truncation": "disabled"]
            if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["instructions"] = systemPrompt }
            // Temperature is not universally supported by Responses reasoning models.
            // Leave provider defaults rather than guessing capabilities from model names.
        } else {
            body = ["model": model, "messages": wireMessages, "stream": true,
                    "temperature": min(2, max(0, temperature))]
            if includeUsage { body["stream_options"] = ["include_usage": true] }
        }
        let thinking = profile.thinkingMode(for: model)
        if thinking != .automatic {
            switch profile.effectiveThinkingFormat(for: model) {
            case .reasoningEffort:
                if let effort = thinking.effortValue { body["reasoning_effort"] = effort }
            case .reasoningObject, .responsesReasoning:
                if let effort = thinking.effortValue {
                    body["reasoning"] = ["effort": effort]
                    if profile.protocolKind == .chatCompletions,
                       URL(string: profile.baseURL)?.scheme?.lowercased() == "https",
                       URL(string: profile.baseURL)?.host?.lowercased() == "openrouter.ai" {
                        body["provider"] = ["require_parameters": true]
                    }
                }
            case .enableThinking:
                if thinking == .enabled { body["chat_template_kwargs"] = ["enable_thinking": true] }
                else if thinking == .disabled { body["chat_template_kwargs"] = ["enable_thinking": false] }
            case .automatic: break
            }
        }
        if let output = profile.effectiveOutput(maxTokens, model: model) {
            body[profile.protocolKind == .responses ? "max_output_tokens" : "max_tokens"] = output
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func stream(profile: ServerProfile, key: String, model: String,
                messages: [ChatMessage], systemPrompt: String, temperature: Double,
                maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        try await streamWithUsage(profile: profile, key: key, model: model, messages: messages,
                                 systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens,
                                 onText: onText, onUsage: { _ in })
    }

    func streamWithUsage(profile: ServerProfile, key: String, model: String,
                messages: [ChatMessage], systemPrompt: String, temperature: Double,
                maxTokens: Int?, onText: @escaping @MainActor (String) -> Void,
                onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws {
        try await streamWithReasoning(profile: profile, key: key, model: model, messages: messages,
                                      systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens,
                                      onText: onText, onReasoning: { _ in }, onUsage: onUsage)
    }

    func streamWithReasoning(profile: ServerProfile, key: String, model: String,
                messages: [ChatMessage], systemPrompt: String, temperature: Double,
                maxTokens: Int?, onText: @escaping @MainActor (String) -> Void,
                onReasoning: @escaping @MainActor (String) -> Void,
                onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws {
        try await streamResponse(profile: profile, key: key, model: model, messages: messages,
            systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens,
            recoverable: false, onCreated: { _ in }, onText: onText,
            onReasoning: onReasoning, onUsage: onUsage)
    }

    fileprivate func streamResponse(profile: ServerProfile, key: String, model: String,
                messages: [ChatMessage], systemPrompt: String, temperature: Double,
                maxTokens: Int?, recoverable: Bool,
                onCreated: @escaping @MainActor (String) throws -> Void,
                onText: @escaping @MainActor (String) -> Void,
                onReasoning: @escaping @MainActor (String) -> Void,
                onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws {
        let host = URL(string: profile.baseURL)?.host?.lowercased() ?? ""
        let requestUsage = profile.protocolKind == .chatCompletions && ["integrate.api.nvidia.com", "api.openai.com", "openrouter.ai"].contains(host)
        let request: URLRequest
        if recoverable {
            request = try OpenAIRecoverableResponseClient.backgroundRequest(profile: profile, key: key,
                model: model, messages: messages, systemPrompt: systemPrompt,
                temperature: temperature, maxTokens: maxTokens)
        } else {
            request = try Self.completionRequest(profile: profile, key: key, model: model,
                messages: messages, systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens, includeUsage: requestUsage)
        }
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: controlConfiguration ?? Self.generationConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if http.statusCode == 400 || http.statusCode == 422 {
                var body = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard body.count < 65_536 else { break }
                    body.append(byte)
                }
                if Self.isContextExceeded(body) { throw EudesError.contextExceeded }
            }
            try Self.check(response)
        }
        try Self.check(response)
        guard let response = response as? HTTPURLResponse,
              response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw EudesError.invalidResponse
        }
        var parser = SSEDecoder()
        var fullText = ""
        var fullReasoning = ""
        var pending = ""
        var pendingReasoning = ""
        var lastEmission = Date.distantPast
        var finished = false
        var outputLimitReached = false
        var receivedBytes = 0
        var usage: TokenUsage?
        var createdID: String?
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                receivedBytes += 1
                guard receivedBytes <= 16_777_216 else { throw EudesError.responseTooLarge }
                guard let event = try parser.feed(byte) else { continue }
                if recoverable {
                    if event.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                        guard finished else { throw EudesError.truncatedStream }
                        break
                    }
                    let metadata = try OpenAIRecoverableResponseClient.streamMetadata(event)
                    if metadata.isKeepalive { continue }
                    if let id = metadata.createdID {
                        if let createdID, createdID != id { throw EudesError.malformedStream }
                        if createdID == nil {
                            try await onCreated(id)
                            createdID = id
                        }
                    }
                    // Never consume answer fragments before its ID is safely stored.
                    guard createdID != nil else { throw EudesError.malformedStream }
                }
                if let reported = Self.parseUsage(event, protocolKind: profile.protocolKind) { usage = reported }
                let chunk = try Self.parseEvent(event, protocolKind: profile.protocolKind)
                outputLimitReached = outputLimitReached || chunk.finishReason == "length"
                fullText += chunk.text
                pending += chunk.text
                fullReasoning += chunk.reasoning
                pendingReasoning += chunk.reasoning
                guard fullText.utf8.count + fullReasoning.utf8.count <= 2_097_152 else { throw EudesError.responseTooLarge }
                if (!pending.isEmpty || !pendingReasoning.isEmpty) && (Date().timeIntervalSince(lastEmission) > 0.045 || chunk.finished) {
                    if !pending.isEmpty { await onText(fullText) }
                    if !pendingReasoning.isEmpty { await onReasoning(fullReasoning) }
                    pending = ""
                    pendingReasoning = ""
                    lastEmission = Date()
                }
                if chunk.finished {
                    finished = true
                    if event.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { break }
                }
            }
            if let tail = try parser.finish() {
                var ignoreTail = false
                if recoverable {
                    if tail.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                        guard finished else { throw EudesError.truncatedStream }
                        ignoreTail = true
                    } else {
                        let metadata = try OpenAIRecoverableResponseClient.streamMetadata(tail)
                        if let id = metadata.createdID {
                            if let createdID, createdID != id { throw EudesError.malformedStream }
                            if createdID == nil { try await onCreated(id); createdID = id }
                        }
                        if metadata.isKeepalive { ignoreTail = true }
                        else if createdID == nil { throw EudesError.malformedStream }
                    }
                }
                if !ignoreTail {
                    if let reported = Self.parseUsage(tail, protocolKind: profile.protocolKind) { usage = reported }
                    let chunk = try Self.parseEvent(tail, protocolKind: profile.protocolKind)
                    outputLimitReached = outputLimitReached || chunk.finishReason == "length"
                    fullText += chunk.text
                    fullReasoning += chunk.reasoning
                    guard fullText.utf8.count + fullReasoning.utf8.count <= 2_097_152 else { throw EudesError.responseTooLarge }
                    finished = finished || chunk.finished
                }
            }
        } catch {
            if !fullText.isEmpty { await onText(fullText) }
            if !fullReasoning.isEmpty { await onReasoning(fullReasoning) }
            if !(error is CancellationError) {
                DiagnosticLog.record(error, context: "flux interrompu")
            }
            throw error
        }
        if !fullText.isEmpty { await onText(fullText) }
        if !fullReasoning.isEmpty { await onReasoning(fullReasoning) }
        guard finished else { throw EudesError.truncatedStream }
        if let usage { await onUsage(usage) }
        if outputLimitReached { throw EudesError.outputLimitReached }
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EudesError.emptyResponse }
    }

    static func parseUsage(_ payload: String, protocolKind: APIProtocol) -> TokenUsage? {
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let parent = protocolKind == .responses ? object["response"] as? [String: Any] : object
        guard let usage = parent?["usage"] as? [String: Any] else { return nil }
        func count(_ key: String) -> Int? {
            guard let n = usage[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
                  n.doubleValue >= 0, n.doubleValue <= 100_000_000 else { return nil }
            return n.intValue
        }
        guard let input = count(protocolKind == .responses ? "input_tokens" : "prompt_tokens"),
              let output = count(protocolKind == .responses ? "output_tokens" : "completion_tokens") else { return nil }
        return TokenUsage(input: input, output: output)
    }

    static func parseEvent(_ payload: String, protocolKind: APIProtocol) throws -> (text: String, reasoning: String, finished: Bool, finishReason: String?) {
        switch protocolKind {
        case .chatCompletions: return try CompletionChunk.parse(payload)
        case .responses:
            let event = try ResponsesEvent.parse(payload)
            return (event.text, event.reasoning, event.finished, nil)
        }
    }

    fileprivate static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw EudesError.invalidResponse }
        if (300...399).contains(response.statusCode) { throw EudesError.redirect }
        guard (200...299).contains(response.statusCode) else { throw EudesError.server(response.statusCode) }
    }

    // A status code alone is ambiguous. Do not classify free-form provider
    // messages or persist them, as they can contain conversation data.
    static func isContextExceeded(_ data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let code = error["code"] as? String else { return false }
        return code == "context_length_exceeded"
    }
}

/// A server-side response that can be queried after an interrupted stream.
struct RecoverableSnapshot: Equatable {
    enum Status: Equatable { case queued, inProgress, completed, failed, cancelled, incomplete }
    let status: Status
    // In-progress responses may omit output. Never replace a saved partial with nil.
    let text: String?
    let reasoning: String?
    let usage: TokenUsage?
}

protocol RecoverableResponseClient {
    func start(profile: ServerProfile, key: String, model: String,
               messages: [ChatMessage], systemPrompt: String, temperature: Double, maxTokens: Int?,
               onCreated: @escaping @MainActor (String) throws -> Void,
               onText: @escaping @MainActor (String) -> Void,
               onReasoning: @escaping @MainActor (String) -> Void,
               onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws
    func retrieve(profile: ServerProfile, key: String, responseID: String) async throws -> RecoverableSnapshot
    func cancel(profile: ServerProfile, key: String, responseID: String) async throws
}

/// OpenAI's documented Responses background mode. It temporarily retains response
/// data at OpenAI even when `store` is false; the user must opt in before start.
/// Recovery never posts a new generation, and never sends credentials to proxies.
struct OpenAIRecoverableResponseClient: RecoverableResponseClient {
    let configuration: URLSessionConfiguration?
    init(configuration: URLSessionConfiguration? = nil) { self.configuration = configuration }

    static func supports(profile: ServerProfile) -> Bool {
        guard profile.protocolKind == .responses,
              let c = URLComponents(string: profile.baseURL),
              c.scheme?.lowercased() == "https", c.host?.lowercased() == "api.openai.com",
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port == nil || c.port == 443,
              c.percentEncodedPath == "/v1" || c.percentEncodedPath == "/v1/" else { return false }
        return true
    }

    static func validResponseID(_ id: String) -> Bool {
        guard id.hasPrefix("resp_"), id.utf8.count > 5, id.utf8.count <= 256 else { return false }
        return id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    static func backgroundRequest(profile: ServerProfile, key: String, model: String,
                                  messages: [ChatMessage], systemPrompt: String,
                                  temperature: Double, maxTokens: Int?) throws -> URLRequest {
        guard supports(profile: profile) else { throw EudesError.invalidResponse }
        var request = try LocalAPIClient.completionRequest(profile: profile, key: key, model: model,
            messages: messages, systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens)
        guard let original = request.httpBody,
              var body = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw EudesError.invalidResponse
        }
        body["background"] = true
        // Keep the existing non-persistent preference; background itself temporarily
        // retains the response on OpenAI's servers for retrieval.
        body["store"] = false
        body["stream"] = true
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func responseRequest(profile: ServerProfile, key: String, responseID: String,
                                        cancel: Bool) throws -> URLRequest {
        guard supports(profile: profile), validResponseID(responseID) else { throw EudesError.invalidResponse }
        var request = try LocalAPIClient.request(profile: profile, key: key, route: .responses)
        guard let original = request.url else { throw EudesError.invalidResponse }
        var url = original.appendingPathComponent(responseID, isDirectory: false)
        if cancel { url.appendPathComponent("cancel", isDirectory: false) }
        request.url = url
        request.httpMethod = cancel ? "POST" : "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func retrieveRequest(profile: ServerProfile, key: String, responseID: String) throws -> URLRequest {
        try responseRequest(profile: profile, key: key, responseID: responseID, cancel: false)
    }

    static func cancelRequest(profile: ServerProfile, key: String, responseID: String) throws -> URLRequest {
        try responseRequest(profile: profile, key: key, responseID: responseID, cancel: true)
    }

    func start(profile: ServerProfile, key: String, model: String,
               messages: [ChatMessage], systemPrompt: String, temperature: Double, maxTokens: Int?,
               onCreated: @escaping @MainActor (String) throws -> Void,
               onText: @escaping @MainActor (String) -> Void,
               onReasoning: @escaping @MainActor (String) -> Void,
               onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws {
        try await LocalAPIClient(controlConfiguration: configuration).streamResponse(profile: profile, key: key,
            model: model, messages: messages, systemPrompt: systemPrompt, temperature: temperature,
            maxTokens: maxTokens, recoverable: true, onCreated: onCreated, onText: onText,
            onReasoning: onReasoning, onUsage: onUsage)
    }

    func retrieve(profile: ServerProfile, key: String, responseID: String) async throws -> RecoverableSnapshot {
        let request = try Self.retrieveRequest(profile: profile, key: key, responseID: responseID)
        let data = try await execute(request)
        return try Self.parseSnapshot(data, expectedID: responseID)
    }

    func cancel(profile: ServerProfile, key: String, responseID: String) async throws {
        let request = try Self.cancelRequest(profile: profile, key: key, responseID: responseID)
        let data = try await execute(request)
        // A successful HTTP transport alone is not proof that this particular
        // generation stopped. Keep the pending job until the provider confirms it.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["id"] as? String, id == responseID,
              root["status"] as? String == "cancelled" else {
            throw EudesError.invalidResponse
        }
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: configuration ?? LocalAPIClient.configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        try LocalAPIClient.check(response)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4_194_304 else { throw EudesError.responseTooLarge }
            data.append(byte)
        }
        return data
    }

    /// Read only a server-created response ID. Do not trust redirects or arbitrary paths.
    static func streamMetadata(_ event: String) throws -> (createdID: String?, isKeepalive: Bool) {
        guard let data = event.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else { throw EudesError.malformedStream }
        if type == "keepalive" { return (nil, true) }
        if type == "response.created" {
            guard let response = root["response"] as? [String: Any],
                  let id = response["id"] as? String, validResponseID(id) else { throw EudesError.malformedStream }
            return (id, false)
        }
        return (nil, false)
    }

    /// The GET endpoint supplies a full snapshot, so the caller replaces text
    /// rather than appending to the saved SSE prefix. This avoids cursor gaps.
    static func parseSnapshot(_ data: Data, expectedID: String? = nil) throws -> RecoverableSnapshot {
        guard data.count <= 4_194_304,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["id"] as? String, validResponseID(id),
              expectedID == nil || expectedID == id,
              let rawStatus = root["status"] as? String else { throw EudesError.invalidResponse }
        let status: RecoverableSnapshot.Status
        switch rawStatus {
        case "queued": status = .queued
        case "in_progress": status = .inProgress
        case "completed": status = .completed
        case "failed": status = .failed
        case "cancelled": status = .cancelled
        case "incomplete": status = .incomplete
        default: throw EudesError.invalidResponse
        }
        var text = ""
        var reasoning = ""
        var hasText = false
        var hasReasoning = false
        if let rawOutput = root["output"], !(rawOutput is NSNull) {
            guard let output = rawOutput as? [[String: Any]] else { throw EudesError.invalidResponse }
            for item in output {
                guard let type = item["type"] as? String else { throw EudesError.invalidResponse }
                switch type {
                case "message":
                    guard let content = item["content"] as? [[String: Any]] else { throw EudesError.invalidResponse }
                    for part in content {
                        guard let kind = part["type"] as? String else { throw EudesError.invalidResponse }
                        if kind == "output_text" || kind == "refusal" {
                            guard let value = part[kind == "refusal" ? "refusal" : "text"] as? String else {
                                throw EudesError.invalidResponse
                            }
                            text += value
                            hasText = true
                        } else { throw EudesError.unsupportedResponse }
                    }
                case "reasoning":
                    if let rawSummary = item["summary"], !(rawSummary is NSNull) {
                        guard let summary = rawSummary as? [[String: Any]] else { throw EudesError.invalidResponse }
                        for part in summary {
                            guard part["type"] as? String == "summary_text", let value = part["text"] as? String else {
                                throw EudesError.invalidResponse
                            }
                            reasoning += value
                            hasReasoning = true
                        }
                    }
                default: throw EudesError.unsupportedResponse
                }
                guard text.utf8.count + reasoning.utf8.count <= 2_097_152 else { throw EudesError.responseTooLarge }
            }
        }
        let usage: TokenUsage?
        if let u = root["usage"], JSONSerialization.isValidJSONObject(["response": ["usage": u]]),
           let wrapped = try? JSONSerialization.data(withJSONObject: ["response": ["usage": u]]),
           let string = String(data: wrapped, encoding: .utf8) {
            usage = LocalAPIClient.parseUsage(string, protocolKind: .responses)
        } else { usage = nil }
        if status == .completed && (!hasText || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            throw EudesError.emptyResponse
        }
        return RecoverableSnapshot(status: status, text: hasText ? text : nil,
                                   reasoning: hasReasoning ? reasoning : nil, usage: usage)
    }
}
