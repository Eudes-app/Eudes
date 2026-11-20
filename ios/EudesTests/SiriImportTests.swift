import XCTest
import SwiftUI
@testable import Eudes

@MainActor
final class SiriImportTests: XCTestCase {
    func testVoiceInstructionSaveRefreshesEnabledSnapshotAndResetWithoutChangingServer() throws {
        let h = try SiriStoreHarness(); defer { h.cleanup() }
        let store = h.makeStore()
        store.setVoiceResponseInstruction("  Speak briefly in my language.  ")
        XCTAssertFalse(h.service.isEnabled, "Saving an instruction does not opt into locked-screen Siri")
        XCTAssertNil(h.persistence.values[SiriAssistantService.configurationAccount])
        XCTAssertEqual(VoiceResponseInstruction.selected(defaults: h.defaults), "Speak briefly in my language.")
        XCTAssertEqual(store.voiceResponseInstruction, "Speak briefly in my language.")
        let reopened = h.makeStore()
        XCTAssertEqual(reopened.voiceResponseInstruction, "Speak briefly in my language.")

        store.setSiriWhileLocked(true)
        let first = try XCTUnwrap(h.persistence.values[SiriAssistantService.configurationAccount])
        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(firstObject["voiceInstruction"] as? String, "Speak briefly in my language.")
        XCTAssertEqual(store.selectedServer?.effectiveInstruction, h.profile.effectiveInstruction)

        store.setVoiceResponseInstruction("Use one sentence.")
        let updated = try XCTUnwrap(h.persistence.values[SiriAssistantService.configurationAccount])
        let updatedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        XCTAssertEqual(updatedObject["voiceInstruction"] as? String, "Use one sentence.")
        XCTAssertNotEqual(first, updated)

        store.setVoiceResponseInstruction(" \n ")
        XCTAssertEqual(store.voiceResponseInstruction, VoiceResponseInstruction.defaultText)
        XCTAssertNil(h.defaults.object(forKey: VoiceResponseInstruction.preferenceKey))
        let reset = try XCTUnwrap(h.persistence.values[SiriAssistantService.configurationAccount])
        let resetObject = try XCTUnwrap(JSONSerialization.jsonObject(with: reset) as? [String: Any])
        XCTAssertEqual(resetObject["voiceInstruction"] as? String, VoiceResponseInstruction.defaultText)
        XCTAssertEqual(store.data.conversations, h.initial.conversations)
    }

    func testSiriAccessRequiresExplicitOptInAndRevokesOnCredentialFailure() throws {
        let h = try SiriStoreHarness(); defer { h.cleanup() }
        var keyFails = false
        var reads = 0
        let store = h.makeStore(readKey: { _ in
            reads += 1
            if keyFails { throw EudesError.keychain(-1) }
            return "synthetic-key"
        })
        XCTAssertFalse(store.siriWhileLockedEnabled)
        XCTAssertEqual(reads, 0)
        store.setSiriWhileLocked(true)
        XCTAssertTrue(store.siriWhileLockedEnabled)
        XCTAssertTrue(h.service.isEnabled)
        keyFails = true
        store.saveNow()
        XCTAssertFalse(store.siriWhileLockedEnabled)
        XCTAssertFalse(h.service.isEnabled)
        XCTAssertNotNil(store.siriConfigurationError)
    }

    func testColdBackgroundLaunchPreservesSnapshotWhenKeychainIsAlreadyLocked() throws {
        let h = try SiriStoreHarness(); defer { h.cleanup() }
        try h.service.configure(profile: h.profile, model: "alpha", key: "synthetic-key", maxTokens: nil)
        let snapshot = h.persistence.values[SiriAssistantService.configurationAccount]
        var active = false
        var keyReads = 0
        let store = h.makeStore(readKey: { _ in
            keyReads += 1
            guard active else { throw EudesError.keychain(-25308) }
            return "updated-key"
        }, unlocked: { true }, active: { active })
        XCTAssertNil(store.startupError)
        XCTAssertTrue(store.siriWhileLockedEnabled)
        XCTAssertTrue(h.service.isEnabled)
        XCTAssertEqual(keyReads, 0)
        store.sceneChanged(.background)
        XCTAssertEqual(keyReads, 0)
        XCTAssertEqual(h.persistence.values[SiriAssistantService.configurationAccount], snapshot)

        // A protected workspace write can also fail during the grace period.
        // A headless failure must never revoke the independent Siri snapshot.
        let workspace = h.directory.appendingPathComponent("workspace.json")
        try FileManager.default.removeItem(at: workspace)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        store.sceneChanged(.background)
        XCTAssertTrue(h.service.isEnabled)
        XCTAssertEqual(h.persistence.values[SiriAssistantService.configurationAccount], snapshot)
        try FileManager.default.removeItem(at: workspace)
        try h.storage.save(h.initial)

        active = true
        store.sceneChanged(.active)
        XCTAssertGreaterThan(keyReads, 0)
        XCTAssertTrue(h.service.isEnabled)
        XCTAssertNotEqual(h.persistence.values[SiriAssistantService.configurationAccount], snapshot)
        XCTAssertNil(store.siriConfigurationError)
    }

    func testSnapshotUpdatesWithModelSelectionButNeverWhileProtectedDataUnavailable() throws {
        let h = try SiriStoreHarness(); defer { h.cleanup() }
        var unlocked = true
        let store = h.makeStore(unlocked: { unlocked })
        store.setSiriWhileLocked(true)
        let first = h.persistence.values[SiriAssistantService.configurationAccount]
        store.selectDraftModel("beta")
        let second = h.persistence.values[SiriAssistantService.configurationAccount]
        XCTAssertNotEqual(first, second)
        unlocked = false
        store.selectDraftModel("gamma")
        XCTAssertEqual(h.persistence.values[SiriAssistantService.configurationAccount], second)
        unlocked = true
        store.sceneChanged(.active)
        XCTAssertNotEqual(h.persistence.values[SiriAssistantService.configurationAccount], second)
    }

    func testImportPreservesSelectionAndDraftAndRetriesAcknowledgementWithoutDuplicates() throws {
        let h = try SiriStoreHarness(); defer { h.cleanup() }
        let store = h.makeStore()
        let pending = Conversation(title: "Depuis Siri", serverID: h.profile.id, model: "alpha",
                                   messages: [ChatMessage(role: .user, text: "Question Siri"), ChatMessage(role: .assistant, text: "Réponse Siri")])
        try h.enqueue([pending])
        h.persistence.failAcknowledgement = true
        store.importSiriConversations()
        XCTAssertEqual(store.data.conversations.filter { $0.id == pending.id }.count, 1)
        XCTAssertEqual(store.data.selectedConversationID, h.existing.id)
        XCTAssertEqual(store.draftImages, h.initial.imageDraft)
        XCTAssertEqual(try h.storage.load().conversations.filter { $0.id == pending.id }.count, 1)
        XCTAssertEqual(try h.service.pendingConversations().count, 1)
        h.persistence.failAcknowledgement = false
        store.importSiriConversations()
        XCTAssertEqual(store.data.conversations.filter { $0.id == pending.id }.count, 1)
        XCTAssertTrue(try h.service.pendingConversations().isEmpty)
    }

    func testFailedPrivateSaveDoesNotConsumeSiriQueueOrPublishUnsavedConversation() throws {
        let h = try SiriStoreHarness(); defer { h.cleanup() }
        let store = h.makeStore()
        let pending = Conversation(title: "Depuis Siri", serverID: h.profile.id, model: "alpha")
        try h.enqueue([pending])
        let workspace = h.directory.appendingPathComponent("workspace.json")
        try FileManager.default.removeItem(at: workspace)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        store.importSiriConversations()
        XCTAssertFalse(store.data.conversations.contains { $0.id == pending.id })
        XCTAssertEqual(try h.service.pendingConversations().map(\.id), [pending.id])
        XCTAssertNotNil(store.siriConfigurationError)
        try FileManager.default.removeItem(at: workspace)
        try h.storage.save(h.initial)
        store.importSiriConversations()
        XCTAssertTrue(store.data.conversations.contains { $0.id == pending.id })
        XCTAssertTrue(try h.service.pendingConversations().isEmpty)
    }

    func testColdHeadlessReadFailureDuringProtectionGraceRetriesOnForeground() throws {
        let h = try SiriStoreHarness(); defer { h.cleanup() }
        try h.service.configure(profile: h.profile, model: "alpha", key: "synthetic-key", maxTokens: nil)
        let snapshot = h.persistence.values[SiriAssistantService.configurationAccount]
        let workspace = h.directory.appendingPathComponent("workspace.json")
        try Data("unreadable fixture".utf8).write(to: workspace)
        var active = false
        let store = h.makeStore(unlocked: { true }, active: { active })
        XCTAssertNotNil(store.startupError)
        store.sceneChanged(.background)
        XCTAssertEqual(h.persistence.values[SiriAssistantService.configurationAccount], snapshot)
        try h.storage.save(h.initial)
        let pending = Conversation(title: "Depuis Siri", serverID: h.profile.id, model: "alpha")
        try h.enqueue([pending])
        active = true
        store.sceneChanged(.active)
        XCTAssertNil(store.startupError)
        XCTAssertTrue(store.siriWhileLockedEnabled)
        XCTAssertEqual(store.data.selectedConversationID, h.existing.id)
        XCTAssertTrue(store.data.conversations.contains { $0.id == pending.id })
        XCTAssertTrue(try h.service.pendingConversations().isEmpty)
    }
}

@MainActor
private final class SiriMemoryPersistence {
    var values: [String: Data] = [:]
    var failAcknowledgement = false
    var adapter: SiriAssistantPersistence {
        SiriAssistantPersistence(read: { self.values[$0] }, write: { self.values[$0] = $1 }, delete: {
            if self.failAcknowledgement, $0 == SiriAssistantService.pendingAccount { throw EudesError.storage("fixture") }
            self.values.removeValue(forKey: $0)
        })
    }
}

@MainActor
private final class SiriStoreHarness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "EudesSiriImport." + UUID().uuidString
    let profile = ServerProfile(name: "Fictif", baseURL: "https://example.invalid/v1", model: "alpha", availableModels: ["alpha", "beta", "gamma"])
    let persistence = SiriMemoryPersistence()
    let defaults: UserDefaults
    let storage: PrivateStorage
    let service: SiriAssistantService
    let existing: Conversation
    let initial: AppData

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        storage = try PrivateStorage(directory: directory)
        service = SiriAssistantService(persistence: persistence.adapter)
        existing = Conversation(title: "Contexte privé", serverID: profile.id, model: "alpha",
                                messages: [ChatMessage(role: .user, text: "Question privée")])
        var data = AppData()
        data.servers = [profile]
        data.selectedServerID = profile.id
        data.selectedConversationID = existing.id
        data.conversations = [existing]
        data.imageDraft = [ImageAttachment(data: Data([1, 2, 3]))]
        initial = data
        try storage.save(data)
    }

    func makeStore(readKey: @escaping (UUID) throws -> String = { _ in "synthetic-key" },
                   unlocked: @escaping @MainActor () -> Bool = { true },
                   active: @escaping @MainActor () -> Bool = { true }) -> AppStore {
        AppStore(storageDirectory: directory, defaults: defaults, appleAvailability: { .unsupportedOS },
                 readKey: readKey, responseContinuation: NoResponseContinuation(), applicationIsActive: active,
                 siriAssistant: service, protectedDataAvailable: unlocked)
    }
    func enqueue(_ conversations: [Conversation]) throws {
        persistence.values[SiriAssistantService.pendingAccount] = try JSONEncoder().encode(conversations)
    }
    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
}
