import XCTest
@testable import Eudes

final class SSEDecoderTests: XCTestCase {
    func testServerTokenCountingAndUnsupportedRoute() async throws {
        let profile = ServerProfile(baseURL: "https://example.com/v1", model: "alpha", systemInstruction: "Consigne")
        for (scenario, expected) in [("success", 17), ("invalid", nil), ("missing", nil)] as [(String, Int?)] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CountURLStub.self]
            config.httpAdditionalHeaders = ["X-Eudes-Fixture": scenario]
            let client = LocalAPIClient(controlConfiguration: config)
            do {
                let count = try await client.countInput(profile: profile, key: "", model: "alpha", messages: [ChatMessage(role: .user, text: "Bonjour")])
                XCTAssertEqual(count, expected)
                XCTAssertNotEqual(scenario, "missing")
            } catch { XCTAssertEqual(scenario, "missing") }
        }
    }
    func testUsageParsingAndPersistence() throws {
        let chat = #"{"choices":[],"usage":{"prompt_tokens":42,"completion_tokens":7}}"#
        XCTAssertEqual(LocalAPIClient.parseUsage(chat, protocolKind: .chatCompletions), TokenUsage(input: 42, output: 7))
        let responses = #"{"type":"response.completed","response":{"usage":{"input_tokens":55,"output_tokens":8}}}"#
        XCTAssertEqual(LocalAPIClient.parseUsage(responses, protocolKind: .responses), TokenUsage(input: 55, output: 8))
        XCTAssertNil(LocalAPIClient.parseUsage(#"{"usage":{"prompt_tokens":true,"completion_tokens":7}}"#, protocolKind: .chatCompletions))
        XCTAssertNil(LocalAPIClient.parseUsage(#"{"usage":{"prompt_tokens":2}}"#, protocolKind: .chatCompletions))
        var message = ChatMessage(role: .assistant, text: "Réponse")
        message.usage = TokenUsage(input: 42, output: 7)
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message)).usage, message.usage)
    }
    func testContextErrorClassificationRequiresExplicitCode() {
        XCTAssertTrue(LocalAPIClient.isContextExceeded(Data(#"{"error":{"code":"context_length_exceeded"}}"#.utf8)))
        XCTAssertFalse(LocalAPIClient.isContextExceeded(Data(#"{"error":{"code":"invalid_request","message":"context length"}}"#.utf8)))
        XCTAssertFalse(LocalAPIClient.isContextExceeded(Data(#"{"error":{"message":"context length exceeded"}}"#.utf8)))
        XCTAssertFalse(LocalAPIClient.isContextExceeded(Data("invalid".utf8)))
    }
    func testCompactedConversationPreservesHistoryAndRoundTrips() throws {
        let first = ChatMessage(role: .user, text: "ancienne question")
        let second = ChatMessage(role: .assistant, text: "ancienne réponse")
        let latest = ChatMessage(role: .user, text: "question récente")
        var conversation = Conversation(serverID: UUID(), model: "fixture")
        conversation.messages = [first, second, latest]
        conversation.contextSummary = "Résumé vérifié"
        conversation.contextSummaryThrough = second.id
        let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        XCTAssertEqual(restored.messages, [first, second, latest])
        XCTAssertEqual(restored.modelMessages.count, 2)
        XCTAssertTrue(restored.modelMessages[0].text.contains("Résumé vérifié"))
        XCTAssertEqual(restored.modelMessages[1], latest)
        conversation.contextSummaryThrough = UUID()
        XCTAssertEqual(conversation.modelMessages, conversation.messages)
    }
    func testManualImageOverrideIsScopedAndSurvivesRefresh() throws {
        var p = ServerProfile(name: "Fixture", baseURL: "https://example.com/v1", model: "a")
        XCTAssertFalse(p.supportsImages("a"))
        p.setManualImages(true, model: "a")
        XCTAssertTrue(p.supportsImages("a"))
        XCTAssertFalse(p.supportsImages("b"))
        XCTAssertEqual(p.capabilities(for: "a").images, .unknown)
        XCTAssertEqual(p.capabilities(for: "a").pdf, .unknown)
        p.applyMetadata(ModelCatalog(ids: ["a"]), model: "a", fields: [.capabilities])
        p.apply(ModelCatalog(ids: ["a"]))
        XCTAssertTrue(p.supportsImages("a"))
        let restored = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(p))
        XCTAssertTrue(restored.supportsImages("a"))
        p.setManualImages(false, model: "a")
        XCTAssertFalse(p.supportsImages("a"))
        p.apply(ModelCatalog(ids: ["a"], capabilities: ["a": ModelCapabilities(images: .supported)]))
        XCTAssertTrue(p.supportsImages("a")) // Off returns to API detection.
        p.setManualImages(true, model: "a")
        p.baseURL = "https://other.example.com/v1"
        XCTAssertFalse(p.supportsImages("a"))
        p.baseURL = "https://example.com/v1"; p.protocolKind = .responses
        XCTAssertFalse(p.supportsImages("a"))
        p.protocolKind = .chatCompletions
        p.apply(ModelCatalog(ids: ["a"], capabilities: ["a": ModelCapabilities(images: .unsupported)]))
        XCTAssertFalse(p.supportsImages("a")) // Explicit incompatibility is not bypassed.
        var apple = ServerProfile.apple
        apple.setManualImages(true, model: ServerProfile.appleModel)
        XCTAssertFalse(apple.supportsImages(ServerProfile.appleModel))
        XCTAssertFalse(restored.duplicate().supportsImages("a"))
    }

    func testSelectiveMetadataRefreshPreservesManualAndOutput() throws {
        var p = ServerProfile(name: "Fixture", baseURL: "https://example.com/v1", model: "a")
        p.apply(ModelCatalog(ids: ["a", "b"], limits: ["a": ModelLimits(advertised: [TokenLimit(tokens: 100, source: "fixture")], output: [TokenLimit(tokens: 25, source: "fixture")])], capabilities: ["a": ModelCapabilities(images: .supported)]))
        p.setContextBudget(77, model: "a")
        let next = ModelCatalog(ids: ["a", "b"], limits: ["a": ModelLimits(advertised: [TokenLimit(tokens: 200, source: "fixture")]), "b": ModelLimits(advertised: [TokenLimit(tokens: 400, source: "fixture")])], capabilities: ["a": ModelCapabilities(images: .unsupported)])
        p.applyMetadata(next, model: "a", fields: [.context])
        XCTAssertEqual(p.maximumContext(for: "a"), 77)
        XCTAssertEqual(p.limits(for: "a").context, 200)
        XCTAssertEqual(p.limits(for: "a").outputLimit, 25)
        XCTAssertEqual(p.capabilities(for: "a").images, .supported)
        p.applyMetadata(next, model: "b", fields: [.context])
        XCTAssertEqual(p.maximumContext(for: "b"), 400)
        p.applyMetadata(next, model: "a", fields: [.capabilities])
        XCTAssertEqual(p.capabilities(for: "a").images, .unsupported)
        p.applyMetadata(ModelCatalog(ids: []), model: "a", fields: [.context, .capabilities])
        XCTAssertNil(p.limits(for: "a").context)
        XCTAssertEqual(p.maximumContext(for: "a"), 77)
        XCTAssertEqual(p.capabilities(for: "a").images, .unknown)
        p.setContextBudget(nil, model: "b")
        p.applyMetadata(next, model: "b", fields: [.context])
        XCTAssertNil(p.maximumContext(for: "b"))
        let restored = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(restored.maximumContext(for: "a"), 77)
        XCTAssertNil(restored.maximumContext(for: "b"))
    }

    @MainActor
    func testMetadataRefreshCoalescesAndRejectsLateSelection() async throws {
        let refresh = ModelMetadataRefresh()
        var old: CheckedContinuation<ModelCatalog, Error>?
        var calls = 0
        var applied: [String] = []
        var appliedFields: Set<ModelMetadataField> = []
        refresh.request(identity: "a", fields: [.context]) {
            calls += 1
            return try await withCheckedThrowingContinuation { old = $0 }
        } apply: { _, _ in applied.append("a") }
        await Task.yield()
        refresh.request(identity: "a", fields: [.capabilities]) {
            calls += 1; return ModelCatalog(ids: [])
        } apply: { _, _ in XCTFail("Duplicate request callback") }
        XCTAssertEqual(calls, 1)
        refresh.request(identity: "b", fields: [.context, .capabilities]) {
            ModelCatalog(ids: ["b"])
        } apply: { _, fields in applied.append("b"); appliedFields = fields }
        for _ in 0..<10 { await Task.yield() }
        old?.resume(returning: ModelCatalog(ids: ["a"]))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(applied, ["b"])
        XCTAssertEqual(appliedFields, [.context, .capabilities])
        XCTAssertFalse(refresh.isLoading)
        refresh.request(identity: "b", fields: [.context]) { throw EudesError.invalidResponse } apply: { _, _ in XCTFail("Failure applied") }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNotNil(refresh.error)
        refresh.request(identity: "b", fields: [.context]) { ModelCatalog(ids: []) } apply: { _, _ in applied.append("recovered") }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(refresh.error)
        XCTAssertEqual(applied.last, "recovered")
    }

    func testMarkdownHeadingBlocksPreserveLiteralHashes() {
        for level in 1...6 {
            let blocks = MarkdownHeadingBlock.parse(String(repeating: "#", count: level) + " **Titre**")
            XCTAssertEqual(blocks, [MarkdownHeadingBlock(text: "**Titre**", level: level)])
        }
        for literal in ["#tag", "####### titre", "    # code", "\\# échappé", "`# code`", "texte # littéral"] {
            XCTAssertEqual(MarkdownHeadingBlock.parse(literal), [MarkdownHeadingBlock(text: literal, level: nil)])
        }
        XCTAssertEqual(MarkdownHeadingBlock.parse("texte\n### Titre\nsuite").map(\.level), [nil, 3, nil])
        XCTAssertEqual(MarkdownHeadingBlock.parse("###").first?.level, 3)
    }


    func testOptionalOutputCapacityPayloadAndModelIsolation() throws {
        var p = ServerProfile(name: "Fixture", baseURL: "https://api.example.com/v1", model: "known")
        let data = Data(#"{"data":[{"id":"known","context_length":9000,"top_provider":{"max_completion_tokens":1024}},{"id":"unknown","context_length":9000},{"id":"bad","top_provider":{"max_completion_tokens":true}},{"id":"negative","top_provider":{"max_completion_tokens":-1}},{"id":"fraction","top_provider":{"max_completion_tokens":2.5}}]}"#.utf8)
        p.apply(try ModelCatalog.decode(data))
        XCTAssertEqual(p.limits(for: "known").outputLimit, 1024)
        for model in ["unknown", "bad", "negative", "fraction"] { XCTAssertNil(p.limits(for: model).outputLimit) }
        for kind in APIProtocol.allCases {
            p.protocolKind = kind
            p.apply(try ModelCatalog.decode(data))
            for model in ["known", "unknown"] {
                let req = try LocalAPIClient.completionRequest(profile: p, key: "", model: model, messages: [], systemPrompt: "", temperature: 0.7, maxTokens: nil)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
                let field = kind == .responses ? "max_output_tokens" : "max_tokens"
                if model == "known" { XCTAssertEqual(body[field] as? Int, 1024) }
                else { XCTAssertNil(body[field]) }
                XCTAssertNil(body[kind == .responses ? "max_tokens" : "max_output_tokens"])
            }
        }
        XCTAssertEqual(p.effectiveOutput(512, model: "known"), 512)
        XCTAssertEqual(p.effectiveOutput(4096, model: "known"), 1024)
        XCTAssertEqual(p.effectiveOutput(4096, model: "unknown"), 4096)
        p.apply(ModelCatalog(ids: ["known"]))
        XCTAssertNil(p.effectiveOutput(nil, model: "known"))
        XCTAssertNil(ServerProfile.apple.effectiveOutput(nil, model: ServerProfile.appleModel))
    }

    func testLegacyResponseDefaultIsNotDetectedOrSent() throws {
        var data = AppData()
        XCTAssertNil(data.requestedMaxTokens)
        let legacy = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
        XCTAssertNil(legacy.requestedMaxTokens)
        data.maxTokens = 4096
        XCTAssertEqual(data.requestedMaxTokens, 4096)
        data.responseLimitEnabled = false
        XCTAssertNil(data.requestedMaxTokens)
        data.maxTokens = 2048; data.responseLimitEnabled = true
        let restored = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(restored.requestedMaxTokens, 2048)
        var profile = ServerProfile(name: "Fixture", baseURL: "https://api.example.com/v1", model: "m")
        profile.setContextBudget(8192, model: "m")
        let assessment = ContextAssessment.make(profile: profile, model: "m", messages: [], instructions: "", requestedOutput: nil)
        XCTAssertNil(assessment.output)
        XCTAssertTrue(assessment.warning?.contains("réserve de sortie est inconnue") == true)
    }
    func testSingleContextFieldAutomaticManualAndExplicitEmptyPersist() throws {
        var p = ServerProfile(name: "Fixture", baseURL: "https://api.example.com/v1", model: "m")
        XCTAssertNil(p.maximumContext(for: "m"))
        let catalog = try ModelCatalog.decode(Data(#"{"data":[{"id":"m","context_length":8192}]}"#.utf8))
        p.apply(catalog)
        XCTAssertEqual(p.maximumContext(for: "m"), 8192)
        XCTAssertFalse(p.hasManualContext(for: "m"))
        p.setContextBudget(12345, model: "m")
        p.apply(catalog)
        XCTAssertEqual(p.maximumContext(for: "m"), 12345)
        var restored = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(restored.maximumContext(for: "m"), 12345)
        restored.setContextBudget(nil, model: "m")
        restored.apply(catalog)
        restored = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(restored))
        XCTAssertNil(restored.maximumContext(for: "m"))
        XCTAssertTrue(restored.hasManualContext(for: "m"))
        restored.protocolKind = .responses
        XCTAssertNil(restored.maximumContext(for: "m"))
        XCTAssertFalse(restored.hasManualContext(for: "m"))
        XCTAssertNil(p.maximumContext(for: "other"))
        XCTAssertFalse(p.duplicate().hasManualContext(for: "m"))
    }

    func testCapabilitiesRequireExplicitMetadataAndDoNotInventPDFSupport() throws {
        let catalog = try ModelCatalog.decode(Data(#"{"data":[{"id":"vision-128k"},{"id":"image","architecture":{"input_modalities":["text","image"]}},{"id":"text","architecture":{"input_modalities":["text"]}},{"id":"file","architecture":{"input_modalities":["text","file"]}},{"id":"bad","architecture":{"input_modalities":true}},{"id":"conflict","architecture":{"input_modalities":["text"]}},{"id":"conflict","architecture":{"input_modalities":["text","image"]}},{"id":"conflict","architecture":{"input_modalities":["text","image"]}}]}"#.utf8))
        XCTAssertEqual(catalog.capabilities["vision-128k"]?.images, .unknown)
        XCTAssertEqual(catalog.capabilities["image"]?.images, .supported)
        XCTAssertEqual(catalog.capabilities["text"]?.images, .unsupported)
        XCTAssertEqual(catalog.capabilities["bad"]?.images, .unknown)
        XCTAssertEqual(catalog.capabilities["conflict"]?.images, .unknown)
        for id in catalog.ids { XCTAssertEqual(catalog.capabilities[id]?.pdf, .unknown) }
        var p = ServerProfile(name: "Fixture", baseURL: "https://api.example.com/v1", model: "image")
        p.apply(catalog)
        XCTAssertTrue(p.supportsImages("image"))
        XCTAssertFalse(p.supportsImages("text"))
        let restored = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(restored.capabilities(for: "image").images, .supported)
        p.protocolKind = .responses
        XCTAssertEqual(p.capabilities(for: "image").images, .unknown)
        XCTAssertFalse(p.supportsImages("image"))
    }

    func testLegacyImageTransportPreservedWithoutClaimingDiscoveredCapability() throws {
        var p = ServerProfile(name: "Fixture", baseURL: "https://api.example.com/v1", model: "m")
        p.imageCompatibility = [p.visionKey("m"): "supported"]
        p.apply(ModelCatalog(ids: ["m"]))
        XCTAssertEqual(p.capabilities(for: "m").images, .unknown)
        XCTAssertTrue(p.supportsImages("m"))
        p.apply(ModelCatalog(ids: ["m"], capabilities: ["m": ModelCapabilities(images: .unsupported)]))
        XCTAssertFalse(p.supportsImages("m"))
        XCTAssertEqual(p.imageUnavailableReason("m"), "Ce modèle n’accepte pas les images.")
        XCTAssertEqual(ServerProfile.apple.capabilities(for: ServerProfile.appleModel).pdf, .unsupported)
    }


    func testCatalogLimitsAreExplicitAndConservative() throws {
        let bytes = Data(#"{"data":[{"id":"arbitrary-999k","context_length":8192,"max_model_len":4096,"top_provider":{"context_length":6000,"max_completion_tokens":1000}},{"id":"no-limit-128k"}]}"#.utf8)
        let catalog = try ModelCatalog.decode(bytes)
        XCTAssertEqual(catalog.limits["arbitrary-999k"]?.context, 4096)
        XCTAssertEqual(catalog.limits["arbitrary-999k"]?.advertised.first?.source, "models.context_length")
        XCTAssertEqual(catalog.limits["arbitrary-999k"]?.outputLimit, 1000)
        XCTAssertNil(catalog.limits["no-limit-128k"]?.context)
        XCTAssertEqual(catalog.limits["no-limit-128k"]?.summary, "Limite inconnue")
    }
    func testMalformedOptionalMetadataDoesNotBreakModelDiscovery() throws {
        for value in ["true", "-1", "0", "1.5", "100000001", "null", "\"8192\""] {
            let data = Data("{\"data\":[{\"id\":\"m\",\"context_length\":\(value)}]}".utf8)
            let catalog = try ModelCatalog.decode(data)
            XCTAssertEqual(catalog.ids, ["m"]); XCTAssertNil(catalog.limits["m"]?.context)
        }
        XCTAssertThrowsError(try ModelCatalog.decode(Data(#"{"error":"invalid"}"#.utf8)))
        let duplicates = try ModelCatalog.decode(Data(#"{"data":[{"id":"m","context_length":8000},{"id":"m","context_length":4000}]}"#.utf8))
        XCTAssertEqual(duplicates.ids, ["m"]); XCTAssertEqual(duplicates.limits["m"]?.context, 4000)
    }
    func testLimitsAndManualBudgetsMigrateAndRemainScoped() throws {
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Fictif","baseURL":"https://api.example.com/v1","model":"m","allowsHTTP":false}"#.utf8)
        var profile = try JSONDecoder().decode(ServerProfile.self, from: old)
        XCTAssertNil(profile.contextBudget(for: "m")); XCTAssertNil(profile.limits(for: "m").context)
        profile.setContextBudget(6000, model: "m")
        profile.apply(try ModelCatalog.decode(Data(#"{"data":[{"id":"m","context_length":8000}]}"#.utf8)))
        let restored = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored.contextBudget(for: "m"), 6000)
        XCTAssertEqual(restored.limits(for: "m").context, 8000)
        XCTAssertNil(restored.contextBudget(for: "other"))
        XCTAssertNil(restored.duplicate().contextBudget(for: "m"))
        profile.protocolKind = .responses; XCTAssertNil(profile.contextBudget(for: "m"))
        profile.protocolKind = .chatCompletions
        profile.baseURL = "https://other.example.com/v1"; XCTAssertNil(profile.limits(for: "m").context)
        var refreshed = restored; refreshed.apply(ModelCatalog(ids: ["m"]))
        XCTAssertNil(refreshed.limits(for: "m").context)
        XCTAssertEqual(refreshed.contextBudget(for: "m"), 6000)
    }
    func testContextPreflightReservesOutputAndMarginWithoutTruncation() {
        var profile = ServerProfile(name: "Fictif", baseURL: "https://api.example.com/v1", model: "m")
        let messages = [ChatMessage(role: .user, text: "Bonjour 👩🏽‍💻 日本語"), ChatMessage(role: .assistant, text: "Conservé")]
        XCTAssertNil(ContextAssessment.make(profile: profile, model: "m", messages: messages, instructions: "", requestedOutput: 2048).budget)
        profile.setContextBudget(2000, model: "m")
        let assessment = ContextAssessment.make(profile: profile, model: "m", messages: messages, instructions: "Volontaire", requestedOutput: 2048)
        XCTAssertEqual(assessment.output, 2048); XCTAssertEqual(assessment.margin, 128)
        XCTAssertGreaterThan(assessment.estimatedInput, messages.map(\.text).joined().count)
        XCTAssertNotNil(assessment.warning); XCTAssertEqual(messages.count, 2)
        let images = [ChatMessage(role: .user, text: "", images: [ImageAttachment(data: Data([1,2]))])]
        profile.setContextBudget(100000, model: "m")
        let imageCheck = ContextAssessment.make(profile: profile, model: "m", messages: images, instructions: "", requestedOutput: 512)
        XCTAssertEqual(imageCheck.images, 1); XCTAssertTrue(imageCheck.warning?.contains("inconnu") == true)
    }
    func testContextEstimateConvertsBytesToTokens() {
        var profile = ServerProfile(name: "Fictif", baseURL: "https://api.example.com/v1", model: "m")
        profile.setContextBudget(100_000, model: "m")
        // 400 octets ASCII ≈ 100 tokens, plus 16 de structure par message.
        let text = String(repeating: "a", count: 400)
        let assessment = ContextAssessment.make(profile: profile, model: "m",
            messages: [ChatMessage(role: .user, text: text)], instructions: "", requestedOutput: 128)
        XCTAssertEqual(assessment.estimatedInput, 100 + 16)
    }

    func testAppliedOutputCapMatchesBothPayloadsAndAppleAppCap() throws {
        var profile = ServerProfile(name: "Fictif", baseURL: "https://api.example.com/v1", model: "m")
        for kind in APIProtocol.allCases {
            profile.protocolKind = kind
            profile.modelLimits = [profile.visionKey("m"): ModelLimits(output: [TokenLimit(tokens: 64, source: "fixture")])]
            let request = try LocalAPIClient.completionRequest(profile: profile, key: "", model: "m", messages: [ChatMessage(role: .user, text: "Fictif")], systemPrompt: "", temperature: 0.7, maxTokens: 8192)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body[kind == .responses ? "max_output_tokens" : "max_tokens"] as? Int, 64)
        }
        XCTAssertEqual(ServerProfile.apple.effectiveOutput(32768, model: ServerProfile.appleModel), 32768)
        XCTAssertEqual(ServerProfile.apple.effectiveOutput(512, model: ServerProfile.appleModel), 512)
    }

    private func decode(_ input: String) throws -> [String] {
        var parser = SSEDecoder()
        var result: [String] = []
        for byte in input.utf8 { if let event = try parser.feed(byte) { result.append(event) } }
        if let event = try parser.finish() { result.append(event) }
        return result
    }

    func testUTF8AcrossIndividualBytesAndCRLF() throws {
        XCTAssertEqual(try decode(": ping\r\ndata: Héllo 🌿\r\n\r\ndata: [DONE]\r\n\r\n"), ["Héllo 🌿", "[DONE]"])
    }

    func testMultilineAndUnterminatedLastEvent() throws {
        XCTAssertEqual(try decode("event: message\ndata: first\ndata: second\n\ndata: last"), ["first\nsecond", "last"])
        XCTAssertEqual(try decode("data: one\r\rdata: two\r\r"), ["one", "two"])
    }

    func testLimitsBeforeAnyNewline() {
        var parser = SSEDecoder(maxEventBytes: 16)
        XCTAssertThrowsError(try Array(repeating: UInt8(65), count: 17).forEach { _ = try parser.feed($0) })
    }

    func testInvalidUTF8IsRejected() throws {
        var parser = SSEDecoder()
        _ = try parser.feed(255)
        XCTAssertThrowsError(try parser.feed(10))
    }

    @MainActor func testReasoningStreamingPreservesSeparateChannels() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReasoningURLStub.self]
        let profile = ServerProfile(baseURL: "https://example.com/v1", model: "alpha")
        var answer = ""
        var reasoning = ""
        try await LocalAPIClient(controlConfiguration: config).streamWithReasoning(
            profile: profile, key: "", model: "alpha", messages: [], systemPrompt: "", temperature: 0.7,
            maxTokens: 512, onText: { answer = $0 }, onReasoning: { reasoning = $0 }, onUsage: { _ in })
        XCTAssertEqual(reasoning, "Analyse étape 1 et 2")
        XCTAssertEqual(answer, "Réponse finale")
    }

    @MainActor func testLengthFinishPreservesPartialTextReasoningAndUsage() async throws {
        for scenario in ["partial", "reasoning-only"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [OutputLimitURLStub.self]
            config.httpAdditionalHeaders = ["X-Eudes-Fixture": scenario]
            let profile = ServerProfile(baseURL: "https://example.com/v1", model: "alpha")
            var answer = ""
            var reasoning = ""
            var usage: TokenUsage?
            do {
                try await LocalAPIClient(controlConfiguration: config).streamWithReasoning(
                    profile: profile, key: "", model: "alpha", messages: [], systemPrompt: "", temperature: 0.7,
                    maxTokens: 5, onText: { answer = $0 }, onReasoning: { reasoning = $0 }, onUsage: { usage = $0 })
                XCTFail("A length finish must not be treated as a complete answer")
            } catch EudesError.outputLimitReached {
                XCTAssertEqual(answer, scenario == "partial" ? "Texte partiel" : "")
                XCTAssertEqual(reasoning, "Analyse partielle")
                XCTAssertEqual(usage, TokenUsage(input: 2, output: 5))
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testReasoningDeltasStaySeparateFromAnswer() throws {
        let a = try CompletionChunk.parse(#"{"choices":[{"delta":{"reasoning_content":"Étape 1"},"finish_reason":null}]}"#)
        XCTAssertEqual(a.text, "")
        XCTAssertEqual(a.reasoning, "Étape 1")
        let b = try CompletionChunk.parse(#"{"choices":[{"delta":{"reasoning":"Étape 2","content":"Réponse"},"finish_reason":null}]}"#)
        XCTAssertEqual(b.reasoning, "Étape 2")
        XCTAssertEqual(b.text, "Réponse")
        let summary = try ResponsesEvent.parse(#"{"type":"response.reasoning_summary_text.delta","delta":"Résumé"}"#)
        XCTAssertEqual(summary.reasoning, "Résumé")
        XCTAssertEqual(summary.text, "")
    }

    func testReasoningPersistsButIsNotSentAsHistory() throws {
        var message = ChatMessage(role: .assistant, text: "Réponse")
        message.reasoning = "Détail privé"
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.reasoning, "Détail privé")
        let old = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"role":"assistant","text":"Ancien","id":"C89F22D1-AC71-4A4F-8F5A-B3C1A6174574","state":"complete","createdAt":0}"#.utf8))
        XCTAssertNil(old.reasoning)
        let profile = ServerProfile(baseURL: "https://example.com/v1", model: "alpha")
        let request = try LocalAPIClient.completionRequest(profile: profile, key: "", model: "alpha", messages: [restored], systemPrompt: "", temperature: 0.7, maxTokens: nil)
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(decoded["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "Réponse")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("Détail privé"))
    }

    func testChunkSemantics() throws {
        let event = #"{"choices":[{"delta":{"content":"Bonjour"},"finish_reason":null}]}"#
        let parsed = try CompletionChunk.parse(event)
        XCTAssertEqual(parsed.text, "Bonjour")
        XCTAssertFalse(parsed.finished)
        XCTAssertTrue(try CompletionChunk.parse("[DONE]").finished)
        XCTAssertTrue(try CompletionChunk.parse(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#).finished)
        XCTAssertEqual(try CompletionChunk.parse(#"{"choices":[],"usage":{"total_tokens":3}}"#).text, "")
        XCTAssertThrowsError(try CompletionChunk.parse("<html>login</html>"))
        XCTAssertThrowsError(try CompletionChunk.parse(#"{"error":{"message":"private error"}}"#))
    }
}

private final class ReasoningURLStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let events = [
            #"{"choices":[{"delta":{"reasoning_content":"Analyse étape 1"},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"reasoning":" et 2"},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"content":"Réponse finale"},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            "[DONE]"
        ]
        let wire = events.map { "data: " + $0 + "\n\n" }.joined()
        client?.urlProtocol(self, didLoad: Data(wire.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class OutputLimitURLStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let partial = request.value(forHTTPHeaderField: "X-Eudes-Fixture") == "partial"
        var events = [#"{"choices":[{"delta":{"reasoning_content":"Analyse partielle"},"finish_reason":null}]}"#]
        if partial { events.append(#"{"choices":[{"delta":{"content":"Texte partiel"},"finish_reason":null}]}"#) }
        events.append(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#)
        events.append(#"{"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":5}}"#)
        events.append("[DONE]")
        client?.urlProtocol(self, didLoad: Data(events.map { "data: " + $0 + "\n\n" }.joined().utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CountURLStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path == "/v1/messages/count_tokens", request.httpMethod == "POST" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let scenario = request.value(forHTTPHeaderField: "X-Eudes-Fixture") ?? "success"
        let response = HTTPURLResponse(url: request.url!, statusCode: scenario == "missing" ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((scenario == "invalid" ? #"{"input_tokens":true}"# : #"{"input_tokens":17}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ResponsesTests: XCTestCase {
    func testLegacyMigrationAndProtocolVisionIsolation() throws {
        var profile = ServerProfile(name: "fixture", baseURL: "https://example.com/v1", model: "alpha")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json.removeValue(forKey: "apiProtocol")
        profile = try JSONDecoder().decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(profile.protocolKind, .chatCompletions)
        profile.imageCompatibility = [profile.visionKey("alpha"): "supported"]
        profile.protocolKind = .responses
        XCTAssertFalse(profile.supportsImages("alpha"))
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.protocolKind, .responses)
        XCTAssertEqual(decoded.duplicate().protocolKind, .responses)
        XCTAssertNotEqual(decoded.duplicate().id, decoded.id)
    }

    func testResponsesPayloadAndChatCompatibility() throws {
        var p = ServerProfile(name: "fixture", baseURL: "https://example.com/v1", model: "alpha")
        p.protocolKind = .responses
        p.imageCompatibility = [p.visionKey("alpha"): "supported"]
        let messages = [ChatMessage(role: .user, text: "Question", images: [ImageAttachment(data: Data([0xff,0xd8,0xff,0x00]))]), ChatMessage(role: .assistant, text: "Réponse"), ChatMessage(role: .assistant, text: "partiel", state: .interrupted)]
        let request = try LocalAPIClient.completionRequest(profile: p, key: "", model: "alpha", messages: messages, systemPrompt: "Instruction choisie", temperature: 0.7, maxTokens: 2048)
        XCTAssertEqual(request.url?.path, "/v1/responses")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["truncation"] as? String, "disabled")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2048)
        XCTAssertEqual(body["instructions"] as? String, "Instruction choisie")
        XCTAssertNil(body["messages"]); XCTAssertNil(body["max_tokens"]); XCTAssertNil(body["previous_response_id"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[1]["type"] as? String, "input_image")
        XCTAssertTrue((content[1]["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        p.protocolKind = .chatCompletions
        let chat = try LocalAPIClient.completionRequest(profile: p, key: "", model: "alpha", messages: [], systemPrompt: " ", temperature: 0.7, maxTokens: 2048)
        let chatBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(chat.httpBody)) as? [String: Any])
        XCTAssertEqual(chat.url?.path, "/v1/chat/completions"); XCTAssertEqual(chatBody["max_tokens"] as? Int, 2048)
        XCTAssertNil(chatBody["input"])
    }

    func testResponsesEventsAndTerminalStates() throws {
        XCTAssertEqual(try ResponsesEvent.parse(#"{"type":"response.output_text.delta","delta":"Hé 🌿"}"#).text, "Hé 🌿")
        XCTAssertEqual(try ResponsesEvent.parse(#"{"type":"response.output_text.done","text":"Hé 🌿"}"#).text, "")
        XCTAssertEqual(try ResponsesEvent.parse(#"{"type":"response.refusal.delta","delta":"Refus"}"#).text, "Refus")
        XCTAssertTrue(try ResponsesEvent.parse(#"{"type":"response.completed","response":{"status":"completed"}}"#).finished)
        for event in [#"{"type":"response.failed"}"#, #"{"type":"response.incomplete"}"#, #"{"type":"error","message":"private"}"#, #"{"type":"response.output_text.delta"}"#, "[DONE]", #"{"type":"response.completed","response":{"status":"failed"}}"#, #"{"type":"response.output_item.added","item":{"type":"function_call"}}"#] {
            XCTAssertThrowsError(try ResponsesEvent.parse(event))
        }
    }

    @MainActor func testResponsesCancellation() async throws {
        var p = ServerProfile(baseURL: "https://example.com/v1", model: "alpha"); p.protocolKind = .responses
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResponsesURLStub.self]
        config.httpAdditionalHeaders = ["X-Eudes-Fixture": "hang"]
        let task = Task { try await LocalAPIClient(controlConfiguration: config).stream(profile: p, key: "", model: "alpha", messages: [], systemPrompt: "", temperature: 0.7, maxTokens: 512) { _ in } }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        do { try await task.value; XCTFail("Cancelled stream must not complete") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }

    func testResponsesEmptyInstructionsAndAddressProtection() throws {
        var p = ServerProfile(baseURL: "https://example.com/custom/v1", model: "alpha"); p.protocolKind = .responses
        let r = try LocalAPIClient.completionRequest(profile: p, key: "", model: "alpha", messages: [], systemPrompt: " ", temperature: 1, maxTokens: 512)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
        XCTAssertNil(body["instructions"]); XCTAssertEqual(r.url?.path, "/custom/v1/responses")
        p.baseURL = "http://example.com/v1"
        XCTAssertThrowsError(try LocalAPIClient.completionRequest(profile: p, key: "", model: "alpha", messages: [], systemPrompt: "", temperature: 1, maxTokens: 512))
    }

    @MainActor func testResponsesStreamingTransportAndPartialFailure() async throws {
        for scenario in ["success", "incomplete", "failed", "truncated", "auth"] {
            var p = ServerProfile(baseURL: "https://example.com/v1", model: "alpha"); p.protocolKind = .responses
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResponsesURLStub.self]
            config.httpAdditionalHeaders = ["X-Eudes-Fixture": scenario]
            let client = LocalAPIClient(controlConfiguration: config)
            var text = ""
            do {
                try await client.stream(profile: p, key: "", model: "alpha", messages: [ChatMessage(role: .user, text: "fixture")], systemPrompt: "", temperature: 0.7, maxTokens: 512) { text = $0 }
                XCTAssertEqual(scenario, "success")
            } catch { XCTAssertNotEqual(scenario, "success") }
            XCTAssertEqual(text, scenario == "auth" ? "" : "Bonjour 🌿")
        }
    }
    func testThinkingManualFormatsAndOpenRouterDiscovery() throws {
        func body(_ profile: ServerProfile, _ model: String) throws -> [String: Any] {
            let request = try LocalAPIClient.completionRequest(profile: profile, key: "", model: model,
                messages: [], systemPrompt: "", temperature: 0.7, maxTokens: nil)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }
        let model = "example/model"
        var profile = ServerProfile(baseURL: "https://example.com/v1", model: model)
        XCTAssertEqual(profile.thinkingOptions(for: model), [.automatic])
        XCTAssertNil(try body(profile, model)["reasoning_effort"])
        profile.setThinkingFormat(.reasoningEffort, for: model)
        profile.setThinkingMode(.low, for: model)
        XCTAssertEqual(try body(profile, model)["reasoning_effort"] as? String, "low")
        XCTAssertNil(try body(profile, "example/other")["reasoning_effort"])
        profile.setThinkingFormat(.enableThinking, for: model)
        XCTAssertEqual(profile.thinkingMode(for: model), .automatic)
        profile.setThinkingMode(.enabled, for: model)
        XCTAssertEqual((try body(profile, model)["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], true)
        var responses = profile
        responses.protocolKind = .responses
        XCTAssertNil(try body(responses, model)["chat_template_kwargs"])
        responses.setThinkingFormat(.responsesReasoning, for: model)
        responses.setThinkingMode(.medium, for: model)
        XCTAssertEqual((try body(responses, model)["reasoning"] as? [String: String])?["effort"], "medium")
        let restored = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(responses))
        XCTAssertEqual(restored.thinkingMode(for: model), .medium)
        XCTAssertEqual(restored.duplicate().thinkingFormat(for: model), .responsesReasoning)

        let json = #"{"data":[{"id":"example/model","supported_parameters":["reasoning"],"reasoning":{"supported_efforts":["none","low","high"],"mandatory":true}}]}"#
        let catalog = try ModelCatalog.decode(Data(json.utf8))
        var router = ServerProfile(baseURL: "https://openrouter.ai/api/v1", model: model)
        router.apply(catalog)
        XCTAssertTrue(router.hasAdvertisedReasoning(for: model))
        XCTAssertTrue(router.hasDetectedThinkingLevels(for: model))
        XCTAssertEqual(router.thinkingOptions(for: model), [.automatic, .low, .high])
        XCTAssertNil(try body(router, model)["reasoning"])
        router.setThinkingMode(.high, for: model)
        let routed = try body(router, model)
        XCTAssertEqual((routed["reasoning"] as? [String: String])?["effort"], "high")
        XCTAssertEqual((routed["provider"] as? [String: Bool])?["require_parameters"], true)
        var otherHost = router
        otherHost.baseURL = "https://example.com/v1"
        XCTAssertFalse(otherHost.hasDetectedThinkingLevels(for: model))
        XCTAssertNil(try body(otherHost, model)["reasoning"])
        let invalid = #"{"data":[{"id":"example/model","reasoning":{"supported_efforts":["invented"]}}]}"#
        router.apply(try ModelCatalog.decode(Data(invalid.utf8)))
        XCTAssertFalse(router.hasDetectedThinkingLevels(for: model))
        XCTAssertEqual(router.thinkingMode(for: model), .automatic)
    }

    func testNVIDIAThinkingOptionsPersistAndEncodeOnlyForDocumentedModels() throws {
        let bolt = "nvidia/nemotron-3.5-bolt-e4b"
        let flash = "deepseek-ai/deepseek-v4-flash"
        let pro = "deepseek-ai/deepseek-v4-pro"
        var profile = ServerProfile(baseURL: "https://integrate.api.nvidia.com/v1", model: bolt)
        func body(_ p: ServerProfile, _ model: String) throws -> [String: Any] {
            let request = try LocalAPIClient.completionRequest(profile: p, key: "", model: model,
                messages: [], systemPrompt: "", temperature: 0.7, maxTokens: nil)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }
        XCTAssertNil(try body(profile, bolt)["chat_template_kwargs"])
        XCTAssertNil(try body(profile, flash)["reasoning_effort"])
        profile.setThinkingMode(.enabled, for: bolt)
        XCTAssertEqual((try body(profile, bolt)["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], true)
        profile.setThinkingMode(.disabled, for: bolt)
        XCTAssertEqual((try body(profile, bolt)["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        for (mode, wire) in [(ThinkingMode.disabled, "none"), (.high, "high"), (.maximum, "max")] {
            profile.setThinkingMode(mode, for: flash)
            XCTAssertEqual(try body(profile, flash)["reasoning_effort"] as? String, wire)
            profile.setThinkingMode(mode, for: pro)
            XCTAssertEqual(try body(profile, pro)["reasoning_effort"] as? String, wire)
        }
        XCTAssertNil(try body(profile, "deepseek-ai/deepseek-v4.1-flash")["reasoning_effort"])
        let restored = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored.thinkingMode(for: bolt), .disabled)
        XCTAssertEqual(restored.thinkingMode(for: flash), .maximum)
        XCTAssertEqual(restored.duplicate().thinkingMode(for: flash), .maximum)
        var differentHost = restored
        differentHost.baseURL = "https://example.com/v1"
        XCTAssertNil(try body(differentHost, bolt)["chat_template_kwargs"])
        XCTAssertNil(try body(differentHost, flash)["reasoning_effort"])
        var responses = restored
        responses.protocolKind = .responses
        XCTAssertNil(try body(responses, flash)["reasoning_effort"])
        XCTAssertNil(try body(responses, flash)["reasoning"])
        profile.setThinkingMode(.automatic, for: flash)
        XCTAssertNil(try body(profile, flash)["reasoning_effort"])
    }

}

private final class ResponsesURLStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path == "/v1/responses", request.httpMethod == "POST" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let scenario = request.value(forHTTPHeaderField: "X-Eudes-Fixture") ?? "success"
        if scenario == "hang" { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: scenario == "auth" ? 401 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let delta = #"{"type":"response.output_text.delta","delta":"Bonjour 🌿"}"#
        let end = scenario == "success" ? #"{"type":"response.completed","response":{"status":"completed"}}"# : "{\"type\":\"response.\(scenario)\"}"
        let wire = "event: response.output_text.delta\r\ndata: \(delta)\r\n\r\n" + (scenario == "truncated" ? "" : "data: \(end)\n\n")
        for byte in wire.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
