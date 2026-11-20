import Foundation
import Security
import XCTest
@testable import Eudes

@MainActor
final class SiriAssistantTests: XCTestCase {
    private func profile() -> ServerProfile {
        ServerProfile(name: "Test Siri", baseURL: "https://example.invalid/v1", model: "configured-model")
    }

    func testLFMConfigurationUsesNoAPIKeyOrEndpoint() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        let profile = ServerProfile.lfmText
        try service.configure(profile: profile, model: profile.model, key: "do-not-retain", maxTokens: 128)
        let response = try await service.answer("Bonjour")
        XCTAssertEqual(response, "Réponse finale")
        XCTAssertEqual(client.model, LocalModelCatalog.text.id)
        XCTAssertEqual(client.key, "")
    }

    func testLFMVoiceSearchUsesLocalPlannerAndKeepsSources() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch()
        let planner = SiriResearchModel()
        planner.turns = [WebResearchTurn(calls: [WebToolCall(id: "s1", name: "web_search",
            arguments: #"{"query":"météo Paris"}"#)]), WebResearchTurn(calls: [])]
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            webSearch: web, localWebResearchModel: planner, voiceWebSearchMode: { .always })
        let profile = ServerProfile.lfmText
        try service.configure(profile: profile, model: profile.model, key: "", maxTokens: 128)
        let id = try service.beginVoiceConversation()
        let answer = try await service.answerVoice("Quelle est la météo ?", conversationID: id)
        XCTAssertEqual(answer, "Réponse finale")
        XCTAssertEqual(web.queries, ["météo Paris"])
        XCTAssertEqual(client.key, "")
        XCTAssertTrue(client.messages.last?.text.contains("https://example.com/weather") == true)
        XCTAssertNotNil(try service.pendingConversations().first?.messages.last?.webContext)
        service.endVoiceConversation(id)
    }

    func testLFMExplicitVoiceRequestSearchesWithOnRequestMode() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch()
        let planner = SiriResearchModel()
        planner.turns = [WebResearchTurn(calls: [WebToolCall(id: "s1", name: "web_search",
            arguments: #"{"query":"météo Paris"}"#)]), WebResearchTurn(calls: [])]
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            webSearch: web, localWebResearchModel: planner, voiceWebSearchMode: { .onRequest })
        let profile = ServerProfile.lfmText
        try service.configure(profile: profile, model: profile.model, key: "", maxTokens: 128)
        let id = try service.beginVoiceConversation()
        let question = "Recherche sur le Web la météo à Paris"
        XCTAssertFalse(VoiceAction.shouldInterpretAction(question, hasClarification: false, voiceWebMode: .onRequest))
        let answer = try await service.answerVoice(question, conversationID: id)
        XCTAssertEqual(answer, "Réponse finale")
        XCTAssertEqual(web.queries, ["météo Paris"])
        XCTAssertTrue(client.messages.last?.text.contains("https://example.com/weather") == true)
        service.endVoiceConversation(id)
    }

    func testVoiceStoresActualLocalUsage() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        client.reportedUsage = TokenUsage(input: 321, output: 24)
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        let profile = ServerProfile.lfmText
        try service.configure(profile: profile, model: profile.model, key: "", maxTokens: 128)
        let id = try service.beginVoiceConversation()
        _ = try await service.answerVoice("Bonjour", conversationID: id)
        let reply = try XCTUnwrap(service.pendingConversations().first?.messages.last)
        XCTAssertEqual(reply.usage, TokenUsage(input: 321, output: 24))
        XCTAssertEqual(reply.reasoningServerID, profile.id)
        XCTAssertEqual(reply.reasoningModel, profile.model)
        service.endVoiceConversation(id)
    }

    func testLFMVoiceDistinguishesResearchPlanningFromSynthesisFailure() async throws {
        let profile = ServerProfile.lfmText
        let planner = SiriResearchModel()
        planner.failure = LocalLlamaEngine.EngineError.decoding
        let planning = SiriAssistantService(persistence: SiriMemory().persistence, client: SiriClient(),
            webSearch: SiriWebSearch(), localWebResearchModel: planner, voiceWebSearchMode: { .always })
        try planning.configure(profile: profile, model: profile.model, key: "", maxTokens: 128)
        let planningID = try planning.beginVoiceConversation()
        do { _ = try await planning.answerVoice("Recherche sur Internet la météo", conversationID: planningID); XCTFail("Expected planning error") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .localWebPlanningFailed) }
        planning.endVoiceConversation(planningID)

        let failingClient = SiriClient()
        failingClient.failure = LocalLlamaEngine.EngineError.decoding
        let synthesis = SiriAssistantService(persistence: SiriMemory().persistence, client: failingClient,
            voiceWebSearchMode: { .disabled })
        try synthesis.configure(profile: profile, model: profile.model, key: "", maxTokens: 128)
        let synthesisID = try synthesis.beginVoiceConversation()
        do { _ = try await synthesis.answerVoice("Bonjour", conversationID: synthesisID); XCTFail("Expected synthesis error") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .localSynthesisFailed) }
        synthesis.endVoiceConversation(synthesisID)
    }

    func testOptInRealLFMVoiceProducesVisibleAnswer() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["EUDES_LFM3_WEB_FIXTURES"] else {
            throw XCTSkip("Set EUDES_LFM3_WEB_FIXTURES to the verified text model file.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LocalModelCatalog.text
        let directory = root.appendingPathComponent(model.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: URL(fileURLWithPath: fixture).appendingPathComponent("text.gguf"),
                                         to: directory.appendingPathComponent(model.assets[0].filename))
        let runtime = LocalModelRuntime(root: root)
        let memory = SiriMemory()
        let service = SiriAssistantService(persistence: memory.persistence,
            client: LocalModelClient(runtime: runtime, directVoiceResponse: true), voiceWebSearchMode: { .disabled })
        let profile = ServerProfile.lfmText
        try service.configure(profile: profile, model: model.id, key: "", maxTokens: 128)
        let id = try service.beginVoiceConversation()
        let answer = try await service.answerVoice("Combien font deux plus deux ?", conversationID: id)
        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(answer.contains("4") || answer.localizedCaseInsensitiveContains("quatre"), answer)
        XCTAssertFalse(answer.contains("<think>"))
        service.endVoiceConversation(id)

        let web = SiriWebSearch()
        let webService = SiriAssistantService(persistence: SiriMemory().persistence,
            client: LocalModelClient(runtime: runtime, directVoiceResponse: true), webSearch: web,
            localWebResearchModel: LocalLFMWebResearchModelClient(runtime: runtime),
            voiceWebSearchMode: { .onRequest }, webToolCallLimit: { 1 })
        try webService.configure(profile: profile, model: model.id, key: "", maxTokens: 128)
        let webID = try webService.beginVoiceConversation()
        let webAnswer = try await webService.answerVoice("Cherche sur Internet la météo à Paris.", conversationID: webID)
        XCTAssertFalse(webAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(web.queries.count, 1)
        XCTAssertNotNil(try webService.pendingConversations().last?.messages.last?.webContext)
        webService.endVoiceConversation(webID)
        try await runtime.unload()
    }

    func testDefaultDisabledDoesNotCallTransport() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        XCTAssertFalse(service.isEnabled)
        do { _ = try await service.answer("Bonjour"); XCTFail("Consent is required") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .disabled) }
        XCTAssertEqual(client.calls, 0)
    }

    func testBeforeFirstUnlockDoesNotStartTransport() async throws {
        let client = SiriClient()
        let persistence = SiriAssistantPersistence(
            read: { _ in throw SiriAssistantError.unlockFirst }, write: { _, _ in }, delete: { _ in })
        let service = SiriAssistantService(persistence: persistence, client: client)
        do { _ = try await service.answer("Bonjour"); XCTFail("Unavailable protected credentials must not be bypassed") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .unlockFirst) }
        XCTAssertEqual(client.calls, 0)
    }

    func testSelectedConfigurationAndFinalAnswerOnlyAreUsed() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        var selected = profile()
        selected.systemInstruction = "Instruction choisie"
        try service.configure(profile: selected, model: "current-model", key: "fixture-only", maxTokens: 123)
        let reply = try await service.answer("  Bonjour  ")
        XCTAssertEqual(reply, "Réponse finale")
        XCTAssertEqual(client.model, "current-model")
        XCTAssertEqual(client.key, "fixture-only")
        XCTAssertEqual(client.messages.map(\.text), ["Bonjour"], "Existing history is never supplied to Siri")
        XCTAssertEqual(client.instructions, "Instruction choisie")
        XCTAssertEqual(client.outputLimit, 123)
        let pending = try service.pendingConversations()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.model, "current-model")
        XCTAssertEqual(pending.first?.serverID, selected.id)
        XCTAssertEqual(pending.first?.messages.map(\.text), ["Bonjour", "Réponse finale"])
        XCTAssertNil(pending.first?.messages.last?.reasoning)
        let ids = Set(pending.map(\.id))
        try service.acknowledge(ids)
        try service.acknowledge(ids)
        XCTAssertTrue(try service.pendingConversations().isEmpty)
    }

    func testIdenticalConfigurationDoesNotCancelRunningRequest() async throws {
        let memory = SiriMemory()
        let client = SiriClient(); client.suspended = true
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let task = Task { try await service.answer("Bonjour") }
        await waitUntil { client.isWaiting }
        let writes = memory.writes
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        XCTAssertEqual(memory.writes, writes)
        client.release()
        let response = try await task.value
        XCTAssertEqual(response, "Réponse finale")
    }

    func testBusyTimeoutAndLateReplyCannotPersist() async throws {
        let memory = SiriMemory()
        let client = SiriClient(); client.suspended = true
        let service = SiriAssistantService(persistence: memory.persistence, client: client, timeout: .milliseconds(100))
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let task = Task { try await service.answer("Bonjour") }
        await waitUntil { client.isWaiting }
        do { _ = try await service.answer("Autre question"); XCTFail("Busy") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .busy) }
        do { _ = try await task.value; XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .timeout) }
        client.release()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(try service.pendingConversations().isEmpty)
    }

    func testCancellationAndDisableSuppressLateResults() async throws {
        for disable in [false, true] {
            let memory = SiriMemory()
            let client = SiriClient(); client.suspended = true
            let service = SiriAssistantService(persistence: memory.persistence, client: client)
            let selected = profile()
            try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
            let task = Task { try await service.answer("Bonjour") }
            await waitUntil { client.isWaiting }
            if disable { try service.disable() } else { task.cancel() }
            do { _ = try await task.value; XCTFail("Cancelled result must not be spoken") }
            catch { XCTAssertTrue(error is CancellationError || error as? SiriAssistantError == .disabled) }
            client.release()
            for _ in 0..<30 { await Task.yield() }
            XCTAssertTrue(try service.pendingConversations().isEmpty)
            XCTAssertEqual(service.isEnabled, !disable)
        }
    }

    func testFullQueueDoesNotStartNetworkRequest() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let existing = (0..<SiriAssistantService.maximumPending).map { _ in Conversation(serverID: selected.id, model: selected.model) }
        memory.values[SiriAssistantService.pendingAccount] = try JSONEncoder().encode(existing)
        do { _ = try await service.answer("Bonjour"); XCTFail("Queue full") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .queueFull) }
        XCTAssertEqual(client.calls, 0)
        XCTAssertEqual(try service.pendingConversations().map(\.id), existing.map(\.id))
    }

    func testFailedPersistenceNeverReturnsSuccessOrDiscardsOlderQueue() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        memory.failWrites = true
        do { _ = try await service.answer("Bonjour"); XCTFail("A save failure is explicit") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .storage) }
        XCTAssertTrue(try service.pendingConversations().isEmpty)
    }

    func testRevocationRemainsDisabledIfKeychainDeletionFails() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        memory.failDeletes = true
        XCTAssertThrowsError(try service.disable())
        XCTAssertFalse(service.isEnabled)
        let relaunched = SiriAssistantService(persistence: memory.persistence, client: client)
        XCTAssertFalse(relaunched.isEnabled)
        do { _ = try await relaunched.answer("Bonjour"); XCTFail("Revoked consent must survive a relaunch") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .disabled) }
        XCTAssertEqual(client.calls, 0)
    }

    func testCredentialItemUsesAfterFirstUnlockOnThisDeviceOnly() throws {
        let keychain = SiriAssistantKeychain(service: "EudesSiriTests." + UUID().uuidString)
        defer { try? keychain.delete("fixture") }
        try keychain.write("fixture", data: Data("test-only".utf8))
        var query = keychain.query("fixture")
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(try keychain.read("fixture"), Data("test-only".utf8))
        try keychain.delete("fixture")
        XCTAssertNil(try keychain.read("fixture"))
    }

    func testVoiceInstructionDefaultsAreAddedOnlyToVoiceAssistantRequests() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        var selected = profile()
        selected.systemInstruction = "Keep the configured persona."
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: 512,
                              voiceInstruction: " \n ")

        let id = try service.beginVoiceConversation()
        _ = try await service.answerVoice("Bonjour", conversationID: id)
        XCTAssertEqual(client.instructions,
                       selected.effectiveInstruction + "\n\n" + VoiceResponseInstruction.defaultText)
        XCTAssertEqual(client.messages.map(\.text), ["Bonjour"], "The voice policy is a system instruction, not a user message")
        XCTAssertEqual(client.outputLimit, 512, "Brevity must not impose an arbitrary token cap")
        service.endVoiceConversation(id)

        _ = try await service.answer("Question textuelle")
        XCTAssertEqual(client.instructions, selected.effectiveInstruction,
                       "The separate text-only action must keep its existing instruction")
        XCTAssertEqual(client.messages.map(\.text), ["Question textuelle"])
    }

    func testCustomVoiceInstructionSurvivesColdServiceStartAndKeepsConversationContext() async throws {
        let memory = SiriMemory()
        let selected = profile()
        let custom = "Use one short spoken sentence in the question's language."
        let first = SiriAssistantService(persistence: memory.persistence, client: SiriClient())
        try first.configure(profile: selected, model: selected.model, key: "", maxTokens: nil,
                            voiceInstruction: "  " + custom + "\n")
        let client = SiriClient()
        let relaunched = SiriAssistantService(persistence: memory.persistence, client: client)
        let id = try relaunched.beginVoiceConversation()

        _ = try await relaunched.answerVoice("Mon prénom est Camille.", conversationID: id)
        XCTAssertTrue(client.instructions.hasSuffix(custom))
        XCTAssertFalse(client.instructions.contains(VoiceResponseInstruction.defaultText))
        _ = try await relaunched.answerVoice("Comment je m’appelle ?", conversationID: id)
        XCTAssertTrue(client.instructions.hasSuffix(custom))
        XCTAssertEqual(client.messages.map(\.text),
                       ["Mon prénom est Camille.", "Réponse finale", "Comment je m’appelle ?"])
        XCTAssertEqual(try relaunched.pendingConversations().first?.messages.map(\.text),
                       ["Mon prénom est Camille.", "Réponse finale", "Comment je m’appelle ?", "Réponse finale"])
        relaunched.endVoiceConversation(id)

        _ = try await relaunched.answer("Question textuelle")
        XCTAssertEqual(client.instructions, selected.effectiveInstruction)
    }

    func testLegacySiriSnapshotWithoutVoiceInstructionUsesDefaultAfterUpgrade() async throws {
        let memory = SiriMemory()
        let service = SiriAssistantService(persistence: memory.persistence, client: SiriClient())
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil,
                              voiceInstruction: "This value must be removed from the legacy snapshot.")
        let encoded = try XCTUnwrap(memory.values[SiriAssistantService.configurationAccount])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "voiceInstruction")
        memory.values[SiriAssistantService.configurationAccount] = try JSONSerialization.data(withJSONObject: legacy)
        let client = SiriClient()
        let upgraded = SiriAssistantService(persistence: memory.persistence, client: client)
        XCTAssertTrue(upgraded.isEnabled)

        let id = try upgraded.beginVoiceConversation()
        _ = try await upgraded.answerVoice("Bonjour", conversationID: id)
        XCTAssertTrue(client.instructions.hasSuffix(VoiceResponseInstruction.defaultText))
        upgraded.endVoiceConversation(id)
    }

    func testChangingAndResettingVoiceInstructionInvalidateOldSessionAndPersistNewPolicy() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil,
                              voiceInstruction: "First voice policy.")
        let firstID = try service.beginVoiceConversation()
        _ = try await service.answerVoice("Premier échange", conversationID: firstID)
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil,
                              voiceInstruction: "Updated voice policy.")
        XCTAssertFalse(service.isVoiceConversationValid(firstID))
        XCTAssertEqual(try service.pendingConversationsForImport().map(\.id), [firstID],
                       "Changing a policy must retain already completed turns")
        let nextID = try service.beginVoiceConversation()
        _ = try await service.answerVoice("Nouvelle session", conversationID: nextID)
        XCTAssertTrue(client.instructions.hasSuffix("Updated voice policy."))
        service.endVoiceConversation(nextID)

        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil,
                              voiceInstruction: "")
        let relaunched = SiriAssistantService(persistence: memory.persistence, client: client)
        let resetID = try relaunched.beginVoiceConversation()
        _ = try await relaunched.answerVoice("Après réinitialisation", conversationID: resetID)
        XCTAssertTrue(client.instructions.hasSuffix(VoiceResponseInstruction.defaultText))
        XCTAssertFalse(client.instructions.contains("Updated voice policy."))
        relaunched.endVoiceConversation(resetID)
    }

    func testVoiceConversationKeepsContextAndOneDurableIdentityUntilEnded() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "fixture-only", maxTokens: 100)
        let id = try service.beginVoiceConversation()
        XCTAssertTrue(service.isVoiceConversationValid(id))
        _ = try await service.answerVoice("Je m’appelle Camille", conversationID: id)
        XCTAssertTrue(try service.pendingConversationsForImport().isEmpty)
        try service.acknowledge([id])
        XCTAssertEqual(try service.pendingConversations().map(\.id), [id], "An importer cannot discard a live conversation")
        _ = try await service.answerVoice("Comment je m’appelle ?", conversationID: id)
        XCTAssertEqual(client.messages.map(\.text), ["Je m’appelle Camille", "Réponse finale", "Comment je m’appelle ?"])
        let queued = try service.pendingConversations()
        XCTAssertEqual(queued.map(\.id), [id])
        XCTAssertEqual(queued.first?.messages.count, 4)
        XCTAssertTrue(queued.first?.messages.allSatisfy { $0.reasoning == nil } == true)
        service.endVoiceConversation(id)
        XCTAssertFalse(service.isVoiceConversationValid(id))
        XCTAssertEqual(try service.pendingConversationsForImport().map(\.id), [id])
        try service.acknowledge([id])
        XCTAssertTrue(try service.pendingConversations().isEmpty)
    }

    func testCompletedVoiceTurnsCanBeRecoveredAfterProcessRestart() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        _ = try await service.answerVoice("Un échange terminé", conversationID: id)
        let relaunched = SiriAssistantService(persistence: memory.persistence, client: client)
        XCTAssertEqual(try relaunched.pendingConversationsForImport().map(\.id), [id])
        XCTAssertFalse(relaunched.isVoiceConversationValid(id), "A new process must not silently resume microphone use")
        service.endVoiceConversation(id)
    }

    func testVoiceSaveFailurePreservesOldContextAndCanRetryWithoutDuplication() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        _ = try await service.answerVoice("Première demande", conversationID: id)
        let saved = try XCTUnwrap(memory.values[SiriAssistantService.pendingAccount])
        memory.failWrites = true
        do { _ = try await service.answerVoice("Deuxième demande", conversationID: id); XCTFail("Failed save") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .storage) }
        XCTAssertEqual(memory.values[SiriAssistantService.pendingAccount], saved)
        memory.failWrites = false
        _ = try await service.answerVoice("Réessayer", conversationID: id)
        XCTAssertEqual(client.messages.map(\.text), ["Première demande", "Réponse finale", "Réessayer"])
        XCTAssertEqual(try service.pendingConversations().first?.messages.count, 4)
        service.endVoiceConversation(id)
    }

    func testEndingVoiceSessionCancelsInflightReplyAndRejectsLateResult() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        _ = try await service.answerVoice("Question terminée", conversationID: id)
        client.suspended = true
        let task = Task { try await service.answerVoice("Ne pas conserver", conversationID: id) }
        await waitUntil { client.isWaiting }
        service.endVoiceConversation(id)
        do { _ = try await task.value; XCTFail("Ended session") }
        catch { XCTAssertTrue(error is CancellationError) }
        client.release()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(try service.pendingConversationsForImport().first?.messages.map(\.text), ["Question terminée", "Réponse finale"])
        do { _ = try await service.answerVoice("Trop tard", conversationID: id); XCTFail("Old ID") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .voiceConversationEnded) }
        let newID = try service.beginVoiceConversation()
        XCTAssertNotEqual(newID, id)
        service.endVoiceConversation(id)
        XCTAssertTrue(service.isVoiceConversationValid(newID), "A late old stop must not terminate a new session")
        service.endVoiceConversation(newID)
    }

    func testVoiceConsentAndConfigurationChangesInvalidateSessions() async throws {
        for revoke in [false, true] {
            let memory = SiriMemory()
            let client = SiriClient(); client.suspended = true
            let service = SiriAssistantService(persistence: memory.persistence, client: client)
            let selected = profile()
            try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
            let id = try service.beginVoiceConversation()
            try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
            XCTAssertTrue(service.isVoiceConversationValid(id), "An identical configuration must not stop a session")
            let task = Task { try await service.answerVoice("Bonjour", conversationID: id) }
            await waitUntil { client.isWaiting }
            if revoke { try service.disable() }
            else { try service.configure(profile: selected, model: "another-model", key: "", maxTokens: nil) }
            do { _ = try await task.value; XCTFail("Revoked snapshot") }
            catch { XCTAssertEqual(error as? SiriAssistantError, revoke ? .disabled : .configurationChanged) }
            XCTAssertFalse(service.isVoiceConversationValid(id))
            client.release()
            for _ in 0..<30 { await Task.yield() }
            XCTAssertTrue(try service.pendingConversations().isEmpty)
        }
    }

    func testVoiceBudgetLimitStopsBeforeTransportAndRetainsHistory() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        var selected = profile()
        selected.setContextBudget(250, model: selected.model)
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: 50,
                              voiceInstruction: "Be brief.")
        let id = try service.beginVoiceConversation()
        _ = try await service.answerVoice("Bonjour", conversationID: id)
        do { _ = try await service.answerVoice(String(repeating: "long ", count: 20), conversationID: id); XCTFail("Known context budget") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .voiceContextFull) }
        XCTAssertEqual(client.calls, 1)
        service.endVoiceConversation(id)
        XCTAssertEqual(try service.pendingConversationsForImport().first?.messages.count, 2)
    }

    func testCustomVoiceInstructionCountsTowardContextBeforeCallingTransport() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        var selected = profile()
        selected.setContextBudget(250, model: selected.model)
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: 50,
                              voiceInstruction: String(repeating: "Long custom instruction. ", count: 100))
        let id = try service.beginVoiceConversation()
        do {
            _ = try await service.answerVoice("Bonjour", conversationID: id)
            XCTFail("The voice instruction must be included in the context budget")
        } catch {
            XCTAssertEqual(error as? SiriAssistantError, .voiceContextFull)
        }
        XCTAssertEqual(client.calls, 0)
        XCTAssertTrue(try service.pendingConversations().isEmpty)
        service.endVoiceConversation(id)

        _ = try await service.answer("Bonjour")
        XCTAssertEqual(client.calls, 1, "The text-only action must not include the long voice instruction")
        XCTAssertEqual(client.instructions, selected.effectiveInstruction)
    }

    func testVoiceTimeoutIsIndependentFromSiriDeadlineAndSuppressesLateReply() async throws {
        let memory = SiriMemory()
        let client = SiriClient(); client.suspended = true
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
                                           timeout: .milliseconds(1), voiceTimeout: .milliseconds(100))
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        let task = Task { try await service.answerVoice("Bonjour", conversationID: id) }
        await waitUntil { client.isWaiting }
        do { _ = try await task.value; XCTFail("Voice deadline") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .voiceTimeout) }
        client.release()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(try service.pendingConversations().isEmpty)
        service.endVoiceConversation(id)
    }

    func testLiveVoiceConversationExcludesOtherRequestsAndNeverNeedsAnotherQueueSlot() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let service = SiriAssistantService(persistence: memory.persistence, client: client)
        let selected = profile()
        do { _ = try service.beginVoiceConversation(); XCTFail("Consent") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .disabled) }
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let existing = (0..<(SiriAssistantService.maximumPending - 1)).map { _ in Conversation(serverID: selected.id, model: selected.model) }
        memory.values[SiriAssistantService.pendingAccount] = try JSONEncoder().encode(existing)
        let id = try service.beginVoiceConversation()
        XCTAssertThrowsError(try service.beginVoiceConversation()) { error in
            XCTAssertEqual(error as? SiriAssistantError, .busy)
        }
        do { _ = try await service.answer("Concurrent Siri request"); XCTFail("One session") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .busy) }
        for index in 0..<SiriAssistantService.maximumVoiceTurns {
            _ = try await service.answerVoice("Tour \(index)", conversationID: id)
        }
        XCTAssertEqual(try service.pendingConversations().count, SiriAssistantService.maximumPending)
        do { _ = try await service.answerVoice("Un tour de trop", conversationID: id); XCTFail("Bounded conversation") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .voiceContextFull) }
        XCTAssertEqual(client.calls, SiriAssistantService.maximumVoiceTurns)
        service.endVoiceConversation(id)
        XCTAssertEqual(try service.pendingConversationsForImport().last?.messages.count, SiriAssistantService.maximumVoiceTurns * 2)
    }

    func testBackgroundVoiceSearchKeepsOriginalQuestionAndImportsEvidence() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch()
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            webSearch: web, voiceWebSearchMode: { .always })
        var selected = profile()
        selected.systemInstruction = "Instruction privée du modèle"
        try service.configure(profile: selected, model: selected.model, key: "fixture-private-key", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        let question = "Quelle est la météo à Paris ?"
        var progress: [Bool] = []
        var traces: [WebResearchTrace] = []
        _ = try await service.answerVoice(question, conversationID: id, onWebSearchProgress: { progress.append($0) },
            onWebResearchTrace: { traces.append($0) })
        XCTAssertEqual(progress, [true, false])
        XCTAssertEqual(web.queries, [question], "Search receives only the current question")
        XCTAssertEqual(client.calls, 1)
        XCTAssertEqual(client.messages.count, 1)
        XCTAssertTrue(client.messages[0].text.hasPrefix(question + "\n\n"))
        XCTAssertTrue(client.messages[0].text.contains("UNTRUSTED_WEB_DATA_JSON"))
        XCTAssertTrue(client.instructions.hasPrefix("Instruction privée du modèle"))
        XCTAssertTrue(client.instructions.contains(HybridWebResearch.evidenceInstructions))
        let queued = try XCTUnwrap(service.pendingConversations().first)
        XCTAssertEqual(queued.messages[0].text, question)
        XCTAssertEqual(queued.messages[0].isVoiceRequest, true)
        XCTAssertEqual(queued.messages[0].webSearchRequested, true)
        XCTAssertEqual(queued.messages[1].webContext?.sources, web.context.sources)
        XCTAssertNil(queued.messages[1].reasoning)
        let trace = try XCTUnwrap(queued.messages[1].webResearchTrace)
        XCTAssertEqual(trace, traces.last)
        XCTAssertEqual(trace.state, .completed)
        XCTAssertEqual(trace.calls.first?.origin, .eudes)
        XCTAssertEqual(trace.calls.first?.tool, .webSearch)
        XCTAssertEqual(trace.calls.first?.state, .succeeded)
        XCTAssertTrue(traces.contains { $0.calls.contains { $0.state == .running } })
        XCTAssertEqual(service.lastWebResearchTrace, trace)
        service.endVoiceConversation(id)
        XCTAssertEqual(try service.pendingConversationsForImport().first?.messages[1].webContext?.sources, web.context.sources)
        XCTAssertEqual(try service.pendingConversationsForImport().first?.messages[1].webResearchTrace, trace)
    }

    func testBackgroundVoiceOnRequestSearchIsPerTurnAndFollowupRetainsEvidence() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch()
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            webSearch: web, voiceWebSearchMode: { .onRequest })
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        let original = "Cherche sur Internet la météo."
        _ = try await service.answerVoice(original, conversationID: id)
        _ = try await service.answerVoice("Et demain ?", conversationID: id)
        XCTAssertEqual(web.queries, [original])
        XCTAssertEqual(client.calls, 2)
        XCTAssertEqual(client.messages.count, 3)
        XCTAssertTrue(client.messages[0].text.hasPrefix(original))
        XCTAssertTrue(client.messages[0].text.contains("https://example.com/weather"))
        XCTAssertEqual(client.messages.last?.text, "Et demain ?")
        XCTAssertTrue(client.instructions.contains(HybridWebResearch.evidenceInstructions), "Earlier evidence keeps its synthesis and trust instructions")
        let messages = try XCTUnwrap(service.pendingConversations().first).messages
        XCTAssertEqual(messages.map(\.text), [original, "Réponse finale", "Et demain ?", "Réponse finale"])
        XCTAssertNotNil(messages[1].webContext)
        XCTAssertNil(messages[3].webContext)
        XCTAssertEqual(messages[2].isVoiceRequest, true)
        XCTAssertNil(messages[2].webSearchRequested)
        service.endVoiceConversation(id)
    }

    func testHybridVoiceResearchAndFinalSynthesisBothReceiveConversationContext() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch()
        let research = SiriResearchModel()
        research.turns = [
            WebResearchTurn(calls: [WebToolCall(id: "search-lyon", name: "web_search",
                arguments: #"{"query":"musée des Confluences Lyon horaires samedi transports"}"#)]),
            WebResearchTurn(calls: [])
        ]
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            webSearch: web, webResearchModel: research, voiceWebSearchMode: { .onRequest })
        var selected = profile()
        selected.systemInstruction = "Réponds en français, en tenant compte de mes contraintes."
        let voiceInstruction = "Answer briefly in the language of the request."
        try service.configure(profile: selected, model: selected.model, key: "fixture-only", maxTokens: nil,
                              voiceInstruction: voiceInstruction)
        let id = try service.beginVoiceConversation()
        let original = "Je veux visiter le musée des Confluences à Lyon samedi, sans voiture."
        _ = try await service.answerVoice(original, conversationID: id)
        let followup = "Cherche sur Internet ses horaires et comment m’y rendre."
        var progress: [Bool] = []
        _ = try await service.answerVoice(followup, conversationID: id,
            onWebSearchProgress: { progress.append($0) })

        XCTAssertEqual(research.requests.count, 2)
        XCTAssertEqual(research.instructions.count, 2)
        XCTAssertTrue(research.instructions.allSatisfy { $0.contains(voiceInstruction) },
                      "Research planning must receive the same voice policy as final synthesis")
        XCTAssertTrue(client.instructions.hasSuffix(voiceInstruction))
        XCTAssertTrue(client.instructions.contains(selected.effectiveInstruction))
        XCTAssertEqual(research.requests[0].map(\.text), [original, "Réponse finale", followup])
        XCTAssertEqual(research.requests[1], research.requests[0], "Tool results accompany the unchanged conversation")
        XCTAssertTrue(research.exchanges[0].isEmpty)
        let toolOutput = try XCTUnwrap(research.exchanges[1].first?.outputs.first)
        XCTAssertEqual(toolOutput.callID, "search-lyon")
        XCTAssertTrue(toolOutput.text.contains(web.context.sources[0].excerpt))
        XCTAssertEqual(web.queries, ["musée des Confluences Lyon horaires samedi transports"])
        XCTAssertEqual(client.messages.count, 3)
        XCTAssertEqual(client.messages[0].text, original)
        XCTAssertEqual(client.messages[1].text, "Réponse finale")
        XCTAssertTrue(client.messages[2].text.hasPrefix(followup + "\n\n"))
        XCTAssertTrue(client.messages[2].text.contains(web.context.sources[0].url.absoluteString))
        XCTAssertTrue(client.instructions.contains(HybridWebResearch.evidenceInstructions))
        XCTAssertEqual(progress, [true, false])
        let stored = try XCTUnwrap(service.pendingConversations().first)
        XCTAssertEqual(stored.messages[2].text, followup, "Research data does not replace or mutate the user's message")
        XCTAssertEqual(stored.messages[3].webContext?.sources, web.context.sources)
        let trace = try XCTUnwrap(stored.messages[3].webResearchTrace)
        XCTAssertTrue(trace.toolsOffered)
        XCTAssertEqual(trace.state, .completed)
        XCTAssertEqual(trace.calls.first?.origin, .model)
        XCTAssertEqual(trace.calls.first?.query, "musée des Confluences Lyon horaires samedi transports")
        XCTAssertEqual(trace.calls.first?.state, .succeeded)
        service.endVoiceConversation(id)
    }

    func testVoiceResearchUsesConfiguredSharedToolBudget() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch()
        let research = SiriResearchModel()
        research.turns = [WebResearchTurn(calls: [
            WebToolCall(id: "first", name: "web_search", arguments: #"{"query":"première recherche"}"#),
            WebToolCall(id: "second", name: "web_search", arguments: #"{"query":"seconde recherche"}"#)
        ])]
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            webSearch: web, webResearchModel: research, voiceWebSearchMode: { .always },
            webToolCallLimit: { 1 })
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "fixture-only", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        _ = try await service.answerVoice("Compare les options", conversationID: id)
        XCTAssertEqual(web.queries, ["première recherche"])
        let trace = try XCTUnwrap(service.lastWebResearchTrace)
        XCTAssertEqual(trace.maximumToolCalls, 1)
        XCTAssertEqual(trace.budgetExhausted, true)
        XCTAssertEqual(trace.calls.filter { $0.startedAt != nil }.count, 1)
        XCTAssertTrue(client.instructions.contains(HybridWebResearch.evidenceInstructions))
        service.endVoiceConversation(id)
    }

    func testHybridVoiceModelCanChooseNoSearchAndPlannerTextIsNotSpoken() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch()
        let research = SiriResearchModel()
        research.turns = [WebResearchTurn(calls: [], text: "Plan interne à ne pas prononcer")]
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            webSearch: web, webResearchModel: research, voiceWebSearchMode: { .always })
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        var progress: [Bool] = []
        var traces: [WebResearchTrace] = []
        let answer = try await service.answerVoice("Bonjour", conversationID: id,
            onWebSearchProgress: { progress.append($0) }, onWebResearchTrace: { traces.append($0) })

        XCTAssertEqual(answer, "Réponse finale")
        XCTAssertEqual(research.requests.count, 1)
        XCTAssertTrue(web.queries.isEmpty)
        XCTAssertEqual(client.messages.map(\.text), ["Bonjour"])
        XCTAssertEqual(progress, [true, false])
        XCTAssertNil(try service.pendingConversations().first?.messages.last?.webContext)
        let trace = try XCTUnwrap(service.pendingConversations().first?.messages.last?.webResearchTrace)
        XCTAssertTrue(trace.toolsOffered)
        XCTAssertEqual(trace.state, .completed)
        XCTAssertTrue(trace.calls.isEmpty)
        XCTAssertEqual(trace, traces.last)
        XCTAssertFalse(traces.contains { $0.calls.contains { $0.state == .running } })
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(trace), as: UTF8.self).contains("Plan interne"))
        service.endVoiceConversation(id)
    }

    func testCancelledHybridVoicePlannerKeepsOnlyTerminalDiagnosticAndIgnoresLateResults() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch()
        let research = SiriResearchModel()
        research.suspended = true
        research.turns = [WebResearchTurn(calls: [WebToolCall(id: "late-search", name: "web_search",
            arguments: #"{"query":"should never leave the device"}"#)])]
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            webSearch: web, webResearchModel: research, voiceWebSearchMode: { .always })
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        var progress: [Bool] = []
        var traces: [WebResearchTrace] = []
        let task = Task {
            try await service.answerVoice("Question annulée", conversationID: id,
                onWebSearchProgress: { progress.append($0) }, onWebResearchTrace: { traces.append($0) })
        }
        await waitUntil { research.isWaiting }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must end the voice turn") }
        catch { XCTAssertTrue(error is CancellationError) }
        let traceCount = traces.count
        XCTAssertEqual(traces.last?.state, .cancelled)
        research.release()
        for _ in 0..<30 { await Task.yield() }

        XCTAssertTrue(web.queries.isEmpty)
        XCTAssertEqual(client.calls, 0)
        let diagnostic = try XCTUnwrap(service.pendingConversations().first)
        XCTAssertTrue(diagnostic.messages.allSatisfy { $0.state == .interrupted })
        XCTAssertEqual(diagnostic.messages.last?.webResearchTrace, traces.last)
        XCTAssertEqual(traces.count, traceCount, "Late planner completion cannot replace cancellation")
        XCTAssertEqual(progress, [true, false])
        service.endVoiceConversation(id)
    }

    func testDisabledVoiceAndTextOnlySiriNeverSearch() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch()
        var mode = VoiceWebSearchMode.disabled
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            webSearch: web, voiceWebSearchMode: { mode })
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        _ = try await service.answerVoice("Cherche sur Internet la météo.", conversationID: id)
        service.endVoiceConversation(id)
        mode = .always
        _ = try await service.answer("Cherche sur Internet les horaires.")
        XCTAssertTrue(web.queries.isEmpty, "Always applies to the voice assistant, not the separate text-only Siri action")
        XCTAssertEqual(client.messages.map(\.text), ["Cherche sur Internet les horaires."])
        let conversations = try service.pendingConversations()
        XCTAssertEqual(conversations.first?.messages.first?.isVoiceRequest, true)
        XCTAssertNil(conversations.last?.messages.first?.isVoiceRequest)
        XCTAssertTrue(conversations.flatMap(\.messages).allSatisfy { $0.webContext == nil })
    }

    func testVoiceSearchFailureNeverGeneratesOrPersistsAnUnsourcedAnswer() async throws {
        for (failure, expected) in [(WebSearchError.blocked, SiriAssistantError.webSearchBlocked), (.networkUnavailable, .webSearchFailed)] {
            let memory = SiriMemory()
            let client = SiriClient()
            let web = SiriWebSearch(); web.failure = failure
            let service = SiriAssistantService(persistence: memory.persistence, client: client,
                webSearch: web, voiceWebSearchMode: { .always })
            let selected = profile()
            try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
            let id = try service.beginVoiceConversation()
            var progress: [Bool] = []
            var traces: [WebResearchTrace] = []
            do {
                _ = try await service.answerVoice("Question privée", conversationID: id, onWebSearchProgress: { progress.append($0) },
                    onWebResearchTrace: { traces.append($0) })
                XCTFail("Expected search failure")
            }
            catch { XCTAssertEqual(error as? SiriAssistantError, expected) }
            XCTAssertEqual(progress, [true, false])
            XCTAssertEqual(client.calls, 0)
            let diagnostic = try XCTUnwrap(service.pendingConversations().first)
            XCTAssertEqual(diagnostic.messages.count, 2)
            XCTAssertTrue(diagnostic.messages.allSatisfy { $0.state == .failed && $0.webContext == nil })
            XCTAssertEqual(diagnostic.messages.last?.webResearchTrace, traces.last)
            XCTAssertEqual(traces.last?.state, .failed)
            XCTAssertEqual(traces.last?.calls.last?.state, .failed)
            XCTAssertEqual(service.lastWebResearchTrace, traces.last)
            web.failure = nil
            _ = try await service.answerVoice("Nouvelle question", conversationID: id)
            XCTAssertEqual(client.messages.count, 1, "The failed diagnostic turn stays out of model context")
            XCTAssertTrue(client.messages[0].text.hasPrefix("Nouvelle question"))
            XCTAssertFalse(String(localized: expected.localizedStringResource).contains("Question privée"))
            service.endVoiceConversation(id)
        }
    }

    func testVoiceDeadlineIncludesSearchAndDiscardsLateSearchResult() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch(); web.suspended = true
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            voiceTimeout: .milliseconds(100), webSearch: web, voiceWebSearchMode: { .always })
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        var progress: [Bool] = []
        var traces: [WebResearchTrace] = []
        let task = Task {
            try await service.answerVoice("Question lente", conversationID: id, onWebSearchProgress: { progress.append($0) },
                onWebResearchTrace: { traces.append($0) })
        }
        await waitUntil { web.isWaiting }
        XCTAssertEqual(progress, [true])
        do { _ = try await task.value; XCTFail("The voice deadline includes Web search") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .voiceTimeout) }
        XCTAssertEqual(progress, [true, false], "The deadline resets progress without waiting for the network")
        let traceCount = traces.count
        XCTAssertEqual(traces.last?.state, .failed)
        XCTAssertEqual(traces.last?.calls.last?.state, .failed)
        web.release()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(progress, [true, false], "A late search result cannot publish more progress")
        XCTAssertEqual(client.calls, 0)
        let diagnostic = try XCTUnwrap(service.pendingConversations().first)
        XCTAssertTrue(diagnostic.messages.allSatisfy { $0.state == .failed })
        XCTAssertEqual(diagnostic.messages.last?.webResearchTrace, traces.last)
        XCTAssertEqual(traces.count, traceCount)
        service.endVoiceConversation(id)
    }

    func testVoiceSearchStopAndRevocationPreventLateInference() async throws {
        for revoke in [false, true] {
            let memory = SiriMemory()
            let client = SiriClient()
            let web = SiriWebSearch(); web.suspended = true
            let service = SiriAssistantService(persistence: memory.persistence, client: client,
                webSearch: web, voiceWebSearchMode: { .always })
            let selected = profile()
            try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
            let id = try service.beginVoiceConversation()
            let task = Task { try await service.answerVoice("Question à annuler", conversationID: id) }
            await waitUntil { web.isWaiting }
            if revoke { try service.disable() } else { service.endVoiceConversation(id) }
            do { _ = try await task.value; XCTFail("Cancelled or revoked search") }
            catch {
                if revoke { XCTAssertEqual(error as? SiriAssistantError, .disabled) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            web.release()
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(client.calls, 0)
            if revoke {
                XCTAssertTrue(try service.pendingConversations().isEmpty, "Revocation prevents diagnostic writes too")
            } else {
                let diagnostic = try XCTUnwrap(service.pendingConversations().first)
                XCTAssertTrue(diagnostic.messages.allSatisfy { $0.state == .interrupted })
                XCTAssertEqual(diagnostic.messages.last?.webResearchTrace?.state, .cancelled)
                XCTAssertEqual(diagnostic.messages.last?.webResearchTrace?.calls.last?.state, .cancelled)
            }
        }
    }

    func testVoiceSearchModeChangeBeforeInferenceRejectsFetchedEvidence() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch(); web.suspended = true
        var mode = VoiceWebSearchMode.always
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            webSearch: web, voiceWebSearchMode: { mode })
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        let task = Task { try await service.answerVoice("Question", conversationID: id) }
        await waitUntil { web.isWaiting }
        mode = .disabled
        web.release()
        do { _ = try await task.value; XCTFail("Changed search preference") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .configurationChanged) }
        XCTAssertEqual(client.calls, 0)
        XCTAssertTrue(try service.pendingConversations().isEmpty)
        service.endVoiceConversation(id)
    }

    func testVoiceEvidenceRespectsKnownBudgetAndStoredConversationLimit() async throws {
        for oversizedEvidence in [false, true] {
            let memory = SiriMemory()
            let client = SiriClient()
            let web = SiriWebSearch()
            var selected = profile()
            if oversizedEvidence { web.context.sources[0].excerpt = String(repeating: "x", count: SiriAssistantService.maximumVoiceConversationBytes) }
            else { selected.setContextBudget(300, model: selected.model) }
            let service = SiriAssistantService(persistence: memory.persistence, client: client,
                webSearch: web, voiceWebSearchMode: { .always })
            try service.configure(profile: selected, model: selected.model, key: "", maxTokens: 50,
                                  voiceInstruction: "Be brief.")
            let id = try service.beginVoiceConversation()
            do { _ = try await service.answerVoice("Météo ?", conversationID: id); XCTFail("Evidence exceeds context limit") }
            catch { XCTAssertEqual(error as? SiriAssistantError, .voiceContextFull) }
            XCTAssertEqual(web.queries, ["Météo ?"], "Short original question fits before evidence is fetched")
            XCTAssertEqual(client.calls, 0)
            let diagnostic = try XCTUnwrap(service.pendingConversations().first)
            XCTAssertTrue(diagnostic.messages.allSatisfy { $0.state == .failed && $0.webContext == nil })
            XCTAssertEqual(diagnostic.messages.last?.webResearchTrace?.state, .completed)
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(diagnostic).count,
                                     SiriAssistantService.maximumVoiceConversationBytes)
            service.endVoiceConversation(id)
        }
    }

    func testFailedVoiceTraceRemainsAvailableWhenDiagnosticStorageFails() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch(); web.failure = .networkUnavailable
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            webSearch: web, voiceWebSearchMode: { .always })
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        memory.failWrites = true
        do { _ = try await service.answerVoice("Question", conversationID: id); XCTFail("Expected search failure") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .webSearchFailed, "Storage must not replace the original error") }
        XCTAssertTrue(try service.pendingConversations().isEmpty)
        XCTAssertEqual(service.lastWebResearchTrace?.state, .failed)
        XCTAssertEqual(service.lastWebResearchTrace?.calls.first?.state, .failed)
        service.endVoiceConversation(id)
    }

    func testFailedVoiceTraceIsRecoverableAfterRestartAndNeverEntersTheModelContext() async throws {
        let memory = SiriMemory()
        let client = SiriClient()
        let web = SiriWebSearch(); web.failure = .blocked
        let service = SiriAssistantService(persistence: memory.persistence, client: client,
            webSearch: web, voiceWebSearchMode: { .always })
        let selected = profile()
        try service.configure(profile: selected, model: selected.model, key: "fixture-private-key", maxTokens: nil)
        let id = try service.beginVoiceConversation()
        do { _ = try await service.answerVoice("Horaires ?", conversationID: id); XCTFail("Expected search failure") }
        catch { XCTAssertEqual(error as? SiriAssistantError, .webSearchBlocked) }
        XCTAssertTrue(try service.pendingConversationsForImport().isEmpty, "The running conversation remains held")
        let restored = SiriAssistantService(persistence: memory.persistence, client: client)
        let imported = try XCTUnwrap(restored.pendingConversationsForImport().first)
        XCTAssertEqual(imported.id, id)
        XCTAssertTrue(imported.messages.allSatisfy { $0.state == .failed })
        XCTAssertEqual(imported.messages.last?.webResearchTrace?.state, .failed)
        let encoded = try JSONEncoder().encode(imported)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fixture-private-key"))
        XCTAssertLessThanOrEqual(encoded.count, SiriAssistantService.maximumVoiceConversationBytes)
        service.endVoiceConversation(id)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class SiriResearchModel: WebResearchModelClient {
    var turns: [WebResearchTurn] = []
    var requests: [[ChatMessage]] = []
    var instructions: [String] = []
    var exchanges: [[WebToolExchange]] = []
    var suspended = false
    var failure: Error?
    var isWaiting: Bool { continuation != nil }
    private var continuation: CheckedContinuation<Void, Never>?

    func turn(profile: ServerProfile, key: String, model: String,
              messages: [ChatMessage], systemPrompt: String, temperature: Double,
              maxTokens: Int?, exchanges: [WebToolExchange]) async throws -> WebResearchTurn {
        requests.append(messages)
        instructions.append(systemPrompt)
        self.exchanges.append(exchanges)
        if suspended { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        return turns.isEmpty ? WebResearchTurn(calls: []) : turns.removeFirst()
    }

    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class SiriWebSearch: WebSearching {
    var queries: [String] = []
    var context = WebSearchContext(query: "fixture", fetchedAt: Date(timeIntervalSince1970: 0), sources: [
        WebSource(url: URL(string: "https://example.com/weather")!, title: "Weather fixture", excerpt: "Prévision fictive utilisée uniquement par les tests.", kind: .searchSnippet)
    ])
    var failure: WebSearchError?
    var suspended = false
    var isWaiting: Bool { continuation != nil }
    private var continuation: CheckedContinuation<Void, Never>?

    func search(query: String) async throws -> WebSearchContext {
        queries.append(query)
        if suspended { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        var result = context
        result.query = query
        return result
    }

    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class SiriMemory {
    var values: [String: Data] = [:]
    var writes = 0
    var failWrites = false
    var failDeletes = false
    var revoked = false
    var persistence: SiriAssistantPersistence {
        .init(read: { self.values[$0] }, write: {
            if self.failWrites { throw SiriAssistantError.storage }
            self.writes += 1
            self.values[$0] = $1
        }, delete: {
            if self.failDeletes { throw SiriAssistantError.storage }
            self.values.removeValue(forKey: $0)
        }, isRevoked: { self.revoked }, setRevoked: { self.revoked = $0 })
    }
}

private final class SiriClient: EudesAPIClient {
    @MainActor var calls = 0
    @MainActor var model = ""
    @MainActor var key = ""
    @MainActor var messages: [ChatMessage] = []
    @MainActor var instructions = ""
    @MainActor var outputLimit: Int?
    @MainActor var reportedUsage: TokenUsage?
    @MainActor var suspended = false
    @MainActor var failure: Error?
    @MainActor var isWaiting: Bool { continuation != nil }
    @MainActor private var continuation: CheckedContinuation<Void, Never>?

    func models(profile: ServerProfile, key: String) async throws -> [String] { [profile.model] }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        await record(key: key, model: model, messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens)
        await wait()
        if let failure = await failure { throw failure }
        await onText("Réponse finale")
    }
    func streamWithReasoning(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void,
                onReasoning: @escaping @MainActor (String) -> Void, onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws {
        await onReasoning("Raisonnement non destiné à Siri")
        try await stream(profile: profile, key: key, model: model, messages: messages,
                         systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens, onText: onText)
        if let usage = await reportedUsage { await onUsage(usage) }
    }
    @MainActor private func record(key: String, model: String, messages: [ChatMessage], systemPrompt: String, maxTokens: Int?) {
        calls += 1
        self.key = key; self.model = model; self.messages = messages
        instructions = systemPrompt; outputLimit = maxTokens
    }
    @MainActor private func wait() async {
        if suspended { await withCheckedContinuation { continuation = $0 } }
    }
    @MainActor func release() { continuation?.resume(); continuation = nil }
}
