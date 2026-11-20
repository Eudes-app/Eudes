import XCTest
@testable import Eudes

@MainActor
final class HybridWebResearchTests: XCTestCase {
    private let profile = ServerProfile(name: "Research fixture", baseURL: "https://example.invalid/v1", model: "alpha")

    // Keep message IDs and timestamps stable throughout a test: full-value
    // comparisons verify the same history reaches planning and synthesis.
    private let conversation: [ChatMessage] =
        [ChatMessage(role: .user, text: "Je compare les trains de nuit européens, en restant sous 100 euros."),
         ChatMessage(role: .assistant, text: "Nous pouvons comparer les lignes et les tarifs."),
         ChatMessage(role: .user, text: "Et en France ?")]

    func testLocalWebResearchDoesNotRejectByteEstimateAsExactTokens() throws {
        let messages = [ChatMessage(role: .user, text: String(repeating: "bonjour ", count: 700))]
        XCTAssertNoThrow(try HybridWebResearch.validateContext(profile: .lfmText,
            model: LocalModelCatalog.text.id, messages: messages, instructions: "", maxTokens: 128,
            additionalBytes: 2048))
    }

    func testLFMUsesLocalPlannerAndSearchToolsWithoutCallingRemotePlanner() async throws {
        let local = HybridPlannerFixture(turns: [
            .success(.init(calls: [searchCall("s1", "trains France")])),
            .success(.init(calls: []))
        ])
        let remote = HybridPlannerFixture(turns: [])
        let search = HybridSearchFixture()
        let trace = HybridTraceRecorder()
        let research = HybridWebResearch(search: search, modelClient: remote, localModelClient: local)
        let result = try await prepare(research, profile: .lfmText, trace: trace)
        let localCalls = await local.requests
        let remoteCalls = await remote.requests
        let queries = await search.queries
        XCTAssertEqual(localCalls.count, 2)
        XCTAssertTrue(remoteCalls.isEmpty)
        XCTAssertEqual(queries, ["trains France"])
        XCTAssertFalse(result?.sources.isEmpty ?? true)
        XCTAssertEqual(trace.last?.calls.first?.origin, .model)
    }

    func testLFMInvalidCallFallsBackWithoutPoisoningLaterTurns() async throws {
        let local = HybridPlannerFixture(turns: [
            .failure(WebResearchModelError.unsupportedTools),
            .success(.init(calls: [searchCall("s2", "France")])),
            .success(.init(calls: []))
        ])
        let search = HybridSearchFixture()
        let trace = HybridTraceRecorder()
        let research = HybridWebResearch(search: search, modelClient: nil, localModelClient: local)
        _ = try await prepare(research, profile: .lfmText, trace: trace)
        XCTAssertEqual(trace.last?.fallbackReason, .localInvalidToolCall)
        _ = try await prepare(research, profile: .lfmText)
        let requests = await local.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testResearchUsesConversationAndReturnsToolEvidenceWithoutReplacingHistory() async throws {
        let search = HybridSearchFixture()
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: [searchCall("s1", "trains de nuit France tarifs moins de 100 euros")])),
            .success(.init(calls: []))
        ])
        let research = HybridWebResearch(search: search, modelClient: planner)
        let context = try await prepare(research)
        let calls = await planner.requests
        let queries = await search.queries
        XCTAssertEqual(queries, ["trains de nuit France tarifs moins de 100 euros"])
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].messages, conversation)
        XCTAssertEqual(calls[1].messages, conversation)
        XCTAssertTrue(calls[0].instructions.contains("Réponds en français et respecte le budget"))
        XCTAssertEqual(calls[1].exchanges.first?.outputs.first?.callID, "s1")
        XCTAssertTrue(calls[1].exchanges.first?.outputs.first?.text.contains("https://example.org/one") == true)
        let enriched = HybridWebResearch.appending(context, to: conversation)
        XCTAssertEqual(Array(enriched.dropLast()), Array(conversation.dropLast()))
        XCTAssertTrue(enriched.last?.text.hasPrefix("Et en France ?\n\n") == true)
        XCTAssertTrue(enriched.last?.text.contains("Fait vérifiable") == true)
        XCTAssertEqual(conversation.last?.text, "Et en France ?", "The stored user text remains unchanged")
    }

    func testFetchUsesCurrentCitationAndKeepsNumberStableAcrossSearches() async throws {
        let first = hybridContext(sources: [hybridSource("one"), hybridSource("two")])
        let second = hybridContext(sources: [hybridSource("two", excerpt: "Extrait deux plus détaillé"), hybridSource("three")])
        let search = HybridSearchFixture(contexts: [first, second])
        let reader = HybridReaderFixture()
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: [searchCall("s1", "première recherche")])),
            .success(.init(calls: [searchCall("s2", "précision"), .init(id: "f1", name: "web_fetch", arguments: #"{"source":2}"#)])),
            .success(.init(calls: []))
        ])
        let result = try await prepare(HybridWebResearch(search: search, modelClient: planner, pageReader: reader))
        let reads = await reader.sources
        XCTAssertEqual(reads.map(\.url), [URL(string: "https://example.org/two")!])
        XCTAssertEqual(result?.sources.map(\.url), ["one", "two", "three"].map { URL(string: "https://example.org/" + $0)! })
        XCTAssertEqual(result?.sources[1].kind, .page)
        XCTAssertEqual(result?.sources[1].excerpt, "Contenu de page vérifié par la fixture")
        XCTAssertEqual(result?.sources[0].kind, .searchSnippet)
    }

    func testUnknownURLAndInvalidCitationNeverReachPageTransport() async throws {
        let search = HybridSearchFixture()
        let reader = HybridReaderFixture()
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: [searchCall("s1", "question")])),
            .success(.init(calls: [
                .init(id: "f1", name: "web_fetch", arguments: #"{"url":"https://localhost/admin"}"#),
                .init(id: "f2", name: "web_fetch", arguments: #"{"source":true}"#),
                .init(id: "f3", name: "web_fetch", arguments: #"{"source":5}"#)
            ])),
            .success(.init(calls: []))
        ])
        let result = try await prepare(HybridWebResearch(search: search, modelClient: planner, pageReader: reader))
        let reads = await reader.sources
        let calls = await planner.requests
        XCTAssertTrue(reads.isEmpty)
        XCTAssertEqual(result?.sources.first?.kind, .searchSnippet)
        XCTAssertEqual(calls.last?.exchanges.last?.outputs.count, 3)
        XCTAssertTrue(calls.last?.exchanges.last?.outputs.allSatisfy { $0.text.contains("error") } == true)
    }

    func testUnsupportedToolsFallsBackAndCachesOnlyThatProfileModel() async throws {
        let search = HybridSearchFixture()
        let planner = HybridPlannerFixture(turns: [
            .failure(WebResearchModelError.unsupportedTools),
            .success(.init(calls: []))
        ])
        let research = HybridWebResearch(search: search, modelClient: planner)
        let originalProfile = profile
        let rejectedTrace = HybridTraceRecorder()
        let cachedTrace = HybridTraceRecorder()
        _ = try await prepare(research, profile: originalProfile, trace: rejectedTrace)
        _ = try await prepare(research, profile: originalProfile, trace: cachedTrace)
        var other = originalProfile
        other.model = "beta"
        _ = try await prepare(research, profile: other)
        let calls = await planner.requests
        let queries = await search.queries
        XCTAssertEqual(calls.count, 2, "A different exact model must not inherit unsupported status")
        XCTAssertEqual(queries, ["Et en France ?", "Et en France ?"])
        XCTAssertEqual(calls[0].messages, conversation)
        XCTAssertEqual(rejectedTrace.last?.fallbackReason, .apiRejected)
        XCTAssertEqual(rejectedTrace.last?.toolsOffered, true)
        XCTAssertEqual(cachedTrace.last?.fallbackReason, .cachedUnsupported)
        XCTAssertEqual(cachedTrace.last?.toolsOffered, false)
        for trace in [rejectedTrace, cachedTrace] {
            XCTAssertEqual(trace.last?.calls.map(\.origin), [.eudes])
            XCTAssertEqual(trace.last?.calls.map(\.state), [.succeeded])
        }
    }

    func testExplicitlyUnsupportedModelSkipsPlannerAndKeepsEvidenceAvailableForSynthesis() async throws {
        var selected = profile
        selected.modelCapabilities = [selected.visionKey("alpha"): ModelCapabilities(tools: false)]
        let search = HybridSearchFixture()
        let planner = HybridPlannerFixture(turns: [])
        let context = try await prepare(HybridWebResearch(search: search, modelClient: planner), profile: selected)
        let calls = await planner.requests
        XCTAssertTrue(calls.isEmpty)
        let enriched = HybridWebResearch.appending(context, to: conversation)
        XCTAssertEqual(enriched.count, conversation.count)
        XCTAssertEqual(enriched.first, conversation.first)
        XCTAssertTrue(enriched.last?.text.contains("https://example.org/one") == true)
    }

    func testModelMayDeclineResearchWithoutCallingSearchOrPageReader() async throws {
        let search = HybridSearchFixture()
        let reader = HybridReaderFixture()
        let planner = HybridPlannerFixture(turns: [.success(.init(calls: [], text: "Aucune recherche nécessaire"))])
        let trace = HybridTraceRecorder()
        let context = try await prepare(HybridWebResearch(search: search, modelClient: planner, pageReader: reader), trace: trace)
        let queries = await search.queries
        let reads = await reader.sources
        XCTAssertNil(context)
        XCTAssertTrue(queries.isEmpty)
        XCTAssertTrue(reads.isEmpty)
        XCTAssertEqual(HybridWebResearch.appending(context, to: conversation), conversation)
        XCTAssertEqual(trace.last?.state, .completed)
        XCTAssertEqual(trace.last?.toolsOffered, true)
        XCTAssertNil(trace.last?.fallbackReason, "No tool call is not an incompatibility result")
        XCTAssertTrue(trace.last?.calls.isEmpty == true)
        XCTAssertNotNil(trace.last?.finishedAt)
    }

    func testExplicitSearchRequestStillSearchesWhenPlannerDeclinesTools() async throws {
        let question = "Cherche sur Internet les trains de nuit en France"
        let messages = Array(conversation.dropLast()) + [ChatMessage(role: .user, text: question)]
        let search = HybridSearchFixture()
        let planner = HybridPlannerFixture(turns: [.success(.init(calls: []))])
        let research = HybridWebResearch(search: search, modelClient: planner)
        let trace = HybridTraceRecorder()
        let context = try await research.prepare(profile: profile, key: "synthetic-key", model: "alpha",
            messages: messages, systemPrompt: "Respecte le budget", temperature: 0.4, maxTokens: 512,
            onTrace: { trace.append($0) })
        let queries = await search.queries
        let calls = await planner.requests
        XCTAssertEqual(queries, [question])
        XCTAssertEqual(calls.first?.messages, messages)
        XCTAssertNotNil(context)
        let enriched = HybridWebResearch.appending(context, to: messages)
        XCTAssertEqual(Array(enriched.dropLast()), Array(messages.dropLast()))
        XCTAssertTrue(enriched.last?.text.contains("https://example.org/one") == true)
        XCTAssertEqual(trace.last?.fallbackReason, .explicitRequest)
        XCTAssertEqual(trace.last?.calls.map(\.origin), [.eudes])
    }

    func testAuthenticationAndNetworkFailuresDoNotTriggerCompatibilityFallback() async throws {
        for failure: Error in [EudesError.server(401), URLError(.networkConnectionLost)] {
            let search = HybridSearchFixture()
            let planner = HybridPlannerFixture(turns: [.failure(failure)])
            do {
                _ = try await prepare(HybridWebResearch(search: search, modelClient: planner))
                XCTFail("Expected the original model failure")
            } catch { XCTAssertEqual(error.localizedDescription, failure.localizedDescription) }
            let queries = await search.queries
            XCTAssertTrue(queries.isEmpty)
        }
    }

    func testCancellationRejectsLateSearchBeforeAnotherModelTurn() async throws {
        let search = HybridSearchFixture(suspended: true)
        let planner = HybridPlannerFixture(turns: [.success(.init(calls: [searchCall("s1", "question")]))])
        let research = HybridWebResearch(search: search, modelClient: planner)
        let trace = HybridTraceRecorder()
        let task = Task { try await prepare(research, maximumToolCalls: 1, trace: trace) }
        for _ in 0..<2000 {
            if await search.isWaiting { break }
            await Task.yield()
        }
        let waiting = await search.isWaiting
        XCTAssertTrue(waiting)
        task.cancel()
        await search.release()
        do { _ = try await task.value; XCTFail("Late evidence must not finish a cancelled request") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await planner.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(trace.last?.state, .cancelled)
        XCTAssertEqual(trace.last?.calls.first?.state, .cancelled)
        XCTAssertNotNil(trace.last?.calls.first?.startedAt)
        XCTAssertNotNil(trace.last?.calls.first?.finishedAt)
        XCTAssertEqual(trace.last?.budgetExhausted, false, "Cancellation wins even on the final permitted call")
    }

    func testFailedSearchCannotBecomeAnUnsourcedSuccessfulWebReply() async throws {
        let search = HybridSearchFixture(failure: .blocked)
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: [searchCall("s1", "question")])),
            .success(.init(calls: []))
        ])
        let trace = HybridTraceRecorder()
        do {
            _ = try await prepare(HybridWebResearch(search: search, modelClient: planner), trace: trace)
            XCTFail("A failed search must remain a visible failure")
        } catch { XCTAssertEqual(error as? WebSearchError, .blocked) }
        let calls = await planner.requests
        XCTAssertTrue(calls.last?.exchanges.last?.outputs.first?.text.contains("error") == true)
        XCTAssertEqual(trace.last?.state, .failed)
        XCTAssertEqual(trace.last?.calls.first?.state, .failed)
        XCTAssertNotNil(trace.last?.calls.first?.startedAt)
        XCTAssertNotNil(trace.last?.calls.first?.finishedAt)
    }

    func testKnownContextLimitStopsBeforePlannerWithoutDroppingHistory() async throws {
        var selected = profile
        selected.setContextBudget(100, model: "alpha")
        let search = HybridSearchFixture()
        let planner = HybridPlannerFixture(turns: [])
        do {
            _ = try await prepare(HybridWebResearch(search: search, modelClient: planner), profile: selected)
            XCTFail("The complete history exceeds the model budget")
        } catch { XCTAssertEqual(error.localizedDescription, EudesError.contextExceeded.localizedDescription) }
        let calls = await planner.requests
        let queries = await search.queries
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(queries.isEmpty)
        XCTAssertEqual(conversation.count, 3)
    }

    func testFullResearchTranscriptStopsPlanningWhileFinalEvidenceStillFits() async throws {
        var selected = profile
        let large = hybridContext(sources: (1...5).map { hybridSource("source\($0)", excerpt: String(repeating: "x", count: 2_000)) })
        let finalAssessment = ContextAssessment.make(profile: profile, model: "alpha",
            messages: HybridWebResearch.appending(large, to: conversation),
            instructions: HybridWebResearch.evidenceInstructions, requestedOutput: 512)
        selected.setContextBudget(finalAssessment.estimatedInput + 512 + 512, model: "alpha")
        let search = HybridSearchFixture(contexts: [large])
        let planner = HybridPlannerFixture(turns: [.success(.init(calls: [searchCall("s1", "question")]))])
        let trace = HybridTraceRecorder()
        let context = try await prepare(HybridWebResearch(search: search, modelClient: planner), profile: selected, trace: trace)
        let calls = await planner.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.messages, conversation)
        XCTAssertEqual(context?.sources, large.sources)
        XCTAssertEqual(trace.last?.state, .completed)
        XCTAssertEqual(trace.last?.contextLimitReached, true)
        XCTAssertEqual(trace.last?.budgetExhausted, false)
        // The larger planning transcript must not prevent a compact final answer
        // request which still preserves the history and all collected evidence.
        XCTAssertNoThrow(try HybridWebResearch.validateContext(profile: selected, model: "alpha",
            messages: HybridWebResearch.appending(context, to: conversation),
            instructions: HybridWebResearch.evidenceInstructions, maxTokens: 512))
    }

    func testPlanningContextRejectionAfterEvidenceReturnsSourcesForSynthesis() async throws {
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: [searchCall("s1", "question")])),
            .failure(EudesError.contextExceeded)
        ])
        let trace = HybridTraceRecorder()
        let context = try await prepare(HybridWebResearch(search: HybridSearchFixture(), modelClient: planner), trace: trace)
        XCTAssertEqual(context?.sources.count, 1)
        XCTAssertEqual(trace.last?.contextLimitReached, true)
        XCTAssertEqual(trace.last?.state, .completed)
    }

    func testNetworkAndAuthenticationFailuresAfterEvidenceAreNotContextStops() async throws {
        for failure: Error in [EudesError.server(401), URLError(.networkConnectionLost)] {
            let planner = HybridPlannerFixture(turns: [
                .success(.init(calls: [searchCall("s1", "question")])),
                .failure(failure)
            ])
            let trace = HybridTraceRecorder()
            do {
                _ = try await prepare(HybridWebResearch(search: HybridSearchFixture(), modelClient: planner), trace: trace)
                XCTFail("Only context exhaustion may finish planning early")
            } catch { XCTAssertEqual(error.localizedDescription, failure.localizedDescription) }
            XCTAssertEqual(trace.last?.state, .failed)
            XCTAssertEqual(trace.last?.contextLimitReached, false)
        }
    }

    func testRepeatedSearchesAndToolLoopRemainBounded() async throws {
        let search = HybridSearchFixture()
        let planner = HybridPlannerFixture(turns: (1...8).map {
            .success(.init(calls: [searchCall("s\($0)", "question")]))
        })
        let trace = HybridTraceRecorder()
        let context = try await prepare(HybridWebResearch(search: search, modelClient: planner), maximumToolCalls: 7, trace: trace)
        let calls = await planner.requests
        let queries = await search.queries
        XCTAssertEqual(queries, ["question"])
        XCTAssertEqual(calls.count, 7)
        XCTAssertEqual(trace.last?.calls.count, 7)
        XCTAssertEqual(trace.last?.calls.filter { $0.state == .rejected }.count, 6)
        XCTAssertEqual(trace.last?.budgetExhausted, true)
        XCTAssertNotNil(context)
    }

    func testRefinedSearchAddsSourcesAfterAFullFirstPageWithoutRenumbering() async throws {
        let first = hybridContext(sources: (1...5).map { hybridSource("first\($0)") })
        let second = hybridContext(sources: [hybridSource("new-detail")])
        let search = HybridSearchFixture(contexts: [first, second])
        let reader = HybridReaderFixture()
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: [searchCall("s1", "large recherche")])),
            .success(.init(calls: [searchCall("s2", "détail précis")])),
            .success(.init(calls: [.init(id: "f1", name: "web_fetch", arguments: #"{"source":6}"#)])),
            .success(.init(calls: []))
        ])
        let context = try await prepare(HybridWebResearch(search: search, modelClient: planner, pageReader: reader))
        let reads = await reader.sources
        XCTAssertEqual(context?.sources.count, 6)
        XCTAssertEqual(Array(context?.sources.prefix(5).map(\.url) ?? []), first.sources.map(\.url))
        XCTAssertEqual(reads.first?.url, URL(string: "https://example.org/new-detail"))
        XCTAssertTrue(context?.modelContext.contains("[6]") == true)
        XCTAssertTrue(context?.modelContext.contains("https://example.org/new-detail") == true)
    }

    func testBatchCrossingBudgetExecutesRemainingPrefixAndKeepsEvidence() async throws {
        let search = HybridSearchFixture()
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: (1...7).map { searchCall("s\($0)", "question \($0)") }))
        ])
        let trace = HybridTraceRecorder()
        let context = try await prepare(HybridWebResearch(search: search, modelClient: planner), maximumToolCalls: 3, trace: trace)
        let queries = await search.queries
        let planning = await planner.requests
        XCTAssertEqual(queries, ["question 1", "question 2", "question 3"])
        XCTAssertEqual(planning.count, 1, "A partial batch is never replayed with missing tool outputs")
        XCTAssertEqual(trace.last?.calls.count, 3)
        XCTAssertTrue(trace.last?.calls.allSatisfy { $0.state == .succeeded } == true)
        XCTAssertEqual(trace.last?.maximumToolCalls, 3)
        XCTAssertEqual(trace.last?.budgetExhausted, true)
        XCTAssertNotNil(context)
    }

    func testDefaultBudgetAllowsOneHundredCallsAndStopsBeforeTheNextTurn() async throws {
        let search = HybridSearchFixture()
        let planner = HybridPlannerFixture(turns: (1...105).map {
            .success(.init(calls: [searchCall("s\($0)", "question \($0)")]))
        })
        let trace = HybridTraceRecorder()
        let context = try await prepare(HybridWebResearch(search: search, modelClient: planner), trace: trace)
        let queries = await search.queries
        let planning = await planner.requests
        XCTAssertEqual(queries.count, 100)
        XCTAssertEqual(planning.count, 100)
        XCTAssertEqual(trace.last?.calls.count, 100, "No old activity-table cap hides later calls")
        XCTAssertEqual(trace.last?.maximumToolCalls, 100)
        XCTAssertEqual(trace.last?.budgetExhausted, true)
        XCTAssertTrue(trace.last?.calls.allSatisfy { $0.state == .succeeded } == true)
        XCTAssertEqual(context?.sources.count, 1, "Repeated source URLs remain deduplicated")
    }

    func testSearchesReadsRoundsAndSourceIDsShareOnlyTheConfiguredBudget() async throws {
        let batches = (0..<4).map { batch in
            hybridContext(sources: (1...5).map { hybridSource("source\(batch * 5 + $0)") })
        }
        let search = HybridSearchFixture(contexts: batches)
        let reader = HybridReaderFixture()
        var turns: [Result<WebResearchTurn, Error>] = (1...4).map {
            .success(.init(calls: [searchCall("s\($0)", "question \($0)")]))
        }
        for number in [16, 17, 20] {
            turns.append(.success(.init(calls: [.init(id: "f\(number)", name: "web_fetch",
                                                    arguments: "{\"source\":\(number)}")])))
        }
        turns.append(.success(.init(calls: [])))
        let planner = HybridPlannerFixture(turns: turns)
        let trace = HybridTraceRecorder()
        let context = try await prepare(HybridWebResearch(search: search, modelClient: planner, pageReader: reader),
                                        maximumToolCalls: 30, trace: trace)
        let queries = await search.queries
        let reads = await reader.sources
        let planning = await planner.requests
        XCTAssertEqual(queries.count, 4)
        XCTAssertEqual(reads.map(\.url.lastPathComponent), ["source16", "source17", "source20"])
        XCTAssertEqual(planning.count, 8)
        XCTAssertEqual(context?.sources.count, 20)
        XCTAssertTrue(context?.modelContext.contains("[20]") == true)
        XCTAssertEqual(context?.sources.filter { $0.kind == .page }.count, 3)
        XCTAssertEqual(trace.last?.calls.count, 7)
        XCTAssertEqual(trace.last?.budgetExhausted, false, "The model can stop before reaching its allowance")
    }

    func testConfiguredBudgetCanExceedTheDefault() async throws {
        let search = HybridSearchFixture()
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: (1...125).map { searchCall("s\($0)", "question \($0)") }))
        ])
        let trace = HybridTraceRecorder()
        _ = try await prepare(HybridWebResearch(search: search, modelClient: planner), maximumToolCalls: 120, trace: trace)
        let queries = await search.queries
        XCTAssertEqual(queries.count, 120)
        XCTAssertEqual(trace.last?.calls.count, 120)
        XCTAssertEqual(trace.last?.maximumToolCalls, 120)
        XCTAssertEqual(trace.last?.budgetExhausted, true)
    }

    func testInvalidAndFailedCallsConsumeTheSameBudgetWithoutDiscardingEvidence() async throws {
        let search = HybridSearchFixture()
        let reader = HybridReaderFixture(failure: .timedOut)
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: [searchCall("s1", "question")])),
            .success(.init(calls: [
                .init(id: "f1", name: "web_fetch", arguments: #"{"source":1}"#),
                .init(id: "bad", name: "unknown", arguments: "{}"),
                searchCall("s2", "question"),
                searchCall("excess", "must not run")
            ]))
        ])
        let trace = HybridTraceRecorder()
        let context = try await prepare(HybridWebResearch(search: search, modelClient: planner, pageReader: reader),
                                        maximumToolCalls: 4, trace: trace)
        let queries = await search.queries
        let reads = await reader.sources
        XCTAssertEqual(queries, ["question"])
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(trace.last?.calls.map(\.state), [.succeeded, .failed, .rejected, .rejected])
        XCTAssertEqual(trace.last?.budgetExhausted, true)
        XCTAssertEqual(context?.sources.first?.kind, .searchSnippet)
    }

    func testExhaustedBudgetWithOnlyFailedSearchesStillFails() async throws {
        let search = HybridSearchFixture(failure: .blocked)
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: [searchCall("s1", "question")]))
        ])
        let trace = HybridTraceRecorder()
        do {
            _ = try await prepare(HybridWebResearch(search: search, modelClient: planner), maximumToolCalls: 1, trace: trace)
            XCTFail("A budget boundary cannot turn missing evidence into a successful Web answer")
        } catch { XCTAssertEqual(error as? WebSearchError, .blocked) }
        XCTAssertEqual(trace.last?.budgetExhausted, true)
        XCTAssertEqual(trace.last?.state, .failed)
    }

    func testConfiguredBudgetDoesNotAffectAutomaticFallback() async throws {
        let search = HybridSearchFixture()
        let trace = HybridTraceRecorder()
        _ = try await prepare(HybridWebResearch(search: search, modelClient: nil), maximumToolCalls: 1, trace: trace)
        let queries = await search.queries
        XCTAssertEqual(queries, ["Et en France ?"])
        XCTAssertNil(trace.last?.maximumToolCalls)
        XCTAssertNil(trace.last?.budgetExhausted)
        XCTAssertEqual(trace.last?.calls.map(\.origin), [.eudes])
    }

    func testTraceSeparatesRequestedRunningAndSuccessfulSearchAndFetch() async throws {
        let search = HybridSearchFixture()
        let reader = HybridReaderFixture()
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: [searchCall("search", "requête précise")])),
            .success(.init(calls: [.init(id: "read", name: "web_fetch", arguments: #"{"source":1}"#)])),
            .success(.init(calls: []))
        ])
        let trace = HybridTraceRecorder()
        _ = try await prepare(HybridWebResearch(search: search, modelClient: planner, pageReader: reader), trace: trace)
        let final = try XCTUnwrap(trace.last)
        XCTAssertEqual(final.state, .completed)
        XCTAssertEqual(final.calls.map(\.tool), [.webSearch, .webFetch])
        XCTAssertEqual(final.calls.map(\.origin), [.model, .model])
        XCTAssertEqual(final.calls.map(\.state), [.succeeded, .succeeded])
        XCTAssertEqual(final.calls.first?.query, "requête précise")
        XCTAssertEqual(final.calls.last?.url, URL(string: "https://example.org/one"))
        for call in final.calls {
            let states = trace.values.compactMap { $0.calls.first(where: { $0.id == call.id })?.state }
            XCTAssertTrue(states.contains(.requested))
            XCTAssertTrue(states.contains(.running))
            XCTAssertEqual(states.last, .succeeded)
            XCTAssertNotNil(call.startedAt)
            XCTAssertNotNil(call.finishedAt)
        }
    }

    func testRejectedCallsNeverCountAsExecutedAndDoNotPersistRawArguments() async throws {
        let search = HybridSearchFixture()
        let reader = HybridReaderFixture()
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: [searchCall("s1", "question")])),
            .success(.init(calls: [searchCall("s2", "question"),
                .init(id: "f1", name: "web_fetch", arguments: #"{"url":"https://localhost/private-token"}"#),
                .init(id: "u1", name: "unknown-secret-tool", arguments: #"{"secret":"fixture-private-key"}"#)])),
            .success(.init(calls: []))
        ])
        let trace = HybridTraceRecorder()
        _ = try await prepare(HybridWebResearch(search: search, modelClient: planner, pageReader: reader), trace: trace)
        let final = try XCTUnwrap(trace.last)
        XCTAssertEqual(final.calls.map(\.state), [.succeeded, .rejected, .rejected, .rejected])
        XCTAssertTrue(final.calls.dropFirst().allSatisfy { $0.startedAt == nil && $0.finishedAt != nil })
        XCTAssertEqual(final.calls.last?.tool, .unknown)
        let serialized = String(data: try JSONEncoder().encode(final), encoding: .utf8)!
        for secret in ["private-token", "fixture-private-key", "unknown-secret-tool", "synthetic-key"] {
            XCTAssertFalse(serialized.contains(secret))
        }
        let queries = await search.queries
        let reads = await reader.sources
        XCTAssertEqual(queries, ["question"])
        XCTAssertTrue(reads.isEmpty)
    }

    func testTraceRecordsPageFailureWhileKeepingSuccessfulSearchEvidence() async throws {
        let search = HybridSearchFixture()
        let reader = HybridReaderFixture(failure: .timedOut)
        let planner = HybridPlannerFixture(turns: [
            .success(.init(calls: [searchCall("s1", "question")])),
            .success(.init(calls: [.init(id: "f1", name: "web_fetch", arguments: #"{"source":1}"#)])),
            .success(.init(calls: []))
        ])
        let trace = HybridTraceRecorder()
        let context = try await prepare(HybridWebResearch(search: search, modelClient: planner, pageReader: reader), trace: trace)
        XCTAssertEqual(context?.sources.first?.kind, .searchSnippet)
        XCTAssertEqual(trace.last?.state, .completed)
        XCTAssertEqual(trace.last?.calls.map(\.state), [.succeeded, .failed])
        XCTAssertNotNil(trace.last?.calls.last?.detail)
    }

    func testFallbackTraceIdentifiesDeclaredUnsupportedAndMissingClient() async throws {
        var unsupported = profile
        unsupported.modelCapabilities = [unsupported.visionKey("alpha"): ModelCapabilities(tools: false)]
        let cases: [(ServerProfile, (any WebResearchModelClient)?, WebResearchTrace.FallbackReason)] = [
            (unsupported, HybridPlannerFixture(turns: []), .modelUnsupported),
            (profile, nil, .noToolClient)
        ]
        for (selected, planner, reason) in cases {
            let trace = HybridTraceRecorder()
            _ = try await prepare(HybridWebResearch(search: HybridSearchFixture(), modelClient: planner),
                                  profile: selected, trace: trace)
            XCTAssertEqual(trace.last?.fallbackReason, reason)
            XCTAssertEqual(trace.last?.toolsOffered, false)
            XCTAssertEqual(trace.last?.calls.map(\.origin), [.eudes])
        }
    }

    func testFallbackFailureKeepsAnExecutedFailedTrace() async throws {
        let trace = HybridTraceRecorder()
        do {
            _ = try await prepare(HybridWebResearch(search: HybridSearchFixture(failure: .blocked), modelClient: nil), trace: trace)
            XCTFail("Expected a failed automatic search")
        } catch { XCTAssertEqual(error as? WebSearchError, .blocked) }
        XCTAssertEqual(trace.last?.state, .failed)
        XCTAssertEqual(trace.last?.calls.first?.origin, .eudes)
        XCTAssertEqual(trace.last?.calls.first?.state, .failed)
        XCTAssertNotNil(trace.last?.calls.first?.startedAt)
    }

    private func prepare(_ research: HybridWebResearch, profile selected: ServerProfile? = nil,
                         maximumToolCalls: Int = WebResearchBudget.defaultMaximumCalls,
                         trace: HybridTraceRecorder? = nil) async throws -> WebSearchContext? {
        let selected = selected ?? profile
        return try await research.prepare(profile: selected, key: "synthetic-key", model: selected.model,
            messages: conversation, systemPrompt: "Réponds en français et respecte le budget",
            temperature: 0.4, maxTokens: 512, maximumToolCalls: maximumToolCalls, onTrace: { trace?.append($0) })
    }

    private func searchCall(_ id: String, _ query: String) -> WebToolCall {
        let data = try! JSONSerialization.data(withJSONObject: ["query": query])
        return WebToolCall(id: id, name: "web_search", arguments: String(data: data, encoding: .utf8)!)
    }
}

private struct HybridPlannerRequest {
    let messages: [ChatMessage]
    let instructions: String
    let exchanges: [WebToolExchange]
}

private actor HybridPlannerFixture: WebResearchModelClient {
    var turns: [Result<WebResearchTurn, Error>]
    private(set) var requests: [HybridPlannerRequest] = []
    init(turns: [Result<WebResearchTurn, Error>]) { self.turns = turns }
    func turn(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
              temperature: Double, maxTokens: Int?, exchanges: [WebToolExchange]) async throws -> WebResearchTurn {
        requests.append(.init(messages: messages, instructions: systemPrompt, exchanges: exchanges))
        guard !turns.isEmpty else { throw EudesError.invalidResponse }
        return try turns.removeFirst().get()
    }
}

private actor HybridSearchFixture: WebSearching {
    private(set) var queries: [String] = []
    var contexts: [WebSearchContext]
    let suspended: Bool
    let failure: WebSearchError?
    var pending: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { pending != nil }
    init(contexts: [WebSearchContext] = [], suspended: Bool = false, failure: WebSearchError? = nil) {
        self.contexts = contexts; self.suspended = suspended; self.failure = failure
    }
    func release() { pending?.resume(); pending = nil }
    func search(query: String) async throws -> WebSearchContext {
        queries.append(query)
        if let failure { throw failure }
        if suspended { await withCheckedContinuation { pending = $0 } }
        return contexts.isEmpty ? hybridContext(query: query) : contexts.removeFirst()
    }
}

private actor HybridReaderFixture: WebPageReading {
    private(set) var sources: [WebSource] = []
    let failure: WebSearchError?
    init(failure: WebSearchError? = nil) { self.failure = failure }
    func read(source: WebSource) async throws -> WebSource {
        sources.append(source)
        if let failure { throw failure }
        var page = source
        page.kind = .page
        page.excerpt = "Contenu de page vérifié par la fixture"
        return page
    }
}

@MainActor
private final class HybridTraceRecorder {
    private(set) var values: [WebResearchTrace] = []
    var last: WebResearchTrace? { values.last }
    func append(_ trace: WebResearchTrace) { values.append(trace) }
}

private func hybridSource(_ path: String, excerpt: String = "Fait vérifiable") -> WebSource {
    WebSource(url: URL(string: "https://example.org/" + path)!, title: path, excerpt: excerpt, kind: .searchSnippet)
}

private func hybridContext(query: String = "query", sources: [WebSource]? = nil) -> WebSearchContext {
    WebSearchContext(query: query, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000), sources: sources ?? [hybridSource("one")])
}
