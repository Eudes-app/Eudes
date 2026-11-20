import XCTest
import FoundationModels
@testable import Eudes

@MainActor
final class AppleWebResearchTests: XCTestCase {
    private var traces: [WebResearchTrace] = []
    private let history = [ChatMessage(role: .user, text: "Compare les trains de nuit à moins de 100 euros"),
                           ChatMessage(role: .assistant, text: "Dans quel pays ?"),
                           ChatMessage(role: .user, text: "Et en France ?")]

    private func run(_ session: any AppleWebResearchSession, search: any WebSearching = AppleSearchFixture(),
                     reader: any WebPageReading = AppleReaderFixture(), budget: Int = 5,
                     messages: [ChatMessage]? = nil,
                     profile: ServerProfile = .apple) async throws -> WebSearchContext? {
        try await HybridWebResearch(search: search, modelClient: ForbiddenRemotePlanner(), pageReader: reader,
                                    appleSession: session)
            .prepare(profile: profile, key: "never-forward-this-key", model: ServerProfile.appleModel,
                     messages: messages ?? history, systemPrompt: "Réponds en français", temperature: 0.4,
                     maxTokens: 512, maximumToolCalls: budget, onTrace: { self.traces.append($0) })
    }

    func testAppleChoosesSearchAndFetchWithFullHistoryAndNativeTrace() async throws {
        let session = AppleSessionFixture(calls: [searchCall("train de nuit France moins de 100 euros"), fetchCall(1)])
        let search = AppleSearchFixture()
        let reader = AppleReaderFixture()
        let context = try await run(session, search: search, reader: reader)
        let received = await session.messages
        let instructions = await session.instructions
        let outputs = await session.outputs
        let queries = await search.queries
        let reads = await reader.sources
        XCTAssertEqual(received, history)
        XCTAssertTrue(instructions.contains("Réponds en français"))
        XCTAssertTrue(instructions.contains(AppleWebResearch.instructions))
        XCTAssertEqual(queries, ["train de nuit France moins de 100 euros"])
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(context?.sources.first?.kind, .page)
        XCTAssertTrue(outputs.first?.contains("BEGIN_UNTRUSTED_WEB_DATA_JSON") == true)
        XCTAssertTrue(outputs.last?.contains("Contenu lu") == true)
        XCTAssertEqual(traces.last?.calls.map(\.origin), [.model, .model])
        XCTAssertEqual(traces.last?.calls.map(\.state), [.succeeded, .succeeded])
        XCTAssertEqual(traces.last?.state, .completed)
        XCTAssertEqual(traces.last?.toolsOffered, true)
        XCTAssertNil(traces.last?.fallbackReason)
    }

    func testSmallAppleContextCanStartNativePlanning() async throws {
        var profile = ServerProfile.apple
        profile.setContextBudget(4_096, model: ServerProfile.appleModel)
        let session = AppleSessionFixture(calls: [])
        _ = try await HybridWebResearch(search: AppleSearchFixture(), modelClient: ForbiddenRemotePlanner(),
                                        appleSession: session)
            .prepare(profile: profile, key: "", model: ServerProfile.appleModel,
                     messages: history, systemPrompt: "Réponds en français", temperature: 0.4, maxTokens: 512)
        let received = await session.messages
        XCTAssertEqual(received, history, "Tool schemas and instructions must not preemptively fill Apple's context")
    }

    func testSharedBudgetStopsBeforeExtraNetworkCall() async throws {
        let search = AppleSearchFixture()
        let reader = AppleReaderFixture()
        let context = try await run(AppleSessionFixture(calls: [searchCall("France"), fetchCall(1), searchCall("Europe")]),
                                    search: search, reader: reader, budget: 2)
        let queries = await search.queries
        XCTAssertEqual(queries, ["France"])
        XCTAssertEqual(context?.sources.first?.kind, .page)
        XCTAssertEqual(traces.last?.calls.count, 2)
        XCTAssertEqual(traces.last?.maximumToolCalls, 2)
        XCTAssertEqual(traces.last?.budgetExhausted, true)
    }

    func testParallelNativeCallsShareBudgetWithoutDiscardingAcceptedEvidence() async throws {
        let search = AppleSearchFixture()
        let executor = AppleWebToolExecution(search: search, pageReader: AppleReaderFixture(), budget: 1, byteBudget: nil, onTrace: { _ in })
        await withTaskGroup(of: Void.self) { group in
            for call in [searchCall("France"), searchCall("Europe"), fetchCall(1)] {
                group.addTask { _ = try? await executor.execute(call) }
            }
        }
        let queries = await search.queries
        XCTAssertLessThanOrEqual(queries.count, 1)
        let count = await executor.callCount
        XCTAssertEqual(count, 1)
        // Test the accepted search deterministically as well as concurrent reservation.
        let executor2 = AppleWebToolExecution(search: search, pageReader: AppleReaderFixture(), budget: 1, byteBudget: nil, onTrace: { _ in })
        _ = try await executor2.execute(searchCall("accepted"))
        do { _ = try await executor2.execute(fetchCall(1)); XCTFail("Expected hard budget stop") }
        catch AppleWebToolExecution.Limit.reached { }
        let result = try await executor2.finish()
        XCTAssertNotNil(result)
    }

    func testInvalidAndDuplicateCallsConsumeBudgetWithoutRepeatingNetwork() async throws {
        let search = AppleSearchFixture()
        let reader = AppleReaderFixture()
        _ = try await run(AppleSessionFixture(calls: [fetchCall(1), searchCall("France"), searchCall("France"),
            fetchCall(1), fetchCall(1), .init(id: "bad", name: "web_fetch", arguments: #"{"source":true}"#)]),
            search: search, reader: reader, budget: 6)
        let queries = await search.queries
        let reads = await reader.sources
        XCTAssertEqual(queries, ["France"])
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(traces.last?.calls.map(\.state), [.rejected, .succeeded, .rejected, .succeeded, .rejected, .rejected])
    }

    func testNoToolsForGreetingDoesNotForceSearch() async throws {
        let search = AppleSearchFixture()
        let context = try await run(AppleSessionFixture(calls: []), search: search,
                                    messages: [ChatMessage(role: .user, text: "Bonjour")])
        let queries = await search.queries
        XCTAssertNil(context)
        XCTAssertTrue(queries.isEmpty)
        XCTAssertEqual(traces.last?.calls, [])
    }

    func testExplicitSearchFallsBackWhenModelDeclinesTools() async throws {
        let context = try await run(AppleSessionFixture(calls: []),
            messages: [ChatMessage(role: .user, text: "Recherche sur le web les trains de nuit")])
        XCTAssertNotNil(context)
        XCTAssertEqual(traces.last?.fallbackReason, .explicitRequest)
        XCTAssertEqual(traces.last?.calls.map(\.origin), [.eudes])
    }

    func testReadFailureKeepsSnippetAndAccurateTrace() async throws {
        let context = try await run(AppleSessionFixture(calls: [searchCall("France"), fetchCall(1)]),
                                    reader: AppleReaderFixture(failure: .blocked))
        XCTAssertEqual(context?.sources.first?.kind, .searchSnippet)
        XCTAssertEqual(traces.last?.calls.map(\.state), [.succeeded, .failed])
    }

    func testFailedSearchDoesNotInventEvidence() async throws {
        do {
            _ = try await run(AppleSessionFixture(calls: [searchCall("France")]), search: AppleSearchFixture(failure: .blocked))
            XCTFail("Expected search failure")
        } catch { XCTAssertEqual(error as? WebSearchError, .blocked) }
        XCTAssertEqual(traces.last?.state, .failed)
        XCTAssertEqual(traces.last?.calls.first?.state, .failed)
    }

    func testUnavailableAppleDoesNotSilentlySearchOrUseRemoteModel() async throws {
        let search = AppleSearchFixture()
        do {
            _ = try await run(AppleSessionFixture(calls: [], error: AppleModelError.unavailable(.disabled)), search: search)
            XCTFail("Expected availability error")
        } catch AppleModelError.unavailable(.disabled) { }
        let queries = await search.queries
        XCTAssertTrue(queries.isEmpty)
        XCTAssertEqual(traces.last?.state, .failed)
        XCTAssertEqual(traces.last?.toolsOffered, false)
    }

    func testContextLimitPreservesCollectedSourcesButDoesNotHideEmptyFailure() async throws {
        let context = try await run(AppleSessionFixture(calls: [searchCall("France")], error: AppleModelError.context))
        XCTAssertNotNil(context)
        XCTAssertEqual(traces.last?.contextLimitReached, true)
        do {
            _ = try await run(AppleSessionFixture(calls: [], error: AppleModelError.context))
            XCTFail("Expected context error")
        } catch AppleModelError.context { }
        XCTAssertEqual(traces.last?.state, .failed)
    }

    func testCancellationDuringSearchIsNotConvertedToFallback() async throws {
        let search = AppleSearchFixture(suspend: true)
        let task = Task { try await self.run(AppleSessionFixture(calls: [searchCall("France")]), search: search) }
        while !(await search.started) { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(traces.last?.state, .cancelled)
        XCTAssertEqual(traces.last?.calls.first?.state, .cancelled)
    }

    func testChatAndVoiceSettingsRouteAppleEvidenceToSynthesis() async throws {
        for voice in [false, true] {
            for enabled in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let suite = "AppleToolsIntegration." + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
                let session = AppleSessionFixture(calls: [searchCall("trains France")])
                let synthesis = AppleSynthesisFixture()
                let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenRemoteSynthesis(),
                    webSearch: AppleSearchFixture(), webResearchModel: ForbiddenRemotePlanner(),
                    appleWebResearchSession: session, appleClient: synthesis, appleAvailability: { .available },
                    appleContextLimits: { ModelLimits() }, readKey: { _ in XCTFail("Apple needs no credential"); return "" },
                    applicationIsActive: { false }, protectedDataAvailable: { true })
                store.saveSettings(prompt: "", temperature: 0.4, maxTokens: 512)
                store.selectServer(ServerProfile.appleID)
                store.webSearchEnabled = enabled
                store.setVoiceWebSearchMode(enabled ? .always : .disabled)
                if voice { _ = try await store.answerShortcut("Compare les trains en France") }
                else {
                    let sent = await store.sendChecked("Compare les trains en France")
                    XCTAssertTrue(sent)
                    for _ in 0..<2_000 {
                        if store.current?.messages.last?.state == .complete { break }
                        await Task.yield()
                    }
                }
                let reply = try XCTUnwrap(store.current?.messages.last)
                XCTAssertEqual(reply.state, .complete)
                XCTAssertEqual(reply.text, "Réponse locale")
                XCTAssertEqual(reply.webContext != nil, enabled)
                XCTAssertEqual(reply.webResearchTrace?.calls.first?.origin, enabled ? .model : nil)
                let received = synthesis.messages
                XCTAssertEqual(received.last?.text.contains("BEGIN_UNTRUSTED_WEB_DATA_JSON"), enabled)
                let planned = await session.messages
                XCTAssertEqual(planned.isEmpty, !enabled)
            }
        }
    }

    func testSiriVoiceUsesAppleToolsAndPersistsEvidence() async throws {
        var values: [String: Data] = [:]
        let persistence = SiriAssistantPersistence(read: { values[$0] }, write: { values[$0] = $1 },
                                                   delete: { values.removeValue(forKey: $0) })
        let synthesis = AppleSynthesisFixture()
        let session = AppleSessionFixture(calls: [searchCall("trains France")])
        let service = SiriAssistantService(persistence: persistence, client: synthesis,
            webSearch: AppleSearchFixture(), webResearchModel: ForbiddenRemotePlanner(),
            appleWebResearchSession: session, voiceWebSearchMode: { .always })
        try service.configure(profile: .apple, model: ServerProfile.appleModel, key: "", maxTokens: 512)
        let id = try service.beginVoiceConversation()
        defer { service.endVoiceConversation(id) }
        let answer = try await service.answerVoice("Compare les trains en France", conversationID: id)
        XCTAssertEqual(answer, "Réponse locale")
        let conversation = try XCTUnwrap(service.pendingConversations().first)
        XCTAssertEqual(conversation.messages.last?.webResearchTrace?.calls.first?.origin, .model)
        XCTAssertEqual(conversation.messages.last?.webContext?.sources.count, 1)
        let received = synthesis.messages
        XCTAssertTrue(received.last?.text.contains("BEGIN_UNTRUSTED_WEB_DATA_JSON") == true)
    }

    func testFoundationModelsWrappedErrorsPreserveBudgetAndCancellation() throws {
        guard #available(iOS 26.0, *) else { return }
        let tool = AppleWebSearchTool { _ in "" }
        let limit = LanguageModelSession.ToolCallError(tool: tool, underlyingError: AppleWebToolExecution.Limit.reached)
        XCTAssertTrue(NativeAppleWebResearchSession.mappedError(limit) is AppleWebToolExecution.Limit)
        let cancelled = LanguageModelSession.ToolCallError(tool: tool, underlyingError: CancellationError())
        XCTAssertTrue(NativeAppleWebResearchSession.mappedError(cancelled) is CancellationError)
        let context = LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "fixture"))
        guard case AppleModelError.context = NativeAppleWebResearchSession.mappedError(context) else {
            return XCTFail("Context exhaustion must retain collected evidence")
        }
    }

    func testSearchAndFetchOutputsCarryOnlyTheirDelta() async throws {
        let session = AppleSessionFixture(calls: [searchCall("France"), fetchCall(1), fetchCall(2)])
        _ = try await run(session, search: AppleMultiSearchFixture(), reader: AppleNumberedReaderFixture(), budget: 4)
        let outputs = await session.outputs
        XCTAssertTrue(outputs[0].contains("https://example.org/un"))
        XCTAssertTrue(outputs[0].contains("https://example.org/deux"))
        // A page read repeats only its own page, never the rest of the table.
        XCTAssertTrue(outputs[1].contains("Page un"))
        XCTAssertTrue(outputs[1].contains("https://example.org/un"))
        XCTAssertFalse(outputs[1].contains("https://example.org/deux"))
        XCTAssertFalse(outputs[2].contains("Page un"))
    }

    func testToolResultsStopWhenTheByteBudgetIsSpent() async throws {
        let executor = AppleWebToolExecution(search: AppleMultiSearchFixture(), pageReader: AppleReaderFixture(),
                                             budget: 5, byteBudget: 2_500, onTrace: { _ in })
        _ = try await executor.execute(searchCall("France"))
        do { _ = try await executor.execute(fetchCall(1)); XCTFail("Expected byte-budget stop") }
        catch AppleWebToolExecution.Limit.reached { }
        let result = try await executor.finish()
        XCTAssertEqual(result?.sources.count, 2)
    }

    func testUnidentifiedNativeFailureKeepsCollectedEvidence() async throws {
        let session = AppleSessionFixture(calls: [searchCall("France")], error: AppleModelError.failed)
        let context = try await run(session)
        XCTAssertEqual(context?.sources.count, 1)
        XCTAssertEqual(traces.last?.toolLoopInterrupted, true)
        XCTAssertEqual(traces.last?.state, .completed)
    }

    func testUnidentifiedNativeFailureWithoutEvidenceStillFails() async throws {
        let session = AppleSessionFixture(calls: [], error: AppleModelError.failed)
        do { _ = try await run(session); XCTFail("Expected failure without evidence") }
        catch AppleModelError.failed { }
        XCTAssertEqual(traces.last?.state, .failed)
    }

    func testRetryDetailIsReportedOnTheSearchCall() async throws {
        let session = AppleSessionFixture(calls: [searchCall("France")])
        _ = try await run(session, search: AppleRetriedSearchFixture())
        XCTAssertEqual(traces.last?.calls.first?.detail, "Nouvel essai réussi après un échec de connexion sécurisée.")
    }

    func testNativeToolArgumentsAreTypedAndEscaped() async throws {
        guard #available(iOS 26.0, *) else { return }
        let recorder = AppleCallRecorder()
        let search = AppleWebSearchTool { await recorder.append($0); return "search" }
        let fetch = AppleWebFetchTool { await recorder.append($0); return "fetch" }
        let query = "France \"train\"\nprix"
        _ = try await search.call(arguments: .init(query: query))
        _ = try await fetch.call(arguments: .init(source: 2))
        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.name), ["web_search", "web_fetch"])
        let object = try JSONDecoder().decode([String: String].self, from: Data(calls[0].arguments.utf8))
        XCTAssertEqual(object["query"], query)
        XCTAssertEqual(HybridWebResearch.sourceNumber(calls[1].arguments), 2)
        XCTAssertEqual(ServerProfile.apple.capabilities(for: ServerProfile.appleModel).tools, true)
    }

    func testEvidenceBudgetLeavesThreeQuartersOfASmallWindowToTheAnswer() {
        var apple = ServerProfile.apple
        // Apple Intelligence fixe lui-même sa fenêtre : elle vient des métadonnées du système,
        // pas d'un budget manuel (qu'Eudes n'expose plus pour Apple).
        apple.modelLimits = [apple.visionKey(ServerProfile.appleModel):
            ModelLimits(advertised: [TokenLimit(tokens: 4_096, source: "fixture")])]
        XCTAssertEqual(AppleWebResearch.evidenceByteBudget(profile: apple, model: ServerProfile.appleModel,
                                                           messages: history, instructions: "Consignes.",
                                                           maxTokens: 512), 4_096)
        // An unknown window must not silently shorten evidence.
        XCTAssertNil(AppleWebResearch.evidenceByteBudget(profile: .apple, model: ServerProfile.appleModel,
                                                         messages: history, instructions: "Consignes.",
                                                         maxTokens: 512))
    }

    func testSearchKeepsFourResultsInsideTheAppleAllowance() async throws {
        var apple = ServerProfile.apple
        // Apple Intelligence fixe lui-même sa fenêtre : elle vient des métadonnées du système,
        // pas d'un budget manuel (qu'Eudes n'expose plus pour Apple).
        apple.modelLimits = [apple.visionKey(ServerProfile.appleModel):
            ModelLimits(advertised: [TokenLimit(tokens: 4_096, source: "fixture")])]
        let session = AppleSessionFixture(calls: [searchCall("météo Strasbourg")])
        let context = try await run(session, search: AppleWideSearchFixture(), profile: apple)
        let sources = try XCTUnwrap(context?.sources)
        XCTAssertEqual(sources.map(\.url.lastPathComponent), ["1", "2", "3", "4"])
        let evidence = sources.reduce(0) { $0 + $1.excerpt.utf8.count }
        XCTAssertLessThanOrEqual(evidence, 2_800)
        XCTAssertGreaterThan(evidence, 1_000)
        // What the native session actually receives for this search, preamble included.
        let outputs = await session.outputs
        XCTAssertLessThanOrEqual(try XCTUnwrap(outputs.first).utf8.count, 4_300)
    }

    func testAFetchedPageStaysWithinItsOwnAllowance() async throws {
        let executor = AppleWebToolExecution(search: AppleMultiSearchFixture(),
                                             pageReader: AppleLongPageReaderFixture(), budget: 4,
                                             byteBudget: 16_000, onTrace: { _ in })
        _ = try await executor.execute(searchCall("météo"))
        _ = try await executor.execute(fetchCall(1))
        let result = try await executor.finish()
        let page = try XCTUnwrap(result?.sources.first { $0.kind == .page })
        XCTAssertLessThanOrEqual(page.excerpt.utf8.count, AppleWebToolExecution.maximumPageBytes)
        XCTAssertGreaterThan(page.excerpt.utf8.count, 1_000)
    }
}

private actor AppleSessionFixture: AppleWebResearchSession {
    let calls: [WebToolCall]
    let error: Error?
    var messages: [ChatMessage] = []
    var instructions = ""
    var outputs: [String] = []
    init(calls: [WebToolCall], error: Error? = nil) { self.calls = calls; self.error = error }
    func run(messages: [ChatMessage], instructions: String, temperature: Double, maxTokens: Int?,
             onToolsOffered: @escaping @Sendable () async -> Void,
             execute: @escaping @Sendable (WebToolCall) async throws -> String) async throws {
        self.messages = messages
        self.instructions = instructions
        if let appleError = error as? AppleModelError, case .unavailable = appleError { throw appleError }
        await onToolsOffered()
        for call in calls { outputs.append(try await execute(call)) }
        if let error { throw error }
    }
}

private actor AppleSearchFixture: WebSearching {
    var queries: [String] = []
    var started = false
    let failure: WebSearchError?
    let suspend: Bool
    init(failure: WebSearchError? = nil, suspend: Bool = false) { self.failure = failure; self.suspend = suspend }
    func search(query: String) async throws -> WebSearchContext {
        queries.append(query)
        started = true
        if suspend { try await Task.sleep(nanoseconds: 60_000_000_000) }
        if let failure { throw failure }
        return WebSearchContext(query: query, fetchedAt: Date(), sources: [WebSource(
            url: URL(string: "https://example.org/train")!, title: "Train", excerpt: "Extrait", kind: .searchSnippet)])
    }
}

private struct AppleMultiSearchFixture: WebSearching {
    func search(query: String) async throws -> WebSearchContext {
        WebSearchContext(query: query, fetchedAt: Date(), sources: [
            WebSource(url: URL(string: "https://example.org/un")!, title: "Un", excerpt: "Extrait un", kind: .searchSnippet),
            WebSource(url: URL(string: "https://example.org/deux")!, title: "Deux", excerpt: "Extrait deux", kind: .searchSnippet)])
    }
}

/// Six verbose results: the executor must keep the first four and shorten them.
private struct AppleWideSearchFixture: WebSearching {
    func search(query: String) async throws -> WebSearchContext {
        WebSearchContext(query: query, fetchedAt: Date(), sources: (1...6).map { index in
            WebSource(url: URL(string: "https://example.org/\(index)")!, title: "Source \(index)",
                      excerpt: String(repeating: "Éclaircies puis averses en soirée. ", count: 50),
                      kind: .searchSnippet)
        })
    }
}

private struct AppleLongPageReaderFixture: WebPageReading {
    func read(source: WebSource) async throws -> WebSource {
        var page = source
        page.kind = .page
        page.excerpt = String(repeating: "Contenu de la page. ", count: 400)
        return page
    }
}

private struct AppleRetriedSearchFixture: WebSearching {
    func search(query: String) async throws -> WebSearchContext {
        WebSearchContext(query: query, fetchedAt: Date(), sources: [WebSource(
            url: URL(string: "https://example.org/retry")!, title: "Retry", excerpt: "Extrait", kind: .searchSnippet)],
            retried: true)
    }
}

private struct AppleNumberedReaderFixture: WebPageReading {
    func read(source: WebSource) async throws -> WebSource {
        var page = source
        page.kind = .page
        page.excerpt = "Page " + source.url.lastPathComponent
        return page
    }
}

private actor AppleReaderFixture: WebPageReading {
    var sources: [WebSource] = []
    let failure: WebSearchError?
    init(failure: WebSearchError? = nil) { self.failure = failure }
    func read(source: WebSource) async throws -> WebSource {
        sources.append(source)
        if let failure { throw failure }
        var page = source
        page.kind = .page
        page.excerpt = "Contenu lu"
        return page
    }
}

private struct ForbiddenRemotePlanner: WebResearchModelClient {
    func turn(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
              temperature: Double, maxTokens: Int?, exchanges: [WebToolExchange]) async throws -> WebResearchTurn {
        XCTFail("Apple must never use the remote planner")
        throw EudesError.invalidResponse
    }
}
private actor AppleCallRecorder {
    var calls: [WebToolCall] = []
    func append(_ call: WebToolCall) { calls.append(call) }
}
private func searchCall(_ query: String) -> WebToolCall {
    let data = try! JSONEncoder().encode(["query": query])
    return WebToolCall(id: UUID().uuidString, name: "web_search", arguments: String(decoding: data, as: UTF8.self))
}
private func fetchCall(_ source: Int) -> WebToolCall {
    WebToolCall(id: UUID().uuidString, name: "web_fetch", arguments: "{\"source\":\(source)}")
}

private final class AppleSynthesisFixture: EudesAPIClient {
    @MainActor var messages: [ChatMessage] = []
    func models(profile: ServerProfile, key: String) async throws -> [String] { [ServerProfile.appleModel] }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        XCTAssertTrue(profile.isApple)
        XCTAssertTrue(key.isEmpty)
        await record(messages)
        await onText("Réponse locale")
    }
    @MainActor private func record(_ messages: [ChatMessage]) { self.messages = messages }
}
private struct ForbiddenRemoteSynthesis: EudesAPIClient {
    func models(profile: ServerProfile, key: String) async throws -> [String] {
        XCTFail("Apple must not request remote models"); throw EudesError.invalidResponse
    }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        XCTFail("Apple must not use remote synthesis"); throw EudesError.invalidResponse
    }
}
