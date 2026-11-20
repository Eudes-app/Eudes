import XCTest
import AppIntents
import AVFoundation
import UIKit
@testable import Eudes

@MainActor
private final class AsyncGate {
    private(set) var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class VoiceAssistantTests: XCTestCase {
    func testVoiceResponseInstructionDefaultsAndBlankValuesUseSpokenReplyPolicy() throws {
        let suite = "EudesVoiceInstruction." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(VoiceResponseInstruction.selected(defaults: defaults), VoiceResponseInstruction.defaultText)
        defaults.set(" \n\t ", forKey: VoiceResponseInstruction.preferenceKey)
        XCTAssertEqual(VoiceResponseInstruction.selected(defaults: defaults), VoiceResponseInstruction.defaultText)
        XCTAssertTrue(VoiceResponseInstruction.defaultText.contains("language of the user's request"))
        XCTAssertTrue(VoiceResponseInstruction.defaultText.contains("1–2 short sentences"))
        XCTAssertTrue(VoiceResponseInstruction.defaultText.contains("No emojis"))
    }

    func testVoiceResponseInstructionPersistsCustomTextAndRestoresDefault() throws {
        let suite = "EudesVoiceInstruction." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("  Speak briefly.\nPreserve my requested language.\n ", forKey: VoiceResponseInstruction.preferenceKey)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(VoiceResponseInstruction.selected(defaults: reloaded),
                       "Speak briefly.\nPreserve my requested language.")
        defaults.removeObject(forKey: VoiceResponseInstruction.preferenceKey)
        XCTAssertEqual(VoiceResponseInstruction.selected(defaults: reloaded), VoiceResponseInstruction.defaultText)
    }

    func testBackgroundApplePreparationFailureNeverDownloadsOrFallsBack() async throws {
        let apple = LocalSpeechFixture()
        apple.preparationError = VoiceAssistantError.localRecognitionUnavailable
        let router = LocalVoiceTranscription(apple: { apple })

        do {
            try await router.prepareForBackgroundUse()
            XCTFail("A Siri session must fail if its selected local model is unavailable")
        } catch {
            XCTAssertEqual(error as? VoiceAssistantError, .localRecognitionUnavailable)
        }

        XCTAssertEqual(apple.prepareDownloadPermissions, [false])
        XCTAssertEqual(apple.transcriptionCalls, 0)
    }

    func testAppleTranscriptionErrorAndCancellationAreReported() async throws {
        let apple = LocalSpeechFixture()
        let router = LocalVoiceTranscription(apple: { apple })
        try await router.prepareForForegroundUse()
        let buffer = try transcriptionBuffer()
        apple.transcriptionError = VoiceAssistantError.recognitionFailed
        do {
            _ = try await router.transcribe(buffer)
            XCTFail("The selected engine's failure must be reported")
        } catch {
            XCTAssertEqual(error as? VoiceAssistantError, .recognitionFailed)
        }

        apple.transcriptionError = CancellationError()
        do {
            _ = try await router.transcribe(buffer)
            XCTFail("A cancelled request must not be retried")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(apple.transcriptionCalls, 2)
    }

    func testMissingAppleAssetsNeverDownloadDuringBackgroundPreparationOrTranscription() async throws {
        let backend = AppleSpeechBackendFixture()
        let manager = AppleSpeechModelManager(backend: backend)

        do {
            try await manager.prepare(allowDownload: false)
            XCTFail("Missing assets require foreground preparation")
        } catch {
            XCTAssertEqual(error as? AppleSpeechError, .preparationRequired)
        }
        do {
            _ = try await manager.transcribe(transcriptionBuffer())
            XCTFail("Transcription must not initiate an implicit download")
        } catch {
            XCTAssertEqual(error as? AppleSpeechError, .preparationRequired)
        }

        XCTAssertEqual(backend.installCalls, 0)
        XCTAssertEqual(backend.transcriptionCalls, 0)
        XCTAssertFalse(manager.isReady)
        XCTAssertFalse(manager.isPreparing)
        XCTAssertFalse(manager.isTranscribing)
    }

    func testAppleForegroundPreparationDownloadsMissingAssetsOnlyOnce() async throws {
        let backend = AppleSpeechBackendFixture()
        let manager = AppleSpeechModelManager(backend: backend)

        try await manager.prepare(allowDownload: true)
        XCTAssertTrue(manager.isReady)
        try await manager.prepare(allowDownload: true)
        try await manager.prepare(allowDownload: false)
        let text = try await manager.transcribe(transcriptionBuffer())

        XCTAssertEqual(text, "Texte Apple fictif")
        XCTAssertEqual(backend.installCalls, 1)
        XCTAssertEqual(backend.transcriptionCalls, 1)
        XCTAssertFalse(manager.isPreparing)
        XCTAssertFalse(manager.isTranscribing)
    }

    func testAlreadyInstalledAppleAssetsAreReservedWithoutDownloadingInBackground() async throws {
        let backend = AppleSpeechBackendFixture()
        backend.state = .ready
        let manager = AppleSpeechModelManager(backend: backend)

        try await manager.prepare(allowDownload: false)

        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(backend.reserveCalls, 1,
                       "Assets installed by another app still need a reservation for Eudes")
        XCTAssertEqual(backend.installCalls, 0)
    }

    func testAppleReservationFailureDoesNotClaimReadinessAndCanRetryWithoutDownload() async throws {
        let backend = AppleSpeechBackendFixture()
        backend.state = .ready
        backend.reserveOperation = { throw AppleSpeechError.preparationFailed }
        let manager = AppleSpeechModelManager(backend: backend)

        do {
            try await manager.prepare(allowDownload: false)
            XCTFail("An installed model must not be reported ready if Eudes could not reserve it")
        } catch {
            XCTAssertEqual(error as? AppleSpeechError, .preparationFailed)
        }
        XCTAssertFalse(manager.isReady)
        XCTAssertFalse(manager.isPreparing)

        backend.reserveOperation = nil
        try await manager.prepare(allowDownload: false)
        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(backend.reserveCalls, 2)
        XCTAssertEqual(backend.installCalls, 0)
    }

    func testAppleSetupErrorsRetainActionableMessagesInBackgroundSession() {
        for error in [AppleSpeechError.unsupported, .preparationRequired, .preparationFailed] {
            XCTAssertEqual(BackgroundVoiceSession.message(for: error), error.localizedDescription,
                           "Siri failures must keep the Apple setup instructions instead of a generic audio error")
        }
    }

    func testFailedApplePreparationClearsBusyStateAndCanRetry() async throws {
        let backend = AppleSpeechBackendFixture()
        backend.installOperation = { throw URLError(.notConnectedToInternet) }
        let manager = AppleSpeechModelManager(backend: backend)

        do {
            try await manager.prepare(allowDownload: true)
            XCTFail("A failed download must not mark the engine as ready")
        } catch {}
        XCTAssertFalse(manager.isReady)
        XCTAssertFalse(manager.isPreparing)
        XCTAssertNotNil(manager.errorMessage)

        backend.installOperation = nil
        try await manager.prepare(allowDownload: true)
        XCTAssertTrue(manager.isReady)
        XCTAssertFalse(manager.isPreparing)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(backend.installCalls, 2)
    }

    func testCancelledApplePreparationRejectsConcurrentWorkAndClearsBusyState() async throws {
        let backend = AppleSpeechBackendFixture()
        let gate = AsyncGate()
        backend.installOperation = { await gate.wait() }
        let manager = AppleSpeechModelManager(backend: backend)
        let preparation = Task { try await manager.prepare(allowDownload: true) }
        for _ in 0..<1000 where gate.continuation == nil { await Task.yield() }
        XCTAssertNotNil(gate.continuation)
        XCTAssertTrue(manager.isPreparing)
        do {
            try await manager.prepare(allowDownload: false)
            XCTFail("Another preparation must not overlap the pending download")
        } catch {
            XCTAssertEqual(error as? VoiceAssistantError, .interrupted)
        }
        do {
            _ = try await manager.transcribe(transcriptionBuffer())
            XCTFail("Transcription must wait for a completed preparation")
        } catch {
            XCTAssertEqual(error as? VoiceAssistantError, .interrupted)
        }

        preparation.cancel()
        gate.resume()
        do {
            try await preparation.value
            XCTFail("Late completion of a download must not complete a cancelled preparation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(manager.isPreparing)
        XCTAssertFalse(manager.isTranscribing)
        XCTAssertFalse(manager.isReady)
        try await manager.prepare(allowDownload: false)
        XCTAssertTrue(manager.isReady, "Assets installed before cancellation remain usable after a fresh check")
        XCTAssertEqual(backend.installCalls, 1)
    }

    func testAppleAssetEvictionIsDetectedBeforeDecoding() async throws {
        let backend = AppleSpeechBackendFixture()
        backend.state = .ready
        let manager = AppleSpeechModelManager(backend: backend)
        try await manager.prepare(allowDownload: false)
        XCTAssertTrue(manager.isReady)
        backend.state = .downloadRequired

        do {
            _ = try await manager.transcribe(transcriptionBuffer())
            XCTFail("Cached readiness must not bypass the current asset check")
        } catch {
            XCTAssertEqual(error as? AppleSpeechError, .preparationRequired)
        }

        XCTAssertFalse(manager.isReady)
        XCTAssertEqual(backend.transcriptionCalls, 0)
        XCTAssertEqual(backend.installCalls, 0)
    }

    func testCancelledAppleTranscriptionClearsBusyStateAndCanRetry() async throws {
        let backend = AppleSpeechBackendFixture()
        backend.state = .ready
        let gate = AsyncGate()
        backend.transcriptionOperation = { await gate.wait() }
        let manager = AppleSpeechModelManager(backend: backend)
        let buffer = try transcriptionBuffer()
        let transcription = Task { try await manager.transcribe(buffer) }
        for _ in 0..<1000 where gate.continuation == nil { await Task.yield() }
        XCTAssertNotNil(gate.continuation)
        XCTAssertTrue(manager.isTranscribing)
        do {
            try await manager.prepare(allowDownload: true)
            XCTFail("Preparation must not overlap a live transcription")
        } catch {
            XCTAssertEqual(error as? VoiceAssistantError, .interrupted)
        }

        transcription.cancel()
        gate.resume()
        do {
            _ = try await transcription.value
            XCTFail("Cancelled speech must never be returned to the assistant")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(manager.isPreparing)
        XCTAssertFalse(manager.isTranscribing)
        backend.transcriptionOperation = nil
        let text = try await manager.transcribe(buffer)
        XCTAssertEqual(text, "Texte Apple fictif")
        XCTAssertEqual(backend.transcriptionCalls, 2)
    }

    func testUnsupportedAppleDeviceDoesNotDownloadOrDecode() async throws {
        let backend = AppleSpeechBackendFixture()
        backend.isAvailable = false
        backend.state = .unsupported
        let manager = AppleSpeechModelManager(backend: backend)

        do {
            try await manager.prepare(allowDownload: true)
            XCTFail("Unsupported devices must expose the unavailable state")
        } catch {
            XCTAssertEqual(error as? AppleSpeechError, .unsupported)
        }

        XCTAssertFalse(manager.isReady)
        XCTAssertEqual(backend.installCalls, 0)
        XCTAssertEqual(backend.transcriptionCalls, 0)
    }

    func testAppleAudioConversionPreservesDurationAcrossMicrophoneFormats() throws {
        for (sourceRate, channels, targetRate) in [(48_000.0, 2, 16_000.0), (16_000.0, 1, 48_000.0), (44_100.0, 1, 16_000.0)] {
            let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: AVAudioChannelCount(channels)))
            let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1))
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(sourceRate)))
            input.frameLength = input.frameCapacity
            let inputChannels = try XCTUnwrap(input.floatChannelData)
            for channel in 0..<channels {
                for frame in 0..<Int(input.frameLength) {
                    inputChannels[channel][frame] = Float(sin(2 * .pi * 440 * Double(frame) / sourceRate)) * 0.2
                }
            }

            let output = try AppleSpeechAudioConversion.convert(input, to: target)
            let frames = output.reduce(0) { $0 + Int($1.frameLength) }
            XCTAssertEqual(Double(frames) / targetRate, 1, accuracy: 0.001,
                           "Conversion must retain the whole recording, including beyond the first output buffer")
            XCTAssertGreaterThan(output.count, 1)
            for buffer in output {
                XCTAssertEqual(buffer.format, target)
                let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                let values = UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))
                XCTAssertTrue(values.allSatisfy(\.isFinite))
                XCTAssertGreaterThan(values.map { abs($0) }.max() ?? 0, 0.05)
            }
        }
    }

    func testAppleAudioConversionRejectsEmptyCapture() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        XCTAssertThrowsError(try AppleSpeechAudioConversion.convert(input, to: format)) { error in
            XCTAssertEqual(error as? VoiceAssistantError, .noSpeech)
        }
    }

    private func transcriptionBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.initialize(repeating: 0.1, count: Int(buffer.frameLength))
        return buffer
    }

    func testVoicePortraitIsAvailableInApplicationBundle() throws {
        // Uses the same asset lookup as the animation, from the running app bundle.
        let portrait = try XCTUnwrap(UIImage(named: "VoicePortrait"))
        let image = try XCTUnwrap(portrait.cgImage)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    func testParticleEnvelopeMovesBetweenMicrophoneUpdates() {
        var envelope = VoiceParticleEnvelope()
        envelope.retarget(level: 1, at: 0)

        // Several rendered frames occur before the next approximately 12 Hz measurement.
        var previous = envelope.value(at: 0)
        for frame in 1...5 {
            let value = envelope.value(at: Double(frame) / 60)
            XCTAssertGreaterThan(value, previous, "Movement must continue between audio samples")
            XCTAssertLessThan(value, 1, "The portrait must not jump directly to the audio target")
            previous = value
        }
    }

    func testParticleEnvelopeRetargetsContinuouslyDuringMotion() {
        var envelope = VoiceParticleEnvelope()
        envelope.retarget(level: 1, at: 0)
        let beforeSilence = envelope.value(at: 0.04)
        XCTAssertGreaterThan(beforeSilence, 0)

        envelope.retarget(level: 0, at: 0.04)
        XCTAssertEqual(envelope.value(at: 0.04), beforeSilence, accuracy: 0.000_001)
        let beforeSpeechReturns = envelope.value(at: 0.06)
        XCTAssertLessThan(beforeSpeechReturns, beforeSilence)

        envelope.retarget(level: 1, at: 0.06)
        XCTAssertEqual(envelope.value(at: 0.06), beforeSpeechReturns, accuracy: 0.000_001)
        XCTAssertGreaterThan(envelope.value(at: 0.08), beforeSpeechReturns)
    }

    func testParticleEnvelopeClampsLevelsAndRejectsNonFiniteInput() {
        XCTAssertEqual(VoiceParticleEnvelope.intensity(for: -1), 0)
        XCTAssertEqual(VoiceParticleEnvelope.intensity(for: 2), 1)
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(VoiceParticleEnvelope.intensity(for: invalid), 0)
            let envelope = VoiceParticleEnvelope(level: invalid, at: 10)
            XCTAssertEqual(envelope.value(at: 10), 0)
        }

        var envelope = VoiceParticleEnvelope(level: 2)
        for (index, level) in [-1, Double.nan, 2, Double.infinity, 0.1].enumerated() {
            let time = Double(index)
            envelope.retarget(level: level, at: time)
            for offset in [0.0, 0.02, 0.1, 0.5] {
                let value = envelope.value(at: time + offset)
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
    }

    func testParticleEnvelopeReleasesMoreGentlyThanItAttacks() {
        var attack = VoiceParticleEnvelope()
        attack.retarget(level: 1, at: 0)
        var release = VoiceParticleEnvelope(level: 1)
        release.retarget(level: 0, at: 0)

        let rise = attack.value(at: 0.1)
        let fall = 1 - release.value(at: 0.1)
        XCTAssertGreaterThan(rise, fall, "Speech should gather the portrait faster than silence disperses it")
        XCTAssertGreaterThan(release.value(at: 0.1), 0)
        XCTAssertLessThan(release.value(at: 1), 0.01, "The portrait must settle back during sustained silence")
    }

    func testParticleEnvelopeResetClearsPendingMovementImmediately() {
        var envelope = VoiceParticleEnvelope()
        envelope.retarget(level: 1, at: 0)
        XCTAssertGreaterThan(envelope.value(at: 0.05), 0)

        envelope.reset(level: 0, at: 0.05)
        XCTAssertEqual(envelope.value(at: 0.05), 0)
        XCTAssertEqual(envelope.value(at: 10), 0, "Hidden or inactive views must not retain an unfinished transition")

        envelope.reset(level: 0.2, at: 10)
        let settled = VoiceParticleEnvelope.intensity(for: 0.2)
        XCTAssertEqual(envelope.value(at: 10), settled, accuracy: 0.000_001)
        XCTAssertEqual(envelope.value(at: 20), settled, accuracy: 0.000_001)
    }

    func testParticleEnvelopeDoesNotDependOnDisplaySamplingCadence() {
        var frequent = VoiceParticleEnvelope()
        var sparse = VoiceParticleEnvelope()
        for (time, level) in [(0.0, 1.0), (0.083, 0.15), (0.166, 0.8), (0.249, 0.0)] {
            frequent.retarget(level: level, at: time)
            sparse.retarget(level: level, at: time)
            for frame in 1...9 {
                _ = frequent.value(at: time + Double(frame) / 120)
            }
            XCTAssertEqual(frequent.value(at: time + 0.08), sparse.value(at: time + 0.08), accuracy: 0.000_001,
                           "Rendering extra frames must not change the envelope's trajectory")
        }
        XCTAssertEqual(frequent.value(at: 2), sparse.value(at: 2), accuracy: 0.000_001)
    }

    func testMicrophoneLevelIsBoundedAndClearedOnCancelAndNewTurn() async {
        let audio = VoiceAudioFixture()
        audio.suspendListening = true
        let model = VoiceAssistantModel(audio: audio)
        model.start { _ in "Réponse fictive" }
        for _ in 0..<1000 where model.phase != .listening { await Task.yield() }
        XCTAssertEqual(model.phase, .listening)
        let oldHandler = audio.levelHandler
        audio.levelHandler?(0.6)
        XCTAssertEqual(model.audioLevel, 0.6, accuracy: 0.001)
        audio.levelHandler?(1.5)
        XCTAssertEqual(model.audioLevel, 1)
        audio.levelHandler?(-0.5)
        XCTAssertEqual(model.audioLevel, 0)
        audio.levelHandler?(0.6)
        model.cancel()
        XCTAssertEqual(model.audioLevel, 0)
        XCTAssertNil(audio.levelHandler)

        model.start { _ in "Réponse fictive" }
        for _ in 0..<1000 where model.phase != .listening { await Task.yield() }
        oldHandler?(0.9)
        XCTAssertEqual(model.audioLevel, 0, "A delayed update from an earlier recording must not animate the next turn")
        model.cancel()
    }

    func testCapturedLevelTracksSpeechAndFallsDuringSilence() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        func buffer(amplitude: Float, frames: AVAudioFrameCount = 4_800) throws -> AVAudioPCMBuffer {
            let result = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            result.frameLength = result.frameCapacity
            let channel = try XCTUnwrap(result.floatChannelData?[0])
            for index in 0..<Int(result.frameLength) { channel[index] = amplitude }
            return result
        }
        let capture = LocalVoiceCapture(sampleRate: 48_000)
        XCTAssertEqual(try XCTUnwrap(capture.appendAndMeasure(buffer(amplitude: 0)).level), 0)
        let speech = try XCTUnwrap(capture.appendAndMeasure(buffer(amplitude: 0.08)).level)
        XCTAssertGreaterThan(speech, 0.4)
        XCTAssertLessThanOrEqual(speech, 1)
        XCTAssertTrue(capture.heardSpeech)
        let quieter = try XCTUnwrap(capture.appendAndMeasure(buffer(amplitude: 0)).level)
        XCTAssertLessThan(quieter, speech)
        XCTAssertGreaterThan(quieter, 0)

        // A 48 kHz input with 1024-frame buffers publishes once every four
        // buffers, not once per real-time audio callback.
        let throttled = LocalVoiceCapture(sampleRate: 48_000)
        for _ in 0..<3 {
            XCTAssertNil(try throttled.appendAndMeasure(buffer(amplitude: 0.08, frames: 1_024)).level)
        }
        XCTAssertNotNil(try throttled.appendAndMeasure(buffer(amplitude: 0.08, frames: 1_024)).level)
    }

    func testVoiceOutputPreferencesPersistAndApplyToUtterances() throws {
        let suite = "EudesVoiceOutput." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let defaultUtterance = VoiceOutputSettings.makeUtterance(text: "Bonjour", defaults: defaults)
        XCTAssertEqual(defaultUtterance.rate, AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertEqual(defaultUtterance.voice?.identifier, AVSpeechSynthesisVoice(language: "fr-FR")?.identifier)

        defaults.set(0.42, forKey: VoiceOutputSettings.rateKey)
        if let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix("fr") }) {
            defaults.set(voice.identifier, forKey: VoiceOutputSettings.voiceIdentifierKey)
            let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
            let utterance = VoiceOutputSettings.makeUtterance(text: "Bonjour", defaults: reloaded)
            XCTAssertEqual(utterance.voice?.identifier, voice.identifier)
            XCTAssertEqual(utterance.rate, 0.42, accuracy: 0.001)
        }

        defaults.set("invalid.removed.voice", forKey: VoiceOutputSettings.voiceIdentifierKey)
        let fallback = VoiceOutputSettings.makeUtterance(text: "Bonjour", defaults: defaults)
        XCTAssertEqual(fallback.voice?.identifier, AVSpeechSynthesisVoice(language: "fr-FR")?.identifier)
        XCTAssertEqual(fallback.rate, 0.42, accuracy: 0.001)
    }

    func testVoiceOutputRateRejectsInvalidValuesAndIsBounded() {
        XCTAssertEqual(VoiceOutputSettings.normalizedRate(.nan), AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertEqual(VoiceOutputSettings.normalizedRate(.infinity), AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertEqual(VoiceOutputSettings.normalizedRate(-1), 0.35, accuracy: 0.001)
        XCTAssertEqual(VoiceOutputSettings.normalizedRate(1), 0.6, accuracy: 0.001)
    }

    func testVoiceTurnSendsOnlyFinalTranscriptAndSpeaksReply() async {
        let audio = VoiceAudioFixture()
        let model = VoiceAssistantModel(audio: audio)
        var questions: [String] = []
        model.start { question in
            questions.append(question)
            return "Réponse fictive"
        }
        for _ in 0..<1000 where model.phase != .complete { await Task.yield() }
        XCTAssertEqual(questions, ["Demande finale"])
        XCTAssertEqual(model.transcript, "Demande finale")
        XCTAssertEqual(model.response, "Réponse fictive")
        XCTAssertEqual(audio.spoken, ["Que souhaites-tu faire ?", "Réponse fictive"])
        XCTAssertEqual(audio.thinkingStarts, 1)
        XCTAssertFalse(audio.isThinking)
        XCTAssertFalse(audio.spokeWhileThinking)
        XCTAssertEqual(model.phase, .complete)
    }

    func testCancelDuringListeningDoesNotSendPartialTranscript() async {
        let audio = VoiceAudioFixture()
        audio.suspendListening = true
        let model = VoiceAssistantModel(audio: audio)
        var calls = 0
        model.start { _ in calls += 1; return "Ne doit pas être lu" }
        for _ in 0..<1000 where model.phase != .listening { await Task.yield() }
        XCTAssertEqual(model.phase, .listening)
        XCTAssertEqual(model.transcript, "Demande partielle")
        model.cancel()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(audio.spoken, ["Que souhaites-tu faire ?"])
    }

    func testLateModelReplyAfterCancellationIsNotSpoken() async {
        let audio = VoiceAudioFixture()
        let model = VoiceAssistantModel(audio: audio)
        var reply: CheckedContinuation<String, Error>?
        model.start { _ in try await withCheckedThrowingContinuation { reply = $0 } }
        for _ in 0..<1000 where reply == nil { await Task.yield() }
        XCTAssertEqual(model.phase, .thinking)
        XCTAssertTrue(audio.isThinking)
        model.cancel()
        XCTAssertFalse(audio.isThinking)
        reply?.resume(returning: "Réponse arrivée après annulation")
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(audio.spoken, ["Que souhaites-tu faire ?"])
        XCTAssertTrue(model.response.isEmpty)
    }

    func testModelFailureStopsThinkingSoundBeforeSpeakingError() async {
        let audio = VoiceAudioFixture()
        let model = VoiceAssistantModel(audio: audio)
        model.start { _ in throw URLError(.timedOut) }
        for _ in 0..<1000 where !model.phase.isFailedForTest { await Task.yield() }
        XCTAssertTrue(model.phase.isFailedForTest)
        XCTAssertEqual(audio.thinkingStarts, 1)
        XCTAssertFalse(audio.isThinking)
        XCTAssertFalse(audio.spokeWhileThinking)
        model.cancel()
    }

    func testOldCancelledReplyCannotSilenceNewThinkingSound() async {
        let audio = VoiceAudioFixture()
        let model = VoiceAssistantModel(audio: audio)
        var oldReply: CheckedContinuation<String, Error>?
        var newReply: CheckedContinuation<String, Error>?
        model.start { _ in try await withCheckedThrowingContinuation { oldReply = $0 } }
        for _ in 0..<1000 where oldReply == nil { await Task.yield() }
        model.start { _ in try await withCheckedThrowingContinuation { newReply = $0 } }
        for _ in 0..<1000 where newReply == nil { await Task.yield() }
        oldReply?.resume(throwing: URLError(.timedOut))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(model.phase, .thinking)
        XCTAssertTrue(audio.isThinking)
        newReply?.resume(returning: "Nouvelle réponse")
        for _ in 0..<1000 where model.phase != .complete { await Task.yield() }
        XCTAssertEqual(model.response, "Nouvelle réponse")
        XCTAssertFalse(audio.isThinking)
        XCTAssertFalse(audio.spokeWhileThinking)
    }

    func testDeniedSpeechPermissionDoesNotCallModel() async {
        let audio = VoiceAudioFixture()
        audio.permissionError = VoiceAssistantError.speechDenied
        let model = VoiceAssistantModel(audio: audio)
        var calls = 0
        model.start { _ in calls += 1; return "Ne doit pas être lu" }
        for _ in 0..<1000 where !model.phase.isFailedForTest { await Task.yield() }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.phase, .failed(VoiceAssistantError.speechDenied.localizedDescription))
        model.cancel()
    }

    func testMicrophoneIsOnlyAdvertisedReadyAfterAudioEngineSignalsReadiness() async {
        let audio = VoiceAudioFixture()
        audio.reportsListeningReadiness = true
        audio.suspendListening = true
        let model = VoiceAssistantModel(audio: audio)
        model.start { _ in "Réponse" }
        for _ in 0..<2000 where audio.listenCount == 0 { await Task.yield() }
        XCTAssertEqual(model.phase, .listening)
        XCTAssertFalse(model.isMicrophoneReady)
        audio.readyHandler?(true)
        XCTAssertTrue(model.isMicrophoneReady)
        model.cancel()
        XCTAssertFalse(model.isMicrophoneReady)
    }

    func testBothPublishedVoiceIntentsStartTheSameHandsFreeMode() {
        XCTAssertEqual(StartEudesHandsFreeIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertFalse(StartEudesHandsFreeIntent.openAppWhenRun)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(StartEudesHandsFreeIntent.supportedModes, .background)
            XCTAssertEqual(OpenEudesVoiceIntent.supportedModes, .background)
        }
    }

    func testContinuousVoiceAnswersTwiceThenStopsLocally() async {
        let audio = VoiceAudioFixture()
        audio.questions = ["Bonjour", "Et ensuite ?", "Arrête Eudes."]
        let model = VoiceAssistantModel(audio: audio)
        var questions: [String] = []
        model.start(continuous: true) { question in
            questions.append(question)
            return "Réponse à " + question
        }
        for _ in 0..<2000 where model.phase != .complete { await Task.yield() }
        XCTAssertEqual(model.phase, .complete)
        XCTAssertEqual(questions, ["Bonjour", "Et ensuite ?"])
        XCTAssertEqual(audio.listenCount, 3)
        XCTAssertEqual(audio.spoken.filter { $0 == "Que souhaites-tu faire ?" }.count, 1)
        XCTAssertEqual(model.response, "L’assistant vocal est arrêté.")
        XCTAssertFalse(audio.isThinking)
    }

    func testContinuousVoicePausesForActionConfirmationAndCancelsNewListening() async {
        let audio = VoiceAudioFixture()
        audio.questions = ["Crée un rappel"]
        let model = VoiceAssistantModel(audio: audio)
        model.start(continuous: true, shouldContinue: { false }) { _ in "Vérifie l’action." }
        for _ in 0..<2000 where model.phase != .complete { await Task.yield() }
        XCTAssertEqual(model.phase, .complete)
        XCTAssertEqual(audio.listenCount, 1)
        audio.questions = ["Bonjour"]
        audio.suspendListening = true
        model.start(continuous: true) { _ in "Bonjour" }
        for _ in 0..<2000 where audio.listenCount < 3 { await Task.yield() }
        model.cancel()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(audio.isThinking)
    }

    func testVoiceShortcutStartsHandsFreeWithoutRequiringUnlock() {
        XCTAssertFalse(OpenEudesVoiceIntent.openAppWhenRun)
        XCTAssertEqual(OpenEudesVoiceIntent.authenticationPolicy, .alwaysAllowed)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(OpenEudesVoiceIntent.supportedModes, .background)
        }
        XCTAssertFalse(VoiceActionError.foreground.localizedDescription.contains("déverrouill"))
    }

    func testVoiceShortcutStartsWithoutQuestionAndPreservesDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EudesVoiceShortcut." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let profile = ServerProfile(name: "Fictif", baseURL: "https://example.invalid/v1", model: "alpha")
        let attachment = ImageAttachment(data: Data([1, 2, 3]))
        var data = AppData(); data.servers = [profile]; data.selectedServerID = profile.id; data.imageDraft = [attachment]
        try PrivateStorage(directory: directory).save(data)
        let store = AppStore(storageDirectory: directory, defaults: defaults, readKey: { _ in "" })
        try store.requestVoiceAssistant()
        try store.requestVoiceAssistant() // A replay must not create another conversation.
        XCTAssertTrue(store.voiceAssistantRequested)
        XCTAssertTrue(store.data.conversations.isEmpty)
        XCTAssertEqual(store.draftImages, [attachment])
        XCTAssertEqual(store.currentModel, "alpha")
    }
}

private extension VoiceAssistantModel.Phase {
    var isFailedForTest: Bool { if case .failed = self { return true }; return false }
}

@MainActor
private final class LocalSpeechFixture: LocalSpeechTranscribing {
    var prepareDownloadPermissions: [Bool] = []
    var transcriptionCalls = 0
    var lastBuffer: AVAudioPCMBuffer?
    var preparationError: Error?
    var transcriptionError: Error?

    func preflight() throws {}

    func prepare(allowDownload: Bool) async throws {
        prepareDownloadPermissions.append(allowDownload)
        if let preparationError { throw preparationError }
    }

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        transcriptionCalls += 1
        lastBuffer = buffer
        if let transcriptionError { throw transcriptionError }
        return "Transcription locale fictive"
    }
}

@MainActor
private final class AppleSpeechBackendFixture: AppleSpeechTranscriptionBackend {
    var isAvailable = true
    var state: AppleSpeechAssetState = .downloadRequired
    var reserveCalls = 0
    var installCalls = 0
    var transcriptionCalls = 0
    var reserveOperation: (@MainActor () async throws -> Void)?
    var installOperation: (@MainActor () async throws -> Void)?
    var transcriptionOperation: (@MainActor () async throws -> Void)?

    func assetState() async -> AppleSpeechAssetState { state }

    func reserveAssets() async throws {
        reserveCalls += 1
        try await reserveOperation?()
    }

    func installAssets() async throws {
        installCalls += 1
        try await installOperation?()
        state = .ready
    }

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        transcriptionCalls += 1
        try await transcriptionOperation?()
        return "Texte Apple fictif"
    }
}

@MainActor
private final class VoiceAudioFixture: VoiceAudioService {
    var spoken: [String] = []
    var questions: [String] = []
    var listenCount = 0
    var reportsListeningReadiness = false
    var readyHandler: (@MainActor (Bool) -> Void)?
    func setListeningReadyHandler(_ handler: (@MainActor (Bool) -> Void)?) { readyHandler = handler }
    var isThinking = false
    var thinkingStarts = 0
    var spokeWhileThinking = false
    var suspendListening = false
    var permissionError: Error?
    var levelHandler: (@MainActor (Float) -> Void)?
    private var pending: CheckedContinuation<String, Error>?

    func requestPermissions() async throws { if let permissionError { throw permissionError } }
    func setLevelHandler(_ handler: (@MainActor (Float) -> Void)?) { levelHandler = handler }
    func startThinkingSound() async { isThinking = true; thinkingStarts += 1 }
    func stopThinkingSound() { isThinking = false }
    func speak(_ text: String) async throws {
        spokeWhileThinking = spokeWhileThinking || isThinking
        spoken.append(text)
    }
    func listen(onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        listenCount += 1
        if !questions.isEmpty { return questions.removeFirst() }
        onPartial("Demande partielle")
        if suspendListening {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return "Demande finale"
    }
    func finishListening() { }
    func cancel() {
        stopThinkingSound()
        guard let pending else { return }
        self.pending = nil
        pending.resume(throwing: CancellationError())
    }
}

@MainActor
final class VoiceThinkingSoundTests: XCTestCase {
    func testFastAnswerCancelsFirstPulse() async throws {
        let output = ThinkingSoundOutputFixture()
        let sound = VoiceThinkingSound(output: output, initialDelay: .milliseconds(30), interval: .milliseconds(10))
        sound.start()
        sound.stop()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(output.pulses, 0)
        XCTAssertFalse(output.isPlaying)
    }

    func testWaitingRepeatsButStopPreventsAnyFurtherPulse() async throws {
        let output = ThinkingSoundOutputFixture()
        let sound = VoiceThinkingSound(output: output, initialDelay: .milliseconds(1), interval: .milliseconds(10))
        sound.start()
        for _ in 0..<100 where output.pulses < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(output.pulses, 2)
        sound.stop()
        let count = output.pulses
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(output.pulses, count)
        XCTAssertFalse(output.isPlaying)
    }

    func testGeneratedToneDecodesAsShortMonoAudioWithSilenceAtItsBoundaries() throws {
        let data = VoiceThinkingTone.wavData
        let player = try AVAudioPlayer(data: data)
        XCTAssertEqual(player.numberOfChannels, 1)
        XCTAssertEqual(player.duration, 0.36, accuracy: 0.001)
        let samples: [Int16] = stride(from: 44, to: data.count, by: 2).map {
            Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)
        }
        XCTAssertEqual(samples.first, 0)
        XCTAssertEqual(samples.last, 0)
        XCTAssertGreaterThan(samples.map { abs(Int($0)) }.max() ?? 0, 1_000)
        XCTAssertLessThan(samples.map { abs(Int($0)) }.max() ?? 0, 8_000)
    }
}

@MainActor
private final class ThinkingSoundOutputFixture: VoiceThinkingSoundOutput {
    var pulses = 0
    var isPlaying = false
    func playPulse() { pulses += 1; isPlaying = true }
    func stop() { isPlaying = false }
}

final class VoiceActionTests: XCTestCase {
    func testDeezerAndApplicationQualifiersAreHandledWithoutTheModel() throws {
        for phrase in ["ouvre l'application deezer", "Ouvre l’application Deezer.", "Lance l’appli Deezer !", "Ouvre Deezer", "Lance l’app Spotify", "Ouvre application Waze"] {
            let action = try XCTUnwrap(VoiceAction.direct(phrase))
            XCTAssertEqual(action.kind, .app)
            XCTAssertNotNil(try action.validated().url)
        }
        XCTAssertEqual(VoiceAction.direct("ouvre l'application deezer")?.url?.absoluteString, "deezer://")
        XCTAssertEqual(VoiceAction.direct("Ouvre l’application inconnue")?.kind, .clarification)
        XCTAssertEqual(VoiceAction.direct("Ouvre l’application Deezer et envoie un SMS")?.kind, .clarification)
        XCTAssertNil(VoiceAction.direct("N’ouvre pas l’application Deezer"))
        XCTAssertNil(VoiceAction.direct("Comment ouvrir l’application Deezer ?"))
    }

    func testSimpleCommandsAndQuotedCommands() throws {
        XCTAssertEqual(VoiceAction.direct("Ouvre Spotify !")?.kind, .app)
        XCTAssertEqual(VoiceAction.direct("Lance Waze")?.value, "waze")
        XCTAssertNil(VoiceAction.direct("Comment dire ouvre Spotify ?"))
        XCTAssertNil(VoiceAction.direct("N’ouvre pas Spotify"))
        XCTAssertNil(VoiceAction.direct("Ouvre Spotify et envoie un SMS"))
        XCTAssertNil(VoiceAction.direct("Ouvre une application inconnue"))
    }
    func testURLBoundariesAndEscaping() throws {
        for url in ["javascript:alert(1)", "https://user:secret@example.com", "file:///tmp/foo.html", "http://example.com", "example.com et fais autre chose"] {
            XCTAssertNil(VoiceAction.websiteURL(url))
        }
        let action = VoiceAction(kind: .route, value: "Paris & Lyon? #1")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(action.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "daddr", value: action.value)])
    }
    func testModelOutputCannotRunUnknownOrMalformedActions() throws {
        XCTAssertThrowsError(try VoiceAction.decode("{\"kind\":\"delete\",\"value\":\"all\"}"))
        XCTAssertThrowsError(try VoiceAction.decode("```json\n{\"kind\":\"app\",\"value\":\"spotify\"}\n```"))
        XCTAssertThrowsError(try VoiceAction.decode("[{\"kind\":\"app\",\"value\":\"spotify\"}]"))
        XCTAssertThrowsError(try VoiceAction(kind: .app, value: "shortcuts://run-shortcut").validated())
        XCTAssertThrowsError(try VoiceAction(kind: .website, value: "tel://123.example").validated())
        XCTAssertThrowsError(try VoiceAction(kind: .sms, value: "Paul", body: "").validated())
        XCTAssertThrowsError(try VoiceAction(kind: .reminder, value: "Appeler Paul").validated())
        XCTAssertThrowsError(try VoiceAction(kind: .event, value: "Dentiste", date: "2026-11-06T10:00:00Z", endDate: "2026-11-06T09:00:00Z").validated())
        XCTAssertEqual(try VoiceAction.decode("{\"kind\":\"app\",\"value\":\"spotify\"}").kind, .app)
    }
    func testReminderUsesInjectedLocalCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T22:00:00Z"))
        let action = try XCTUnwrap(VoiceAction.direct("Rappelle-moi de téléphoner demain à 9 h", now: now, calendar: calendar))
        XCTAssertEqual(action.kind, .reminder)
        XCTAssertEqual(action.date, "2026-11-06T08:00:00Z")
        XCTAssertNil(VoiceAction.direct("Rappelle-moi de téléphoner demain à 29 h", now: now, calendar: calendar))
        XCTAssertNil(VoiceAction.direct("Rappelle-moi de téléphoner demain à 9 h 99", now: now, calendar: calendar))
    }
    func testLocalEventRequiresExplicitDurationAndBackgroundSearchRemainsAvailable() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z"))
        let action = try XCTUnwrap(VoiceAction.direct("Ajoute Dentiste demain à 14 h pendant 1 heure.", now: now))
        XCTAssertEqual(action.value, "Dentiste")
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: try XCTUnwrap(action.date)))
        let end = try XCTUnwrap(ISO8601DateFormatter().date(from: try XCTUnwrap(action.endDate)))
        XCTAssertEqual(end.timeIntervalSince(start), 3600)
        XCTAssertNil(VoiceAction.direct("Ajoute Dentiste demain à 14 h", now: now))
        XCTAssertFalse(VoiceAction.requiresForeground("Cherche sur Internet la météo."))
        XCTAssertFalse(VoiceAction.requiresForeground("Recherche sur le web la météo"))
        XCTAssertTrue(VoiceAction.requiresForeground("Ouvre Spotify"))
    }
    func testExplicitVoiceResearchBypassesActionsOnlyWhenEnabled() {
        for question in ["Recherche sur le Web la météo", "Cherche sur Internet la météo",
                         "Peux-tu rechercher sur Internet les horaires ?"] {
            for mode in [VoiceWebSearchMode.onRequest, .always] {
                XCTAssertFalse(VoiceAction.shouldInterpretAction(question, hasClarification: false, voiceWebMode: mode), question)
            }
            XCTAssertTrue(VoiceAction.shouldInterpretAction(question, hasClarification: false, voiceWebMode: .disabled), question)
            XCTAssertTrue(VoiceAction.shouldInterpretAction(question, hasClarification: true, voiceWebMode: .onRequest), question)
        }
        XCTAssertTrue(VoiceAction.shouldInterpretAction("Ouvre Spotify", hasClarification: false, voiceWebMode: .onRequest))
        XCTAssertFalse(VoiceAction.shouldInterpretAction("Quelle heure est-il ?", hasClarification: false, voiceWebMode: .always))
    }
    func testSMSPreservesBodyAndRequiresExplicitSeparator() {
        let action = VoiceAction.direct("Écris à Paul : J’arrive à Noël !")
        XCTAssertEqual(action?.body, "J’arrive à Noël !")
        XCTAssertEqual(action?.value, "paul")
        XCTAssertNil(VoiceAction.direct("Écris à Paul quand tu auras le temps"))
        XCTAssertFalse(VoiceAction.mayRequestAction("Qu’est-ce qu’un rappel ?"))
        XCTAssertTrue(VoiceAction.mayRequestAction("Je voudrais écouter de la musique sur Spotify"))
    }
}

private struct VoicePlannerFixture: EudesAPIClient {
    var snapshots: Bool
    func models(profile: ServerProfile, key: String) async throws -> [String] { [profile.model] }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(systemPrompt.contains("secret historique"))
        let first = "{\"kind\":\"app\","
        let second = "\"value\":\"spotify\"}"
        await onText(first)
        await onText(snapshots ? first + second : second)
    }
}

@MainActor
final class VoicePlannerTests: XCTestCase {
    func testNetworkDeltasAndAppleSnapshotsPreserveDraftAndHistory() async throws {
        for apple in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let suite = "VoicePlanner." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
            let profile = apple ? ServerProfile.apple : ServerProfile(name: "Fixture", baseURL: "https://example.invalid/v1", model: "alpha")
            var data = AppData()
            data.servers = [profile]
            data.selectedServerID = profile.id
            let conversation = Conversation(serverID: profile.id, model: profile.model,
                messages: [ChatMessage(role: .user, text: "secret historique")])
            data.conversations = [conversation]
            data.selectedConversationID = conversation.id
            let storage = try PrivateStorage(directory: directory)
            try storage.save(data)
            let fixture = VoicePlannerFixture(snapshots: apple)
            let store = AppStore(storageDirectory: directory, defaults: defaults, client: fixture,
                                 appleClient: fixture, appleAvailability: { .available }, readKey: { _ in "fixture" })
            let before = store.data
            let action = try await store.planVoiceAction("Je voudrais ouvrir Spotify")
            XCTAssertEqual(action.kind, .app)
            XCTAssertEqual(action.value, "spotify")
            XCTAssertEqual(store.data.conversations, before.conversations)
            XCTAssertEqual(store.data.selectedConversationID, before.selectedConversationID)
        }
    }
}
