import XCTest
@testable import Eudes

@MainActor
final class WebSearchStoreTests: XCTestCase {
    func testLFMWebSearchUsesLocalModelAndKeepsSources() async throws {
        let planner = WebStoreResearchFixture()
        let local = WebStoreModelFixture()
        let fixture = try makeFixture(localResearch: planner, localModel: local)
        defer { fixture.cleanUp() }
        fixture.store.selectServer(ServerProfile.lfmTextID)
        fixture.store.webSearchEnabled = true
        let sent = await fixture.store.sendChecked("Recherche les trains")
        XCTAssertTrue(sent)
        await finish(fixture.store)
        let localRequests = await local.requests
        let remoteRequests = await fixture.model.requests
        let queries = await fixture.web.queries
        XCTAssertTrue(remoteRequests.isEmpty)
        XCTAssertEqual(queries, ["trains de nuit France tarifs 100 euros"])
        XCTAssertTrue(localRequests.last?.last?.text.contains("https://example.org/source") == true)
        XCTAssertNotNil(fixture.store.current?.messages.last?.webContext)
    }

    func testContinuousVoiceRetainsEarlierTurnsInOneConversation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.store.answerShortcut("Je m’appelle Alice")
        let id = try XCTUnwrap(fixture.store.current?.id)
        _ = try await fixture.store.answerShortcut("Quel est mon prénom ?", continuing: id)
        XCTAssertEqual(fixture.store.current?.id, id)
        XCTAssertEqual(fixture.store.data.conversations.count, 1)
        let messages = try XCTUnwrap(fixture.store.current?.messages)
        XCTAssertEqual(messages.count, 4)
        let requests = await fixture.model.requests
        XCTAssertEqual(requests.last?.first?.text, "Je m’appelle Alice")
        XCTAssertEqual(requests.last?.last?.text, "Quel est mon prénom ?")
    }

    func testToolBudgetPersistsAndIsAppliedToEachResponseAndRetry() async throws {
        let planner = WebStoreResearchFixture()
        let fixture = try makeFixture(research: planner)
        defer { fixture.cleanUp() }
        XCTAssertEqual(fixture.store.webToolCallLimit, 100)
        fixture.store.setWebToolCallLimit(1)
        XCTAssertEqual(reopen(fixture).webToolCallLimit, 1)
        fixture.store.webSearchEnabled = true
        let sent = await fixture.store.sendChecked("Compare les trains de nuit")
        XCTAssertTrue(sent)
        await finish(fixture.store)
        let firstTrace = try XCTUnwrap(fixture.store.current?.messages.last?.webResearchTrace)
        XCTAssertEqual(firstTrace.maximumToolCalls, 1)
        XCTAssertEqual(firstTrace.budgetExhausted, true)
        XCTAssertEqual(firstTrace.calls.filter { $0.startedAt != nil }.count, 1)
        let firstRounds = await planner.exchanges.count
        XCTAssertEqual(firstRounds, 1, "A one-call budget must stop before another planning request")

        fixture.store.setWebToolCallLimit(250)
        await fixture.store.retryChecked()
        await finish(fixture.store)
        let retryTrace = try XCTUnwrap(fixture.store.current?.messages.last?.webResearchTrace)
        XCTAssertEqual(retryTrace.maximumToolCalls, 250)
        XCTAssertNotEqual(retryTrace.budgetExhausted, true)
        XCTAssertEqual(reopen(fixture).webToolCallLimit, 250)
        XCTAssertNotNil(fixture.store.current?.messages.last?.webContext)
    }

    func testVoiceInstructionReachesWebPlanningAndSynthesisButNotWrittenFollowUp() async throws {
        let planner = WebStoreResearchFixture()
        let fixture = try makeFixture(research: planner)
        defer { fixture.cleanUp() }
        let instruction = "Answer briefly in the language of the user."
        fixture.store.setVoiceResponseInstruction(instruction)
        fixture.store.setVoiceWebSearchMode(.always)

        _ = try await fixture.store.answerShortcut("Compare les trains de nuit")
        let planningPrompts = await planner.prompts
        XCTAssertFalse(planningPrompts.isEmpty)
        XCTAssertTrue(planningPrompts.allSatisfy { $0.contains(instruction) })
        let voicePrompts = await fixture.model.prompts
        XCTAssertTrue(voicePrompts.last?.contains(HybridWebResearch.evidenceInstructions) == true)
        XCTAssertTrue(voicePrompts.last?.hasSuffix(instruction) == true)

        let sent = await fixture.store.sendChecked("Merci pour les sources")
        XCTAssertTrue(sent)
        await finish(fixture.store)
        let textPrompts = await fixture.model.prompts
        XCTAssertFalse(textPrompts.last?.contains(instruction) == true)
        XCTAssertTrue(textPrompts.last?.contains(HybridWebResearch.evidenceInstructions) == true)
        let requests = await fixture.model.requests
        XCTAssertEqual(requests.last?.count, 3, "The written follow-up keeps its prior voice exchange")
    }

    func testWebIsOffByDefaultAndDoesNotContactSearchProvider() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        XCTAssertFalse(fixture.store.webSearchEnabled)

        let sent = await fixture.store.sendChecked("Question sans recherche")
        XCTAssertTrue(sent)
        await finish(fixture.store)

        let queries = await fixture.web.queries
        let requests = await fixture.model.requests
        XCTAssertTrue(queries.isEmpty)
        XCTAssertEqual(requests.last?.last?.text, "Question sans recherche")
        XCTAssertNil(fixture.store.current?.messages.last?.webContext)
        XCTAssertNil(fixture.store.current?.messages.first?.webSearchRequested)
        XCTAssertNil(fixture.store.current?.messages.last?.webResearchTrace)
    }

    func testSearchSendsOnlyQuestionThenEvidenceToModelAndPersistsSources() async throws {
        let fixture = try makeFixture(previousConversation: true)
        defer { fixture.cleanUp() }
        fixture.store.webSearchEnabled = true

        let sent = await fixture.store.sendChecked("Question publique")
        XCTAssertTrue(sent)
        await finish(fixture.store)

        let queries = await fixture.web.queries
        let requests = await fixture.model.requests
        let prompts = await fixture.model.prompts
        XCTAssertEqual(queries, ["Question publique"])
        let submitted = try XCTUnwrap(requests.last?.last)
        XCTAssertTrue(submitted.text.hasPrefix("Question publique\n\n"))
        XCTAssertTrue(submitted.text.contains("https://example.org/source"))
        XCTAssertTrue(submitted.text.contains("Fait issu du résultat de recherche"))
        XCTAssertTrue(prompts.last?.contains("non fiables") == true)
        XCTAssertEqual(requests.last?.first?.text, "Ancien échange confidentiel")
        let answer = try XCTUnwrap(fixture.store.current?.messages.last)
        XCTAssertEqual(answer.state, .complete)
        XCTAssertEqual(answer.webContext?.sources, sampleWebContext().sources)
        let trace = try XCTUnwrap(answer.webResearchTrace)
        XCTAssertFalse(trace.toolsOffered)
        XCTAssertEqual(trace.fallbackReason, .noToolClient)
        XCTAssertEqual(trace.state, .completed)
        XCTAssertEqual(trace.calls.map(\.origin), [.eudes])
        XCTAssertEqual(trace.calls.map(\.state), [.succeeded])
        XCTAssertNotNil(trace.calls.first?.startedAt)
        XCTAssertFalse(fixture.store.isSearchingWeb)

        let loaded = try fixture.storage.load()
        let restored = try XCTUnwrap(loaded.conversations.first)
        XCTAssertEqual(restored.messages.last?.webContext, answer.webContext)
        XCTAssertEqual(restored.messages.last?.webResearchTrace, trace)
        XCTAssertEqual(reopen(fixture).current?.messages.last?.webResearchTrace, trace)
        XCTAssertEqual(restored.messages[2].text, "Question publique")
        XCTAssertEqual(restored.messages[2].webSearchRequested, true)
        XCTAssertTrue(restored.modelMessages[2].text.contains("https://example.org/source"))
        XCTAssertEqual(restored.modelMessages[0].text, "Ancien échange confidentiel")
    }

    func testSearchFailureDoesNotGenerateAnUnsourcedAnswerOrBlameModelConnection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        await fixture.web.setFailure(true)
        fixture.store.webSearchEnabled = true

        let sent = await fixture.store.sendChecked("Question bloquée")
        XCTAssertTrue(sent)
        await finish(fixture.store)

        let requests = await fixture.model.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(fixture.store.current?.messages.last?.state, .failed)
        XCTAssertNil(fixture.store.current?.messages.last?.webContext)
        XCTAssertEqual(fixture.store.notice, WebSearchError.blocked.localizedDescription)
        XCTAssertEqual(fixture.store.current?.messages.last?.failureDetail, WebSearchError.blocked.localizedDescription)
        if case .failed = fixture.store.connectionState { XCTFail("Search failure must not blame the model server") }
        XCTAssertFalse(fixture.store.isSearchingWeb)
        XCTAssertFalse(fixture.store.isGenerating)
    }

    func testHybridPlanningAndFinalSynthesisBothReceiveChatContext() async throws {
        let planner = WebStoreResearchFixture()
        let history = [
            ChatMessage(role: .user, text: "Je compare les trains de nuit, avec un budget de 100 euros."),
            ChatMessage(role: .assistant, text: "Nous comparerons les lignes et les prix.")
        ]
        let fixture = try makeFixture(research: planner, previousMessages: history)
        defer { fixture.cleanUp() }
        fixture.store.webSearchEnabled = true
        let sent = await fixture.store.sendChecked("Et en France ?")
        XCTAssertTrue(sent)
        await finish(fixture.store)

        let planning = await planner.messages
        let toolExchanges = await planner.exchanges
        let synthesis = await fixture.model.requests
        let instructions = await fixture.model.prompts
        let queries = await fixture.web.queries
        XCTAssertEqual(planning.count, 2)
        XCTAssertEqual(Array(planning[0].prefix(2)), history)
        XCTAssertEqual(planning[0].last?.text, "Et en France ?")
        XCTAssertEqual(planning[1], planning[0])
        XCTAssertTrue(toolExchanges.last?.first?.outputs.first?.text.contains("Fait issu du résultat de recherche") == true)
        XCTAssertEqual(queries, ["trains de nuit France tarifs 100 euros"])
        let submitted = try XCTUnwrap(synthesis.last)
        XCTAssertEqual(Array(submitted.prefix(2)), history)
        XCTAssertTrue(submitted.last?.text.hasPrefix("Et en France ?\n\n") == true)
        XCTAssertTrue(submitted.last?.text.contains("https://example.org/source") == true)
        XCTAssertTrue(instructions.last?.contains("contexte du chat") == true)
        XCTAssertEqual(fixture.store.current?.messages.last?.state, .complete)
        XCTAssertNotNil(fixture.store.current?.messages.last?.webContext)
        XCTAssertEqual(fixture.store.current?.messages.last?.webResearchTrace?.calls.map(\.origin), [.model])
        XCTAssertEqual(fixture.store.current?.messages.last?.webResearchTrace?.calls.map(\.state), [.succeeded])
        XCTAssertTrue(fixture.store.current?.messages.last?.webResearchTrace?.toolsOffered == true)
        XCTAssertEqual(fixture.store.current?.messages[2].text, "Et en France ?")
    }

    func testHybridNoSearchDecisionStillProducesNormalReplyWithHistory() async throws {
        let planner = WebStoreResearchFixture(shouldSearch: false)
        let fixture = try makeFixture(previousConversation: true, research: planner)
        defer { fixture.cleanUp() }
        fixture.store.webSearchEnabled = true
        let sent = await fixture.store.sendChecked("Merci")
        XCTAssertTrue(sent)
        await finish(fixture.store)
        let queries = await fixture.web.queries
        let synthesis = await fixture.model.requests
        XCTAssertTrue(queries.isEmpty)
        XCTAssertEqual(synthesis.last?.first?.text, "Ancien échange confidentiel")
        XCTAssertEqual(synthesis.last?.last?.text, "Merci")
        XCTAssertEqual(fixture.store.current?.messages.last?.state, .complete)
        XCTAssertNil(fixture.store.current?.messages.last?.webContext)
        XCTAssertFalse(fixture.store.isSearchingWeb)
    }

    func testNoCallTraceIsPersistedIndependentlyOfSources() async throws {
        let fixture = try makeFixture(research: WebStoreResearchFixture(shouldSearch: false))
        defer { fixture.cleanUp() }
        fixture.store.webSearchEnabled = true
        let sent = await fixture.store.sendChecked("Bonjour")
        XCTAssertTrue(sent)
        await finish(fixture.store)
        let reply = try XCTUnwrap(reopen(fixture).current?.messages.last)
        let trace = try XCTUnwrap(reply.webResearchTrace)
        XCTAssertNil(reply.webContext)
        XCTAssertEqual(trace.state, .completed)
        XCTAssertTrue(trace.toolsOffered)
        XCTAssertNil(trace.fallbackReason)
        XCTAssertTrue(trace.calls.isEmpty)
    }

    func testFailedTraceWithoutSourcesSurvivesReopening() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        await fixture.web.setFailure(true)
        fixture.store.webSearchEnabled = true
        let sent = await fixture.store.sendChecked("Question bloquée")
        XCTAssertTrue(sent)
        await finish(fixture.store)
        let reply = try XCTUnwrap(reopen(fixture).current?.messages.last)
        XCTAssertNil(reply.webContext)
        XCTAssertEqual(reply.webResearchTrace?.state, .failed)
        XCTAssertEqual(reply.webResearchTrace?.calls.first?.state, .failed)
        XCTAssertNotNil(reply.webResearchTrace?.calls.first?.startedAt)
    }

    func testReloadMarksUnfinishedToolResultUnknownWithoutChangingCompletedCalls() throws {
        let fixture = try makeFixture(previousConversation: true)
        defer { fixture.cleanUp() }
        var data = try fixture.storage.load()
        let now = Date()
        let success = WebToolActivity(tool: .webSearch, origin: .model, state: .succeeded,
                                      query: "requête", startedAt: now, finishedAt: now)
        let running = WebToolActivity(tool: .webFetch, origin: .model, state: .running,
                                      url: URL(string: "https://example.org/source"), startedAt: now)
        data.conversations[0].messages[1].state = .streaming
        data.conversations[0].messages[1].webResearchTrace = WebResearchTrace(toolsOffered: true, calls: [success, running])
        try fixture.storage.save(data)
        let reply = try XCTUnwrap(reopen(fixture).current?.messages.last)
        XCTAssertEqual(reply.state, .interrupted)
        XCTAssertEqual(reply.webResearchTrace?.state, .interrupted)
        XCTAssertEqual(reply.webResearchTrace?.calls.first, success)
        XCTAssertEqual(reply.webResearchTrace?.calls.last?.state, .interrupted)
        XCTAssertNil(reply.webResearchTrace?.calls.last?.finishedAt)
    }

    func testPlannerFailureNeverDisplaysOrPersistsRawPrivateErrorText() async throws {
        let privateText = "PRIVATE_FIXTURE_CHAT_TEXT"
        let privateURL = "https://example.invalid/private?token=SYNTHETIC_SECRET_123"
        let failure = NSError(domain: "SyntheticPrivateTransport", code: 17, userInfo: [
            NSLocalizedDescriptionKey: privateText + " " + privateURL,
            NSURLErrorFailingURLStringErrorKey: privateURL
        ])
        let planner = WebStoreResearchFixture(failure: failure)
        let fixture = try makeFixture(research: planner)
        defer { fixture.cleanUp() }
        fixture.store.webSearchEnabled = true
        let sent = await fixture.store.sendChecked("Question à documenter")
        XCTAssertTrue(sent)
        await finish(fixture.store)

        let failed = try XCTUnwrap(fixture.store.current?.messages.last)
        XCTAssertEqual(failed.state, .failed)
        let notice = try XCTUnwrap(fixture.store.notice)
        let detail = try XCTUnwrap(failed.failureDetail)
        let persisted = try XCTUnwrap(fixture.storage.load().conversations.first?.messages.last?.failureDetail)
        for presented in [notice, detail, persisted] {
            XCTAssertFalse(presented.isEmpty)
            XCTAssertFalse(presented.contains(privateText))
            XCTAssertFalse(presented.contains(privateURL))
            XCTAssertFalse(presented.contains("SYNTHETIC_SECRET_123"))
            XCTAssertFalse(presented.contains("SyntheticPrivateTransport"))
        }
        let queries = await fixture.web.queries
        let modelRequests = await fixture.model.requests
        XCTAssertTrue(queries.isEmpty)
        XCTAssertTrue(modelRequests.isEmpty)
        XCTAssertNil(failed.webContext)
        let encodedTrace = try JSONEncoder().encode(failed.webResearchTrace)
        let traceText = String(decoding: encodedTrace, as: UTF8.self)
        XCTAssertFalse(traceText.contains(privateText))
        XCTAssertFalse(traceText.contains("SYNTHETIC_SECRET_123"))
    }

    func testLaterWebOffTurnRetainsEvidenceAndTrustInstructionsWithoutNewSearch() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.webSearchEnabled = true
        let firstSent = await fixture.store.sendChecked("Trouve une source")
        XCTAssertTrue(firstSent)
        await finish(fixture.store)
        fixture.store.webSearchEnabled = false
        let followupSent = await fixture.store.sendChecked("Explique ce résultat dans mon contexte")
        XCTAssertTrue(followupSent)
        await finish(fixture.store)
        let queries = await fixture.web.queries
        let requests = await fixture.model.requests
        let prompts = await fixture.model.prompts
        XCTAssertEqual(queries, ["Trouve une source"])
        XCTAssertTrue(requests.last?.first?.text.contains("https://example.org/source") == true)
        XCTAssertEqual(requests.last?.last?.text, "Explique ce résultat dans mon contexte")
        XCTAssertTrue(prompts.last?.contains("non fiables") == true)
        XCTAssertTrue(prompts.last?.contains("Les anciennes tables documentent leurs échanges d'origine") == true)
        XCTAssertTrue(prompts.last?.contains("sans renvois numérotés") == true)
        XCTAssertNil(fixture.store.current?.messages.last?.webContext)
    }

    func testEvidenceBudgetOverflowStopsSynthesisAndPreservesConversation() async throws {
        let fixture = try makeFixture(previousConversation: true, contextBudget: 500)
        defer { fixture.cleanUp() }
        fixture.store.webSearchEnabled = true
        let sent = await fixture.store.sendChecked("Recherche à documenter")
        XCTAssertTrue(sent)
        await finish(fixture.store)
        let requests = await fixture.model.requests
        let queries = await fixture.web.queries
        XCTAssertEqual(queries, ["Recherche à documenter"])
        XCTAssertTrue(requests.isEmpty, "The model must not receive an over-budget enriched context")
        XCTAssertEqual(fixture.store.current?.messages.last?.state, .failed)
        XCTAssertEqual(fixture.store.current?.messages.first?.text, "Ancien échange confidentiel")
        XCTAssertEqual(fixture.store.current?.messages[1].text, "Ancienne réponse")
        XCTAssertEqual(fixture.store.current?.messages[2].text, "Recherche à documenter")
        XCTAssertEqual(fixture.store.current?.messages.count, 4)
    }

    func testSearchFailureNeverStartsOrLeavesPendingAnOpenAIBackgroundResponse() async throws {
        let fixture = try makeFixture(openAIBackground: true)
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.store.selectedServer?.usesOpenAIBackground == true)
        await fixture.web.setFailure(true)
        fixture.store.webSearchEnabled = true

        let sent = await fixture.store.sendChecked("Question Web bloquée avant la soumission distante")
        XCTAssertTrue(sent)
        await finish(fixture.store)

        let failed = try XCTUnwrap(fixture.store.current?.messages.last)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNil(failed.remoteResponse)
        XCTAssertNotEqual(failed.remoteSubmissionPending, true)
        XCTAssertNil(failed.webContext)
        XCTAssertEqual(failed.failureDetail, WebSearchError.blocked.localizedDescription)
        let persisted = try XCTUnwrap(fixture.storage.load().conversations.first?.messages.last)
        XCTAssertNil(persisted.remoteResponse)
        XCTAssertNotEqual(persisted.remoteSubmissionPending, true)

        let reopened = reopen(fixture)
        XCTAssertNotEqual(reopened.current?.messages.last?.remoteSubmissionPending, true)
        XCTAssertNil(reopened.current?.messages.last?.remoteResponse)
        let starts = await fixture.remote.starts
        let ordinaryRequests = await fixture.model.requests
        XCTAssertEqual(starts, 0, "A failed search happens before any remote response submission")
        XCTAssertTrue(ordinaryRequests.isEmpty)
        XCTAssertFalse(fixture.store.isSearchingWeb)
    }

    func testCancellationRejectsLateSearchResultBeforeContactingModel() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        await fixture.web.setSuspended(true)
        fixture.store.webSearchEnabled = true
        let sent = await fixture.store.sendChecked("Question annulée")
        XCTAssertTrue(sent)
        for _ in 0..<1000 {
            if await fixture.web.isWaiting { break }
            await Task.yield()
        }
        let waiting = await fixture.web.isWaiting
        XCTAssertTrue(waiting)
        XCTAssertTrue(fixture.store.isSearchingWeb)
        XCTAssertEqual(fixture.store.webResearchTrace?.calls.last?.state, .running)

        fixture.store.stop(reason: .user)
        await fixture.web.release()
        for _ in 0..<100 { await Task.yield() }

        let requests = await fixture.model.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(fixture.store.current?.messages.last?.state, .interrupted)
        XCTAssertNil(fixture.store.current?.messages.last?.webContext)
        XCTAssertFalse(fixture.store.isSearchingWeb)
        XCTAssertFalse(fixture.store.isGenerating)
        XCTAssertNil(try fixture.storage.load().conversations.first?.messages.last?.webContext)
        XCTAssertEqual(fixture.store.current?.messages.last?.webResearchTrace?.state, .cancelled)
        XCTAssertEqual(fixture.store.current?.messages.last?.webResearchTrace?.calls.last?.state, .cancelled)
        XCTAssertEqual(try fixture.storage.load().conversations.first?.messages.last?.webResearchTrace,
                       fixture.store.current?.messages.last?.webResearchTrace)
    }

    func testRetryStopsSearchingWhenConversationWebIsTurnedOff() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.webSearchEnabled = true
        let sent = await fixture.store.sendChecked("Question à vérifier")
        XCTAssertTrue(sent)
        await finish(fixture.store)
        fixture.store.webSearchEnabled = false
        XCTAssertFalse(fixture.store.retryUsesWebSearch)

        await fixture.store.retryChecked()
        await finish(fixture.store)

        let queries = await fixture.web.queries
        let requests = await fixture.model.requests
        XCTAssertEqual(queries, ["Question à vérifier"])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(fixture.store.current?.messages.count, 2)
        XCTAssertNil(fixture.store.current?.messages.last?.webContext)
    }

    func testRetryStartsSearchingWhenConversationWebIsTurnedOn() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let sent = await fixture.store.sendChecked("Question ordinaire")
        XCTAssertTrue(sent)
        await finish(fixture.store)
        fixture.store.webSearchEnabled = true
        XCTAssertTrue(fixture.store.retryUsesWebSearch)

        await fixture.store.retryChecked()
        await finish(fixture.store)

        let queries = await fixture.web.queries
        XCTAssertEqual(queries, ["Question ordinaire"])
        XCTAssertNotNil(fixture.store.current?.messages.last?.webContext)
    }

    func testChatAndVoiceModesPersistIndependentlyAcrossRestarts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        XCTAssertEqual(fixture.store.chatWebSearchMode, .perConversation)
        XCTAssertEqual(fixture.store.voiceWebSearchMode, .disabled)
        fixture.store.setChatWebSearchMode(.allConversations)
        fixture.store.setVoiceWebSearchMode(.onRequest)

        let reopened = reopen(fixture)
        XCTAssertEqual(reopened.chatWebSearchMode, .allConversations)
        XCTAssertEqual(reopened.voiceWebSearchMode, .onRequest)
        XCTAssertTrue(reopened.webSearchEnabled)
        reopened.setChatWebSearchMode(.disabled)
        reopened.setVoiceWebSearchMode(.always)

        let reopenedAgain = reopen(fixture)
        XCTAssertEqual(reopenedAgain.chatWebSearchMode, .disabled)
        XCTAssertEqual(reopenedAgain.voiceWebSearchMode, .always)
        XCTAssertFalse(reopenedAgain.webSearchEnabled)
    }

    func testPerConversationChoiceIsIsolatedAndRestoredAfterRestart() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.webSearchEnabled = true
        let firstSent = await fixture.store.sendChecked("Première conversation Web")
        XCTAssertTrue(firstSent)
        await finish(fixture.store)
        let first = try XCTUnwrap(fixture.store.current)

        fixture.store.newConversation()
        XCTAssertFalse(fixture.store.webSearchEnabled)
        let secondSent = await fixture.store.sendChecked("Deuxième conversation ordinaire")
        XCTAssertTrue(secondSent)
        await finish(fixture.store)
        let second = try XCTUnwrap(fixture.store.current)
        XCTAssertFalse(fixture.store.webSearchEnabled)
        fixture.store.selectConversation(first)
        XCTAssertTrue(fixture.store.webSearchEnabled)

        let reopened = reopen(fixture)
        XCTAssertEqual(reopened.current?.id, first.id)
        XCTAssertTrue(reopened.webSearchEnabled)
        reopened.selectConversation(second)
        XCTAssertFalse(reopened.webSearchEnabled)
        let queries = await fixture.web.queries
        XCTAssertEqual(queries, ["Première conversation Web"])
    }

    func testNewConversationResetsAnUnsavedDraftWebChoice() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        XCTAssertNil(fixture.store.current)
        fixture.store.webSearchEnabled = true
        XCTAssertTrue(fixture.store.webSearchEnabled)
        fixture.store.newConversation()
        XCTAssertNil(fixture.store.current)
        XCTAssertFalse(fixture.store.webSearchEnabled)
        XCTAssertFalse(reopen(fixture).webSearchEnabled)
    }

    func testGlobalChatModesOverrideTheConversationToggleAndRetry() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.setChatWebSearchMode(.allConversations)
        fixture.store.webSearchEnabled = false
        XCTAssertTrue(fixture.store.webSearchEnabled)
        let sent = await fixture.store.sendChecked("Recherche imposée par le réglage")
        XCTAssertTrue(sent)
        await finish(fixture.store)
        fixture.store.setChatWebSearchMode(.disabled)
        XCTAssertFalse(fixture.store.retryUsesWebSearch)
        await fixture.store.retryChecked()
        await finish(fixture.store)
        XCTAssertNil(fixture.store.current?.messages.last?.webContext)
        fixture.store.setChatWebSearchMode(.allConversations)
        fixture.store.newConversation()
        XCTAssertTrue(fixture.store.webSearchEnabled)

        fixture.store.setChatWebSearchMode(.disabled)
        fixture.store.webSearchEnabled = true
        XCTAssertFalse(fixture.store.webSearchEnabled)
        let secondSent = await fixture.store.sendChecked("Le réglage désactive la recherche")
        XCTAssertTrue(secondSent)
        await finish(fixture.store)
        XCTAssertFalse(fixture.store.retryUsesWebSearch)

        fixture.store.setChatWebSearchMode(.allConversations)
        XCTAssertTrue(fixture.store.retryUsesWebSearch)
        await fixture.store.retryChecked()
        await finish(fixture.store)
        let queries = await fixture.web.queries
        XCTAssertEqual(queries, ["Recherche imposée par le réglage", "Le réglage désactive la recherche"])
    }

    func testVoiceDisabledNeverUsesWebEvenWhenAllChatsDo() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.setChatWebSearchMode(.allConversations)
        fixture.store.setVoiceWebSearchMode(.disabled)
        let answer = try await fixture.store.answerShortcut("Recherche sur Internet la météo à Paris")

        XCTAssertFalse(answer.isEmpty)
        let queries = await fixture.web.queries
        XCTAssertTrue(queries.isEmpty)
        XCTAssertEqual(fixture.store.current?.messages.first?.isVoiceRequest, true)
        XCTAssertNil(fixture.store.current?.messages.last?.webContext)
        XCTAssertFalse(fixture.store.retryUsesWebSearch)
    }

    func testVoiceOnRequestSearchesOnlyTheExplicitTurnIndependentlyOfChatMode() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.setChatWebSearchMode(.disabled)
        fixture.store.setVoiceWebSearchMode(.onRequest)
        let explicitQuestion = "Recherche sur Internet la météo à Paris"
        _ = try await fixture.store.answerShortcut(explicitQuestion)
        XCTAssertNotNil(fixture.store.current?.messages.last?.webContext)
        XCTAssertEqual(fixture.store.current?.messages.first?.isVoiceRequest, true)
        XCTAssertFalse(fixture.store.webSearchEnabled)

        _ = try await fixture.store.answerShortcut("Raconte une histoire courte")
        let queries = await fixture.web.queries
        XCTAssertEqual(queries, [explicitQuestion])
        XCTAssertNil(fixture.store.current?.messages.last?.webContext)
        XCTAssertFalse(fixture.store.retryUsesWebSearch)
        XCTAssertEqual(fixture.store.voiceWebSearchMode, .onRequest)
    }

    func testVoiceAlwaysSearchesWithoutEnablingChatWeb() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.setVoiceWebSearchMode(.always)
        XCTAssertFalse(fixture.store.webSearchEnabled)
        _ = try await fixture.store.answerShortcut("Question vocale ordinaire")
        XCTAssertNotNil(fixture.store.current?.messages.last?.webContext)
        XCTAssertFalse(fixture.store.webSearchEnabled)
        _ = try await fixture.store.answerShortcut("Une autre question vocale")
        let queries = await fixture.web.queries
        XCTAssertEqual(queries, ["Question vocale ordinaire", "Une autre question vocale"])
        XCTAssertFalse(fixture.store.webSearchEnabled)
        XCTAssertTrue(fixture.store.retryUsesWebSearch)
    }

    func testVoiceRetryUsesCurrentVoicePolicyRatherThanCurrentChatPolicy() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.setChatWebSearchMode(.allConversations)
        fixture.store.setVoiceWebSearchMode(.always)
        let question = "Question vocale sans demande Web"
        _ = try await fixture.store.answerShortcut(question)
        fixture.store.setVoiceWebSearchMode(.disabled)
        XCTAssertFalse(fixture.store.retryUsesWebSearch)
        await fixture.store.retryChecked()
        await finish(fixture.store)
        XCTAssertNil(fixture.store.current?.messages.last?.webContext)
        fixture.store.setVoiceWebSearchMode(.onRequest)
        XCTAssertFalse(fixture.store.retryUsesWebSearch)
        await fixture.store.retryChecked()
        await finish(fixture.store)
        var queries = await fixture.web.queries
        XCTAssertEqual(queries, [question])

        fixture.store.setChatWebSearchMode(.disabled)
        fixture.store.setVoiceWebSearchMode(.always)
        XCTAssertTrue(fixture.store.retryUsesWebSearch)
        await fixture.store.retryChecked()
        await finish(fixture.store)
        queries = await fixture.web.queries
        XCTAssertEqual(queries, [question, question])
    }

    func testPreviousHistoriesWithoutWebFieldsStillDecode() throws {
        var message = ChatMessage(role: .assistant, text: "Réponse historique")
        message.webSearchRequested = true
        message.webContext = sampleWebContext()
        message.isVoiceRequest = true
        let data = try JSONEncoder().encode(message)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "webSearchRequested")
        object.removeValue(forKey: "webContext")
        object.removeValue(forKey: "isVoiceRequest")
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.text, "Réponse historique")
        XCTAssertNil(decoded.webSearchRequested)
        XCTAssertNil(decoded.webContext)
        XCTAssertNil(decoded.isVoiceRequest)
        XCTAssertNil(decoded.webResearchTrace)
    }

    func testFailedEvidenceIsNotReintroducedIntoConversationContext() {
        let question = ChatMessage(role: .user, text: "Question originale", webSearchRequested: true)
        let failed = ChatMessage(role: .assistant, text: "Partiel", state: .failed, webContext: sampleWebContext())
        let conversation = Conversation(serverID: UUID(), model: "alpha", messages: [question, failed])
        XCTAssertEqual(conversation.modelMessages.first?.text, "Question originale")
        XCTAssertEqual(conversation.messages.first?.text, "Question originale")
    }

    func testLaterTurnsReinjectAShortDigestInsteadOfTheFullEvidence() {
        let question = ChatMessage(role: .user, text: "Météo demain Strasbourg", webSearchRequested: true)
        var answer = ChatMessage(role: .assistant, text: "Voici la météo.")
        answer.webContext = WebSearchContext(query: "météo", fetchedAt: Date(), sources: (1...4).map { index in
            WebSource(url: URL(string: "https://example.org/meteo/\(index)")!, title: "Météo \(index)",
                      excerpt: String(repeating: "Éclaircies puis averses en soirée. ", count: 80),
                      kind: .searchSnippet)
        })
        let conversation = Conversation(serverID: UUID(), model: "alpha", messages: [question, answer])
        let text = conversation.modelMessages.first?.text ?? ""
        XCTAssertTrue(text.contains("https://example.org/meteo/4"))
        XCTAssertLessThanOrEqual(text.utf8.count,
                                 question.text.utf8.count + 2 + WebSearchContext.digestByteBudget)
        XCTAssertFalse(text.contains(String(repeating: "Éclaircies puis averses en soirée. ", count: 10)))
        // The stored evidence keeps the full text for the source list.
        XCTAssertEqual(answer.webContext?.sources.first?.excerpt.utf8.count,
                       String(repeating: "Éclaircies puis averses en soirée. ", count: 80).utf8.count)
    }

    func testCompactionReceivesEarlierWebEvidenceAndPreservationInstructionsWithoutSearchingAgain() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.webSearchEnabled = true
        let firstSent = await fixture.store.sendChecked("Question Web à conserver dans le résumé")
        XCTAssertTrue(firstSent)
        await finish(fixture.store)
        let firstAnswerID = try XCTUnwrap(fixture.store.current?.messages.last?.id)
        fixture.store.webSearchEnabled = false
        for question in ["Échange récent sans Web", "Question à reprendre après compactage"] {
            let sent = await fixture.store.sendChecked(question)
            XCTAssertTrue(sent)
            await finish(fixture.store)
        }

        let conversationID = try XCTUnwrap(fixture.store.current?.id)
        var persisted = try fixture.storage.load()
        let conversationIndex = try XCTUnwrap(persisted.conversations.firstIndex { $0.id == conversationID })
        let answerIndex = persisted.conversations[conversationIndex].messages.count - 1
        persisted.conversations[conversationIndex].messages[answerIndex].state = .failed
        try fixture.storage.save(persisted)
        fixture.store.reload()
        let requestCountBeforeCompaction = await fixture.model.requests.count

        await fixture.store.compactContextAndRetry(conversationID: conversationID)
        await finish(fixture.store)

        let requests = await fixture.model.requests
        let prompts = await fixture.model.prompts
        let summarizationCalls = zip(requests.dropFirst(requestCountBeforeCompaction),
                                     prompts.dropFirst(requestCountBeforeCompaction))
            .filter { $0.1.hasPrefix("Résume fidèlement") }
        XCTAssertFalse(summarizationCalls.isEmpty)
        XCTAssertTrue(summarizationCalls.contains { request, instruction in
            request.contains { $0.text.contains("https://example.org/source") }
                && instruction.localizedCaseInsensitiveContains("URL")
        }, "Compaction must receive the source URL together with instructions to preserve citations")
        XCTAssertEqual(fixture.store.current?.contextSummaryThrough, firstAnswerID)
        XCTAssertNotNil(fixture.store.current?.contextSummary)
        let queries = await fixture.web.queries
        XCTAssertEqual(queries, ["Question Web à conserver dans le résumé"])
        // This fixture does not summarize semantically: only the summarizer's input is verified.
    }

    private func finish(_ store: AppStore) async {
        for _ in 0..<2000 where store.isGenerating { await Task.yield() }
        XCTAssertFalse(store.isGenerating, "The deterministic fixture should finish")
    }

    private func reopen(_ fixture: WebStoreFixture) -> AppStore {
        AppStore(storageDirectory: fixture.directory, defaults: fixture.defaults, client: fixture.model,
                 webSearch: fixture.web, readKey: { _ in "synthetic-model-key" },
                 responseContinuation: NoResponseContinuation(), recoverableClient: fixture.remote,
                 applicationIsActive: { false }, protectedDataAvailable: { true })
    }

    private func makeFixture(previousConversation: Bool = false, openAIBackground: Bool = false,
                             research: (any WebResearchModelClient)? = nil,
                             localResearch: (any WebResearchModelClient)? = nil,
                             localModel: (any EudesAPIClient)? = nil,
                             previousMessages: [ChatMessage]? = nil,
                             contextBudget: Int? = nil) throws -> WebStoreFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesWebSearch." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var profile = ServerProfile(name: "Fixture",
                                    baseURL: openAIBackground ? "https://api.openai.com/v1" : "https://example.invalid/v1",
                                    model: "alpha")
        if let contextBudget { profile.setContextBudget(contextBudget, model: "alpha") }
        if openAIBackground {
            profile.protocolKind = .responses
            profile.openAIBackgroundResponses = true
        }
        let storage = try PrivateStorage(directory: directory)
        var data = AppData()
        data.servers = [profile]
        data.selectedServerID = profile.id
        if previousConversation || previousMessages != nil {
            let conversation = Conversation(serverID: profile.id, model: "alpha", messages: previousMessages ?? [
                ChatMessage(role: .user, text: "Ancien échange confidentiel"),
                ChatMessage(role: .assistant, text: "Ancienne réponse")
            ])
            data.conversations = [conversation]
            data.selectedConversationID = conversation.id
        }
        try storage.save(data)
        let web = WebStoreSearchFixture()
        let model = WebStoreModelFixture()
        let remote = WebStoreRecoverableFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: model,
                             webSearch: web, webResearchModel: research, localWebResearchModel: localResearch,
                             localModelClient: localModel ?? LocalModelClient(), readKey: { _ in "synthetic-model-key" },
                             responseContinuation: NoResponseContinuation(), recoverableClient: remote,
                             applicationIsActive: { false }, protectedDataAvailable: { true })
        return WebStoreFixture(store: store, storage: storage, web: web, model: model, remote: remote,
                               directory: directory, suite: suite, defaults: defaults)
    }
}

private actor WebStoreResearchFixture: WebResearchModelClient {
    private(set) var messages: [[ChatMessage]] = []
    private(set) var exchanges: [[WebToolExchange]] = []
    private(set) var prompts: [String] = []
    let shouldSearch: Bool
    let failure: Error?
    init(shouldSearch: Bool = true, failure: Error? = nil) {
        self.shouldSearch = shouldSearch
        self.failure = failure
    }
    func turn(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
              temperature: Double, maxTokens: Int?, exchanges: [WebToolExchange]) async throws -> WebResearchTurn {
        self.messages.append(messages)
        self.exchanges.append(exchanges)
        self.prompts.append(systemPrompt)
        if let failure { throw failure }
        if shouldSearch && exchanges.isEmpty {
            return WebResearchTurn(calls: [.init(id: "search-1", name: "web_search",
                arguments: #"{"query":"trains de nuit France tarifs 100 euros"}"#)])
        }
        return WebResearchTurn(calls: [])
    }
}

@MainActor
private struct WebStoreFixture {
    let store: AppStore
    let storage: PrivateStorage
    let web: WebStoreSearchFixture
    let model: WebStoreModelFixture
    let remote: WebStoreRecoverableFixture
    let directory: URL
    let suite: String
    let defaults: UserDefaults

    func cleanUp() {
        store.stop()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
}

private func sampleWebContext(query: String = "Question publique") -> WebSearchContext {
    WebSearchContext(query: query, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000), sources: [
        WebSource(url: URL(string: "https://example.org/source")!, title: "Source fictive",
                  excerpt: "Fait issu du résultat de recherche", kind: .searchSnippet)
    ])
}

private actor WebStoreSearchFixture: WebSearching {
    private(set) var queries: [String] = []
    private var failure = false
    private var suspended = false
    private var pending: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { pending != nil }

    func setFailure(_ value: Bool) { failure = value }
    func setSuspended(_ value: Bool) { suspended = value }
    func release() { pending?.resume(); pending = nil }
    func search(query: String) async throws -> WebSearchContext {
        queries.append(query)
        if failure { throw WebSearchError.blocked }
        if suspended { await withCheckedContinuation { pending = $0 } }
        // Intentionally ignores cancellation so the store must reject late results.
        return sampleWebContext(query: query)
    }
}

private actor WebStoreModelFixture: EudesAPIClient {
    private(set) var requests: [[ChatMessage]] = []
    private(set) var prompts: [String] = []
    func models(profile: ServerProfile, key: String) async throws -> [String] { ["alpha"] }
    nonisolated func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        await record(messages: messages, prompt: systemPrompt)
        await onText("Réponse fondée sur la source [1].")
    }

    private func record(messages: [ChatMessage], prompt: String) {
        requests.append(messages)
        prompts.append(prompt)
    }
}

private actor WebStoreRecoverableFixture: RecoverableResponseClient {
    private(set) var starts = 0

    nonisolated func start(profile: ServerProfile, key: String, model: String,
                          messages: [ChatMessage], systemPrompt: String, temperature: Double, maxTokens: Int?,
                          onCreated: @escaping @MainActor (String) throws -> Void,
                          onText: @escaping @MainActor (String) -> Void,
                          onReasoning: @escaping @MainActor (String) -> Void,
                          onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws {
        await recordStart()
        throw URLError(.networkConnectionLost)
    }

    private func recordStart() { starts += 1 }

    func retrieve(profile: ServerProfile, key: String, responseID: String) async throws -> RecoverableSnapshot {
        throw URLError(.networkConnectionLost)
    }

    func cancel(profile: ServerProfile, key: String, responseID: String) async throws { }
}
