import XCTest
import UIKit
import SwiftUI
@testable import Eudes

/// Holds an authorized provider response so tests can dismiss while no thumbnail exists.
private final class DeferredClipboardProvider: @unchecked Sendable {
    let provider = NSItemProvider()
    private let lock = NSLock()
    private var completion: ((Data?, Error?) -> Void)?

    init() {
        provider.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .all) { [weak self] completion in
            guard let self else { return nil }
            self.lock.lock()
            self.completion = completion
            self.lock.unlock()
            return nil
        }
    }

    private var hasRequest: Bool {
        lock.lock(); defer { lock.unlock() }
        return completion != nil
    }

    @MainActor
    func waitForRequest() async throws {
        for _ in 0..<100 {
            if hasRequest { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The preview did not begin loading the supplied image provider")
    }

    func finish(data: Data? = nil, error: Error? = nil) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(data, error)
    }
}

final class PrivateStorageTests: XCTestCase {

    func testWebCitationPresentationHidesValidProseReferencesWithoutChangingSavedText() throws {
        let raw = "Le départ est confirmé. [1]\nDeux sources concordent. [1][2]\nUne autre précision est disponible. [2, 3]\nLa synthèse est terminée. [3]"
        let message = webCitationMessage(raw)
        XCTAssertEqual(message.presentationText,
                       "Le départ est confirmé.\nDeux sources concordent.\nUne autre précision est disponible.\nLa synthèse est terminée.")
        XCTAssertEqual(message.text, raw)
        let encoded = try JSONEncoder().encode(message)
        let restored = try JSONDecoder().decode(ChatMessage.self, from: encoded)
        XCTAssertEqual(restored.text, raw)
        XCTAssertEqual(restored.presentationText, message.presentationText)
        let conversation = Conversation(serverID: UUID(), model: "fixture", messages: [message])
        XCTAssertEqual(conversation.modelMessages.first?.text, raw)
    }

    func testWebCitationPresentationRequiresAssistantEvidenceAndValidSourceIdentifiers() {
        let raw = "Cette phrase est sourcée. [1]\nL’année reste [2026]. Cette référence est inconnue. [4]"
        var message = webCitationMessage(raw)
        XCTAssertEqual(message.presentationText,
                       "Cette phrase est sourcée.\nL’année reste [2026]. Cette référence est inconnue. [4]")
        message.role = .user
        XCTAssertEqual(message.presentationText, raw)
        message.role = .assistant
        message.webContext = nil
        XCTAssertEqual(message.presentationText, raw)
        message.webContext = WebSearchContext(query: "fixture", fetchedAt: Date(), sources: [])
        XCTAssertEqual(message.presentationText, raw)
    }

    func testWebCitationPresentationPreservesFencedInlineAndIndentedCode() {
        let raw = """
        Une phrase sourcée. [1]
        ````swift
        let exemple = "Une phrase sourcée. [1]"
        ```
        let autre = "Une phrase sourcée. [2]"
        ````
        Du code `une phrase. [1]` et ``une phrase. [2]``.
            Du code indenté. [1]
        ~~~text
        Une phrase sourcée. [1]
        ~~~
        Cette phrase termine. [2]
        """
        let expected = "Une phrase sourcée.\n" + raw.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            .replacingOccurrences(of: "Cette phrase termine. [2]", with: "Cette phrase termine.")
        XCTAssertEqual(webCitationMessage(raw).presentationText, expected)
        let unfinished = "Début du code `plusieurs mots. [1]\nEncore du code. [2]"
        XCTAssertEqual(webCitationMessage(unfinished).presentationText, unfinished)
    }

    func testWebCitationPresentationPreservesMathArraysEscapesAndLinks() {
        let raw = #"""
        Une valeur réelle vaut 12 et une année vaut 2026.
        La valeur x[1] reste un indice.
        Voici un vecteur [1, 2].
        Les valeurs sont x = [1].
        Une formule $x = [1]$ et une formule \(x = [2]\).
        $$
        Le vecteur vaut [1, 2]
        $$
        Une référence échappée \[1].
        Une référence liée [1](https://example.org/source).
        [Une référence [1]](https://example.org/source)
        Une phrase sourcée. [3]
        """#
        XCTAssertEqual(webCitationMessage(raw).presentationText,
                       raw.replacingOccurrences(of: "Une phrase sourcée. [3]", with: "Une phrase sourcée."))
    }

    func testWebCitationPresentationPreservesMarkdownReferenceLinksAndAmbiguousLabels() {
        let raw = "Une référence Markdown. [1][2]\n\n[2]: https://example.org/source\n\nRéponse [3]\n[1]\nUne phrase cite. [3]"
        XCTAssertEqual(webCitationMessage(raw).presentationText,
                       "Une référence Markdown. [1][2]\n\n[2]: https://example.org/source\n\nRéponse [3]\n[1]\nUne phrase cite.")
    }

    func testWebCitationPresentationPreservesAmbiguousBracketedValues() {
        let raw = "Les valeurs retenues sont [1, 2].\nLa solution est [1].\nUne précision ambiguë [3]."
        XCTAssertEqual(webCitationMessage(raw).presentationText, raw)
    }

    private func webCitationMessage(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, webContext: WebSearchContext(query: "fixture", fetchedAt: Date(),
            sources: (1...3).map { WebSource(url: URL(string: "https://example.org/\($0)")!,
                                           title: "Source \($0)", excerpt: "Extrait", kind: .searchSnippet) }))
    }

    func testCollapsedHistoryKeepsCountsButExcludesHiddenChatsFromBulkSelection() {
        let folder = ConversationFolder(name: "Travail")
        let recent = Conversation(title: "Récent", serverID: UUID(), model: "test")
        var filed = Conversation(title: "Classé", serverID: UUID(), model: "test")
        filed.folderID = folder.id
        let snapshot = HistoryMenuSnapshot(folders: [folder], conversations: [recent, filed],
                                           recentsExpanded: false)
        XCTAssertEqual(snapshot.recentConversations.map(\.id), [recent.id])
        XCTAssertEqual(snapshot.matchingCount, 2)
        XCTAssertTrue(snapshot.visibleConversationIDs.isEmpty)
        XCTAssertFalse(snapshot.recentsExpanded)
        guard case .folder(_, let count, let expanded) = snapshot.folderEntries.first else {
            return XCTFail("The closed folder must remain visible")
        }
        XCTAssertEqual(count, 1)
        XCTAssertFalse(expanded)
    }

    func testHistorySearchFindsMessageContentsInsideBothCollapsedGroups() {
        let folder = ConversationFolder(name: "Travail")
        let other = ConversationFolder(name: "Autre")
        let serverID = UUID()
        let recent = Conversation(title: "Voyage", serverID: serverID, model: "test",
                                  messages: [ChatMessage(role: .assistant, text: "Un passage secret")])
        var filed = Conversation(title: "Secret classé", serverID: serverID, model: "test")
        filed.folderID = folder.id
        let unrelated = Conversation(title: "Sans rapport", serverID: serverID, model: "test")
        let snapshot = HistoryMenuSnapshot(folders: [folder, other],
                                           conversations: [recent, filed, unrelated],
                                           search: " secret ", recentsExpanded: false)
        XCTAssertTrue(snapshot.isSearching)
        XCTAssertTrue(snapshot.recentsExpanded)
        XCTAssertEqual(snapshot.visibleConversationIDs, [recent.id, filed.id])
        XCTAssertEqual(snapshot.folderEntries.count, 2) // matching folder + its chat
        XCTAssertEqual(snapshot.recentConversations.map(\.id), [recent.id])
        let cleared = HistoryMenuSnapshot(folders: [folder, other], conversations: [recent, filed],
                                          search: "", recentsExpanded: false)
        XCTAssertFalse(cleared.recentsExpanded)
        XCTAssertTrue(cleared.visibleConversationIDs.isEmpty)
    }

    func testHistoryRecentsKeepOrphansAndOlderChatsWithoutDuplicatingFiledConversations() {
        let folder = ConversationFolder(name: "Travail")
        let serverID = UUID()
        var orphan = Conversation(title: "Dossier absent", serverID: serverID, model: "test")
        orphan.folderID = UUID()
        orphan.updatedAt = Date(timeIntervalSince1970: 1)
        var filed = Conversation(title: "Classé", serverID: serverID, model: "test")
        filed.folderID = folder.id
        let recents = (1...200).map { index in
            var chat = Conversation(title: "Chat \(index)", serverID: serverID, model: "test")
            chat.updatedAt = Date(timeIntervalSince1970: Double(index + 1))
            return chat
        }
        let snapshot = HistoryMenuSnapshot(folders: [folder], conversations: recents + [orphan, filed],
                                           expandedFolderIDs: [folder.id])
        XCTAssertEqual(snapshot.recentConversations.count, 201)
        XCTAssertEqual(snapshot.recentConversations.first?.title, "Chat 200")
        XCTAssertEqual(snapshot.recentConversations.last?.id, orphan.id)
        XCTAssertFalse(snapshot.recentConversations.contains { $0.id == filed.id })
        XCTAssertEqual(snapshot.visibleConversationIDs.count, 202)
    }

    func testHistoryEmptySearchResultsDoNotShowUnrelatedFoldersOrChats() {
        let snapshot = HistoryMenuSnapshot(folders: [ConversationFolder(name: "Travail")],
            conversations: [Conversation(title: "Voyage", serverID: UUID(), model: "test")],
            search: "introuvable", recentsExpanded: false)
        XCTAssertTrue(snapshot.isSearching)
        XCTAssertEqual(snapshot.matchingCount, 0)
        XCTAssertTrue(snapshot.folderEntries.isEmpty)
        XCTAssertTrue(snapshot.recentConversations.isEmpty)
        XCTAssertTrue(snapshot.visibleConversationIDs.isEmpty)
    }

    @MainActor
    func testRecentDisclosurePreferencePersistsWithoutAffectingConversationData() throws {
        let suite = "EudesHistoryDisclosure." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let original = AppStore(storageDirectory: directory, defaults: defaults, readKey: { _ in "" })
        XCTAssertTrue(original.recentConversationsExpanded)
        original.setRecentConversationsExpanded(false)
        let reopened = AppStore(storageDirectory: directory, defaults: defaults, readKey: { _ in "" })
        XCTAssertFalse(reopened.recentConversationsExpanded)
        XCTAssertEqual(reopened.data.conversations, original.data.conversations)
        reopened.setRecentConversationsExpanded(true)
        XCTAssertEqual(defaults.object(forKey: "recentConversationsExpanded") as? Bool, true)
    }

    @MainActor
    func testFolderMigrationAndBulkOperationsPreserveConversations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesFolders." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }

        let profile = ServerProfile(name: "Fixture", baseURL: "https://example.invalid/v1", model: "alpha")
        let first = Conversation(serverID: profile.id, model: "alpha", messages: [ChatMessage(role: .user, text: "Un")])
        let second = Conversation(serverID: profile.id, model: "alpha", messages: [ChatMessage(role: .user, text: "Deux")])
        let third = Conversation(serverID: profile.id, model: "alpha", messages: [ChatMessage(role: .user, text: "Trois")])
        var legacy = AppData()
        legacy.servers = [profile]
        legacy.conversations = [first, second, third]
        legacy.selectedConversationID = first.id
        let encoded = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "folders")
        var conversations = try XCTUnwrap(object["conversations"] as? [[String: Any]])
        for index in conversations.indices { conversations[index].removeValue(forKey: "folderID") }
        object["conversations"] = conversations
        let oldData = try JSONDecoder().decode(AppData.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(oldData.folders)
        XCTAssertTrue(oldData.conversations.allSatisfy { $0.folderID == nil })

        let storage = try PrivateStorage(directory: directory)
        try storage.save(oldData)
        let store = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertNil(store.createFolder(name: "  \n"))
        let work = try XCTUnwrap(store.createFolder(name: "  Travail  "))
        let personal = try XCTUnwrap(store.createFolder(name: "Personnel"))
        XCTAssertTrue(store.moveConversations(ids: [first.id, second.id], to: work))
        XCTAssertFalse(store.moveConversations(ids: [third.id], to: UUID()))
        XCTAssertTrue(store.renameFolder(personal, name: "  Maison  "))

        let reopened = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(reopened.data.folders?.map(\.name), ["Travail", "Maison"])
        XCTAssertEqual(reopened.data.conversations.map(\.folderID), [work, work, nil])
        XCTAssertEqual(reopened.current?.id, first.id)
        XCTAssertEqual(reopened.data.conversations.map(\.messages), [first.messages, second.messages, third.messages])
        XCTAssertTrue(reopened.moveConversations(ids: [second.id], to: nil))
        XCTAssertTrue(reopened.deleteFolder(work))
        let afterDelete = try storage.load()
        XCTAssertEqual(afterDelete.folders?.map(\.name), ["Maison"])
        XCTAssertEqual(afterDelete.conversations.count, 3)
        XCTAssertTrue(afterDelete.conversations.allSatisfy { $0.folderID == nil })
        XCTAssertEqual(afterDelete.conversations.map(\.messages), [first.messages, second.messages, third.messages])
    }

    @MainActor
    func testFolderSaveFailureRollsBackChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesFolderWriteFailure." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let storage = try PrivateStorage(directory: directory)
        let profile = ServerProfile(name: "Fixture", baseURL: "https://example.invalid/v1", model: "alpha")
        let conversation = Conversation(serverID: profile.id, model: "alpha")
        var data = AppData(); data.servers = [profile]; data.conversations = [conversation]
        try storage.save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults)
        let folder = try XCTUnwrap(store.createFolder(name: "Travail"))

        let file = directory.appendingPathComponent("workspace.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(store.moveConversations(ids: [conversation.id], to: folder))
        XCTAssertNil(store.data.conversations.first?.folderID)
        XCTAssertFalse(store.renameFolder(folder, name: "Autre"))
        XCTAssertEqual(store.data.folders?.first?.name, "Travail")
        XCTAssertFalse(store.deleteFolder(folder))
        XCTAssertEqual(store.data.folders?.first?.id, folder)
        XCTAssertNil(store.createFolder(name: "Autre"))
        XCTAssertEqual(store.data.folders?.count, 1)
        XCTAssertTrue(try XCTUnwrap(store.notice).contains("n’a pas pu être confirmé"))
    }

    @MainActor
    func testInterruptedResponseKeepsKnownOrUnknownCause() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesInterruption." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "Fixture", baseURL: "https://example.invalid/v1", model: "alpha")
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
        let storage = try PrivateStorage(directory: directory); try storage.save(data)

        let client = BackgroundFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: client, readKey: { _ in "" })
        let sent = await store.sendChecked("Fictif")
        XCTAssertTrue(sent)
        for _ in 0..<1000 { if store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        store.stop(reason: .user)
        XCTAssertEqual(store.current?.messages.last?.state, .interrupted)
        XCTAssertEqual(store.current?.messages.last?.failureDetail, "La génération a été arrêtée avec le bouton Arrêter.")
        XCTAssertEqual(try storage.load().conversations.first?.messages.last?.failureDetail, store.current?.messages.last?.failureDetail)
        await client.complete()

        let cancelled = AppStore(storageDirectory: directory, defaults: defaults, client: CancelledGenerationFixture(), readKey: { _ in "" })
        cancelled.newConversation()
        let sentAgain = await cancelled.sendChecked("Autre question")
        XCTAssertTrue(sentAgain)
        for _ in 0..<1000 where cancelled.isGenerating { await Task.yield() }
        XCTAssertEqual(cancelled.current?.messages.last?.state, .interrupted)
        XCTAssertEqual(cancelled.current?.messages.last?.failureDetail, "La génération a été annulée. La cause exacte n’a pas été communiquée à Eudes.")

        var recovered = try storage.load()
        recovered.conversations[0].messages.append(ChatMessage(role: .assistant, text: "Partiel", state: .streaming))
        recovered.selectedConversationID = recovered.conversations[0].id
        try storage.save(recovered)
        let restarted = AppStore(storageDirectory: directory, defaults: defaults, client: CancelledGenerationFixture(), readKey: { _ in "" })
        XCTAssertEqual(restarted.current?.messages.last?.state, .interrupted)
        XCTAssertEqual(restarted.current?.messages.last?.failureDetail, "La génération précédente s’est arrêtée avant la fin. La cause exacte n’a pas été enregistrée.")
    }

    @MainActor
    func testFailureDetailStaysWithFailedResponseAndIsPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesFailureDetail." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let server = ServerProfile(name: "Fixture", baseURL: "https://example.invalid/v1", model: "alpha")
        var data = AppData(); data.servers = [server]; data.selectedServerID = server.id
        let storage = try PrivateStorage(directory: directory); try storage.save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: FailingShortcutFixture(), readKey: { _ in "" })
        let sent = await store.sendChecked("Question fictive"); XCTAssertTrue(sent)
        for _ in 0..<1000 where store.isGenerating { await Task.yield() }
        XCTAssertFalse(store.isGenerating)
        let first = try XCTUnwrap(store.current?.messages.last)
        XCTAssertEqual(first.state, .failed)
        XCTAssertTrue(try XCTUnwrap(first.failureDetail).contains("code réseau"))
        XCTAssertEqual(try storage.load().conversations.first?.messages.last?.failureDetail, first.failureDetail)
        let request = try LocalAPIClient.completionRequest(profile: server, key: "", model: "alpha",
            messages: store.current?.messages ?? [], systemPrompt: "", temperature: 0.7, maxTokens: nil)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("code réseau"))
        XCTAssertFalse(body.contains("failureDetail"))
        XCTAssertEqual(generationFailureDetail(EudesError.server(422)), "Le serveur a refusé la requête (HTTP 422). Vérifie les paramètres et le modèle choisis.")
        XCTAssertFalse(generationFailureDetail(EudesError.storage("secret-test" )).contains("secret-test"))
        XCTAssertFalse(generationFailureDetail(NSError(domain: "secret-test", code: 1)).contains("secret-test"))
        let encoded = try JSONEncoder().encode(first)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "failureDetail")
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: old)).failureDetail)
        await store.retryChecked()
        for _ in 0..<1000 where store.isGenerating { await Task.yield() }
        let retried = try XCTUnwrap(store.current?.messages.last)
        XCTAssertNotEqual(retried.id, first.id)
        XCTAssertEqual(retried.state, .failed)
        XCTAssertNotNil(retried.failureDetail)
    }

    @MainActor
    func testSavingServerSelectsItsModelWithoutLosingConversation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesServerSelection." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let first = ServerProfile(name: "Premier", baseURL: "https://example.invalid/v1", model: "alpha")
        var second = ServerProfile(name: "Second", baseURL: "https://example.org/v1", model: "beta")
        let messages = [ChatMessage(role: .user, text: "Contexte conservé"), ChatMessage(role: .assistant, text: "Réponse précédente")]
        let conversation = Conversation(serverID: first.id, model: "alpha", messages: messages)
        let other = Conversation(serverID: first.id, model: "alpha", messages: messages)
        var data = AppData(); data.servers = [first, second]; data.selectedServerID = first.id
        data.selectedConversationID = conversation.id; data.conversations = [conversation, other]
        data.draftModels = [second.id.uuidString: "ancien"]
        let storage = try PrivateStorage(directory: directory); try storage.save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults)
        second.model = "nouveau"
        try store.saveServer(second, key: "")
        XCTAssertEqual(store.current?.id, conversation.id)
        XCTAssertEqual(store.current?.serverID, second.id)
        XCTAssertEqual(store.currentModel, "nouveau")
        XCTAssertEqual(store.current?.messages, messages)
        XCTAssertEqual(store.data.conversations.first(where: { $0.id == other.id }), other)
        let reopened = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(reopened.current?.serverID, second.id)
        XCTAssertEqual(reopened.currentModel, "nouveau")
        XCTAssertEqual(reopened.current?.messages, messages)
        reopened.newConversation()
        XCTAssertEqual(reopened.currentModel, "nouveau")
    }

    @MainActor
    func testVoiceInstructionReachesBothRemoteProtocolsAndNeverLeaksIntoFollowingChat() async throws {
        for protocolKind in APIProtocol.allCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let suite = "EudesVoiceInstructionRouting." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
            var profile = ServerProfile(name: "Fixture", baseURL: "https://example.invalid/v1", model: "alpha")
            profile.protocolKind = protocolKind
            profile.systemInstruction = "Keep the server's domain expertise."
            var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
            data.maxTokens = 512
            try PrivateStorage(directory: directory).save(data)
            let fixture = ShortcutFixture()
            let store = AppStore(storageDirectory: directory, defaults: defaults, client: fixture,
                                 readKey: { _ in "" }, responseContinuation: NoResponseContinuation())
            _ = try await store.answerShortcut("Bonjour")
            let defaultPrompts = await fixture.prompts
            XCTAssertEqual(defaultPrompts.last, profile.effectiveInstruction + "\n\n" + VoiceResponseInstruction.defaultText)

            store.setVoiceResponseInstruction("  Answer briefly in my language.  ")
            _ = try await store.answerShortcut("Explique en détail, s’il te plaît")
            let voicePrompts = await fixture.prompts
            XCTAssertEqual(voicePrompts.last, profile.effectiveInstruction + "\n\nAnswer briefly in my language.")
            XCTAssertEqual(store.selectedServer?.effectiveInstruction, profile.effectiveInstruction)
            let limits = await fixture.outputLimits
            XCTAssertTrue(limits.allSatisfy { $0 == 512 }, "The global output setting must remain unchanged")

            let sent = await store.sendChecked("Cette demande est écrite")
            XCTAssertTrue(sent)
            for _ in 0..<1000 { if !store.isGenerating { break }; await Task.yield() }
            let finalPrompts = await fixture.prompts
            XCTAssertEqual(finalPrompts.last, profile.effectiveInstruction,
                           "A text follow-up in a voice conversation must not inherit the voice policy")
            XCTAssertEqual(store.current?.messages.last?.state, .complete)
            let requests = await fixture.requests
            XCTAssertEqual(requests.last?.map(\.text),
                           ["Explique en détail, s’il te plaît", "Réponse fictive", "Cette demande est écrite"])
        }
    }

    @MainActor
    func testAppleVoiceReplyReceivesCustomInstructionAndResetUsesDefault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesAppleVoiceInstruction." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let fixture = ShortcutFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(),
                             appleClient: fixture, appleAvailability: { .available },
                             readKey: { _ in XCTFail("Apple must not read API credentials"); return "" })
        store.selectServer(ServerProfile.appleID)
        store.setVoiceResponseInstruction("Speak one short sentence.")
        _ = try await store.answerShortcut("Bonjour")
        let customPrompts = await fixture.prompts
        XCTAssertEqual(customPrompts.last, "Speak one short sentence.")
        store.setVoiceResponseInstruction(VoiceResponseInstruction.defaultText)
        XCTAssertNil(defaults.object(forKey: VoiceResponseInstruction.preferenceKey))
        _ = try await store.answerShortcut("Bonjour encore")
        let resetPrompts = await fixture.prompts
        XCTAssertEqual(resetPrompts.last, VoiceResponseInstruction.defaultText)
    }

    @MainActor
    func testShortcutCreatesSeparatePersistedConversationsAndPreservesDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesShortcutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "Fictif", baseURL: "https://example.invalid/v1", model: "alpha")
        let existing = Conversation(title: "Ancienne conversation", serverID: profile.id, model: "alpha", messages: [ChatMessage(role: .user, text: "Ancien message")])
        let attachment = ImageAttachment(data: Data([1, 2, 3]))
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
        data.conversations = [existing]; data.selectedConversationID = existing.id; data.imageDraft = [attachment]
        try PrivateStorage(directory: directory).save(data)
        let fixture = ShortcutFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: fixture, readKey: { _ in "" })
        let firstAnswer = try await store.answerShortcut("Question Siri")
        XCTAssertEqual(firstAnswer, "Réponse fictive")
        let first = try XCTUnwrap(store.current)
        XCTAssertNotEqual(first.id, existing.id)
        XCTAssertEqual(first.messages.map(\.text), ["Question Siri", "Réponse fictive"])
        XCTAssertEqual(store.draftImages, [attachment])
        XCTAssertEqual(store.data.conversations.first(where: { $0.id == existing.id }), existing)
        let secondAnswer = try await store.answerShortcut("Deuxième question")
        XCTAssertEqual(secondAnswer, "Réponse fictive")
        XCTAssertEqual(store.data.conversations.count, 3)
        let sent = await fixture.requests
        XCTAssertEqual(sent.map { $0.map(\.text) }, [["Question Siri"], ["Deuxième question"]])
        XCTAssertEqual(try PrivateStorage(directory: directory).load().conversations.count, 3)
    }

    @MainActor
    func testShortcutFailurePreservesQuestionAndDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesShortcutFailure." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "Fictif", baseURL: "https://example.invalid/v1", model: "alpha")
        let attachment = ImageAttachment(data: Data([1, 2, 3]))
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id; data.imageDraft = [attachment]
        try PrivateStorage(directory: directory).save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: FailingShortcutFixture(), readKey: { _ in "" })
        do { _ = try await store.answerShortcut("Question fictive"); XCTFail("Expected failure") }
        catch EudesShortcutError.sendFailed { }
        XCTAssertEqual(store.current?.messages.first?.text, "Question fictive")
        XCTAssertEqual(store.current?.messages.last?.state, .failed)
        XCTAssertEqual(store.draftImages, [attachment])
        XCTAssertEqual(try PrivateStorage(directory: directory).load().conversations.count, 1)
    }

    @MainActor
    func testShortcutDoesNotInterruptActiveGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesShortcutBusy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "Fictif", baseURL: "https://example.invalid/v1", model: "alpha")
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
        try PrivateStorage(directory: directory).save(data)
        let fixture = BackgroundFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: fixture, readKey: { _ in "" })
        let first = Task { try await store.answerShortcut("Première question") }
        for _ in 0..<1000 { if await fixture.sends > 0 { break }; await Task.yield() }
        do { _ = try await store.answerShortcut("Question concurrente"); XCTFail("Expected busy") }
        catch EudesShortcutError.busy { }
        await fixture.complete()
        let reply = try await first.value
        XCTAssertEqual(reply, "Terminé")
        XCTAssertEqual(store.data.conversations.count, 1)
    }

    @MainActor
    func testCancellingOldShortcutDoesNotStopNewGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesShortcutCancel." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "Fictif", baseURL: "https://example.invalid/v1", model: "alpha")
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
        try PrivateStorage(directory: directory).save(data)
        let fixture = ShortcutCancellationFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: fixture, readKey: { _ in "" })
        let old = Task { try await store.answerShortcut("Première question") }
        for _ in 0..<1000 { if await fixture.count == 1 { break }; await Task.yield() }
        store.newConversation() // Interrupts the old request as navigation normally does.
        let latest = Task { try await store.answerShortcut("Deuxième question") }
        for _ in 0..<1000 { if await fixture.count == 2 { break }; await Task.yield() }
        old.cancel()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(store.isGenerating)
        await fixture.complete(0)
        do { _ = try await old.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        await fixture.complete(1)
        let answer = try await latest.value
        XCTAssertEqual(answer, "Réponse fictive")
        XCTAssertEqual(store.data.conversations.count, 2)
    }

    @MainActor
    func testAlreadyCancelledShortcutDoesNotCreateConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesShortcutPrecancel." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "Fictif", baseURL: "https://example.invalid/v1", model: "alpha")
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
        try PrivateStorage(directory: directory).save(data)
        let fixture = ShortcutFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: fixture, readKey: { _ in "" })
        let cancelled = Task { try await store.answerShortcut("Question annulée") }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(store.data.conversations.isEmpty)
        let sent = await fixture.requests
        XCTAssertTrue(sent.isEmpty)
    }

    @MainActor
    func testCompactionPreservesHistoryAndRetriesWithSummary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesCompactionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "Fictif", baseURL: "https://example.invalid/v1", model: "alpha")
        var conversation = Conversation(serverID: profile.id, model: "alpha")
        conversation.messages = [ChatMessage(role: .user, text: "Ancienne question"), ChatMessage(role: .assistant, text: "Ancienne réponse"), ChatMessage(role: .user, text: "Question récente"), ChatMessage(role: .assistant, text: "Réponse récente"), ChatMessage(role: .user, text: "Nouvelle question"), ChatMessage(role: .assistant, text: "", state: .failed)]
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
        data.conversations = [conversation]; data.selectedConversationID = conversation.id
        try PrivateStorage(directory: directory).save(data)
        let client = CompactionFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: client, readKey: { _ in "" })
        await store.compactContextAndRetry(conversationID: conversation.id)
        for _ in 0..<1000 where store.isGenerating { await Task.yield() }
        let current = try XCTUnwrap(store.current)
        XCTAssertEqual(current.contextSummary, "Résumé fictif")
        XCTAssertEqual(current.messages.prefix(5).map(\.text), conversation.messages.prefix(5).map(\.text))
        let sent = await client.lastMessages
        XCTAssertTrue(sent.first?.text.contains("Résumé fictif") == true)
        XCTAssertFalse(sent.contains(where: { $0.text == "Ancienne question" }))
        XCTAssertTrue(sent.contains(where: { $0.text == "Nouvelle question" }))
        XCTAssertEqual(try PrivateStorage(directory: directory).load().conversations.first?.contextSummary, "Résumé fictif")
    }

    @MainActor
    func testCopyControlsRenderWithCodeTextAndMarkdown() throws {
        let source = "# Exemple fictif\nUne **réponse** et une liste :\n- [x] Première étape\n> Citation fictive\n```swift\nlet valeur = 42\nprint(valeur)\n```\n```text\nTexte encadré\n  indentation conservée\n```"
        XCTAssertEqual(MessageCopyBlock.parse(source).filter { $0.language != nil }.count, 2)
        for dark in [false, true] {
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
                let renderer = ImageRenderer(content: MessageView(message: ChatMessage(role: .assistant, text: source), model: "fictif")
                    .padding(16).frame(width: 390).background(dark ? Color.black : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light))
                renderer.scale = 2
                guard let image = renderer.uiImage else { XCTFail("Missing message render"); return }
                let attachment = XCTAttachment(image: image)
                attachment.name = "copy120-" + (dark ? "dark" : "light")
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    func testServerModelSheetPreservesSelectionAndRenders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesCompactSheetTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let storage = try PrivateStorage(directory: directory)
        let server = ServerProfile(name: "Serveur fictif", baseURL: "https://example.invalid/v1", model: "alpha")
        var data = AppData(); data.servers = [server]; data.selectedServerID = server.id
        try storage.save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ModelFixtureAPI(models: ["alpha", "beta"]), readKey: { _ in "" })
        await store.loadModels()
        store.selectDraftModel("beta")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var addCalls = 0
        for started in [false, true] {
            if started {
                let sent = await store.sendChecked("Message fictif")
                XCTAssertTrue(sent)
                for _ in 0..<100 where store.isGenerating { await Task.yield() }
                store.selectDraftModel("alpha")
                XCTAssertEqual(store.currentModel, "alpha")
            }
            let before = try encoder.encode(store.data)
            for dark in [false, true] {
                UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
                    let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 20) {
                        Text("Serveur et modèle").font(.headline)
                        ServerModelControls { addCalls += 1 }.environmentObject(store)
                    }.padding(20).frame(width: 390)
                        .background(dark ? Color.black : Color.white)
                        .foregroundStyle(dark ? Color.white : Color.black)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    renderer.scale = 2
                    guard let image = renderer.uiImage else { XCTFail("Missing render"); return }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "compact117-" + (started ? "locked" : "new") + (dark ? "-dark" : "-light")
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            XCTAssertEqual(try encoder.encode(store.data), before)
            XCTAssertEqual(addCalls, 0)
        }
        let restored = AppStore(storageDirectory: directory, defaults: defaults, client: ModelFixtureAPI(models: []), readKey: { _ in "" })
        XCTAssertEqual(restored.currentModel, "alpha")
        XCTAssertNotNil(restored.current)
    }

    func testFootnotesMathAndEscapes() throws {
        let sections = MessageCopyBlock.parse("Référence[^a].\n[^a]: Note fictive\n```text\n[^hidden]: code\n```")
        let notes = FootnoteDocument(sections: sections)
        XCTAssertEqual(notes.notes, [.init(id: "a", text: "Note fictive")])
        XCTAssertEqual(notes.number("a"), 1)
        XCTAssertNil(notes.number("missing"))
        XCTAssertEqual(notes.clean(sections[0].content), "Référence[^a].\n")
        XCTAssertEqual(RichInline.parts(#"\$x$ et `[^a] $x$` et \[^a]"#), [.text(#"\$x$ et `[^a] $x$` et \[^a]"#)])
        XCTAssertEqual(RichInline.parts("Énergie $E=mc^2$[^a]"), [.text("Énergie "), .math("E=mc^2"), .note("a")])
        XCTAssertEqual(try XCTUnwrap(NativeMath.parse("E=mc^2")).last, .init(value: "2", script: 1))
        let integral = try XCTUnwrap(NativeMath.parse(#"\int_{a}^{b} f(x)\,dx = F(b)-F(a)"#))
        XCTAssertEqual(integral.first?.value, "∫")
        XCTAssertTrue(integral.contains(.init(value: "a", script: -1)))
        XCTAssertNil(NativeMath.parse(#"\input{/etc/passwd}"#))
        XCTAssertNil(NativeMath.parse(#"\href{https://example.com}{x}"#))
        XCTAssertNil(NativeMath.parse("x^{"))
        XCTAssertEqual(MessageMarkdownBlock.parse("$$\nx^2\n$$"), [.math("x^2")])
        XCTAssertEqual(MessageMarkdownBlock.parse("$$\nx^"), [.text("$$\nx^")])
    }

    func testNativeHTMLAllowlistAndSecurity() throws {
        let html = try XCTUnwrap(NativeHTML.parse(#"<div style="background:#ffeaa7; padding:10px; border-radius:5px;"><strong>Encadré</strong> Texte</div>"#))
        XCTAssertEqual(html.background, 0xffeaa7)
        XCTAssertEqual(html.padding, 10)
        XCTAssertEqual(html.radius, 5)
        XCTAssertTrue(html.markdown.contains("**Encadré**"))
        for rejected in ["<script>alert(1)</script>", "<iframe src='https://example.com'/>", "<img src='file:///etc/passwd'/>", "<div onclick='evil()'>x</div>", "<div style='background:url(https://example.com/x)'>x</div>", "<div style='padding:999999px'>x</div>", "<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><div>&a;</div>", "<div>incomplet", "<svg onload='x'/>"] {
            XCTAssertNil(NativeHTML.parse(rejected), rejected)
        }
        XCTAssertNotNil(NativeHTML.parse("<div>&lt;script&gt;texte&lt;/script&gt;</div>"))
        XCTAssertEqual(MessageCopyBlock.parse("```html\n<div>code</div>\n```").first?.language, "html")
        XCTAssertEqual(RichInline.parts(##"\*littéral\* \# titre \`code\`"##), [.text(##"\*littéral\* \# titre \`code\`"##)])
    }

    func testNativeMermaidBranchesAndRejectedDirectives() throws {
        let source = "graph TD\nA[Début] --> B{Décision}\nB -->|Oui| C[Action 1]\nB -->|Non| D[Action 2]\nC --> E[Fin]\nD --> E"
        let graph = try XCTUnwrap(NativeMermaid.parse(source))
        XCTAssertEqual(graph.nodes.count, 5)
        XCTAssertEqual(graph.edges.count, 5)
        XCTAssertEqual(graph.levels?.map(\.count), [1, 1, 2, 1])
        XCTAssertTrue(graph.nodes.contains { $0.decision && $0.label == "Décision" })
        XCTAssertEqual(graph.edges.filter { !$0.label.isEmpty }.map(\.label), ["Oui", "Non"])
        for bad in ["graph TD\nA -->", "graph TD\nA --> B\nB --> A", "graph TD\nclick A evil()", "graph TD\nA[<script>x</script>]", "%%{init: {securityLevel: 'loose'}}%%\ngraph TD\nA --> B", "sequenceDiagram\nA->>B: x"] {
            XCTAssertNil(NativeMermaid.parse(bad), bad)
        }
        XCTAssertNotNil(NativeMermaid.parse("graph LR\nA --> B"))
    }

    @MainActor
    func testRichMarkdownStaticRendersLightAndDark() throws {
        // Render pure SwiftUI content; ScrollView viewport/gestures require separate UI QA.
        let graph = try XCTUnwrap(NativeMermaid.parse("graph TD\nA[Début] --> B{Décision}\nB -->|Oui| C[Action 1]\nB -->|Non| D[Action 2]\nC --> E[Fin]\nD --> E"))
        let atoms = try XCTUnwrap(NativeMath.parse(#"\int_{a}^{b} f(x)\,dx = F(b)-F(a)"#))
        let fixtures: [(String, AnyView)] = [
            ("notes-inline-math", AnyView(SafeMessageText(text: "Référence[^1] et autre[^2].\n[^1]: Première note.\n[^2]: Deuxième note.\n\nÉnergie $E=mc^2$."))),
            ("block-math", AnyView(NativeMath.rendered(atoms))),
            ("diagram", AnyView(NativeMermaidView(graph: graph).diagram)),
            ("html-escapes", AnyView(SafeMessageText(text: ##"\*Pas italique\* et \# pas titre"## + "\n<div style=\"background:#ffeaa7; padding:10px; border-radius:5px;\"><strong>Encadré HTML :</strong> texte fictif.</div>")))
        ]
        for (name, content) in fixtures {
            for dark in [false, true] {
                UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
                    let renderer = ImageRenderer(content: content.padding(20)
                        .background(dark ? Color.black : Color.white).foregroundStyle(dark ? Color.white : Color.black)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    renderer.proposedSize = ProposedViewSize(width: name == "diagram" ? 440 : 390, height: nil)
                    renderer.scale = 2
                    guard let image = renderer.uiImage else { XCTFail("Native snapshot unavailable"); return }
                    XCTAssertGreaterThan(image.size.height, 40)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "rich116-" + name + (dark ? "-dark" : "-light")
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testMarkdownAlertsAndRulesStayOutOfCode() {
        for kind in MarkdownAlertKind.allCases {
            XCTAssertEqual(MessageMarkdownBlock.parse("> [!" + kind.rawValue + "]\n> Message **fictif**"), [.alert(kind, "Message **fictif**")])
        }
        XCTAssertEqual(MessageMarkdownBlock.parse("> [!UNKNOWN]\n> texte"), [.quote("[!UNKNOWN]\ntexte")])
        XCTAssertEqual(MessageMarkdownBlock.parse("---\n***\n___\n* * *"), [.separator, .separator, .separator, .separator])
        XCTAssertEqual(MessageMarkdownBlock.parse("\\---\n    ***\n`___`"), [.text("\\---\n    ***\n`___`")])
        let code = MessageCopyBlock.parse("```text\n> [!WARNING]\n---\n``` **literal**")
        XCTAssertEqual(code.first?.language, "text")
        XCTAssertTrue(code.first!.content.contains("> [!WARNING]\n---"))
    }

    func testTaskAndQuoteMarkdownBlocks() {
        XCTAssertEqual(MessageMarkdownBlock.parse("- [ ] À faire\n- [x] Fait\n> Une citation\n> suite"),
            [.task(false, "À faire"), .task(true, "Fait"), .quote("Une citation\nsuite")])
        XCTAssertEqual(MessageMarkdownBlock.parse("\\- [x] littéral\n    > code"), [.text("\\- [x] littéral\n    > code")])
        let sections = MessageCopyBlock.parse("```text\n- [x] brut\n> brut\n| A | B |\n| --- | --- |\n```\n- [ ] vrai")
        XCTAssertEqual(sections.first?.language, "text")
        XCTAssertEqual(sections.first?.content, "- [x] brut\n> brut\n| A | B |\n| --- | --- |\n")
        XCTAssertEqual(MessageMarkdownBlock.parse(sections.last!.content), [.task(false, "vrai")])
    }

    func testMarkdownTablesAndIncompleteStreamingRows() {
        XCTAssertEqual(MessageMarkdownBlock.parse("| Nom | Valeur |\n| :--- | ---: |\n| A | `x|y` |\n| incomplet"),
            [.table(["Nom", "Valeur"], [["A", "`x|y`"]]), .text("| incomplet")])
        XCTAssertEqual(MessageMarkdownBlock.cells("| a\\|b | c |"), ["a\\|b", "c"])
        XCTAssertEqual(MessageMarkdownBlock.parse("A | B\n--- | ---\nx | y"), [.table(["A", "B"], [["x", "y"]])])
        XCTAssertEqual(MessageMarkdownBlock.parse("A | B\n-- | --"), [.text("A | B\n-- | --")])
    }

    func testMarkdownLinksRemainClickableOnlyForAllowedSchemes() {
        let safe = MessageMarkdownBlock.inline("[Exemple](https://example.com/test) et `code`")
        XCTAssertTrue(safe.runs.contains { $0.link?.absoluteString == "https://example.com/test" })
        let blocked = MessageMarkdownBlock.inline("[Local](file:///private/test) [Script](javascript:alert)")
        XCTAssertFalse(blocked.runs.contains { $0.link != nil })
        XCTAssertFalse(MessageMarkdownBlock.isAllowedLink(URL(string: "custom://test")!))
        XCTAssertTrue(MessageMarkdownBlock.isAllowedLink(URL(string: "mailto:test@example.com")!))
    }

    func testCopyBlocksPreserveOnlyTheirExactSource() {
        let source = "Introduction\n```wlangage\n  # code `littéral`\n\tSuite()\n```\nConclusion\n```text\n  Texte\nligne 2\n```"
        let blocks = MessageCopyBlock.parse(source)
        XCTAssertEqual(blocks.map(\.content), ["Introduction\n", "  # code `littéral`\n\tSuite()\n", "Conclusion\n", "  Texte\nligne 2\n"])
        XCTAssertEqual(blocks.map(\.language), [nil, "wlangage", nil, "text"])
        XCTAssertEqual(MessageCopyBlock.parse(source), blocks)
        XCTAssertEqual(MessageCopyBlock.parse("Une `valeur` et ``` littéraux"), [.init(content: "Une `valeur` et ``` littéraux", language: nil)])
        XCTAssertEqual(MessageCopyBlock.parse("```swift\n  let x = 1").first?.content, "  let x = 1")
        XCTAssertEqual(MessageCopyBlock.parse("````text\n```\n# titre\n````").first?.content, "```\n# titre\n")
        XCTAssertEqual(MessageCopyBlock.parse("```text\nA\n```\nB").count, 2)
    }

    func testResponseSettingsMigrationAndServerIsolation() throws {
        var legacy = AppData()
        legacy.systemPrompt = "Consigne fictive conservée"
        legacy.temperature = 0.3
        var explicit = ServerProfile(name: "Deux", model: "b")
        explicit.systemInstruction = ""
        explicit.creativity = 1.2
        legacy.servers = [ServerProfile(name: "Un", model: "a"), explicit]
        legacy.migrateServerResponseSettings()
        XCTAssertEqual(legacy.servers[0].effectiveInstruction, "Consigne fictive conservée")
        XCTAssertEqual(legacy.servers[0].effectiveCreativity, 0.3)
        XCTAssertEqual(legacy.servers[1].effectiveInstruction, "")
        XCTAssertEqual(legacy.servers[1].effectiveCreativity, 1.2)
        legacy.systemPrompt = "Ancien global ignoré"
        legacy.migrateServerResponseSettings()
        XCTAssertEqual(legacy.servers[0].effectiveInstruction, "Consigne fictive conservée")
        let restored = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(restored.servers, legacy.servers)
        XCTAssertEqual(ServerProfile().effectiveInstruction, "")
        XCTAssertEqual(explicit.duplicate().effectiveCreativity, 1.2)
    }

    @MainActor
    func testLateCatalogCannotReplaceLimitsAfterSelectionOrServerSave() async throws {
        for scenario in ["selection", "save"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let suite = "EudesCatalogTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
            let profile = ServerProfile(name: "Fictif", baseURL: "https://192.168.254.254/v1", model: "alpha", availableModels: ["alpha", "beta"])
            var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
            try PrivateStorage(directory: directory).save(data)
            let client = CatalogGateFixture()
            let store = AppStore(storageDirectory: directory, defaults: defaults, client: client, readKey: { _ in "" })
            let loading = Task { await store.loadModels() }
            for _ in 0..<1000 { if await client.started { break }; await Task.yield() }
            if scenario == "selection" { store.selectDraftModel("beta") }
            else { try store.saveServer(profile, key: "") }
            await client.finish()
            await loading.value
            XCTAssertNil(store.selectedServer?.limits(for: "alpha").context)
            XCTAssertFalse(store.loadingModels)
            XCTAssertEqual(store.currentModel, scenario == "selection" ? "beta" : "alpha")
        }
    }

    @MainActor
    func testSendDoesNotRequireBudgetWarningConfirmation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesBudgetTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        var profile = ServerProfile(name: "Fictif", baseURL: "https://192.168.254.254/v1", model: "alpha")
        profile.setContextBudget(1000, model: "alpha")
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
        let storage = try PrivateStorage(directory: directory); try storage.save(data)
        let client = BackgroundFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: client, readKey: { _ in "" })
        let accepted = await store.sendChecked("Fictif modifié")
        XCTAssertTrue(accepted)
        for _ in 0..<100 { await Task.yield() }
        store.stop()
        XCTAssertEqual(store.current?.messages.first?.text, "Fictif modifié")
        let sends = await client.sends; XCTAssertEqual(sends, 1)
        store.saveContextBudget(6000, profile: profile, model: "alpha")
        let restored = AppStore(storageDirectory: directory, defaults: defaults, client: client, readKey: { _ in "" })
        XCTAssertEqual(restored.selectedServer?.contextBudget(for: "alpha"), 6000)
        XCTAssertEqual(restored.data.maxTokens, 2048)
        XCTAssertEqual(restored.current?.messages.first?.text, "Fictif modifié")
    }

    @MainActor
    func testBulkDeletionAndGlassPreferencePersistWithoutChangingOthers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesBulkTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let server = ServerProfile(name: "Fixture", baseURL: "https://192.168.1.2/v1", model: "fixture")
        var data = AppData(); data.servers = [server]; data.selectedServerID = server.id
        data.conversations = (1...3).map { Conversation(title: "Fixture \($0)", serverID: server.id, model: "fixture", messages: []) }
        data.selectedConversationID = data.conversations[0].id
        let storage = try PrivateStorage(directory: directory); try storage.save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: BackgroundFixture(), readKey: { _ in "" })
        XCTAssertTrue(store.liquidGlassEnabled)
        store.setLiquidGlassEnabled(false)
        XCTAssertTrue(store.requiresDeletionConfirmation)
        // Selecting/cancelling is UI-only: no mutation until this explicit confirmation.
        XCTAssertEqual(try storage.load().conversations.count, 3)
        XCTAssertFalse(store.confirmConversationDeletions(ids: []))
        XCTAssertTrue(store.confirmConversationDeletions(ids: Set(data.conversations.prefix(2).map(\.id))))
        XCTAssertNil(store.current)
        XCTAssertEqual(store.data.conversations.map(\.id), [data.conversations[2].id])
        XCTAssertEqual(try storage.load().conversations.map(\.id), [data.conversations[2].id])
        XCTAssertTrue(store.requiresDeletionConfirmation)
        let restored = AppStore(storageDirectory: directory, defaults: defaults, client: BackgroundFixture(), readKey: { _ in "" })
        XCTAssertFalse(restored.liquidGlassEnabled)
        restored.setLiquidGlassEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: "liquidGlassEnabled"))
        XCTAssertEqual(restored.data.servers.map(\.id), store.data.servers.map(\.id))
    }

    @MainActor
    func testKeyboardPreferenceAndIntroductionPersistIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesKeyboardTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: BackgroundFixture(), readKey: { _ in "" })
        XCTAssertFalse(store.automaticKeyboard)
        XCTAssertFalse(store.hasSeenKeyboardIntroduction)
        store.newConversation()
        XCTAssertFalse(store.hasSeenKeyboardIntroduction)
        XCTAssertTrue(store.claimKeyboardIntroduction())
        XCTAssertFalse(store.claimKeyboardIntroduction())
        store.setAutomaticKeyboard(true)
        let restored = AppStore(storageDirectory: directory, defaults: defaults, client: BackgroundFixture(), readKey: { _ in "" })
        XCTAssertTrue(restored.automaticKeyboard)
        XCTAssertTrue(restored.hasSeenKeyboardIntroduction)
        XCTAssertFalse(restored.claimKeyboardIntroduction())
        restored.setAutomaticKeyboard(false)
        XCTAssertFalse(defaults.bool(forKey: "automaticConversationKeyboard"))
        XCTAssertFalse(restored.hasSeenMenuIntroduction)
    }

    @MainActor
    func testNewConversationSwipeDefaultsOffAndPersistsBothValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesNewConversationSwipeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertFalse(store.newConversationSwipeEnabled)
        store.setConversationMenuMode(.right)
        store.setAutomaticKeyboard(true)
        store.newConversationSwipeEnabled = true
        let restored = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertTrue(restored.newConversationSwipeEnabled)
        XCTAssertEqual(restored.conversationMenuMode, .right)
        XCTAssertTrue(restored.automaticKeyboard)
        restored.newConversationSwipeEnabled = false
        let reopened = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertFalse(reopened.newConversationSwipeEnabled)
        XCTAssertEqual(reopened.conversationMenuMode, .right)
    }

    func testNewConversationSwipeRequiresRightEdgeAndDeliberateHorizontalMovement() {
        func action(startX: CGFloat = 389, width: CGFloat = 390, dx: CGFloat = -120,
                    dy: CGFloat = 5, enabled: Bool = true, available: Bool = true) -> ConversationEdgeSwipe.Action? {
            ConversationEdgeSwipe.action(startX: startX, width: width,
                translation: CGSize(width: dx, height: dy), menuMode: .bottom,
                newConversationEnabled: enabled, canStartNewConversation: available)
        }
        XCTAssertEqual(action(), .newConversation)
        XCTAssertNil(action(enabled: false))
        XCTAssertNil(action(available: false))
        XCTAssertNil(action(startX: 200))
        XCTAssertNil(action(startX: 5))
        XCTAssertNil(action(dx: 120))
        XCTAssertNil(action(dx: -30))
        XCTAssertNil(action(dx: -120, dy: 140))
        XCTAssertNil(action(dx: -120, dy: -100))
        XCTAssertNil(action(startX: 391))
        XCTAssertNil(action(width: 0))
        // The physical edge follows the current container width, including rotation.
        XCTAssertNil(action(startX: 389, width: 844))
        XCTAssertEqual(action(startX: 840, width: 844), .newConversation)
    }

    func testNewConversationSwipeReservesRightEdgeWithoutBreakingLeftHistory() {
        for mode in ConversationMenuMode.allCases {
            XCTAssertEqual(ConversationEdgeSwipe.action(startX: 389, width: 390,
                translation: CGSize(width: -120, height: 0), menuMode: mode,
                newConversationEnabled: true, canStartNewConversation: true), .newConversation)
            // Neither a short gesture nor a busy response may fall back to history.
            XCTAssertNil(ConversationEdgeSwipe.action(startX: 389, width: 390,
                translation: CGSize(width: -60, height: 0), menuMode: mode,
                newConversationEnabled: true, canStartNewConversation: true))
            XCTAssertNil(ConversationEdgeSwipe.action(startX: 389, width: 390,
                translation: CGSize(width: -120, height: 0), menuMode: mode,
                newConversationEnabled: true, canStartNewConversation: false))
        }
        XCTAssertEqual(ConversationEdgeSwipe.action(startX: 389, width: 390,
            translation: CGSize(width: -120, height: 0), menuMode: .right,
            newConversationEnabled: false, canStartNewConversation: true), .history)
        XCTAssertEqual(ConversationEdgeSwipe.action(startX: 2, width: 390,
            translation: CGSize(width: 120, height: 0), menuMode: .left,
            newConversationEnabled: true, canStartNewConversation: true), .history)
        XCTAssertNil(ConversationEdgeSwipe.action(startX: 200, width: 390,
            translation: CGSize(width: 120, height: 0), menuMode: .left,
            newConversationEnabled: true, canStartNewConversation: true))
    }

    @MainActor
    func testNewConversationSwipeKeepsPreviousExchangeAfterReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesSwipeHistoryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let storage = try PrivateStorage(directory: directory)
        var data = AppData()
        data.conversations = [Conversation(title: "Échange à conserver", serverID: UUID(), model: "fixture",
            messages: [ChatMessage(role: .user, text: "Question"), ChatMessage(role: .assistant, text: "Réponse")])]
        data.selectedConversationID = data.conversations[0].id
        try storage.save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults)
        store.newConversationSwipeEnabled = true
        let entry = store.composerEntryID
        let action = ConversationEdgeSwipe.action(startX: 389, width: 390,
            translation: CGSize(width: -120, height: 5), menuMode: store.conversationMenuMode,
            newConversationEnabled: store.newConversationSwipeEnabled, canStartNewConversation: true)
        XCTAssertEqual(action, .newConversation)
        if action == .newConversation { store.newConversation() }
        XCTAssertNil(store.current)
        XCTAssertNotEqual(store.composerEntryID, entry)
        XCTAssertEqual(store.data.conversations, data.conversations)
        let reopened = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertNil(reopened.current)
        XCTAssertEqual(reopened.data.conversations, data.conversations)
        XCTAssertTrue(reopened.newConversationSwipeEnabled)
    }

    @MainActor
    func testSpellCheckPreferenceDefaultsOnAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesSpellCheckTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: BackgroundFixture(), readKey: { _ in "" })
        XCTAssertTrue(store.spellCheckEnabled)
        store.setSpellCheckEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: "composerSpellCheckEnabled"))
        let restored = AppStore(storageDirectory: directory, defaults: defaults, client: BackgroundFixture(), readKey: { _ in "" })
        XCTAssertFalse(restored.spellCheckEnabled)
        restored.setSpellCheckEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: "composerSpellCheckEnabled"))
    }

    @MainActor
    func testComposerAppliesBothCorrectionAndSpellCheckingWithoutChangingText() {
        let view = ImagePasteTextView()
        view.text = "Bonjour le monde"
        view.setCorrectionEnabled(true)
        XCTAssertEqual(view.autocorrectionType, .yes)
        XCTAssertEqual(view.spellCheckingType, .yes)
        view.setCorrectionEnabled(false)
        XCTAssertEqual(view.autocorrectionType, .no)
        XCTAssertEqual(view.spellCheckingType, .no)
        XCTAssertEqual(view.text, "Bonjour le monde")
        view.setCorrectionEnabled(true)
        XCTAssertEqual(view.autocorrectionType, .yes)
        XCTAssertEqual(view.spellCheckingType, .yes)
    }

    @MainActor
    func testBackgroundContinuationExpirationAndLateCallbacks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesBackgroundTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "Fictif", baseURL: "https://192.168.254.254/v1", model: "alpha")
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
        let storage = try PrivateStorage(directory: directory); try storage.save(data)
        let client = BackgroundFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: client, readKey: { _ in "" })
        let sent = await store.sendChecked("Fictif"); XCTAssertTrue(sent)
        for _ in 0..<1000 { if store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.text, "Partiel")
        store.sceneChanged(.inactive); store.sceneChanged(.background)
        XCTAssertTrue(store.isGenerating)
        XCTAssertEqual(try storage.load().conversations.first?.messages.last?.text, "Partiel")
        store.sceneChanged(.active)
        XCTAssertTrue(store.isGenerating)
        store.expireBackgroundGeneration()
        XCTAssertFalse(store.isGenerating)
        XCTAssertEqual(store.current?.messages.last?.state, .interrupted)
        XCTAssertEqual(store.current?.messages.last?.failureDetail, "Le délai d’exécution en arrière-plan accordé par iOS a expiré.")
        XCTAssertEqual(try storage.load().conversations.first?.messages.last?.state, .interrupted)
        XCTAssertEqual(try storage.load().conversations.first?.messages.last?.failureDetail, store.current?.messages.last?.failureDetail)
        await client.complete()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.text, "Partiel")
        let sends = await client.sends; XCTAssertEqual(sends, 1)
        let restored = AppStore(storageDirectory: directory, defaults: defaults, client: client, readKey: { _ in "" })
        XCTAssertEqual(restored.current?.messages.last?.state, .interrupted)
        XCTAssertEqual(restored.current?.messages.last?.text, "Partiel")
    }

    @MainActor
    func testLFMGenerationPausesOnForegroundLossAndResumesAfterUnlock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesLFMLock." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let local = BackgroundFixture()
        var active = true
        var unlocked = true
        let store = AppStore(storageDirectory: directory, defaults: defaults,
                             client: ForbiddenAppleNetwork(), localModelClient: local,
                             appleAvailability: { .unsupportedOS }, readKey: { _ in XCTFail("LFM requires no API key"); return "" },
                             applicationIsActive: { active }, protectedDataAvailable: { unlocked })
        store.selectServer(ServerProfile.lfmTextID)
        store.saveSettings(prompt: "", temperature: 0.7, maxTokens: 128)
        let sent = await store.sendChecked("Question")
        XCTAssertTrue(sent)
        for _ in 0..<1000 { if store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        let id = try XCTUnwrap(store.current?.messages.last?.id)
        active = false
        store.sceneChanged(.inactive)
        XCTAssertFalse(store.isGenerating)
        XCTAssertEqual(store.current?.messages.last?.state, .interrupted)
        XCTAssertNil(store.notice, "La pause automatique ne doit pas afficher de fenêtre")
        XCTAssertEqual(store.current?.messages.last?.text, "Partiel")
        XCTAssertEqual(store.current?.messages.last?.resumeLocalAfterUnlock, true)
        let saved = try PrivateStorage(directory: directory).load()
        XCTAssertEqual(saved.conversations.first?.messages.last?.resumeLocalAfterUnlock, true)
        unlocked = false
        store.protectedDataWillBecomeUnavailable()
        store.sceneChanged(.background)
        unlocked = true
        active = true
        store.sceneChanged(.active)
        for _ in 0..<30 { await Task.yield() }
        let beforeRelease = await local.sends
        XCTAssertEqual(beforeRelease, 1, "Do not run two instances of the model simultaneously")
        XCTAssertTrue(store.isPreparingSend)
        let prematureSend = await store.sendChecked("Autre question")
        XCTAssertFalse(prematureSend, "Do not start a new request before the cancelled model releases its context")
        for _ in 0..<2000 { if await local.isWaiting { break }; await Task.yield() }
        await local.complete()
        for _ in 0..<2000 {
            let sends = await local.sends
            let waiting = await local.isWaiting
            if sends == 2 && waiting { break }
            await Task.yield()
        }
        let resumedCount = await local.sends
        XCTAssertEqual(resumedCount, 2)
        XCTAssertEqual(store.current?.messages.last?.id, id)
        XCTAssertEqual(store.current?.messages.last?.text, "Partiel")
        await local.complete()
        for _ in 0..<2000 { if !store.isGenerating { break }; await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.state, .complete)
        XCTAssertEqual(store.current?.messages.last?.text, "Terminé")
        XCTAssertNil(store.current?.messages.last?.resumeLocalAfterUnlock)
    }

    @MainActor
    func testLFMResumeKeepsPartialIfNoVisibleAnswerIsProduced() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesLFMEmptyResume." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let local = EmptyLFMResumeFixture()
        var active = true
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(),
                             localModelClient: local, appleAvailability: { .unsupportedOS }, readKey: { _ in "" },
                             applicationIsActive: { active }, protectedDataAvailable: { true })
        store.selectServer(ServerProfile.lfmTextID)
        let sent = await store.sendChecked("Question")
        XCTAssertTrue(sent)
        for _ in 0..<2000 { if await local.isWaiting { break }; await Task.yield() }
        active = false
        store.sceneChanged(.inactive)
        active = true
        store.sceneChanged(.active)
        await local.release()
        for _ in 0..<2000 {
            let sends = await local.sends
            if sends >= 2 && !store.isPreparingSend && !store.isGenerating { break }
            await Task.yield()
        }
        XCTAssertEqual(store.current?.messages.last?.text, "Réponse partielle")
        XCTAssertEqual(store.current?.messages.last?.state, .interrupted)
        XCTAssertTrue(store.current?.messages.last?.failureDetail?.contains("texte précédent est conservé") == true)
    }

    @MainActor
    func testLFMPauseReportsWhenProtectedCheckpointCannotBeSaved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesLFMLockSaveFailure." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let local = BackgroundFixture()
        var active = true
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(),
                             localModelClient: local, appleAvailability: { .unsupportedOS }, readKey: { _ in "" },
                             applicationIsActive: { active }, protectedDataAvailable: { true })
        store.selectServer(ServerProfile.lfmTextID)
        store.saveSettings(prompt: "", temperature: 0.7, maxTokens: 128)
        let sent = await store.sendChecked("Question")
        XCTAssertTrue(sent)
        for _ in 0..<2000 { if await local.isWaiting { break }; await Task.yield() }
        let file = directory.appendingPathComponent("workspace.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        active = false
        store.sceneChanged(.inactive)
        XCTAssertFalse(store.isGenerating)
        XCTAssertTrue(store.notice?.contains("n’a pas pu être enregistrée") == true)
        XCTAssertEqual(store.current?.messages.last?.text, "Partiel")
        await local.complete()
    }

    @MainActor
    func testLFMResumeReusesWebEvidenceWithoutRepeatingSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesLFMResumeWeb." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile.lfmText
        let question = ChatMessage(role: .user, text: "Cherche la météo", webSearchRequested: true)
        let context = WebSearchContext(query: "météo", fetchedAt: Date(), sources: [
            WebSource(url: URL(string: "https://example.org/weather")!, title: "Météo",
                      excerpt: "Soleil", kind: .searchSnippet)])
        var interrupted = ChatMessage(role: .assistant, text: "Partiel", state: .interrupted,
                                      reasoningServerID: profile.id, reasoningModel: profile.model)
        interrupted.webContext = context
        interrupted.resumeLocalAfterUnlock = true
        let conversation = Conversation(serverID: profile.id, model: profile.model, messages: [question, interrupted])
        var data = AppData()
        data.selectedServerID = profile.id
        data.conversations = [conversation]
        data.selectedConversationID = conversation.id
        try PrivateStorage(directory: directory).save(data)
        let local = BackgroundFixture()
        let web = ForbiddenLFMResumeSearch()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(),
                             webSearch: web, localModelClient: local, appleAvailability: { .unsupportedOS },
                             readKey: { _ in "" }, applicationIsActive: { true }, protectedDataAvailable: { true })
        store.markLocalAnswerPausedForResume(interrupted.id)
        store.resumeLocalAfterForegroundReturn()
        for _ in 0..<2000 { if await local.isWaiting { break }; await Task.yield() }
        let requests = await local.inputMessages
        let count = await web.calls
        XCTAssertEqual(count, 0)
        XCTAssertTrue(requests.last?.last(where: { $0.role == .user })?.text.contains("https://example.org/weather") == true)
        await local.complete()
        for _ in 0..<2000 { if !store.isGenerating { break }; await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.webContext, context)
    }

    @MainActor
    func testLFMAutomaticallyRestartsSearchInterruptedByLock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesLFMLockSearch." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let search = BlockingLFMResumeSearch()
        let local = BackgroundFixture()
        var active = true
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(),
                             webSearch: search, localWebResearchModel: LFMResumePlanner(),
                             localModelClient: local, appleAvailability: { .unsupportedOS }, readKey: { _ in "" },
                             applicationIsActive: { active }, protectedDataAvailable: { true })
        store.selectServer(ServerProfile.lfmTextID)
        store.webSearchEnabled = true
        let sent = await store.sendChecked("Recherche sur Internet")
        XCTAssertTrue(sent)
        for _ in 0..<2000 { if await search.isWaiting { break }; await Task.yield() }
        let waiting = await search.isWaiting
        XCTAssertTrue(waiting)
        active = false
        store.sceneChanged(.inactive)
        XCTAssertFalse(store.isGenerating)
        XCTAssertEqual(store.current?.messages.last?.resumeLocalAfterUnlock, true)
        active = true
        store.sceneChanged(.active)
        await search.release()
        for _ in 0..<2000 {
            let calls = await search.calls
            let waiting = await search.isWaiting
            if calls == 2 && waiting { break }
            await Task.yield()
        }
        let searchCount = await search.calls
        XCTAssertEqual(searchCount, 2)
        XCTAssertNil(store.notice, "La reprise automatique ne doit pas afficher de fenêtre")
        await search.release()
        for _ in 0..<2000 { if await local.isWaiting { break }; await Task.yield() }
        let sendCount = await local.sends
        XCTAssertEqual(sendCount, 1)
        await local.complete()
        for _ in 0..<2000 { if !store.isGenerating { break }; await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.state, .complete)
    }

    @MainActor
    func testLFMResumeMarkerDoesNotRestartAfterAppRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesLFMResumeRestart." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile.lfmText
        let question = ChatMessage(role: .user, text: "Question")
        var interrupted = ChatMessage(role: .assistant, text: "Partiel", state: .interrupted,
                                      reasoningServerID: profile.id, reasoningModel: profile.model)
        interrupted.resumeLocalAfterUnlock = true
        let conversation = Conversation(serverID: profile.id, model: profile.model, messages: [question, interrupted])
        var data = AppData()
        data.selectedServerID = profile.id
        data.conversations = [conversation]
        data.selectedConversationID = conversation.id
        try PrivateStorage(directory: directory).save(data)
        let local = BackgroundFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(),
                             localModelClient: local, appleAvailability: { .unsupportedOS }, readKey: { _ in "" },
                             applicationIsActive: { true }, protectedDataAvailable: { true })
        // Aucune pause faite par ce lancement : c'est le cas d'une app fermée puis rouverte.
        store.resumeLocalAfterForegroundReturn()
        for _ in 0..<1000 { await Task.yield() }
        let sends = await local.sends
        XCTAssertEqual(sends, 0, "Une fermeture complète ne doit rien relancer")
        XCTAssertFalse(store.isGenerating)
        XCTAssertEqual(store.current?.messages.last?.id, interrupted.id)
        XCTAssertEqual(store.current?.messages.last?.state, .interrupted)
        // Le marqueur survit à l'arrêt pour l'affichage, mais ne déclenche plus de reprise.
        XCTAssertEqual(store.current?.messages.last?.resumeLocalAfterUnlock, true)
    }

    @MainActor
    func testBackgroundCompletesAndProtectionInterruptsWithoutResend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesBackgroundCompletion." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "Fictif", baseURL: "https://192.168.254.254/v1", model: "alpha")
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
        let storage = try PrivateStorage(directory: directory); try storage.save(data)
        let client = BackgroundFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: client, readKey: { _ in "" })
        let first = await store.sendChecked("Premier"); XCTAssertTrue(first)
        for _ in 0..<1000 { if store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        store.sceneChanged(.background)
        await client.complete()
        for _ in 0..<1000 { if !store.isGenerating { break }; await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.state, .complete)
        XCTAssertEqual(store.current?.messages.last?.text, "Terminé")
        store.sceneChanged(.active)
        let second = await store.sendChecked("Second"); XCTAssertTrue(second)
        for _ in 0..<1000 { if store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        store.protectedDataWillBecomeUnavailable()
        XCTAssertFalse(store.isGenerating)
        XCTAssertEqual(store.current?.messages.last?.state, .interrupted)
        XCTAssertEqual(store.current?.messages.last?.failureDetail, "La génération a été interrompue avant le verrouillage des données protégées.")
        await client.complete()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.text, "Partiel")
        let sends = await client.sends; XCTAssertEqual(sends, 2)
    }

    func testConnectionProbeUsesOnlyBoundedNonGeneratingRequests() async throws {
        let profile = ServerProfile(name: "Fictif", baseURL: "https://192.168.254.254/v1", model: "alpha")
        for scenario in ["success", "optional", "unsupported", "auth", "server", "timeout", "html"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ConnectionURLStub.self]
            config.httpAdditionalHeaders = ["X-Eudes-Test": scenario]
            let client = LocalAPIClient(controlConfiguration: config)
            do {
                let result = try await client.checkConnection(profile: profile, key: "")
                XCTAssertTrue(["success", "optional", "unsupported"].contains(scenario))
                XCTAssertEqual(result, scenario == "unsupported" ? .unverified : .reachable)
            } catch {
                switch scenario {
                case "auth": guard case EudesError.server(401) = error else { return XCTFail("auth incorrecte") }
                case "server": guard case EudesError.server(503) = error else { return XCTFail("serveur incorrect") }
                case "timeout": XCTAssertEqual((error as? URLError)?.code, .timedOut)
                case "html": guard case EudesError.invalidResponse = error else { return XCTFail("HTML accepté") }
                default: XCTFail("Échec inattendu : \(scenario) \(error)")
                }
            }
        }
        var invalid = profile; invalid.baseURL = "bad URL"
        do { _ = try await LocalAPIClient().checkConnection(profile: invalid, key: ""); XCTFail("URL acceptée") }
        catch { guard case EudesError.invalidAddress = error else { return XCTFail("Mauvaise erreur URL") } }
        XCTAssertEqual(LocalAPIClient.configuration().timeoutIntervalForResource, 180)
    }

    @MainActor
    func testConnectionStaleResultsRecoveryAndPerMessageCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesConnectionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let a = ServerProfile(name: "A fictif", baseURL: "https://192.168.254.254/v1", model: "alpha")
        let b = ServerProfile(name: "B fictif", baseURL: "https://192.168.254.253/v1", model: "beta")
        var data = AppData(); data.servers = [a, b]; data.selectedServerID = a.id
        try PrivateStorage(directory: directory).save(data)
        let client = ConnectionFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: client, readKey: { _ in "" })
        let pending = Task { await store.checkConnection() }
        while store.connectionState != .checking { await Task.yield() }
        await store.refreshConnectionFromConversation()
        let concurrentChecks = await client.checks
        XCTAssertLessThanOrEqual(concurrentChecks, 1)
        XCTAssertTrue(store.data.conversations.isEmpty)
        store.selectServer(b.id)
        let obsolete = await pending.value
        XCTAssertFalse(obsolete); XCTAssertFalse(store.connectionReady)
        await client.setFailure(true)
        let failed = await store.checkConnection(); XCTAssertFalse(failed)
        guard case .failed = store.connectionState else { return XCTFail("Échec non visible") }
        await client.setFailure(false)
        let recovered = await store.checkConnection(); XCTAssertTrue(recovered); XCTAssertTrue(store.connectionReady)
        let canceled = Task { await store.checkConnection() }
        while store.connectionState != .checking { await Task.yield() }
        canceled.cancel()
        let canceledResult = await canceled.value
        XCTAssertFalse(canceledResult); XCTAssertEqual(store.connectionState, .idle)
        await store.refreshConnectionFromConversation()
        XCTAssertTrue(store.connectionReady)
        XCTAssertTrue(store.data.conversations.isEmpty)
        let before = await client.checks
        let sent = await store.sendChecked("Prompt fictif jamais transmis par le contrôle")
        XCTAssertTrue(sent)
        let after = await client.checks; XCTAssertEqual(after, before + 1)
        for _ in 0..<100 where store.isGenerating { await Task.yield() }
        XCTAssertEqual(store.current?.model, "beta")
    }

    @MainActor
    func testImageNormalizationAndMultimodalPayload() throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).pngData { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let image = try ImageAttachment.importData(png)
        XCTAssertTrue(image.data.starts(with: [0xff, 0xd8, 0xff]))
        XCTAssertThrowsError(try ImageAttachment.importData(Data("<svg/>".utf8)))
        XCTAssertThrowsError(try ImageAttachment.importData(Data(repeating: 0, count: 8 * 1024 * 1024 + 1)))
        var profile = ServerProfile(name: "Fixture", baseURL: "https://192.168.254.254/v1", model: "vision")
        let message = ChatMessage(role: .user, text: "Image fictive", images: [image])
        func request(_ p: ServerProfile, _ model: String = "vision") throws -> URLRequest {
            try LocalAPIClient.completionRequest(profile: p, key: "", model: model, messages: [message], systemPrompt: "", temperature: 0.7, maxTokens: 512)
        }
        XCTAssertThrowsError(try request(profile))
        profile.imageCompatibility = [profile.visionKey("vision"): "supported"]
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request(profile).httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["text"] as? String, "Image fictive")
        let url = try XCTUnwrap((content[1]["image_url"] as? [String: String])?["url"])
        XCTAssertEqual(url, "data:image/jpeg;base64," + image.data.base64EncodedString())
        XCTAssertThrowsError(try request(profile, "other"))
        var otherEndpoint = profile; otherEndpoint.baseURL = "https://192.168.254.253/v1"
        XCTAssertThrowsError(try request(otherEndpoint))
        XCTAssertFalse(profile.duplicate().supportsImages("vision"))
        let oldMessage = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(ChatMessage(role: .user, text: "Avant")))
        XCTAssertNil(oldMessage.images)
        let tooMany = ChatMessage(role: .user, text: "", images: Array(repeating: image, count: 5))
        XCTAssertThrowsError(try LocalAPIClient.completionRequest(profile: profile, key: "", model: "vision", messages: [tooMany], systemPrompt: "", temperature: 0.7, maxTokens: 512))
    }

    @MainActor
    func testImageDraftPersistsAndIncompatibleSendPreservesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesImageTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let image = try ImageAttachment.importData(png)
        var profile = ServerProfile(name: "Fixture", baseURL: "https://192.168.254.254/v1", model: "vision")
        profile.imageCompatibility = [profile.visionKey("vision"): "supported"]
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
        let storage = try PrivateStorage(directory: directory); try storage.save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ModelFixtureAPI(models: ["vision", "text"]), readKey: { _ in "" })
        store.addImage(image)
        await store.loadModels(); store.selectDraftModel("text")
        let blockedSend = await store.sendChecked("Garder"); XCTAssertFalse(blockedSend); XCTAssertEqual(store.draftImages, [image]); XCTAssertNil(store.current)
        XCTAssertEqual(try storage.load().imageDraft, [image])
        store.selectDraftModel("vision")
        let imageSent = await store.sendChecked(""); XCTAssertTrue(imageSent)
        for _ in 0..<100 where store.isGenerating { await Task.yield() }
        XCTAssertEqual(store.current?.messages.first?.images, [image])
        XCTAssertEqual(store.current?.model, "vision")
        XCTAssertTrue(store.draftImages.isEmpty)
        let reloaded = try storage.load()
        XCTAssertEqual(reloaded.conversations.first?.messages.first?.images, [image])
        store.addImage(image); store.removeImage(image.id); XCTAssertTrue(store.draftImages.isEmpty)
    }

    @MainActor
    func testReasoningVisibilityPerServerAndModelKeepsHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesReasoningVisibility." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        var server = ServerProfile(name: "Fixture", baseURL: "https://example.invalid/v1", model: "alpha", availableModels: ["alpha", "beta"])
        XCTAssertTrue(server.showsReasoning(for: "alpha"))
        server.setShowsReasoning(false, for: "alpha")
        XCTAssertFalse(server.showsReasoning(for: "alpha"))
        XCTAssertTrue(server.showsReasoning(for: "beta"))
        XCTAssertFalse(server.duplicate().showsReasoning(for: "alpha"))
        let legacy = ChatMessage(role: .assistant, text: "Réponse", reasoning: "Texte conservé")
        let conversation = Conversation(serverID: server.id, model: "alpha", messages: [legacy])
        var data = AppData(); data.servers = [server]; data.selectedServerID = server.id
        data.conversations = [conversation]; data.selectedConversationID = conversation.id
        let storage = try PrivateStorage(directory: directory); try storage.save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults, readKey: { _ in "" })
        XCTAssertFalse(store.showsReasoning(for: legacy, in: conversation))
        store.selectDraftModel("beta")
        let changed = try XCTUnwrap(store.current)
        let recorded = try XCTUnwrap(changed.messages.first)
        XCTAssertEqual(recorded.reasoningServerID, server.id)
        XCTAssertEqual(recorded.reasoningModel, "alpha")
        XCTAssertEqual(recorded.reasoning, "Texte conservé")
        XCTAssertFalse(store.showsReasoning(for: recorded, in: changed))
        let reloaded = AppStore(storageDirectory: directory, defaults: defaults, readKey: { _ in "" })
        let persisted = try XCTUnwrap(reloaded.current)
        XCTAssertFalse(reloaded.showsReasoning(for: try XCTUnwrap(persisted.messages.first), in: persisted))
        var saved = try storage.load()
        saved.servers[0].setShowsReasoning(true, for: "alpha")
        try storage.save(saved)
        reloaded.reload()
        let restored = try XCTUnwrap(reloaded.current)
        XCTAssertTrue(reloaded.showsReasoning(for: try XCTUnwrap(restored.messages.first), in: restored))
        XCTAssertEqual(restored.messages.first?.reasoning, "Texte conservé")
    }

    @MainActor
    func testModelSelectionChangesAfterFailedFirstSendAndPersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesModelTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let storage = try PrivateStorage(directory: directory)
        let server = ServerProfile(name: "Fixture", baseURL: "https://192.168.254.254/v1", model: "alpha")
        var data = AppData(); data.servers = [server]; data.selectedServerID = server.id
        try storage.save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ModelFixtureAPI(models: ["alpha", "beta"]), readKey: { _ in "" })
        await store.loadModels()
        XCTAssertEqual(store.modelChoices, ["alpha", "beta"])
        store.selectDraftModel("beta")
        XCTAssertEqual(AppStore(storageDirectory: directory, defaults: defaults).currentModel, "beta")
        let blankSent = await store.sendChecked("  "); XCTAssertFalse(blankSent)
        XCTAssertNil(store.current)
        let sent = await store.sendChecked("Message fictif"); XCTAssertTrue(sent)
        for _ in 0..<100 where store.isGenerating { await Task.yield() }
        XCTAssertFalse(store.isGenerating)
        XCTAssertEqual(store.current?.messages.last?.state, .failed)
        store.selectDraftModel("alpha")
        XCTAssertEqual(store.currentModel, "alpha")
        XCTAssertEqual(store.current?.messages.first?.text, "Message fictif")
        var saved = try storage.load()
        saved.conversations[0].messages = []
        saved.servers[0].model = "changed globally"
        try storage.save(saved)
        let reopened = AppStore(storageDirectory: directory, defaults: defaults)
        reopened.selectDraftModel("alpha")
        XCTAssertEqual(reopened.currentModel, "alpha")
        XCTAssertNotNil(reopened.current)
    }

    @MainActor
    func testModelListsAndDuplicateAreNonDestructive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesModelListTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let storage = try PrivateStorage(directory: directory)
        let original = ServerProfile(name: "Fixture", baseURL: "https://192.168.254.254/v1", model: "alpha")
        var data = AppData(); data.servers = [original]; data.selectedServerID = original.id
        try storage.save(data)
        for result in [["alpha"], [], ["error"]] {
            let store = AppStore(storageDirectory: directory, defaults: defaults, client: ModelFixtureAPI(models: result), readKey: { _ in "" })
            await store.loadModels()
            XCTAssertFalse(store.loadingModels)
            XCTAssertEqual(store.currentModel, "alpha")
            XCTAssertEqual(store.modelChoices, ["alpha"])
            if result != ["alpha"] { XCTAssertNotNil(store.modelListNote) }
        }
        var copy = original.duplicate()
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.baseURL, original.baseURL)
        XCTAssertEqual(copy.model, original.model)
        XCTAssertNil(copy.availableModels)
        copy.baseURL = "https://192.168.254.253/v1"
        XCTAssertEqual(try storage.load().servers.count, 1) // Cancelling a draft creates nothing.
        let store = AppStore(storageDirectory: directory, defaults: defaults)
        try store.saveServer(copy, key: "")
        XCTAssertEqual(try storage.load().servers.first?.baseURL, original.baseURL)
        XCTAssertEqual(try storage.load().servers.last?.baseURL, copy.baseURL)
        XCTAssertEqual(try storage.load().servers.count, 2)
    }

    func testCompletionPayloadOmitsBlankSystemAndPreservesCustomInstruction() throws {
        let profile = ServerProfile(name: "Fixture", baseURL: "https://192.168.254.254/v1", model: "fixture")
        let history = [ChatMessage(role: .user, text: "Question fictive")]
        for prompt in ["", " \n\t", "Instruction volontaire exacte."] {
            let request = try LocalAPIClient.completionRequest(profile: profile, key: "", model: "fixture",
                messages: history, systemPrompt: prompt, temperature: 0.7, maxTokens: 2048)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                XCTAssertEqual(messages, [["role": "user", "content": "Question fictive"]])
            } else {
                XCTAssertEqual(messages.first, ["role": "system", "content": prompt])
                XCTAssertEqual(messages.count, 2)
            }
        }
    }

    @MainActor
    func testNewConversationHasNoDefaultInstructionAndExistingSettingsSurvive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesPromptTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let fresh = AppStore(storageDirectory: directory, defaults: defaults)
        fresh.newConversation()
        XCTAssertEqual(fresh.data.systemPrompt, "")
        let storage = try PrivateStorage(directory: directory)
        var existing = AppData()
        existing.conversations = [Conversation(serverID: UUID(), model: "fixture",
            messages: [ChatMessage(role: .user, text: "Historique conservé")])]
        existing.selectedConversationID = existing.conversations.first?.id
        for instruction in ["Instruction personnalisée", "Tu es un assistant utile. Réponds dans la langue de l’utilisateur."] {
            existing.systemPrompt = instruction
            try storage.save(existing)
            let reopened = AppStore(storageDirectory: directory, defaults: defaults)
            XCTAssertEqual(reopened.data.systemPrompt, instruction)
            reopened.newConversation()
            XCTAssertEqual(reopened.data.systemPrompt, instruction)
            XCTAssertEqual(reopened.data.conversations, existing.conversations)
            XCTAssertEqual(try storage.load().systemPrompt, instruction)
        }
    }

    @MainActor
    func testAppearancePersistsWithoutChangingConversationOrMenu() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesAppearanceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let storage = try PrivateStorage(directory: directory)
        var data = AppData()
        data.conversations = [Conversation(serverID: UUID(), model: "fixture")]
        data.selectedConversationID = data.conversations.first?.id
        try storage.save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(store.appearance, .automatic)
        store.completeMenuIntroduction(selection: .right)
        for appearance in AppAppearance.allCases {
            store.setAppearance(appearance)
            XCTAssertEqual(store.appearance, appearance)
            XCTAssertEqual(store.current?.id, data.selectedConversationID)
            let reopened = AppStore(storageDirectory: directory, defaults: defaults)
            XCTAssertEqual(reopened.appearance, appearance)
            XCTAssertEqual(reopened.data.conversations, data.conversations)
            XCTAssertEqual(reopened.conversationMenuMode, .right)
            XCTAssertTrue(reopened.hasSeenMenuIntroduction)
            XCTAssertTrue(reopened.requiresDeletionConfirmation)
        }
        defaults.set("unknown", forKey: "appAppearance")
        XCTAssertEqual(AppStore(storageDirectory: directory, defaults: defaults).appearance, .automatic)
    }

    @MainActor
    func testMenuPresentationAndOneTimeIntroduction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesMenuTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        // Existing installations have conversation storage but no introduction key.
        let storage = try PrivateStorage(directory: directory)
        var existing = AppData()
        existing.conversations = [Conversation(serverID: UUID(), model: "fixture")]
        try storage.save(existing)
        let store = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(store.conversationMenuMode, .bottom)
        XCTAssertFalse(store.hasSeenMenuIntroduction)
        store.completeMenuIntroduction(selection: nil)
        let deferred = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertTrue(deferred.hasSeenMenuIntroduction)
        XCTAssertEqual(deferred.conversationMenuMode, .bottom)
        for mode in ConversationMenuMode.allCases {
            store.setConversationMenuMode(mode)
            let reopened = AppStore(storageDirectory: directory, defaults: defaults)
            XCTAssertEqual(reopened.conversationMenuMode, mode)
            XCTAssertTrue(reopened.requiresDeletionConfirmation)
            XCTAssertEqual(reopened.data.conversations, existing.conversations)
        }
        store.completeMenuIntroduction(selection: .left)
        let chosen = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertEqual(chosen.conversationMenuMode, .left)
        XCTAssertTrue(chosen.hasSeenMenuIntroduction)
        chosen.completeMenuIntroduction(selection: nil)
        XCTAssertEqual(chosen.conversationMenuMode, .left)
    }

    @MainActor
    func testIndividualDeletionConfirmationAndPreference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesDeletionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let storage = try PrivateStorage(directory: directory)
        let first = Conversation(serverID: UUID(), model: "fixture")
        let second = Conversation(serverID: UUID(), model: "fixture")
        let third = Conversation(serverID: UUID(), model: "fixture")
        var data = AppData()
        data.conversations = [first, second, third]
        data.selectedConversationID = first.id
        try storage.save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertTrue(store.requiresDeletionConfirmation)
        XCTAssertTrue(store.requestConversationDeletion(first))
        // Cancelling does not invoke confirmation or alter storage/preferences.
        XCTAssertEqual(try storage.load().conversations, [first, second, third])
        XCTAssertTrue(AppStore(storageDirectory: directory, defaults: defaults).requiresDeletionConfirmation)
        store.confirmConversationDeletion(second, doNotAskAgain: false)
        XCTAssertEqual(store.current?.id, first.id)
        XCTAssertEqual(try storage.load().conversations, [first, third])
        XCTAssertTrue(store.requiresDeletionConfirmation)
        store.confirmConversationDeletion(first, doNotAskAgain: true)
        XCTAssertNil(store.current)
        XCTAssertNil(try storage.load().selectedConversationID)
        XCTAssertEqual(try storage.load().conversations, [third])
        let relaunched = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertFalse(relaunched.requiresDeletionConfirmation)
        XCTAssertFalse(relaunched.requestConversationDeletion(third))
        XCTAssertTrue(try storage.load().conversations.isEmpty)
    }

    @MainActor
    func testMissingConversationCannotRememberDeletionPreference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesDeletionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = AppStore(storageDirectory: directory, defaults: defaults)
        let missing = Conversation(serverID: UUID(), model: "fixture")
        XCTAssertFalse(store.requestConversationDeletion(missing))
        store.confirmConversationDeletion(missing, doNotAskAgain: true)
        XCTAssertTrue(store.requiresDeletionConfirmation)
    }

    func testHistoryPersistsAndIsExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try PrivateStorage(directory: directory)
        var data = AppData()
        let profile = ServerProfile(name: "Local", baseURL: "http://192.168.1.2:8000/v1", model: "model", allowsHTTP: true)
        data.servers = [profile]
        var conversation = Conversation(serverID: profile.id, model: profile.model)
        conversation.messages = [ChatMessage(role: .user, text: "Bonjour 🌿")]
        data.conversations = [conversation]
        try storage.save(data)
        XCTAssertEqual(try storage.load().conversations.first?.messages.first?.text, "Bonjour 🌿")
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let file = directory.appendingPathComponent("workspace.json")
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(json.contains("apiKey"))
    }

    func testCorruptDataIsNotSilentlyReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try PrivateStorage(directory: directory)
        let file = directory.appendingPathComponent("workspace.json")
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try storage.load())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "invalid")
    }

    func testKeychainRoundTripAndDeletion() throws {
        let store = KeychainStore()
        let id = UUID()
        defer { try? store.delete(id) }
        try store.write("test-value", for: id)
        XCTAssertEqual(try store.read(id), "test-value")
        try store.write("updated", for: id)
        XCTAssertEqual(try store.read(id), "updated")
        try store.delete(id)
        XCTAssertEqual(try store.read(id), "")
    }
}

private struct ModelFixtureAPI: EudesAPIClient {
    let models: [String]
    func models(profile: ServerProfile, key: String) async throws -> [String] {
        if models == ["error"] { throw URLError(.notConnectedToInternet) }
        return models
    }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        throw URLError(.notConnectedToInternet)
    }
}

private actor CompactionFixture: EudesAPIClient {
    private(set) var lastMessages: [ChatMessage] = []
    func models(profile: ServerProfile, key: String) async throws -> [String] { [profile.model] }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        if systemPrompt.hasPrefix("Résume fidèlement") { await onText("Résumé fictif") }
        else { lastMessages = messages; await onText("Réponse fictive") }
    }
}

private final class ConnectionURLStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard ["GET", "OPTIONS"].contains(request.httpMethod ?? ""), request.httpBody == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let scenario = request.value(forHTTPHeaderField: "X-Eudes-Test") ?? "success"
        if scenario == "timeout" { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var body = Data("{\"data\":[{\"id\":\"alpha\"}]}".utf8)
        switch scenario {
        case "auth": status = 401
        case "server": status = 503
        case "html": body = Data("<html>not an API</html>".utf8)
        case "optional", "unsupported":
            status = request.httpMethod == "GET" ? 404 : 204
            if scenario == "optional" { headers["Allow"] = "POST, OPTIONS" }
        default: break
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor ConnectionFixture: EudesAPIClient {
    var checks = 0
    private var fail = false
    func setFailure(_ value: Bool) { fail = value }
    func checkConnection(profile: ServerProfile, key: String) async throws -> ConnectionProof {
        checks += 1
        try await Task.sleep(for: .milliseconds(30))
        if fail { throw URLError(.timedOut) }
        return .reachable
    }
    func models(profile: ServerProfile, key: String) async throws -> [String] { [profile.model] }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        await onText("Réponse fictive")
    }
}


private actor ShortcutCancellationFixture: EudesAPIClient {
    private var pending: [CheckedContinuation<Void, Never>] = []
    var count: Int { pending.count }
    func models(profile: ServerProfile, key: String) async throws -> [String] { ["alpha"] }
    func complete(_ index: Int) { pending[index].resume() }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        await withCheckedContinuation { pending.append($0) }
        await onText("Réponse fictive")
    }
}

private struct CancelledGenerationFixture: EudesAPIClient {
    func models(profile: ServerProfile, key: String) async throws -> [String] { ["alpha"] }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        throw URLError(.cancelled)
    }
}

private struct FailingShortcutFixture: EudesAPIClient {
    func models(profile: ServerProfile, key: String) async throws -> [String] { ["alpha"] }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        throw URLError(.notConnectedToInternet)
    }
}

private actor ShortcutFixture: EudesAPIClient {
    private(set) var requests: [[ChatMessage]] = []
    private(set) var prompts: [String] = []
    private(set) var outputLimits: [Int?] = []
    func models(profile: ServerProfile, key: String) async throws -> [String] { ["alpha"] }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        requests.append(messages)
        prompts.append(systemPrompt)
        outputLimits.append(maxTokens)
        await onText("Réponse fictive")
    }
}

private actor EmptyLFMResumeFixture: EudesAPIClient {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var sends = 0
    var isWaiting: Bool { continuation != nil }
    func checkConnection(profile: ServerProfile, key: String) async throws -> ConnectionProof { .reachable }
    func models(profile: ServerProfile, key: String) async throws -> [String] { [] }
    func release() { continuation?.resume(); continuation = nil }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        sends += 1
        if sends == 1 {
            await onText("Réponse partielle")
            await withCheckedContinuation { continuation = $0 }
        } else {
            await onText("")
        }
    }
}

private struct LFMResumePlanner: WebResearchModelClient {
    func turn(profile: ServerProfile, key: String, model: String, messages: [ChatMessage],
              systemPrompt: String, temperature: Double, maxTokens: Int?,
              exchanges: [WebToolExchange]) async throws -> WebResearchTurn {
        exchanges.isEmpty ? WebResearchTurn(calls: [WebToolCall(id: "search", name: "web_search", arguments: #"{"query":"météo"}"#)]) : WebResearchTurn(calls: [])
    }
}

private actor BlockingLFMResumeSearch: WebSearching {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    var isWaiting: Bool { continuation != nil }
    func search(query: String) async throws -> WebSearchContext {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return WebSearchContext(query: query, fetchedAt: Date(), sources: [WebSource(url: URL(string: "https://example.org/weather")!, title: "Météo", excerpt: "Soleil", kind: .searchSnippet)])
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor ForbiddenLFMResumeSearch: WebSearching {
    private(set) var calls = 0
    func search(query: String) async throws -> WebSearchContext {
        calls += 1
        throw WebSearchError.networkUnavailable
    }
}

private actor BackgroundFixture: EudesAPIClient {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var sends = 0
    private(set) var inputMessages: [[ChatMessage]] = []
    var isWaiting: Bool { continuation != nil }
    func models(profile: ServerProfile, key: String) async throws -> [String] { ["alpha"] }
    func checkConnection(profile: ServerProfile, key: String) async throws -> ConnectionProof { .reachable }
    func complete() { continuation?.resume(); continuation = nil }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        sends += 1
        inputMessages.append(messages)
        await onText("Partiel")
        await withCheckedContinuation { continuation = $0 }
        // Deliberately ignores cancellation to exercise rejection of stale callbacks.
        await onText("Terminé")
    }
}

// LUE-16: all prompts and images below are synthetic; no real engine inference or network.
import FoundationModels

extension PrivateStorageTests {
    @MainActor
    func testAppleRoutingPersistenceAndModelLockWithoutCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesAppleTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let engine = BackgroundFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults,
                             client: ForbiddenAppleNetwork(), appleClient: engine,
                             appleAvailability: { .available }, readKey: { _ in XCTFail("No key for Apple"); return "" })
        store.saveSettings(prompt: "", temperature: 0.7, maxTokens: 512) // Explicit fixture reserve, not a model capacity.
        store.selectServer(ServerProfile.appleID)
        XCTAssertEqual(store.selectedServer?.id, ServerProfile.appleID)
        XCTAssertEqual(store.selectedServer?.model, ServerProfile.appleModel)
        XCTAssertEqual(store.currentModel, ServerProfile.appleModel)
        XCTAssertFalse(store.canAttachImages)
        let sent = await store.sendChecked("Question fictive"); XCTAssertTrue(sent)
        for _ in 0..<1000 { if store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        store.selectDraftModel("autre")
        XCTAssertEqual(store.current?.model, ServerProfile.appleModel)
        store.stop()
        await engine.complete()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.state, .interrupted)
        XCTAssertEqual(store.current?.messages.last?.text, "Partiel")
        let restored = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(), appleClient: engine, appleAvailability: { .disabled }, readKey: { _ in XCTFail("No key on restore"); return "" })
        XCTAssertEqual(restored.current?.model, ServerProfile.appleModel)
        XCTAssertEqual(restored.selectedServer?.id, ServerProfile.appleID)
        XCTAssertEqual(restored.data.servers.count, 0)
        XCTAssertEqual(restored.appleStatus, .disabled)
    }

    @MainActor
    func testAppleUnavailableDoesNotCreateConversationAndPreservesImageDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesAppleUnavailable." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(),
                             appleClient: UnavailableAppleFixture(), appleAvailability: { .notReady }, readKey: { _ in XCTFail("No key"); return "" })
        store.selectServer(ServerProfile.appleID)
        let image = ImageAttachment(data: Data([1, 2, 3]))
        store.addImage(image)
        let sent = await store.sendChecked("Fictif"); XCTAssertFalse(sent)
        XCTAssertNil(store.current)
        XCTAssertEqual(store.draftImages, [image])
        XCTAssertEqual(store.connectionState, .idle)
        XCTAssertFalse(store.connectionChoices.contains(where: { $0.isApple }))
        XCTAssertThrowsError(try AppleModelClient.validate(model: ServerProfile.appleModel, messages: [ChatMessage(role: .user, text: "Fictif", images: [image])]))
        for status: AppleModelAvailability in [.unsupportedOS, .ineligible, .disabled, .notReady, .unknown] {
            XCTAssertFalse(status.message.isEmpty)
        }
    }

    func testAppleTranscriptRolesAndExplicitInstructionsOnly() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires Foundation Models SDK runtime") }
        let messages = [ChatMessage(role: .user, text: "Fictif"), ChatMessage(role: .assistant, text: "Réponse"), ChatMessage(role: .assistant, text: "Partiel", state: .interrupted)]
        let empty = AppleModelClient.transcript(messages: messages, instructions: "  ")
        XCTAssertEqual(empty.count, 2)
        guard case .prompt = empty[0], case .response = empty[1] else { return XCTFail("Roles must be preserved") }
        let explicit = AppleModelClient.transcript(messages: messages, instructions: "Instruction volontaire")
        XCTAssertEqual(explicit.count, 3)
        guard case .instructions(let entry) = explicit[0], case .text(let text) = entry.segments[0] else { return XCTFail("Missing instruction") }
        XCTAssertEqual(text.content, "Instruction volontaire")
        XCTAssertTrue(entry.toolDefinitions.isEmpty)
    }

    func testAppleContextAndRefusalErrorsAreActionable() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires Foundation Models") }
        let error = LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "fixture"))
        XCTAssertEqual(friendlyError(AppleModelClient.generationError(error)), AppleModelError.context.localizedDescription)
        if #available(iOS 27.0, *) {
            let modern = LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "fixture"))
            XCTAssertEqual(friendlyError(AppleModelClient.generationError(modern)), AppleModelError.context.localizedDescription)
        }
        XCTAssertFalse(AppleModelError.refusal.localizedDescription.isEmpty)
        XCTAssertFalse(AppleModelError.language.localizedDescription.isEmpty)
    }

    @MainActor
    func testAppleFailureLocksFirstTurnAndRemoteConversationIsUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesAppleFailure." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let remote = ServerProfile(name: "Fictif", baseURL: "https://192.168.254.254/v1", model: "remote-original", systemInstruction: "", creativity: 0.7)
        let old = Conversation(serverID: remote.id, model: "remote-original", messages: [ChatMessage(role: .user, text: "Fictif")])
        var data = AppData(); data.servers = [remote]; data.conversations = [old]
        try PrivateStorage(directory: directory).save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(), appleClient: FailingAppleFixture(), appleAvailability: { .available }, readKey: { _ in XCTFail("No key"); return "" })
        store.saveSettings(prompt: "", temperature: 0.7, maxTokens: 512) // Explicit fixture reserve, not a model capacity.
        store.selectServer(ServerProfile.appleID)
        let sent = await store.sendChecked("Fictif"); XCTAssertTrue(sent)
        for _ in 0..<1000 { if !store.isGenerating { break }; await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.state, .failed)
        XCTAssertEqual(store.notice, AppleModelError.context.localizedDescription)
        XCTAssertEqual(store.current?.model, ServerProfile.appleModel)
        store.selectDraftModel("remote-original")
        XCTAssertEqual(store.current?.model, ServerProfile.appleModel)
        store.selectConversation(old)
        XCTAssertEqual(store.current, old)
        XCTAssertEqual(store.selectedServer, remote)
        XCTAssertEqual(store.data.servers, [remote])
    }

    @MainActor
    func testAppleContextLimitsAreReadOncePerAvailabilityRefreshNotPerSelectedServerAccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesAppleLimitsCache." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        var reads = 0
        let fixture = ModelLimits(advertised: [TokenLimit(tokens: 4096, source: "fixture")])
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(),
                             appleAvailability: { .available },
                             appleContextLimits: { reads += 1; return fixture },
                             readKey: { _ in "" })
        let afterInit = reads
        XCTAssertGreaterThan(afterInit, 0)
        for _ in 0..<20 { _ = store.selectedServer }
        XCTAssertEqual(reads, afterInit)
        XCTAssertEqual(store.selectedServer?.limits(for: ServerProfile.appleModel).context, 4096)
        store.refreshAppleAvailability()
        XCTAssertEqual(reads, afterInit + 1)
        for _ in 0..<20 { _ = store.selectedServer }
        XCTAssertEqual(reads, afterInit + 1)
    }
}

private struct ForbiddenAppleNetwork: EudesAPIClient {
    func models(profile: ServerProfile, key: String) async throws -> [String] { XCTFail("Unexpected remote call"); throw URLError(.badURL) }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String, temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws { XCTFail("Unexpected remote generation") }
}
private struct UnavailableAppleFixture: EudesAPIClient {
    func models(profile: ServerProfile, key: String) async throws -> [String] { throw AppleModelError.unavailable(.notReady) }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String, temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws { XCTFail("Unavailable must not generate") }
}
private struct FailingAppleFixture: EudesAPIClient {
    func models(profile: ServerProfile, key: String) async throws -> [String] { [ServerProfile.appleModel] }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String, temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws { throw AppleModelError.context }
}

extension PrivateStorageTests {
    @MainActor
    func testUnifiedSelectionDefaultsAvailabilityAndPersistence() throws {
        for status: AppleModelAvailability in [.available, .unsupportedOS, .ineligible, .disabled, .notReady, .unknown] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let suite = "Eudes18." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
            let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(), appleAvailability: { status }, readKey: { _ in XCTFail("No key read"); return "" })
            XCTAssertEqual(store.connectionChoices.map(\.id),
                           (status == .available ? [ServerProfile.appleID] : []) + [ServerProfile.lfmTextID, ServerProfile.lfmVisionID])
            XCTAssertEqual(store.selectedServer?.id, status == .available ? ServerProfile.appleID : nil)
            store.selectServer(ServerProfile.appleID)
            XCTAssertEqual(store.selectedServer?.id, status == .available ? ServerProfile.appleID : nil)
            let restored = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(), appleAvailability: { status }, readKey: { _ in "" })
            XCTAssertEqual(restored.data.selectedServerID, store.data.selectedServerID)
        }
    }

    @MainActor
    func testUnifiedSelectionPreservesProfilesConversationsAndTemporaryAppleChoice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Eudes18Selection." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let remote = ServerProfile(name: "Fictif", baseURL: "https://192.168.254.254/v1", model: "alpha", systemInstruction: "", creativity: 0.7)
        let conversation = Conversation(serverID: remote.id, model: "locked")
        var data = AppData(); data.servers = [remote]; data.selectedServerID = remote.id; data.conversations = [conversation]
        let storage = try PrivateStorage(directory: directory); try storage.save(data)
        var status = AppleModelAvailability.available
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(), appleAvailability: { status }, readKey: { _ in "" })
        XCTAssertEqual(store.selectedServer, remote)
        store.selectConversation(conversation)
        XCTAssertEqual(store.currentModel, "locked")
        store.refreshAppleAvailability()
        XCTAssertEqual(store.current?.id, conversation.id)
        store.selectServer(ServerProfile.appleID)
        XCTAssertEqual(store.current?.id, conversation.id)
        XCTAssertEqual(store.currentModel, ServerProfile.appleModel)
        store.newConversation()
        status = .notReady; store.refreshAppleAvailability()
        XCTAssertNil(store.selectedServer)
        XCTAssertEqual(store.data.selectedServerID, ServerProfile.appleID)
        status = .available; store.refreshAppleAvailability()
        XCTAssertEqual(store.selectedServer?.id, ServerProfile.appleID)
        store.selectConversation(conversation)
        XCTAssertEqual(store.selectedServer?.id, ServerProfile.appleID)
        XCTAssertEqual(store.currentModel, ServerProfile.appleModel)
        store.selectServer(remote.id)
        XCTAssertEqual(store.selectedServer, remote)
        XCTAssertEqual(store.currentModel, "alpha")
        XCTAssertEqual(store.data.servers, [remote])
    }

    @MainActor
    func testUnifiedSelectionDeletionDoesNotRetargetStartedConversation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Eudes18Deletion." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let remote = ServerProfile(name: "Fictif", baseURL: "https://192.168.254.254/v1", model: "alpha", systemInstruction: "", creativity: 0.7)
        let conversation = Conversation(serverID: remote.id, model: "locked", messages: [ChatMessage(role: .user, text: "Fictif")])
        var data = AppData(); data.servers = [remote]; data.selectedServerID = remote.id
        data.conversations = [conversation]; data.selectedConversationID = conversation.id
        try PrivateStorage(directory: directory).save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(), appleAvailability: { .available }, readKey: { _ in "" })
        store.deleteServer(remote)
        XCTAssertNil(store.selectedServer)
        XCTAssertEqual(store.current, conversation)
        store.newConversation()
        XCTAssertEqual(store.selectedServer?.id, ServerProfile.appleID)
        XCTAssertEqual(store.data.conversations, [conversation])
        store.selectConversation(conversation)
        XCTAssertNil(store.selectedServer)
        XCTAssertEqual(store.currentModel, "locked")
    }
}

extension PrivateStorageTests {
    @MainActor
    func testUnifiedSelectionNeverDefaultsOverUnselectedConfiguredServerOrAppleHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Eudes18History." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        var data = AppData()
        data.servers = [ServerProfile(name: "Fictif", baseURL: "https://192.168.254.254/v1", model: "alpha")]
        let storage = try PrivateStorage(directory: directory); try storage.save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(), appleAvailability: { .available }, readKey: { _ in "" })
        XCTAssertNil(store.selectedServer)
        XCTAssertNil(store.data.selectedServerID)
        let old = Conversation(serverID: ServerProfile.appleID, model: ServerProfile.appleModel, messages: [ChatMessage(role: .user, text: "Fictif")])
        data.conversations = [old]; data.selectedConversationID = old.id; data.selectedServerID = ServerProfile.appleID
        try storage.save(data)
        let restored = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(), appleClient: UnavailableAppleFixture(), appleAvailability: { .notReady }, readKey: { _ in XCTFail("No key"); return "" })
        XCTAssertEqual(restored.current, old)
        XCTAssertEqual(restored.selectedServer?.id, ServerProfile.appleID)
        XCTAssertFalse(restored.connectionChoices.contains(where: { $0.isApple }))
        let ready = await restored.checkConnection(); XCTAssertFalse(ready)
        XCTAssertEqual(restored.connectionState, .failed(AppleModelAvailability.notReady.message))
        XCTAssertEqual(restored.current, old)
    }
}

extension PrivateStorageTests {
    func testPasteProviderImportsSyntheticPNGAndRejectsText() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).pngData { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let provider = NSItemProvider(item: png as NSData, typeIdentifier: "public.png")
        let image = try await PastedImageLoader.load(provider)
        XCTAssertNotNil(UIImage(data: image.data))
        XCTAssertTrue(image.data.starts(with: [0xff, 0xd8]))
        let generic = NSItemProvider(item: png as NSData, typeIdentifier: "public.image")
        let genericImage = try await PastedImageLoader.load(generic)
        XCTAssertNotNil(UIImage(data: genericImage.data))
        let text = NSItemProvider(item: "Fictif" as NSString, typeIdentifier: "public.utf8-plain-text")
        do { _ = try await PastedImageLoader.load(text); XCTFail("Text is not an image") }
        catch { XCTAssertTrue(error is ImageAttachmentError) }
    }
    func testImageCompatibilityExplanationsDistinguishUnknownUnsupportedAndApple() {
        var profile = ServerProfile(name: "Fictif", baseURL: "https://192.168.254.254/v1", model: "vision")
        XCTAssertTrue(profile.imageUnavailableReason("vision")!.contains("non déterminée"))
        profile.imageCompatibility = [profile.visionKey("vision"): "unsupported"]
        XCTAssertEqual(profile.imageUnavailableReason("vision"), "Ce modèle n’accepte pas les images.")
        profile.imageCompatibility = [profile.visionKey("vision"): "supported"]
        XCTAssertNil(profile.imageUnavailableReason("vision"))
        XCTAssertNotNil(profile.imageUnavailableReason("other"))
        XCTAssertEqual(ServerProfile.apple.imageUnavailableReason(ServerProfile.appleModel), "Ce modèle n’accepte pas les images.")
        XCTAssertFalse(ServerProfile.apple.supportsImages(ServerProfile.appleModel))
    }
}

extension PrivateStorageTests {
    @MainActor
    func testClipboardPreviewRequiresActiveContextAndDoesNotRepeatedlyRetryDenial() {
        var reads = 0, count = 1
        let suite = "ClipboardDenied." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preview = ClipboardImagePreview(changeCount: { count }, containsImage: { true }, providers: { reads += 1; return [] }, dismissal: ClipboardImageDismissal(defaults: defaults))
        preview.refresh(active: false)
        XCTAssertEqual(reads, 0)
        preview.refresh(active: true)
        XCTAssertEqual(reads, 1)
        XCTAssertNil(preview.image)
        XCTAssertNotNil(preview.message)
        preview.refresh(active: false); preview.refresh(active: true); preview.refresh(active: true)
        XCTAssertEqual(reads, 1, "A refusal must not loop at refocus or foreground")
        count = 2; preview.refresh(active: true)
        XCTAssertEqual(reads, 2, "A different copy is a new preview request")
    }
    @MainActor
    func testClipboardPreviewLoadsFixtureAndInvalidatesChangedContent() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        var count = 1, hasImage = true, reads = 0
        let suite = "ClipboardPreview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preview = ClipboardImagePreview(changeCount: { count }, containsImage: { hasImage }, providers: {
            reads += 1; return [NSItemProvider(item: png as NSData, typeIdentifier: "public.png")]
        }, dismissal: ClipboardImageDismissal(defaults: defaults))
        preview.refresh(active: true)
        for _ in 0..<100 { if preview.image != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(preview.image); XCTAssertTrue(preview.isCurrent)
        preview.refresh(active: true); XCTAssertEqual(reads, 1)
        count = 2; hasImage = false; preview.refresh(active: true)
        XCTAssertFalse(preview.hasImage); XCTAssertNil(preview.image); XCTAssertFalse(preview.isCurrent)
        count = 3; hasImage = true; preview.refresh(active: true)
        for _ in 0..<100 { if preview.image != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(preview.image); XCTAssertEqual(reads, 2)
    }
    @MainActor
    func testDismissClipboardProposalDoesNotReadAgainUntilNewCopy() {
        var count = 1, reads = 0
        var containsImage = true
        let suite = "ClipboardDismiss." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dismissal = ClipboardImageDismissal(defaults: defaults)
        let preview = ClipboardImagePreview(changeCount: { count }, containsImage: { containsImage }, providers: { reads += 1; return [] }, dismissal: dismissal)
        preview.refresh(active: true)
        XCTAssertTrue(preview.hasImage); XCTAssertEqual(reads, 1)
        preview.dismiss()
        preview.refresh(active: true); preview.refresh(active: false); preview.refresh(active: true)
        XCTAssertFalse(preview.hasImage); XCTAssertEqual(reads, 1)
        // A recreated conversation view keeps the dismissal without reading again.
        let recreated = ClipboardImagePreview(changeCount: { count }, containsImage: { containsImage }, providers: { reads += 1; return [] }, dismissal: ClipboardImageDismissal(defaults: defaults))
        recreated.refresh(active: true)
        XCTAssertFalse(recreated.hasImage); XCTAssertEqual(reads, 1)
        count = 2; recreated.refresh(active: true)
        XCTAssertFalse(recreated.hasImage, "A counter change alone cannot identify a different image when the rejected preview never loaded")
        XCTAssertNil(recreated.message)
        XCTAssertEqual(reads, 1, "An unresolved dismissal must not request paste access again")
        count = 3; containsImage = false; recreated.refresh(active: true)
        XCTAssertFalse(recreated.hasImage)
        XCTAssertNil(dismissal.changeCount, "Non-image clipboard content ends the previous refusal")
        count = 4; containsImage = true; recreated.refresh(active: true)
        XCTAssertTrue(recreated.hasImage); XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testDismissedImageStaysHiddenAcrossCounterChangesButDifferentImageAppears() async throws {
        func image(_ color: UIColor) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { ctx in
                color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
        }
        let firstImage = image(.gray), secondImage = image(.red)
        var content = firstImage, count = 1, reads = 0
        let suite = "ClipboardDigest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dismissal = ClipboardImageDismissal(defaults: defaults)
        func makePreview() -> ClipboardImagePreview {
            ClipboardImagePreview(changeCount: { count }, containsImage: { true }, providers: {
                reads += 1; return [NSItemProvider(item: content as NSData, typeIdentifier: "public.png")]
            }, dismissal: ClipboardImageDismissal(defaults: defaults))
        }
        let initial = makePreview()
        initial.refresh(active: true)
        for _ in 0..<100 { if initial.image != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(initial.image)
        initial.dismiss()
        XCTAssertEqual(dismissal.digest?.count, 32)
        let reopened = makePreview()
        count = 2; reopened.refresh(active: true)
        XCTAssertFalse(reopened.hasImage, "Do not flash the dismissed image while checking")
        for _ in 0..<100 { if dismissal.changeCount == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(dismissal.changeCount, 2)
        XCTAssertFalse(reopened.hasImage)
        XCTAssertNil(reopened.image)
        count = 3; content = secondImage; reopened.refresh(active: true)
        XCTAssertFalse(reopened.hasImage)
        for _ in 0..<100 { if reopened.image != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(reopened.hasImage)
        XCTAssertNotNil(reopened.image)
        XCTAssertNil(dismissal.digest)
        XCTAssertEqual(reads, 3)
    }

    @MainActor
    func testDismissedDigestRechecksCounterCollisionAfterRelaunch() async throws {
        func image(_ color: UIColor) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { ctx in
                color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
        }
        var content = image(.gray)
        let suite = "ClipboardCounterCollision." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func makePreview() -> ClipboardImagePreview {
            ClipboardImagePreview(changeCount: { 1 }, containsImage: { true }, providers: {
                [NSItemProvider(item: content as NSData, typeIdentifier: "public.png")]
            }, dismissal: ClipboardImageDismissal(defaults: defaults))
        }
        let original = makePreview(); original.refresh(active: true)
        for _ in 0..<100 { if original.image != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(original.image)
        original.dismiss()
        content = image(.red)
        let afterRelaunch = makePreview(); afterRelaunch.refresh(active: true)
        XCTAssertFalse(afterRelaunch.hasImage)
        for _ in 0..<100 { if afterRelaunch.image != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(afterRelaunch.hasImage)
        XCTAssertNotNil(afterRelaunch.image)
    }

    @MainActor
    func testDismissalKeepsInFlightImagePreviewHidden() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .all) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { completion(png, nil) }
            return nil
        }
        let suite = "ClipboardCancel." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preview = ClipboardImagePreview(changeCount: { 1 }, containsImage: { true }, providers: { [provider] }, dismissal: ClipboardImageDismissal(defaults: defaults))
        preview.refresh(active: true)
        XCTAssertTrue(preview.hasImage)
        preview.dismiss()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(preview.hasImage)
        XCTAssertNil(preview.image)
        XCTAssertNil(preview.message)
    }

    @MainActor
    func testDismissedProposalStaysHiddenWhenPasteAccessDenied() {
        let suite = "ClipboardDigestDenied." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dismissal = ClipboardImageDismissal(defaults: defaults)
        dismissal.changeCount = 1
        dismissal.digest = Data(repeating: 1, count: 32)
        let preview = ClipboardImagePreview(changeCount: { 2 }, containsImage: { true }, providers: { [] }, dismissal: dismissal)
        preview.refresh(active: true)
        XCTAssertFalse(preview.hasImage, "Denied comparison cannot prove that a rejected image changed")
        XCTAssertNil(preview.message)
        XCTAssertEqual(dismissal.changeCount, 1)
        XCTAssertNotNil(dismissal.digest)
    }

    @MainActor
    func testDismissalBeforeThumbnailLoadsKeepsDigestAndHidesSameImageAfterCounterChange() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let delayed = DeferredClipboardProvider()
        let suite = "ClipboardDismissBeforeThumbnail." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dismissal = ClipboardImageDismissal(defaults: defaults)
        var count = 1, reads = 0
        let preview = ClipboardImagePreview(changeCount: { count }, containsImage: { true }, providers: {
            reads += 1
            return reads == 1 ? [delayed.provider] : [NSItemProvider(item: png as NSData, typeIdentifier: "public.png")]
        }, dismissal: dismissal)
        preview.refresh(active: true)
        try await delayed.waitForRequest()
        XCTAssertTrue(preview.hasImage)
        XCTAssertNil(preview.image)
        preview.dismiss()
        preview.refresh(active: false); preview.refresh(active: true)
        XCTAssertEqual(reads, 1)
        delayed.finish(data: png)
        for _ in 0..<100 { if dismissal.digest != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(dismissal.digest?.count, 32, "An already authorized load may retain its fingerprint, never its dismissed thumbnail")
        XCTAssertFalse(preview.hasImage)
        XCTAssertNil(preview.image)
        XCTAssertNil(preview.message)

        count = 2; preview.refresh(active: true)
        XCTAssertFalse(preview.hasImage, "The dismissed proposal must not flash while its fingerprint is checked")
        for _ in 0..<100 { if dismissal.changeCount == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(dismissal.changeCount, 2)
        XCTAssertFalse(preview.hasImage)
        XCTAssertNil(preview.image)
        XCTAssertNil(preview.message)
        preview.refresh(active: false); preview.refresh(active: true)
        XCTAssertFalse(preview.hasImage)
        XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testFailedReadCannotRestoreDismissedClipboardProposal() async throws {
        let delayed = DeferredClipboardProvider()
        let suite = "ClipboardDismissedReadFailure." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dismissal = ClipboardImageDismissal(defaults: defaults)
        let digest = Data(repeating: 1, count: 32)
        dismissal.changeCount = 1
        dismissal.digest = digest
        let preview = ClipboardImagePreview(changeCount: { 2 }, containsImage: { true }, providers: { [delayed.provider] }, dismissal: dismissal)
        preview.refresh(active: true)
        try await delayed.waitForRequest()
        XCTAssertFalse(preview.hasImage)
        delayed.finish(error: NSError(domain: "ClipboardFixture", code: 1))
        // Observe the failure callback after it has been released, including any late UI update.
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        preview.refresh(active: false); preview.refresh(active: true)
        XCTAssertFalse(preview.hasImage)
        XCTAssertNil(preview.image)
        XCTAssertNil(preview.message)
        XCTAssertEqual(dismissal.changeCount, 1)
        XCTAssertEqual(dismissal.digest, digest)
    }

    @MainActor
    func testOlderPreviewLoadCannotOverrideDismissalFromAnotherPreview() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let delayed = DeferredClipboardProvider()
        let suite = "ClipboardSharedDismissal." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dismissal = ClipboardImageDismissal(defaults: defaults)
        let oldPreview = ClipboardImagePreview(changeCount: { 1 }, containsImage: { true }, providers: { [delayed.provider] }, dismissal: dismissal)
        oldPreview.refresh(active: true)
        try await delayed.waitForRequest()
        let newPreview = ClipboardImagePreview(changeCount: { 1 }, containsImage: { true }, providers: {
            [NSItemProvider(item: png as NSData, typeIdentifier: "public.png")]
        }, dismissal: ClipboardImageDismissal(defaults: defaults))
        newPreview.refresh(active: true)
        for _ in 0..<100 { if newPreview.image != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(newPreview.image)
        newPreview.dismiss()
        let rejectedDigest = try XCTUnwrap(dismissal.digest)
        delayed.finish(data: png)
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(oldPreview.hasImage, "A loader started before a newer refusal cannot publish its thumbnail")
        XCTAssertNil(oldPreview.image)
        XCTAssertNil(oldPreview.message)
        XCTAssertFalse(newPreview.hasImage)
        XCTAssertEqual(dismissal.changeCount, 1)
        XCTAssertEqual(dismissal.digest, rejectedDigest, "An old loader cannot erase the latest shared refusal")
    }

    @MainActor
    func testOlderDismissedLoadCannotReplaceNewerDigestFromAnotherLedger() async throws {
        func image(_ color: UIColor) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { ctx in
                color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
        }
        let gray = image(.gray), red = image(.red)
        let delayed = DeferredClipboardProvider()
        let suite = "ClipboardSharedDismissalRevision." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstLedger = ClipboardImageDismissal(defaults: defaults)
        let first = ClipboardImagePreview(changeCount: { 1 }, containsImage: { true }, providers: {
            [delayed.provider]
        }, dismissal: firstLedger)
        first.refresh(active: true)
        try await delayed.waitForRequest()

        // Both views begin before either refusal, but share the persisted decision.
        let secondLedger = ClipboardImageDismissal(defaults: defaults)
        let second = ClipboardImagePreview(changeCount: { 1 }, containsImage: { true }, providers: {
            [NSItemProvider(item: red as NSData, typeIdentifier: "public.png")]
        }, dismissal: secondLedger)
        second.refresh(active: true)
        for _ in 0..<100 { if second.image != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(second.image)
        first.dismiss()
        XCTAssertNil(firstLedger.digest)
        second.dismiss()
        let newestDigest = try XCTUnwrap(secondLedger.digest)
        XCTAssertEqual(firstLedger.digest, newestDigest)

        delayed.finish(data: gray)
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(first.hasImage)
        XCTAssertNil(first.image)
        XCTAssertFalse(second.hasImage)
        XCTAssertEqual(firstLedger.digest, newestDigest, "The completed gray load must not overwrite the newer red-image refusal")
        XCTAssertEqual(secondLedger.digest, newestDigest)
        XCTAssertEqual(secondLedger.changeCount, 1)
    }

    @MainActor
    func testNativeImagePasteRoutesWithoutReplacingDraftText() {
        let view = ImagePasteTextView()
        view.text = "Brouillon fictif"
        view.imagePresence = { true }
        var requests = 0
        view.onImagePaste = { requests += 1 }
        XCTAssertTrue(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        view.paste(nil)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(view.text, "Brouillon fictif")
        var delivered = 0
        view.onProviders = { delivered = $0.count }
        view.paste(itemProviders: [NSItemProvider(item: Data([1]) as NSData, typeIdentifier: "public.png")])
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(view.text, "Brouillon fictif")
    }
    @MainActor
    func testNativeTextProviderPasteRemainsText() async throws {
        let view = ImagePasteTextView()
        var successes = 0
        view.onSuccessfulTextPaste = { successes += 1 }
        view.text = "Début "
        view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
        view.imagePresence = { false }
        view.onProviders = { _ in XCTFail("Text must not become an attachment") }
        view.paste(itemProviders: [NSItemProvider(object: "fictif" as NSString)])
        for _ in 0..<100 { if view.text.contains("fictif") { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(view.text, "Début fictif")
        XCTAssertEqual(successes, 1)
    }
    @MainActor
    func testPasteHelpIsOnlyClaimedAfterSuccessAndSurvivesRestart() throws {
        let suite = "PasteHelp." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(storageDirectory: directory, defaults: defaults)
        XCTAssertFalse(store.claimPasteHelp()) // No success, including denial/import failure.
        store.recordSuccessfulPaste()
        XCTAssertTrue(store.pasteHelpPending)
        XCTAssertTrue(store.claimPasteHelp())
        XCTAssertFalse(store.claimPasteHelp())
        store.recordSuccessfulPaste()
        XCTAssertFalse(store.pasteHelpPending)
        let reopened = AppStore(storageDirectory: directory, defaults: defaults)
        reopened.recordSuccessfulPaste()
        XCTAssertFalse(reopened.claimPasteHelp()) // Both dismiss and return from Settings.
    }

    @MainActor
    func testRepeatedPastedImageIsDeduplicatedAndCanBeAddedAfterRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Eudes19Duplicates." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(), appleAvailability: { .ineligible }, readKey: { _ in "" })
        let first = ImageAttachment(data: Data([1,2,3]))
        store.addPastedImage(first)
        store.addPastedImage(ImageAttachment(data: first.data))
        XCTAssertEqual(store.draftImages.count, 1)
        store.removeImage(first.id)
        store.addPastedImage(first)
        XCTAssertEqual(store.draftImages, [first])
        let second = ImageAttachment(data: Data([4,5,6]))
        store.addImage(second)
        store.removeImage(first.id)
        XCTAssertEqual(store.draftImages, [second])
        store.addImage(first)
        XCTAssertEqual(store.draftImages, [second, first])
        XCTAssertEqual(first.data, Data([1,2,3]))
        let restored = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(), appleAvailability: { .ineligible }, readKey: { _ in "" })
        XCTAssertEqual(restored.draftImages, [second, first])
    }
}

private actor CatalogGateFixture: EudesAPIClient {
    private(set) var started = false
    private var continuation: CheckedContinuation<ModelCatalog, Never>?
    func models(profile: ServerProfile, key: String) async throws -> [String] { ["alpha", "beta"] }
    func catalog(profile: ServerProfile, key: String) async throws -> ModelCatalog {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: ModelCatalog(ids: ["alpha", "beta"], limits: ["alpha": ModelLimits(advertised: [TokenLimit(tokens: 1000, source: "fixture")])]))
        continuation = nil
    }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String, temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws { XCTFail("No generation in discovery test") }
}

/// A controllable scheduler for exercising real generation and persistence without
/// claiming that a simulator reproduces iOS background execution budgets.
@MainActor
private final class ResponseContinuationFixture: ResponseContinuationScheduling {
    struct Registration {
        let token: UUID
        let granted: @MainActor (UUID) -> Void
        let expired: @MainActor (UUID) -> Void
    }
    private(set) var registrations: [Registration] = []
    private(set) var finishes: [(UUID, Bool)] = []
    private(set) var updates: [(UUID, Int64)] = []
    var onFinish: (@MainActor (UUID, Bool) -> Void)?
    func start(token: UUID, onGranted: @escaping @MainActor (UUID) -> Void,
               onExpired: @escaping @MainActor (UUID) -> Void) {
        registrations.append(Registration(token: token, granted: onGranted, expired: onExpired))
    }
    func update(token: UUID, completedBytes: Int64) { updates.append((token, completedBytes)) }
    func finish(token: UUID, success: Bool) {
        finishes.append((token, success))
        onFinish?(token, success)
    }
    func grant(_ index: Int) { let entry = registrations[index]; entry.granted(entry.token) }
    func expire(_ index: Int) { let entry = registrations[index]; entry.expired(entry.token) }
}

@MainActor
private struct ResponseContinuationHarness {
    let store: AppStore
    let scheduler: ResponseContinuationFixture
    let client: BackgroundFixture
    let storage: PrivateStorage
    let directory: URL
    let defaults: UserDefaults
    let suite: String

    static func make(active: Bool = true) throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesContinuation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profile = ServerProfile(name: "Fictif", baseURL: "https://192.168.254.254/v1", model: "alpha")
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
        let storage = try PrivateStorage(directory: directory); try storage.save(data)
        let scheduler = ResponseContinuationFixture()
        let client = BackgroundFixture()
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: client,
                             readKey: { _ in "" }, responseContinuation: scheduler,
                             applicationIsActive: { active })
        return Self(store: store, scheduler: scheduler, client: client, storage: storage,
                    directory: directory, defaults: defaults, suite: suite)
    }
    func clean() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
}

extension PrivateStorageTests {
    @MainActor
    func testContinuedResponseFinishesAfterBackgroundWithoutSecondRequest() async throws {
        let h = try ResponseContinuationHarness.make(); defer { h.clean() }
        var persistedAtFinish: String?
        h.scheduler.onFinish = { _, success in
            if success { persistedAtFinish = try? h.storage.load().conversations.first?.messages.last?.text }
        }
        let sent = await h.store.sendChecked("Question fictive"); XCTAssertTrue(sent)
        for _ in 0..<1000 { if h.store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        XCTAssertEqual(h.store.current?.messages.last?.text, "Partiel")
        XCTAssertEqual(h.scheduler.registrations.count, 1)
        XCTAssertEqual(h.scheduler.updates.last?.1, Int64("Partiel".utf8.count))
        h.scheduler.grant(0)
        h.store.sceneChanged(.background)
        await h.client.complete()
        for _ in 0..<1000 { if !h.store.isGenerating { break }; await Task.yield() }
        XCTAssertFalse(h.store.isGenerating)
        XCTAssertEqual(h.store.current?.messages.last?.text, "Terminé")
        XCTAssertEqual(h.store.current?.messages.last?.state, .complete)
        h.store.sceneChanged(.active)
        XCTAssertEqual(try h.storage.load().conversations.first?.messages.last?.text, "Terminé")
        let sends = await h.client.sends; XCTAssertEqual(sends, 1)
        XCTAssertEqual(h.scheduler.finishes.count, 1)
        XCTAssertTrue(try XCTUnwrap(h.scheduler.finishes.first).1)
        XCTAssertEqual(persistedAtFinish, "Terminé")
        h.scheduler.onFinish = nil
    }

    @MainActor
    func testUnclaimedContinuationKeepsShortFallbackAndPreservesPartialResponse() async throws {
        let h = try ResponseContinuationHarness.make(); defer { h.clean() }
        let sent = await h.store.sendChecked("Question fictive"); XCTAssertTrue(sent)
        for _ in 0..<1000 { if h.store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        XCTAssertEqual(h.scheduler.registrations.count, 1)
        // No grant simulates a refused or unstarted long-running request.
        h.store.sceneChanged(.background)
        XCTAssertTrue(h.store.isGenerating)
        h.store.expireBackgroundGeneration()
        XCTAssertFalse(h.store.isGenerating)
        XCTAssertEqual(h.store.current?.messages.last?.text, "Partiel")
        XCTAssertEqual(h.store.current?.messages.last?.state, .interrupted)
        XCTAssertEqual(try h.storage.load().conversations.first?.messages.last?.text, "Partiel")
        await h.client.complete()
        for _ in 0..<100 { await Task.yield() }
        let sends = await h.client.sends; XCTAssertEqual(sends, 1)
        XCTAssertEqual(h.store.current?.messages.last?.text, "Partiel")
    }

    @MainActor
    func testContinuedResponseExpirationIsIdempotentAndKeepsPartial() async throws {
        let h = try ResponseContinuationHarness.make(); defer { h.clean() }
        let sent = await h.store.sendChecked("Question fictive"); XCTAssertTrue(sent)
        for _ in 0..<1000 { if h.store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        XCTAssertEqual(h.scheduler.registrations.count, 1)
        h.scheduler.grant(0)
        h.scheduler.expire(0); h.scheduler.expire(0)
        XCTAssertFalse(h.store.isGenerating)
        XCTAssertEqual(h.store.current?.messages.last?.state, .interrupted)
        XCTAssertEqual(h.store.current?.messages.last?.text, "Partiel")
        XCTAssertEqual(try h.storage.load().conversations.first?.messages.last?.state, .interrupted)
        XCTAssertEqual(h.scheduler.finishes.count, 1)
        XCTAssertFalse(try XCTUnwrap(h.scheduler.finishes.first).1)
        await h.client.complete()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(h.store.current?.messages.last?.text, "Partiel")
        let sends = await h.client.sends; XCTAssertEqual(sends, 1)
    }

    @MainActor
    func testOldContinuationExpirationCannotInterruptNewResponse() async throws {
        let h = try ResponseContinuationHarness.make(); defer { h.clean() }
        let first = await h.store.sendChecked("Première question"); XCTAssertTrue(first)
        for _ in 0..<1000 { if h.store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        XCTAssertEqual(h.scheduler.registrations.count, 1)
        h.scheduler.grant(0)
        h.store.stop(reason: .user)
        await h.client.complete()
        for _ in 0..<100 { await Task.yield() }
        let second = await h.store.sendChecked("Deuxième question"); XCTAssertTrue(second)
        for _ in 0..<1000 { if h.store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        XCTAssertEqual(h.scheduler.registrations.count, 2)
        h.scheduler.grant(1)
        h.scheduler.expire(0)
        XCTAssertTrue(h.store.isGenerating)
        await h.client.complete()
        for _ in 0..<1000 { if !h.store.isGenerating { break }; await Task.yield() }
        XCTAssertEqual(h.store.current?.messages.last?.text, "Terminé")
        XCTAssertEqual(h.store.current?.messages.last?.state, .complete)
        let sends = await h.client.sends; XCTAssertEqual(sends, 2)
        XCTAssertEqual(h.scheduler.finishes.count, 2)
    }

    @MainActor
    func testBackgroundStartedRequestDoesNotSubmitForegroundOnlyContinuation() async throws {
        let h = try ResponseContinuationHarness.make(active: false); defer { h.clean() }
        let sent = await h.store.sendChecked("Question fictive"); XCTAssertTrue(sent)
        for _ in 0..<1000 { if h.store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        XCTAssertTrue(h.scheduler.registrations.isEmpty)
        await h.client.complete()
        for _ in 0..<1000 { if !h.store.isGenerating { break }; await Task.yield() }
        XCTAssertEqual(h.store.current?.messages.last?.state, .complete)
        let sends = await h.client.sends; XCTAssertEqual(sends, 1)
    }

    @MainActor
    func testProtectedDataInterruptionReleasesGrantedContinuation() async throws {
        let h = try ResponseContinuationHarness.make(); defer { h.clean() }
        let sent = await h.store.sendChecked("Question fictive"); XCTAssertTrue(sent)
        for _ in 0..<1000 { if h.store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        XCTAssertEqual(h.scheduler.registrations.count, 1)
        h.scheduler.grant(0)
        h.store.protectedDataWillBecomeUnavailable()
        XCTAssertFalse(h.store.isGenerating)
        XCTAssertEqual(h.store.current?.messages.last?.state, .interrupted)
        XCTAssertEqual(h.store.current?.messages.last?.text, "Partiel")
        XCTAssertEqual(h.scheduler.finishes.count, 1)
        XCTAssertFalse(try XCTUnwrap(h.scheduler.finishes.first).1)
        h.scheduler.expire(0)
        XCTAssertEqual(h.scheduler.finishes.count, 1)
        await h.client.complete()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(h.store.current?.messages.last?.text, "Partiel")
    }

    @MainActor
    func testSiriShortcutDoesNotSubmitForegroundOnlyContinuation() async throws {
        let h = try ResponseContinuationHarness.make(); defer { h.clean() }
        let shortcut = Task { try await h.store.answerShortcut("Question fictive") }
        for _ in 0..<1000 { if h.store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        XCTAssertEqual(h.store.current?.messages.last?.text, "Partiel")
        XCTAssertTrue(h.scheduler.registrations.isEmpty)
        await h.client.complete()
        let answer = try await shortcut.value; XCTAssertEqual(answer, "Terminé")
        let sends = await h.client.sends; XCTAssertEqual(sends, 1)
    }

    @MainActor
    func testCompletedResponseReportsUnsuccessfulContinuationWhenSavingFails() async throws {
        let h = try ResponseContinuationHarness.make(); defer { h.clean() }
        let sent = await h.store.sendChecked("Question fictive"); XCTAssertTrue(sent)
        for _ in 0..<1000 { if h.store.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        XCTAssertEqual(h.store.current?.messages.last?.text, "Partiel")
        XCTAssertEqual(h.scheduler.registrations.count, 1)
        h.scheduler.grant(0)
        // Deterministically force an atomic-write failure in this isolated fixture.
        let file = h.directory.appendingPathComponent("workspace.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await h.client.complete()
        for _ in 0..<1000 { if !h.store.isGenerating { break }; await Task.yield() }
        XCTAssertFalse(h.store.isGenerating)
        XCTAssertEqual(h.scheduler.finishes.count, 1)
        XCTAssertFalse(try XCTUnwrap(h.scheduler.finishes.first).1)
        XCTAssertNotNil(h.store.notice)
    }

}

/// All requests and server jobs in these tests are synthetic, with no network access.
private actor RecoverableResponseFixture: RecoverableResponseClient {
    private(set) var starts = 0
    private(set) var retrieves = 0
    private(set) var cancellations = 0
    private(set) var createdCallbacks = 0
    private var remainingCancellationFailures = 0
    private var retrievalError: Int? = nil
    private var failBeforeCreated = false
    private var startHTTPError: Int?
    private var holdBeforeCreated = false
    private var pendingCreated: CheckedContinuation<Void, Never>?
    var isAwaitingCreated: Bool { pendingCreated != nil }
    private var nextSnapshot = RecoverableSnapshot(status: .completed, text: "Réponse finale", reasoning: nil, usage: nil)

    func setSnapshot(_ snapshot: RecoverableSnapshot) { nextSnapshot = snapshot }
    func failNextCancellations(_ count: Int) { remainingCancellationFailures = count }
    func setRetrievalError(_ code: Int?) { retrievalError = code }
    func setFailBeforeCreated(_ value: Bool) { failBeforeCreated = value }
    func setStartHTTPError(_ code: Int?) { startHTTPError = code }
    func holdIdentity() { holdBeforeCreated = true }
    func releaseIdentity() { pendingCreated?.resume(); pendingCreated = nil }
    func start(profile: ServerProfile, key: String, model: String, messages: [ChatMessage],
               systemPrompt: String, temperature: Double, maxTokens: Int?,
               onCreated: @escaping @MainActor (String) throws -> Void,
               onText: @escaping @MainActor (String) -> Void,
               onReasoning: @escaping @MainActor (String) -> Void,
               onUsage: @escaping @MainActor (TokenUsage) -> Void) async throws {
        starts += 1
        if let startHTTPError { throw EudesError.server(startHTTPError) }
        if failBeforeCreated { throw URLError(.networkConnectionLost) }
        if holdBeforeCreated { await withCheckedContinuation { pendingCreated = $0 } }
        do { try await onCreated("resp_fixture") }
        catch { createdCallbacks += 1; throw error }
        createdCallbacks += 1
        await onText("Partiel")
        try await Task.sleep(for: .seconds(3600))
    }
    func retrieve(profile: ServerProfile, key: String, responseID: String) async throws -> RecoverableSnapshot {
        retrieves += 1
        if retrievalError == 404 { throw EudesError.server(404) }
        if retrievalError != nil { throw URLError(.notConnectedToInternet) }
        return nextSnapshot
    }
    func cancel(profile: ServerProfile, key: String, responseID: String) async throws {
        cancellations += 1
        if remainingCancellationFailures > 0 {
            remainingCancellationFailures -= 1
            throw URLError(.notConnectedToInternet)
        }
    }
}

@MainActor
private final class RecoverableActivityFixture { var active = false }

@MainActor
private struct RecoverableStoreHarness {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let profile: ServerProfile
    let storage: PrivateStorage
    let activity: RecoverableActivityFixture
    let remote: RecoverableResponseFixture
    let ordinary: BackgroundFixture

    static func make(pending: Bool = false, overrideBase: String? = nil) throws -> RecoverableStoreHarness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesRecoverable." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var profile = ServerProfile(name: "Fictif", baseURL: overrideBase ?? "https://api.openai.com/v1", model: "alpha")
        profile.protocolKind = .responses
        profile.openAIBackgroundResponses = true
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id
        if pending {
            let reference = RemoteResponseReference(responseID: "resp_fixture", serverID: profile.id, baseURL: "https://api.openai.com/v1")
            var message = ChatMessage(role: .assistant, text: "Partiel", state: .interrupted)
            message.remoteResponse = reference
            let conversation = Conversation(serverID: profile.id, model: "alpha", messages: [ChatMessage(role: .user, text: "Question"), message])
            data.conversations = [conversation]; data.selectedConversationID = conversation.id
        }
        let storage = try PrivateStorage(directory: directory); try storage.save(data)
        return Self(directory: directory, defaults: defaults, suite: suite, profile: profile, storage: storage,
                    activity: RecoverableActivityFixture(), remote: RecoverableResponseFixture(), ordinary: BackgroundFixture())
    }
    func makeStore() -> AppStore {
        AppStore(storageDirectory: directory, defaults: defaults, client: ordinary,
                 readKey: { _ in "fixture-key" }, responseContinuation: NoResponseContinuation(),
                 recoverableClient: remote, applicationIsActive: { activity.active })
    }
    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
}

extension PrivateStorageTests {
    @MainActor
    func testRecoverableResponseSurvivesExpiryAndRelaunchWithoutPostingTwice() async throws {
        let h = try RecoverableStoreHarness.make(); defer { h.cleanup() }
        let first = h.makeStore()
        let sent = await first.sendChecked("Question fictive")
        XCTAssertTrue(sent)
        for _ in 0..<5000 { if first.current?.messages.last?.text == "Partiel" { break }; await Task.yield() }
        let partial = try XCTUnwrap(first.current?.messages.last)
        XCTAssertEqual(partial.remoteResponse?.responseID, "resp_fixture")
        XCTAssertEqual(try h.storage.load().conversations.first?.messages.last?.remoteResponse?.responseID, "resp_fixture")
        first.expireBackgroundGeneration()
        XCTAssertEqual(first.current?.messages.last?.state, .interrupted)
        XCTAssertEqual(first.current?.messages.last?.text, "Partiel")
        XCTAssertEqual(first.current?.messages.last?.remoteResponse?.responseID, "resp_fixture")
        h.activity.active = true
        let restarted = h.makeStore()
        for _ in 0..<10000 { if restarted.current?.messages.last?.state == .complete { break }; await Task.yield() }
        XCTAssertEqual(restarted.current?.messages.last?.text, "Réponse finale")
        XCTAssertEqual(restarted.current?.messages.last?.state, .complete)
        XCTAssertNil(restarted.current?.messages.last?.remoteResponse)
        XCTAssertEqual(try h.storage.load().conversations.first?.messages.last?.text, "Réponse finale")
        let starts = await h.remote.starts
        let retrieves = await h.remote.retrieves
        let ordinarySends = await h.ordinary.sends
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(retrieves, 1)
        XCTAssertEqual(ordinarySends, 0)
    }

    @MainActor
    func testRecoverableConsentPersistsWithoutAccessingKeychain() throws {
        let h = try RecoverableStoreHarness.make(); defer { h.cleanup() }
        let saved = try h.storage.load()
        let profile = try XCTUnwrap(saved.servers.first)
        XCTAssertEqual(profile.openAIBackgroundResponses, true)
        XCTAssertTrue(profile.usesOpenAIBackground)
        let encoded = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(ServerProfile.self, from: encoded)
        XCTAssertEqual(restored.openAIBackgroundResponses, true)
        XCTAssertTrue(restored.usesOpenAIBackground)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        raw.removeValue(forKey: "openAIBackgroundResponses")
        let legacy = try JSONDecoder().decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(legacy.openAIBackgroundResponses)
        XCTAssertFalse(legacy.usesOpenAIBackground)
    }

    @MainActor
    func testRecoverableReloadAfterStorageErrorStartsRecoveryWithoutSceneChange() async throws {
        let h = try RecoverableStoreHarness.make(pending: true); defer { h.cleanup() }
        let file = h.directory.appendingPathComponent("workspace.json")
        let valid = try Data(contentsOf: file)
        try Data("invalid JSON".utf8).write(to: file, options: .atomic)
        h.activity.active = true
        let store = h.makeStore()
        XCTAssertNotNil(store.startupError)
        try valid.write(to: file, options: .atomic)
        store.reload()
        for _ in 0..<10000 { if store.current?.messages.last?.state == .complete { break }; await Task.yield() }
        XCTAssertNil(store.startupError)
        XCTAssertEqual(store.current?.messages.last?.state, .complete)
        XCTAssertEqual(store.current?.messages.last?.text, "Réponse finale")
        let retrieves = await h.remote.retrieves
        let starts = await h.remote.starts
        XCTAssertEqual(retrieves, 1)
        XCTAssertEqual(starts, 0)
    }

    @MainActor
    func testRecoverablePendingPreventsDuplicateNewMessageAndRegeneration() async throws {
        let h = try RecoverableStoreHarness.make(pending: true); defer { h.cleanup() }
        let store = h.makeStore()
        let sent = await store.sendChecked("Ne pas envoyer")
        XCTAssertFalse(sent)
        await store.retryChecked()
        let starts = await h.remote.starts
        let ordinarySends = await h.ordinary.sends
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(ordinarySends, 0)
        XCTAssertEqual(store.current?.messages.count, 2)
        XCTAssertEqual(store.current?.messages.last?.remoteResponse?.responseID, "resp_fixture")
    }

    @MainActor
    func testLateIdentityAfterConversationChangeIsRecoveredWithoutReposting() async throws {
        let h = try RecoverableStoreHarness.make(); defer { h.cleanup() }
        await h.remote.holdIdentity()
        let store = h.makeStore()
        let sent = await store.sendChecked("Question fictive")
        XCTAssertTrue(sent)
        for _ in 0..<10000 { if await h.remote.isAwaitingCreated { break }; await Task.yield() }
        store.stop(reason: .conversationChanged)
        XCTAssertEqual(store.current?.messages.last?.remoteSubmissionPending, true)
        await h.remote.releaseIdentity()
        for _ in 0..<10000 { if store.current?.messages.last?.remoteResponse?.responseID == "resp_fixture" { break }; await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.remoteResponse?.responseID, "resp_fixture")
        XCTAssertNotEqual(store.current?.messages.last?.remoteSubmissionPending, true)
        let cancellationsBeforeRecovery = await h.remote.cancellations
        XCTAssertEqual(cancellationsBeforeRecovery, 0)
        h.activity.active = true
        store.sceneChanged(.active)
        for _ in 0..<10000 { if store.current?.messages.last?.state == .complete { break }; await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.text, "Réponse finale")
        let starts = await h.remote.starts
        let retrieves = await h.remote.retrieves
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(retrieves, 1)
    }

    @MainActor
    func testLateIdentityAfterExplicitAbandonDoesNotResurrectTracking() async throws {
        let h = try RecoverableStoreHarness.make(); defer { h.cleanup() }
        await h.remote.holdIdentity()
        let store = h.makeStore()
        let sent = await store.sendChecked("Question fictive")
        XCTAssertTrue(sent)
        for _ in 0..<10000 { if await h.remote.isAwaitingCreated { break }; await Task.yield() }
        store.stop(reason: .conversationChanged)
        let messageID = try XCTUnwrap(store.current?.messages.last?.id)
        XCTAssertEqual(store.current?.messages.last?.remoteSubmissionPending, true)
        store.abandonPendingResponse(messageID: messageID)
        XCTAssertNotEqual(store.current?.messages.last?.remoteSubmissionPending, true)
        await h.remote.releaseIdentity()
        for _ in 0..<10000 { if await h.remote.createdCallbacks > 0 { break }; await Task.yield() }
        XCTAssertNil(store.current?.messages.last?.remoteResponse)
        XCTAssertNotEqual(store.current?.messages.last?.remoteSubmissionPending, true)
        let starts = await h.remote.starts
        let retrieves = await h.remote.retrieves
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(retrieves, 0)
        let persisted = try h.storage.load()
        XCTAssertNil(persisted.conversations.first?.messages.last?.remoteResponse)
        XCTAssertNotEqual(persisted.conversations.first?.messages.last?.remoteSubmissionPending, true)
    }

    @MainActor
    func testLateIdentityAfterUserStopCancelsWithoutPollingOrReposting() async throws {
        let h = try RecoverableStoreHarness.make(); defer { h.cleanup() }
        await h.remote.holdIdentity()
        let store = h.makeStore()
        let sent = await store.sendChecked("Question fictive")
        XCTAssertTrue(sent)
        for _ in 0..<10000 { if await h.remote.isAwaitingCreated { break }; await Task.yield() }
        store.stop(reason: .user)
        XCTAssertEqual(store.current?.messages.last?.remoteSubmissionPending, true)
        await h.remote.releaseIdentity()
        for _ in 0..<10000 { if await h.remote.cancellations > 0 { break }; await Task.yield() }
        for _ in 0..<10000 { if store.current?.messages.last?.remoteResponse == nil && store.current?.messages.last?.remoteSubmissionPending != true { break }; await Task.yield() }
        let starts = await h.remote.starts
        let retrieves = await h.remote.retrieves
        let cancellations = await h.remote.cancellations
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(retrieves, 0)
        XCTAssertEqual(cancellations, 1)
        XCTAssertNil(store.current?.messages.last?.remoteResponse)
        XCTAssertNotEqual(store.current?.messages.last?.remoteSubmissionPending, true)
        XCTAssertEqual(store.current?.messages.last?.state, .interrupted)
    }

    @MainActor
    func testDefinitiveServerRejectionsDoNotBlockExplicitRetryOrRetryAutomatically() async throws {
        for status in [400, 401] {
            let h = try RecoverableStoreHarness.make(); defer { h.cleanup() }
            await h.remote.setStartHTTPError(status)
            let store = h.makeStore()
            let sent = await store.sendChecked("Question fictive")
            XCTAssertTrue(sent)
            for _ in 0..<10000 { if !store.isGenerating { break }; await Task.yield() }
            XCTAssertEqual(store.current?.messages.last?.state, .failed, "HTTP \(status)")
            XCTAssertNotEqual(store.current?.messages.last?.remoteSubmissionPending, true)
            XCTAssertNil(store.current?.messages.last?.remoteResponse)
            let beforeRetry = await h.remote.starts
            XCTAssertEqual(beforeRetry, 1)
            await store.retryChecked()
            for _ in 0..<10000 { if !store.isGenerating { break }; await Task.yield() }
            let afterRetry = await h.remote.starts
            XCTAssertEqual(afterRetry, 2, "Only an explicit user retry may send another request")
        }
    }

    @MainActor
    func testUnacknowledgedServerRequestDoesNotRetryAutomaticallyAfterRelaunch() async throws {
        let h = try RecoverableStoreHarness.make(); defer { h.cleanup() }
        await h.remote.setFailBeforeCreated(true)
        let first = h.makeStore()
        let sent = await first.sendChecked("Question fictive")
        XCTAssertTrue(sent)
        for _ in 0..<10000 { if !first.isGenerating { break }; await Task.yield() }
        let uncertain = try XCTUnwrap(first.current?.messages.last)
        XCTAssertEqual(uncertain.remoteSubmissionPending, true)
        XCTAssertNil(uncertain.remoteResponse)
        XCTAssertEqual(try h.storage.load().conversations.first?.messages.last?.remoteSubmissionPending, true)
        h.activity.active = true
        let restarted = h.makeStore()
        for _ in 0..<1000 { await Task.yield() }
        let repeated = await restarted.sendChecked("Ne pas renvoyer")
        XCTAssertFalse(repeated)
        await restarted.retryChecked()
        let starts = await h.remote.starts
        let retrieves = await h.remote.retrieves
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(retrieves, 0)
        XCTAssertEqual(restarted.current?.messages.last?.remoteSubmissionPending, true)
        let id = try XCTUnwrap(restarted.current?.messages.last?.id)
        restarted.abandonPendingResponse(messageID: id)
        XCTAssertNotEqual(restarted.current?.messages.last?.remoteSubmissionPending, true)
    }

    @MainActor
    func testRecoverableExpiredResponseKeepsPartialAndDoesNotPostAgain() async throws {
        let h = try RecoverableStoreHarness.make(pending: true); defer { h.cleanup() }
        await h.remote.setRetrievalError(404)
        h.activity.active = true
        let store = h.makeStore()
        for _ in 0..<10000 { if store.current?.messages.last?.failureDetail?.contains("introuvable") == true { break }; await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.state, .interrupted)
        XCTAssertEqual(store.current?.messages.last?.text, "Partiel")
        XCTAssertEqual(store.current?.messages.last?.remoteResponse?.responseID, "resp_fixture")
        XCTAssertTrue(store.current?.messages.last?.failureDetail?.contains("introuvable") == true)
        let starts = await h.remote.starts
        XCTAssertEqual(starts, 0)
    }

    @MainActor
    func testRecoverableInProgressPollsUntilCompleteWithoutSecondPost() async throws {
        let h = try RecoverableStoreHarness.make(pending: true); defer { h.cleanup() }
        await h.remote.setSnapshot(RecoverableSnapshot(status: .inProgress, text: nil, reasoning: nil, usage: nil))
        h.activity.active = true
        let store = h.makeStore()
        for _ in 0..<100 { if store.current?.messages.last?.failureDetail?.contains("encore en cours") == true { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.current?.messages.last?.text, "Partiel")
        XCTAssertEqual(store.current?.messages.last?.remoteResponse?.responseID, "resp_fixture")
        await h.remote.setSnapshot(RecoverableSnapshot(status: .completed, text: "Réponse finale", reasoning: nil, usage: nil))
        for _ in 0..<400 { if store.current?.messages.last?.state == .complete { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.current?.messages.last?.state, .complete)
        XCTAssertEqual(store.current?.messages.last?.text, "Réponse finale")
        XCTAssertNil(store.current?.messages.last?.remoteResponse)
        let starts = await h.remote.starts
        let retrieves = await h.remote.retrieves
        XCTAssertEqual(starts, 0)
        XCTAssertGreaterThanOrEqual(retrieves, 2)
    }

    @MainActor
    func testRecoverableTransientFailureCanRecoverLaterWithoutSecondPost() async throws {
        let h = try RecoverableStoreHarness.make(pending: true); defer { h.cleanup() }
        await h.remote.setRetrievalError(1)
        h.activity.active = true
        let store = h.makeStore()
        for _ in 0..<10000 { if store.current?.messages.last?.failureDetail?.contains("pas pu être effectuée") == true { break }; await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.text, "Partiel")
        XCTAssertEqual(store.current?.messages.last?.remoteResponse?.responseID, "resp_fixture")
        await h.remote.setRetrievalError(nil)
        store.sceneChanged(.active)
        for _ in 0..<10000 { if store.current?.messages.last?.state == .complete { break }; await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.text, "Réponse finale")
        XCTAssertEqual(store.current?.messages.last?.state, .complete)
        let starts = await h.remote.starts
        XCTAssertEqual(starts, 0)
    }

    @MainActor
    func testRecoverableUnconfirmedCancellationPersistsAndRetriesOnlyCancellation() async throws {
        let h = try RecoverableStoreHarness.make(pending: true); defer { h.cleanup() }
        await h.remote.failNextCancellations(1)
        let store = h.makeStore()
        let id = try XCTUnwrap(store.current?.messages.last?.id)
        store.cancelPendingResponse(messageID: id)
        for _ in 0..<10000 { if store.current?.messages.last?.failureDetail?.contains("pas pu être confirmé") == true { break }; await Task.yield() }
        XCTAssertEqual(store.current?.messages.last?.remoteResponse?.cancelRequested, true)
        XCTAssertEqual(try h.storage.load().conversations.first?.messages.last?.remoteResponse?.cancelRequested, true)
        XCTAssertEqual(store.current?.messages.last?.text, "Partiel")
        h.activity.active = true
        let restarted = h.makeStore()
        for _ in 0..<10000 { if restarted.current?.messages.last?.remoteResponse == nil { break }; await Task.yield() }
        XCTAssertNil(restarted.current?.messages.last?.remoteResponse)
        XCTAssertEqual(restarted.current?.messages.last?.state, .interrupted)
        let starts = await h.remote.starts
        let retrieves = await h.remote.retrieves
        let cancellations = await h.remote.cancellations
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(retrieves, 0)
        XCTAssertEqual(cancellations, 2)
    }

    @MainActor
    func testPendingJobPreventsDestructiveChangesAndKeyOrOriginReplacement() throws {
        let h = try RecoverableStoreHarness.make(pending: true); defer { h.cleanup() }
        let store = h.makeStore()
        let conversation = try XCTUnwrap(store.current)
        XCTAssertFalse(store.confirmConversationDeletions(ids: [conversation.id]))
        store.eraseHistory()
        store.deleteServer(h.profile)
        XCTAssertEqual(store.data.conversations.map(\.id), [conversation.id])
        XCTAssertEqual(store.data.servers.map(\.id), [h.profile.id])
        var changed = h.profile
        changed.baseURL = "https://integrate.api.nvidia.com/v1"
        XCTAssertThrowsError(try store.saveServer(changed, key: "fixture-key"))
        XCTAssertThrowsError(try store.saveServer(h.profile, key: "different-key"))
        let persisted = try h.storage.load()
        XCTAssertEqual(persisted.conversations.first?.messages.last?.remoteResponse?.responseID, "resp_fixture")
        XCTAssertEqual(persisted.servers.first?.baseURL, "https://api.openai.com/v1")
    }

    @MainActor
    func testRecoverableChangedServerNeverReceivesKeyOrRequest() async throws {
        let h = try RecoverableStoreHarness.make(pending: true, overrideBase: "https://integrate.api.nvidia.com/v1")
        defer { h.cleanup() }
        h.activity.active = true
        var readKeyCount = 0
        let store = AppStore(storageDirectory: h.directory, defaults: h.defaults, client: h.ordinary,
            readKey: { _ in readKeyCount += 1; return "fixture-key" }, responseContinuation: NoResponseContinuation(),
            recoverableClient: h.remote, applicationIsActive: { h.activity.active })
        for _ in 0..<5000 { if store.current?.messages.last?.failureDetail?.contains("serveur") == true { break }; await Task.yield() }
        let retrieves = await h.remote.retrieves
        XCTAssertEqual(retrieves, 0)
        XCTAssertEqual(readKeyCount, 0)
        XCTAssertEqual(store.current?.messages.last?.remoteResponse?.responseID, "resp_fixture")
        XCTAssertEqual(store.current?.messages.last?.text, "Partiel")
    }
}

private struct LocalLFMFixture: EudesAPIClient {
    func models(profile: ServerProfile, key: String) async throws -> [String] {
        XCTAssertTrue(profile.isLocalLFM)
        XCTAssertEqual(key, "")
        return [profile.model]
    }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage],
                systemPrompt: String, temperature: Double, maxTokens: Int?,
                onText: @escaping @MainActor (String) -> Void) async throws {
        XCTAssertTrue(profile.isLocalLFM)
        XCTAssertEqual(key, "")
        XCTAssertEqual(model, profile.model)
        await onText("Réponse locale")
    }
}

extension PrivateStorageTests {
    @MainActor
    func testLFMSelectionUsesLocalClientAndPreservesImagesWithoutSwitching() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesLFMSelection." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(storageDirectory: directory, defaults: defaults, client: ForbiddenAppleNetwork(),
                             localModelClient: LocalLFMFixture(), appleAvailability: { .unsupportedOS },
                             readKey: { _ in XCTFail("LFM3 must not read an API key"); return "" })
        store.selectServer(ServerProfile.lfmVisionID)
        XCTAssertEqual(store.currentModel, LocalModelCatalog.vision.id)
        XCTAssertTrue(store.canAttachImages)
        let image = ImageAttachment(data: Data([1, 2, 3]))
        store.addImage(image)
        store.selectServer(ServerProfile.lfmTextID)
        XCTAssertEqual(store.currentModel, LocalModelCatalog.text.id)
        XCTAssertFalse(store.canAttachImages)
        let blocked = await store.sendChecked("Décris")
        XCTAssertFalse(blocked)
        XCTAssertEqual(store.draftImages, [image])
        XCTAssertEqual(store.selectedServer?.id, ServerProfile.lfmTextID)
        store.selectServer(ServerProfile.lfmVisionID)
        let sent = await store.sendChecked("Décris")
        XCTAssertTrue(sent)
        for _ in 0..<1000 {
            if store.current?.messages.last?.text == "Réponse locale" { break }
            await Task.yield()
        }
        XCTAssertEqual(store.current?.messages.first?.images, [image])
        XCTAssertEqual(store.current?.messages.last?.text, "Réponse locale")
        XCTAssertEqual(store.selectedServer?.id, ServerProfile.lfmVisionID)
    }
}

extension PrivateStorageTests {
    @MainActor
    func testOptInLFMChatUsesRealTextAndVisionModelsWithoutNetwork() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["EUDES_LFM3_FIXTURES"] else {
            throw XCTSkip("Set EUDES_LFM3_FIXTURES to the verified LFM3 fixture directory.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelsRoot = root.appendingPathComponent("models", isDirectory: true)
        let storage = root.appendingPathComponent("workspace", isDirectory: true)
        let suite = "EudesRealLFMChat." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let fixtureRoot = URL(fileURLWithPath: fixture, isDirectory: true)
        for (model, files) in [(LocalModelCatalog.text, ["text.gguf"]),
                               (LocalModelCatalog.vision, ["vision.gguf", "mmproj.gguf"])] {
            let directory = modelsRoot.appendingPathComponent(model.id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (asset, source) in zip(model.assets, files) {
                try FileManager.default.linkItem(at: fixtureRoot.appendingPathComponent(source),
                                                 to: directory.appendingPathComponent(asset.filename))
            }
        }
        let runtime = LocalModelRuntime(root: modelsRoot)
        let store = AppStore(storageDirectory: storage, defaults: defaults, client: ForbiddenAppleNetwork(),
            localModelClient: LocalModelClient(runtime: runtime), appleAvailability: { .unsupportedOS },
            readKey: { _ in XCTFail("Local generation must not access API credentials"); return "" })
        store.saveSettings(prompt: "Réponds en français.", temperature: 0.7, maxTokens: 128)
        store.selectServer(ServerProfile.lfmTextID)
        let textSent = await store.sendChecked("Quelle est la capitale de la France ?")
        XCTAssertTrue(textSent)
        for _ in 0..<2400 {
            if !store.isGenerating { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(store.isGenerating)
        XCTAssertTrue(store.current?.messages.last?.text.localizedCaseInsensitiveContains("Paris") == true)
        XCTAssertEqual(store.current?.messages.last?.state, .complete)
        store.newConversation()
        store.selectServer(ServerProfile.lfmVisionID)
        let bytes = try Data(contentsOf: fixtureRoot.appendingPathComponent("test-image.jpeg"))
        let image = try ImageAttachment.importData(bytes)
        store.addImage(image)
        let imageSent = await store.sendChecked("Décris brièvement cette image.")
        XCTAssertTrue(imageSent)
        for _ in 0..<2400 {
            if !store.isGenerating { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(store.isGenerating)
        XCTAssertEqual(store.current?.messages.first?.images, [image])
        XCTAssertEqual(store.current?.messages.last?.state, .complete)
        XCTAssertFalse(store.current?.messages.last?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        XCTAssertEqual(store.selectedServer?.id, ServerProfile.lfmVisionID)
        try await runtime.unload()
    }

    /// Un modèle n'est « installé » que lorsque tous ses fichiers occupent leur place
    /// finale : une présence partielle ne doit jamais autoriser la sélection.
    func testModelIsInstalledOnlyWhenEveryAssetIsPresent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("modeles-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LocalModelCatalog.vision
        XCTAssertFalse(LocalModelDownloads.isInstalled(model, at: directory))
        let folder = directory.appendingPathComponent(model.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for asset in model.assets {
            try Data([0]).write(to: folder.appendingPathComponent(asset.filename))
        }
        XCTAssertTrue(LocalModelDownloads.isInstalled(model, at: directory))
        let last = model.assets[model.assets.count - 1]
        try FileManager.default.removeItem(at: folder.appendingPathComponent(last.filename))
        XCTAssertFalse(LocalModelDownloads.isInstalled(model, at: directory))
    }

    /// Le remplaçant garde la capacité d'images quand c'est possible, ne choisit jamais
    /// un modèle absent, et écarte ceux que l'appareil ne peut pas charger.
    func testReplacementKeepsImageCapabilityAndSkipsUnusableModels() {
        let device = DeviceProfile(machineIdentifier: "test", physicalMemory: 16_000_000_000)
        let vision = LocalModelCatalog.vision
        let text = LocalModelCatalog.text
        XCTAssertEqual(
            LocalModelCatalog.replacement(afterRemoving: vision.id, installed: [vision.id, text.id], device: device)?.id,
            text.id)
        let otherVision = LocalModelCatalog.bonsai_2b
        XCTAssertEqual(
            LocalModelCatalog.replacement(afterRemoving: vision.id,
                                           installed: [vision.id, otherVision.id, text.id], device: device)?.id,
            otherVision.id)
        XCTAssertNil(LocalModelCatalog.replacement(afterRemoving: vision.id, installed: [vision.id], device: device))
        let small = DeviceProfile(machineIdentifier: "test", physicalMemory: 2_500_000_000)
        XCTAssertNil(LocalModelCatalog.replacement(afterRemoving: vision.id, installed: [vision.id, text.id], device: small))
    }
}

private actor ReleaseCounter {
    private var value = 0
    func record() { value += 1 }
    var count: Int { value }
}

/// « Charger à l'ouverture » décoché : iOS garde le process vivant, donc le moteur local
/// doit être libéré. Pas au moindre passage en arrière-plan (une notification fait revenir
/// l'utilisateur tout de suite), seulement après un délai d'absence, au retour.
final class LocalModelReleaseTests: XCTestCase {
    private struct Fixture {
        let store: AppStore
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor
    private func makeStore(startupLoading: Bool, appleAvailable: Bool = false,
                           grace: TimeInterval = 0.05,
                           releases: ReleaseCounter) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesLocalRelease." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(startupLoading, forKey: AppStore.loadAtStartupKey)
        let store = AppStore(storageDirectory: directory, defaults: defaults,
                             client: ForbiddenAppleNetwork(),
                             appleAvailability: { appleAvailable ? .available : .unsupportedOS },
                             readKey: { _ in "" }, applicationIsActive: { true },
                             protectedDataAvailable: { true },
                             releaseLocalModel: { await releases.record() },
                             backgroundGrace: grace)
        return Fixture(store: store, directory: directory, defaults: defaults, suite: suite)
    }

    @MainActor
    private func waitForRelease(_ releases: ReleaseCounter) async {
        for _ in 0..<2000 {
            if await releases.count > 0 { return }
            await Task.yield()
        }
    }

    @MainActor
    func testQuickReturnKeepsTheLocalModel() async throws {
        let releases = ReleaseCounter()
        let fixture = try makeStore(startupLoading: false, grace: 120, releases: releases)
        defer { fixture.cleanUp() }
        fixture.store.selectServer(ServerProfile.lfmTextID)
        fixture.store.sceneChanged(.background)
        fixture.store.sceneChanged(.active)
        for _ in 0..<500 { await Task.yield() }
        // Un aller-retour rapide (notification, changement d'app) ne doit rien coûter.
        let count = await releases.count
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testLongAbsenceReleasesTheLocalModelOnReturn() async throws {
        let releases = ReleaseCounter()
        let fixture = try makeStore(startupLoading: false, grace: 0.05, releases: releases)
        defer { fixture.cleanUp() }
        fixture.store.selectServer(ServerProfile.lfmTextID)
        fixture.store.sceneChanged(.background)
        try await Task.sleep(for: .milliseconds(200))
        fixture.store.sceneChanged(.active)
        await waitForRelease(releases)
        let count = await releases.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testStartupLoadingKeepsTheModelAfterALongAbsence() async throws {
        let releases = ReleaseCounter()
        let fixture = try makeStore(startupLoading: true, grace: 0.05, releases: releases)
        defer { fixture.cleanUp() }
        fixture.store.selectServer(ServerProfile.lfmTextID)
        fixture.store.sceneChanged(.background)
        try await Task.sleep(for: .milliseconds(200))
        fixture.store.sceneChanged(.active)
        for _ in 0..<500 { await Task.yield() }
        let count = await releases.count
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testLongAbsenceReleasesEvenWhenAnotherProfileIsSelected() async throws {
        let releases = ReleaseCounter()
        let fixture = try makeStore(startupLoading: false, appleAvailable: true, releases: releases)
        defer { fixture.cleanUp() }
        fixture.store.selectServer(ServerProfile.appleID)
        XCTAssertEqual(fixture.store.selectedServer?.isLocalLFM, false)
        // Un moteur local resté en mémoire après un passage sur Apple n'a aucune raison
        // d'occuper l'iPhone.
        fixture.store.sceneChanged(.background)
        try await Task.sleep(for: .milliseconds(200))
        fixture.store.sceneChanged(.active)
        await waitForRelease(releases)
        let count = await releases.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testLockThenReturnAfterGraceReleasesTheModel() async throws {
        let releases = ReleaseCounter()
        let fixture = try makeStore(startupLoading: false, releases: releases)
        defer { fixture.cleanUp() }
        fixture.store.selectServer(ServerProfile.lfmTextID)
        fixture.store.protectedDataWillBecomeUnavailable()
        for _ in 0..<200 { await Task.yield() }
        let afterLock = await releases.count
        XCTAssertEqual(afterLock, 0, "Le verrouillage seul ne doit pas décharger")
        try await Task.sleep(for: .milliseconds(200))
        fixture.store.sceneChanged(.active)
        await waitForRelease(releases)
        let count = await releases.count
        XCTAssertEqual(count, 1)
    }
}
