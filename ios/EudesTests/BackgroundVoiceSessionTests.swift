import Foundation
import XCTest
@testable import Eudes

@MainActor
final class BackgroundVoiceSessionTests: XCTestCase {
    func testVisualMeterFollowsVisibilityAndStopWithoutStoppingMicrophoneWhenHidden() async throws {
        let fixture = VoiceSessionFixture()
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { fixture.audio.isListening }

        session.setVisualFeedbackVisible(true, for: fixture.id)
        XCTAssertTrue(fixture.audio.meteringEnabled)
        fixture.audio.levelObserver?(0.7)
        XCTAssertEqual(session.audioLevel, 0.7, accuracy: 0.001)

        session.setVisualFeedbackVisible(false, for: fixture.id)
        XCTAssertFalse(fixture.audio.meteringEnabled)
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(fixture.audio.isListening)
        fixture.audio.levelObserver?(0.9)
        XCTAssertEqual(session.audioLevel, 0)

        session.setVisualFeedbackVisible(true, for: fixture.id)
        fixture.audio.levelObserver?(0.4)
        XCTAssertEqual(session.audioLevel, 0.4, accuracy: 0.001)
        await session.stop()
        fixture.audio.levelObserver?(0.8)
        XCTAssertEqual(session.audioLevel, 0)
        XCTAssertFalse(fixture.audio.meteringEnabled)
    }
    func testMultipleQuestionsShareConversationAndStopPhraseIsNotSent() async throws {
        let fixture = VoiceSessionFixture()
        fixture.audio.questions = ["Bonjour", "Et ensuite ?", "Arrête Eudes."]
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { !session.isRunning }
        XCTAssertEqual(fixture.questions, ["Bonjour", "Et ensuite ?"])
        XCTAssertEqual(fixture.answerIDs, [fixture.id, fixture.id])
        XCTAssertEqual(fixture.audio.spoken.suffix(2), ["Réponse 1", "Réponse 2"])
        XCTAssertEqual(fixture.ended, [fixture.id])
        XCTAssertEqual(fixture.activity.ends, 1)
        XCTAssertGreaterThan(fixture.audio.stops, 0)
        XCTAssertEqual(fixture.audio.thinkingStarts, 2)
        XCTAssertFalse(fixture.audio.isThinking)
        XCTAssertFalse(fixture.audio.spokeWhileThinking)
    }

    func testDeniedMicrophoneNeverStartsActivityOrBackend() async {
        let fixture = VoiceSessionFixture()
        fixture.audio.preflightError = VoiceAssistantError.microphoneDenied
        let session = fixture.makeSession()
        do { try await session.start(); XCTFail("Permission must be granted in foreground") } catch {}
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(fixture.begins, 0)
        XCTAssertEqual(fixture.activity.starts, 0)
        XCTAssertNotNil(session.lastError)
    }

    func testFailedActivityNeverActivatesMicrophone() async {
        let fixture = VoiceSessionFixture()
        fixture.activity.startError = VoiceActivityError.disabled
        let session = fixture.makeSession()
        do { try await session.start(); XCTFail("Activity is mandatory") } catch {}
        XCTAssertEqual(fixture.audio.prepares, 0)
        XCTAssertEqual(fixture.ended, [fixture.id])
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.lastError?.contains("activités") == true)
    }

    func testRepeatedStartAndStaleStopCannotDisruptCurrentSession() async throws {
        let fixture = VoiceSessionFixture()
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { fixture.audio.isListening }
        do { try await session.start(); XCTFail("One session at a time") } catch {}
        await session.stop(sessionID: UUID())
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(fixture.audio.prepares, 1)
        await session.stop(sessionID: fixture.id)
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(fixture.audio.isListening)
    }

    func testDismissingActivityStopsMicrophoneAndConversation() async throws {
        let fixture = VoiceSessionFixture()
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { fixture.audio.isListening }
        fixture.activity.dismissed?()
        await waitUntil { !session.isRunning }
        XCTAssertFalse(fixture.audio.isListening)
        XCTAssertEqual(fixture.ended, [fixture.id])
    }

    func testConsentRevocationDuringListeningStopsWithoutSending() async throws {
        let fixture = VoiceSessionFixture()
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { fixture.audio.isListening }
        fixture.valid = false
        await waitUntil { !session.isRunning }
        XCTAssertTrue(fixture.questions.isEmpty)
        XCTAssertFalse(fixture.audio.isListening)
        XCTAssertNotNil(session.lastError)
    }

    func testDeadlineEndsActualAudioSession() async throws {
        let fixture = VoiceSessionFixture()
        let session = fixture.makeSession(maximumDuration: .milliseconds(40))
        try await session.start()
        await waitUntil { !session.isRunning }
        XCTAssertFalse(fixture.audio.isListening)
        XCTAssertEqual(fixture.ended, [fixture.id])
    }

    func testAudioInterruptionStopsAndReportsAnExplanation() async throws {
        let fixture = VoiceSessionFixture()
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { fixture.audio.isListening }
        fixture.audio.interruption?()
        await waitUntil { !session.isRunning }
        XCTAssertTrue(session.lastError?.contains("interrompue") == true)
        XCTAssertTrue(fixture.questions.isEmpty)
    }

    func testStopDuringPreparationCleansLateResourcesAndPreventsRestart() async {
        let fixture = VoiceSessionFixture()
        fixture.audio.suspendPreparation = true
        let session = fixture.makeSession()
        let starting = Task { try await session.start() }
        await waitUntil { fixture.audio.preparation != nil }
        await session.stop()
        do { try await session.start(); XCTFail("Old startup still owns the resources") } catch {}
        fixture.audio.preparation?.resume(); fixture.audio.preparation = nil
        do { try await starting.value; XCTFail("Cancelled startup must not start listening") } catch {}
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(fixture.audio.isListening)
        XCTAssertTrue(fixture.questions.isEmpty)
        XCTAssertNil(session.lastError, "A voluntary stop is not a launch failure")
    }

    func testConsentRevocationDuringPreparationStopsMicrophoneBeforeLoadCompletes() async {
        let fixture = VoiceSessionFixture()
        fixture.audio.suspendPreparation = true
        let session = fixture.makeSession()
        let starting = Task { try await session.start() }
        await waitUntil { fixture.audio.preparation != nil }
        fixture.valid = false
        await waitUntil { !session.isRunning }
        XCTAssertGreaterThan(fixture.audio.stops, 0)
        fixture.audio.preparation?.resume(); fixture.audio.preparation = nil
        do { try await starting.value; XCTFail("Revoked") } catch {}
        XCTAssertFalse(fixture.audio.isListening)
    }

    func testStopWordsMustBeTheWholeUtterance() {
        XCTAssertTrue(BackgroundVoiceSession.isStopCommand("Arrête Eudes !"))
        XCTAssertTrue(BackgroundVoiceSession.isStopCommand("ARRÊTE L’ASSISTANT"))
        XCTAssertFalse(BackgroundVoiceSession.isStopCommand("Comment arrêter une voiture ?"))
        XCTAssertFalse(BackgroundVoiceSession.isStopCommand("Explique le mot stop"))
    }

    func testStopDuringModelWaitingSilencesFeedbackAndIgnoresLateReply() async throws {
        let fixture = VoiceSessionFixture()
        fixture.audio.questions = ["Bonjour"]
        var reply: CheckedContinuation<String, Error>?
        fixture.answer = { _ in try await withCheckedThrowingContinuation { reply = $0 } }
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { reply != nil }
        XCTAssertTrue(fixture.audio.isThinking)
        await session.stop()
        XCTAssertFalse(fixture.audio.isThinking)
        reply?.resume(returning: "Réponse tardive")
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(fixture.audio.spoken.contains("Réponse tardive"))
        XCTAssertFalse(fixture.audio.isThinking)
    }

    func testModelErrorStopsThinkingSoundBeforeErrorSpeech() async throws {
        let fixture = VoiceSessionFixture()
        fixture.audio.questions = ["Bonjour"]
        fixture.answer = { _ in
            fixture.progressObserver?(true)
            throw URLError(.timedOut)
        }
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { !session.isRunning }
        XCTAssertEqual(fixture.audio.thinkingStarts, 1)
        XCTAssertFalse(fixture.audio.isThinking)
        XCTAssertFalse(fixture.audio.spokeWhileThinking)
        XCTAssertFalse(session.isSearchingWeb)
        XCTAssertNotNil(session.lastError)
    }

    func testWebProgressClearsBetweenTurnsAndIgnoresLateCallbacksAfterStop() async throws {
        let fixture = VoiceSessionFixture()
        fixture.audio.questions = ["Première question", "Deuxième question"]
        var replies: [CheckedContinuation<String, Error>] = []
        fixture.answer = { _ in try await withCheckedThrowingContinuation { replies.append($0) } }
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { replies.count == 1 }
        let firstProgress = try XCTUnwrap(fixture.progressObserver)
        firstProgress(true)
        XCTAssertTrue(session.isSearchingWeb)
        firstProgress(false)
        XCTAssertFalse(session.isSearchingWeb)
        firstProgress(true)
        replies[0].resume(returning: "Première réponse")
        await waitUntil { replies.count == 2 }
        XCTAssertFalse(session.isSearchingWeb, "Completing an answer clears progress even if the backend omits false")
        firstProgress(true)
        XCTAssertFalse(session.isSearchingWeb, "A previous turn cannot change the current turn")
        let secondProgress = try XCTUnwrap(fixture.progressObserver)
        secondProgress(true)
        XCTAssertTrue(session.isSearchingWeb)
        await session.stop()
        XCTAssertFalse(session.isSearchingWeb)
        secondProgress(true)
        replies[1].resume(returning: "Réponse tardive")
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(session.isSearchingWeb)
        XCTAssertFalse(fixture.audio.spoken.contains("Réponse tardive"))
    }

    func testToolTraceRemainsVisibleAfterSpeechAndNeverEntersSpokenReply() async throws {
        let fixture = VoiceSessionFixture()
        fixture.audio.questions = ["Cherche les horaires"]
        let trace = WebResearchTrace(toolsOffered: true, state: .completed, finishedAt: Date(), calls: [
            WebToolActivity(tool: .webSearch, origin: .model, state: .succeeded,
                            query: "requête de recherche", startedAt: Date(), finishedAt: Date())
        ])
        fixture.answer = { _ in
            fixture.traceObserver?(trace)
            return "La réponse à prononcer."
        }
        let session = fixture.makeSession(withTrace: true)
        try await session.start()
        await waitUntil { fixture.audio.isListening }
        XCTAssertEqual(session.webResearchTrace, trace)
        XCTAssertEqual(fixture.audio.spoken.last, "La réponse à prononcer.")
        XCTAssertFalse(fixture.audio.spoken.contains { $0.contains("requête de recherche") })
        await session.stop()
        XCTAssertEqual(session.webResearchTrace, trace)
    }

    func testTraceClearsBetweenTurnsAndCancellationRejectsLateUpdates() async throws {
        let fixture = VoiceSessionFixture()
        fixture.audio.questions = ["Première recherche", "Deuxième recherche"]
        var replies: [CheckedContinuation<String, Error>] = []
        fixture.answer = { _ in try await withCheckedThrowingContinuation { replies.append($0) } }
        let session = fixture.makeSession(withTrace: true)
        try await session.start()
        await waitUntil { replies.count == 1 }
        let firstTrace = try XCTUnwrap(fixture.traceObserver)
        var trace = WebResearchTrace(toolsOffered: true, calls: [
            WebToolActivity(tool: .webSearch, origin: .model, state: .running, query: "première", startedAt: Date())
        ])
        firstTrace(trace)
        XCTAssertEqual(session.webResearchTrace, trace)
        trace.state = .completed
        trace.calls[0].state = .succeeded
        firstTrace(trace)
        replies[0].resume(returning: "Première réponse")
        await waitUntil { replies.count == 2 }
        XCTAssertNil(session.webResearchTrace)
        firstTrace(trace)
        XCTAssertNil(session.webResearchTrace, "An old turn cannot restore its trace")
        let secondTrace = try XCTUnwrap(fixture.traceObserver)
        trace.state = .preparing
        trace.calls[0].state = .running
        trace.calls[0].query = "deuxième"
        secondTrace(trace)
        await session.stop()
        XCTAssertEqual(session.webResearchTrace?.state, .cancelled)
        XCTAssertEqual(session.webResearchTrace?.calls.first?.state, .cancelled)
        XCTAssertNotNil(session.webResearchTrace?.calls.first?.finishedAt)
        let cancelled = session.webResearchTrace
        secondTrace(trace)
        replies[1].resume(returning: "Réponse tardive")
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(session.webResearchTrace, cancelled)
        XCTAssertFalse(fixture.audio.spoken.contains("Réponse tardive"))
    }

    func testFailedToolTraceSurvivesSessionStopWithoutReadingDetails() async throws {
        let fixture = VoiceSessionFixture()
        fixture.audio.questions = ["Cherche les horaires"]
        let trace = WebResearchTrace(state: .failed, finishedAt: Date(), calls: [
            WebToolActivity(tool: .webSearch, origin: .eudes, state: .failed,
                            query: "requête privée", startedAt: Date(), finishedAt: Date(), detail: "Échec de la recherche.")
        ])
        fixture.answer = { _ in
            fixture.traceObserver?(trace)
            throw SiriAssistantError.webSearchFailed
        }
        let session = fixture.makeSession(withTrace: true)
        try await session.start()
        await waitUntil { !session.isRunning }
        XCTAssertEqual(session.webResearchTrace, trace)
        XCTAssertNotNil(session.lastError)
        XCTAssertFalse(fixture.audio.spoken.contains { $0.contains("requête privée") })
    }

    func testLockedActionWaitsForInterfaceAndExecutesOnlyOnceInSameSession() async throws {
        let fixture = VoiceSessionFixture()
        fixture.audio.questions = ["Ouvre Deezer"]
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { session.isWaitingForAction }
        XCTAssertEqual(session.pendingQuestion, "Ouvre Deezer")
        XCTAssertTrue(fixture.questions.isEmpty)
        XCTAssertNil(session.claimAutomaticAction(for: fixture.id))
        session.setActionHandler(for: fixture.id) { question in
            try session.propose(XCTUnwrap(VoiceAction.direct(question)), confirmation: false, for: fixture.id)
            return "Ouverture de Deezer"
        }
        await session.resolvePendingAction(for: fixture.id)
        XCTAssertNil(session.pendingQuestion)
        XCTAssertNotNil(session.claimAutomaticAction(for: fixture.id))
        XCTAssertNil(session.claimAutomaticAction(for: fixture.id))
        session.completeAction(for: fixture.id, result: "Deezer ouvert")
        await waitUntil { fixture.audio.isListening }
        XCTAssertEqual(session.sessionID, fixture.id)
        XCTAssertEqual(fixture.audio.prepares, 1)
        XCTAssertEqual(fixture.begins, 1)
        await session.stop()
    }

    func testActionConfirmationAndStopClearPendingWork() async throws {
        let fixture = VoiceSessionFixture()
        fixture.audio.questions = ["Ouvre Spotify"]
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { session.isWaitingForAction }
        session.setActionHandler(for: fixture.id) { question in
            try session.propose(XCTUnwrap(VoiceAction.direct(question)), confirmation: true, for: fixture.id)
            return "Vérifier l’action"
        }
        await session.resolvePendingAction(for: fixture.id)
        XCTAssertNotNil(session.pendingAction)
        XCTAssertNil(session.claimAutomaticAction(for: fixture.id))
        XCTAssertFalse(fixture.audio.isListening)
        session.completeAction(for: UUID(), result: "Retour périmé")
        XCTAssertNotNil(session.pendingAction)
        await session.stop()
        XCTAssertNil(session.pendingAction)
        XCTAssertNil(session.pendingQuestion)
        XCTAssertFalse(session.isWaitingForAction)
        XCTAssertThrowsError(try session.propose(XCTUnwrap(VoiceAction.direct("Ouvre Deezer")), confirmation: false, for: fixture.id))
    }

    func testInterfaceHandlerLeavesOrdinaryConversationInExistingBackend() async throws {
        let fixture = VoiceSessionFixture()
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { fixture.audio.isListening }
        session.setActionHandler(for: fixture.id) { _ in nil }
        let waiting = fixture.audio.waiting
        fixture.audio.waiting = nil
        waiting?.resume(returning: "Bonjour")
        await waitUntil { fixture.questions.count == 1 && fixture.audio.isListening }
        XCTAssertEqual(fixture.answerIDs, [fixture.id])
        XCTAssertEqual(fixture.begins, 1)
        await session.stop()
    }

    func testVoiceActivityLinksContainOnlySessionAndRejectUnrelatedURLs() {
        let id = UUID()
        XCTAssertEqual(VoiceActivityAttributes.sessionID(from: VoiceActivityAttributes.url(for: id)), id)
        for value in ["https://voice/\(id)", "eudes://other/\(id)", "eudes://voice/not-a-uuid",
                      "eudes://voice/\(id)?action=open", "eudes://voice/\(id)#fragment", "eudes://voice/extra/\(id)"] {
            XCTAssertNil(VoiceActivityAttributes.sessionID(from: URL(string: value)!))
        }
    }

    func testSilenceResumesListeningWithoutRestartingSession() async throws {
        let fixture = VoiceSessionFixture()
        let session = fixture.makeSession()
        try await session.start()
        await waitUntil { fixture.audio.isListening }
        let waiting = fixture.audio.waiting
        fixture.audio.waiting = nil
        waiting?.resume(throwing: VoiceAssistantError.noSpeech)
        await waitUntil { fixture.audio.isListening }
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(fixture.audio.prepares, 1)
        XCTAssertTrue(fixture.questions.isEmpty)
        await session.stop()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for session state")
    }
}

@MainActor
private final class VoiceSessionFixture {
    let id = UUID()
    let audio = SessionTestAudio()
    let activity = SessionTestActivity()
    var valid = true
    var begins = 0
    var questions: [String] = []
    var answerIDs: [UUID] = []
    var ended: [UUID] = []
    var answer: (@MainActor (String) async throws -> String)?
    var progressObserver: (@MainActor (Bool) -> Void)?
    var traceObserver: (@MainActor (WebResearchTrace) -> Void)?

    func makeSession(maximumDuration: Duration = .seconds(10), withTrace: Bool = false) -> BackgroundVoiceSession {
        var backend = BackgroundVoiceSession.Backend(
            begin: { self.begins += 1; return self.id },
            answer: { try await self.respond($0, id: $1, onProgress: $2) },
            end: { self.ended.append($0) },
            isValid: { $0 == self.id && self.valid })
        if withTrace {
            backend.answerWithTrace = { question, id, onProgress, onTrace in
                self.traceObserver = onTrace
                return try await self.respond(question, id: id, onProgress: onProgress)
            }
        }
        return BackgroundVoiceSession(audio: audio, activity: activity, backend: backend,
            maximumDuration: maximumDuration,
            defaults: UserDefaults(suiteName: "BackgroundVoiceTests.\(UUID())")!)
    }

    private func respond(_ question: String, id: UUID, onProgress: @escaping @MainActor (Bool) -> Void) async throws -> String {
        questions.append(question); answerIDs.append(id)
        progressObserver = onProgress
        if let answer { return try await answer(question) }
        return "Réponse \(questions.count)"
    }
}

@MainActor
private final class SessionTestAudio: BackgroundVoiceAudioService {
    var preflightError: Error?
    var questions: [String] = []
    var spoken: [String] = []
    var prepares = 0
    var stops = 0
    var thinkingStarts = 0
    var isThinking = false
    var spokeWhileThinking = false
    var suspendPreparation = false
    var preparation: CheckedContinuation<Void, Never>?
    var waiting: CheckedContinuation<String, Error>?
    var interruption: (@MainActor () -> Void)?
    var levelObserver: (@MainActor (Float) -> Void)?
    var meteringEnabled = false
    var isListening: Bool { waiting != nil }
    func preflight() throws { if let preflightError { throw preflightError } }
    func prepare(onInterruption: @escaping @MainActor () -> Void) async throws {
        prepares += 1; interruption = onInterruption
        if suspendPreparation { await withCheckedContinuation { preparation = $0 } }
    }
    func startThinkingSound() async { isThinking = true; thinkingStarts += 1 }
    func stopThinkingSound() { isThinking = false }
    func speak(_ text: String) async throws {
        try Task.checkCancellation()
        spokeWhileThinking = spokeWhileThinking || isThinking
        spoken.append(text)
    }
    func listen() async throws -> String {
        try Task.checkCancellation()
        if !questions.isEmpty { return questions.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func listen(onLevel: @escaping @MainActor (Float) -> Void) async throws -> String {
        levelObserver = onLevel
        return try await listen()
    }
    func setVisualFeedbackEnabled(_ enabled: Bool) { meteringEnabled = enabled }
    func stop() {
        stopThinkingSound()
        stops += 1
        let old = waiting; waiting = nil
        old?.resume(throwing: CancellationError())
    }
}

@MainActor
private final class SessionTestActivity: VoiceActivityManaging {
    var starts = 0
    var ends = 0
    var startError: Error?
    var dismissed: (@MainActor () -> Void)?
    func start(sessionID: UUID, onDismissed: @escaping @MainActor () -> Void) async throws {
        starts += 1
        if let startError { throw startError }
        dismissed = onDismissed
    }
    func update(phase: VoiceActivityPhase) async {}
    func end() async { ends += 1; dismissed = nil }
}
