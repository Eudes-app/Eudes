import XCTest
import CoreML
import AVFoundation
@testable import Eudes

@MainActor
final class PocketTTSTests: XCTestCase {
    func testSpeechEngineDefaultsToSystemAndPersistsSelection() throws {
        let suite = "EudesSpeechEngine." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(SpeechOutputEngine.selected(defaults: defaults), .system)
        defaults.set("nonsense", forKey: SpeechOutputEngine.preferenceKey)
        XCTAssertEqual(SpeechOutputEngine.selected(defaults: defaults), .system)
        defaults.set(SpeechOutputEngine.pocketTTS.rawValue, forKey: SpeechOutputEngine.preferenceKey)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(SpeechOutputEngine.selected(defaults: reloaded), .pocketTTS)
    }

    func testNonCommercialVoicesAreExcludedFromTheShippedList() {
        let ids = PocketTTSVoices.allowed.map(\.id)
        XCTAssertEqual(ids.count, 24)
        XCTAssertFalse(ids.contains("cosette"), "Expresso is CC-NC-4.0")
        XCTAssertFalse(ids.contains("jean"), "EARS is CC-NC-4.0")
        XCTAssertTrue(PocketTTSVoices.nonCommercialExcluded.allSatisfy { !ids.contains($0) })
        XCTAssertEqual(Set(ids).count, ids.count, "voice ids must be unique")
        XCTAssertTrue(ids.contains(PocketTTSVoices.defaultID))
    }

    func testEveryAllowedVoiceIsPinnedToAnImmutableHuggingFaceRevision() {
        for voice in PocketTTSVoices.allowed {
            XCTAssertFalse(voice.source.repo.isEmpty)
            XCTAssertEqual(voice.source.revision.count, 40, "\(voice.id) must pin a full commit sha")
            XCTAssertTrue(voice.source.url.absoluteString.hasPrefix("https://huggingface.co/"))
            XCTAssertFalse(voice.license.isEmpty)
            XCTAssertFalse(voice.fileName.isEmpty)
        }
    }

    func testVoiceSelectionFallsBackToEstelleForUnknownStoredValue() throws {
        let suite = "EudesPocketVoice." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(PocketTTSVoices.selected(defaults: defaults).id, "estelle")
        defaults.set("cosette", forKey: PocketTTSVoices.preferenceKey)
        XCTAssertEqual(PocketTTSVoices.selected(defaults: defaults).id, "estelle",
                       "a removed CC-NC voice must never be selected")
        defaults.set("daan", forKey: PocketTTSVoices.preferenceKey)
        XCTAssertEqual(PocketTTSVoices.selected(defaults: defaults).id, "estelle")
        defaults.set("fantine", forKey: PocketTTSVoices.preferenceKey)
        XCTAssertEqual(PocketTTSVoices.selected(defaults: defaults).id, "fantine")
    }

    func testPinnedCoreMLManifestContainsOnlyAllowedVoices() {
        XCTAssertEqual(PocketTTSModel.revision.count, 40)
        XCTAssertGreaterThan(PocketCoreMLManifest.bytes, 1_000_000_000)
        let paths = PocketCoreMLManifest.assets.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count)
        XCTAssertTrue(paths.allSatisfy { !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("/cosette.safetensors") || $0.hasSuffix("/jean.safetensors") })
        for voice in PocketTTSVoices.allowed {
            XCTAssertTrue(paths.contains { $0.hasSuffix("/\(voice.id).safetensors") }, voice.id)
        }
        XCTAssertTrue(PocketCoreMLManifest.assets.allSatisfy { $0.size > 0 && ($0.digest.count == 40 || $0.digest.count == 64) })
    }

    func testSixLayerManifestAndModelRemovalPreserveOtherModel() throws {
        let defaults = UserDefaults.standard
        let old = defaults.string(forKey: PocketTTSVariant.preferenceKey)
        defer {
            if let old { defaults.set(old, forKey: PocketTTSVariant.preferenceKey) }
            else { defaults.removeObject(forKey: PocketTTSVariant.preferenceKey) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("FluidAudio-v1/keep")
        let six = root.appendingPathComponent("PocketFrench6-v1/keep")
        for file in [legacy, six] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: file)
        }
        let manager = PocketTTSModelManager(directory: root)
        manager.selectVariant(.french6)
        XCTAssertEqual(PocketFrenchSixManifest.revision.count, 40)
        XCTAssertEqual(Set(PocketFrenchSixManifest.assets.map(\.path)).count, PocketFrenchSixManifest.assets.count)
        XCTAssertTrue(manager.availableVoices.contains { $0.id == "estelle" })
        XCTAssertFalse(manager.availableVoices.contains { $0.id == "cosette" || $0.id == "jean" })
        XCTAssertTrue(PocketFrenchSixManifest.assets.allSatisfy { $0.algorithm == "sha256" && $0.digest.count == 64 })
        try manager.removeModel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: six.path))
    }

    func testDownloadedAssetsRejectWrongHashAndSize() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("abc".utf8).write(to: path)
        let good = PocketCoreMLManifest.Asset(path: "example", size: 3, algorithm: "sha256", digest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(try PocketTTSModelManager.validAsset(path, asset: good))
        let wrong = PocketCoreMLManifest.Asset(path: "example", size: 2, algorithm: "sha256", digest: good.digest)
        XCTAssertFalse(try PocketTTSModelManager.validAsset(path, asset: wrong))
        let badAlgorithm = PocketCoreMLManifest.Asset(path: "example", size: 3, algorithm: "unknown", digest: good.digest)
        XCTAssertFalse(try PocketTTSModelManager.validAsset(path, asset: badAlgorithm))
        let git = PocketCoreMLManifest.Asset(path: "example", size: 3, algorithm: "gitSHA1", digest: "f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f")
        XCTAssertTrue(try PocketTTSModelManager.validAsset(path, asset: git))
    }

    func testDownloadStageProgressIsBoundedAndNeverRegresses() {
        var stage = ModelDownloadStage.listing
        stage.record(0.4)
        XCTAssertEqual(stage, .downloading(0.4))
        stage.record(0.2)
        stage.record(.nan)
        stage.record(.infinity)
        XCTAssertEqual(stage, .downloading(0.4))
        stage.record(1.5)
        XCTAssertEqual(stage, .downloading(1))
    }

    func testLateDownloadProgressCannotReplacePreparationOrCancellation() {
        var stage = ModelDownloadStage.preparing
        stage.record(0.9)
        XCTAssertEqual(stage, .preparing)
        stage = .cancelling
        stage.record(1)
        XCTAssertEqual(stage, .cancelling)
    }

    func testCellularConfirmationIsRequiredOnlyOnCellularPaths() {
        XCTAssertTrue(NetworkMonitor.requiresCellularConfirmation(usesCellular: true))
        XCTAssertFalse(NetworkMonitor.requiresCellularConfirmation(usesCellular: false))
    }

    func testWAVEncodingProducesAReadableHeaderAndSamples() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let data = try XCTUnwrap(WAVFile.encode(samples: samples, sampleRate: 24_000))
        let header = String(decoding: data.prefix(4), as: UTF8.self)
        XCTAssertEqual(header, "RIFF")
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertNil(WAVFile.encode(samples: [], sampleRate: 24_000))
        XCTAssertNil(WAVFile.encode(samples: [0], sampleRate: 0))
    }

    func testManagerIsNotDownloadedWithoutMarkerAndAssets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("PocketTTS")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent(PocketTTSModelManager.markerName))
        let manager = PocketTTSModelManager(directory: directory)
        XCTAssertFalse(manager.isDownloaded, "a marker without the model files is not a valid installation")
        XCTAssertFalse(manager.isDownloading)
    }
    func testOldOnnxMarkerCannotEnableCoreMLInferenceWithoutDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("old-onnx".utf8).write(to: root.appendingPathComponent(PocketTTSModelManager.markerName))
        let manager = PocketTTSModelManager(directory: root)
        XCTAssertTrue(manager.hasLegacyModel)
        XCTAssertFalse(manager.isDownloaded)
        let voice = try XCTUnwrap(PocketTTSVoices.allowed.first { $0.id == "estelle" })
        do {
            _ = try await manager.synthesize(text: "Bonjour", voice: voice, rate: 0.5)
            XCTFail("Old ONNX files must not trigger a hidden model download")
        } catch let error as VoiceAssistantError {
            guard case .synthesisUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRemovingLegacyFilesPreservesCoreMLModelAndOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("model"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("voices"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("FluidAudio-v1"), withIntermediateDirectories: true)
        let unrelated = root.appendingPathComponent("other-data")
        try Data("keep".utf8).write(to: unrelated)
        let manager = PocketTTSModelManager(directory: root)
        XCTAssertTrue(manager.hasLegacyModel)
        try manager.removeLegacyModel()
        XCTAssertFalse(manager.hasLegacyModel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("FluidAudio-v1").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("model").path))
    }

    func testEncodedWAVCanBeDecodedByAVFoundation() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let data = try XCTUnwrap(WAVFile.encode(samples: samples, sampleRate: 24_000))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 5)
        XCTAssertEqual(file.processingFormat.sampleRate, 24_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 5))
        try file.read(into: buffer)
        let decoded = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in samples.indices { XCTAssertEqual(decoded[index], samples[index], accuracy: 0.0001) }
        XCTAssertNil(WAVFile.encode(samples: [.nan], sampleRate: 24_000))
        XCTAssertNil(WAVFile.encode(samples: [.infinity], sampleRate: 24_000))
    }
    func testFrenchSpeechTextNormalizesUnsupportedPunctuation() {
        XCTAssertEqual(PocketTTSFrenchText.normalize("J’ai dit : « aujourd’hui » ; (oui)"),
                       "J'ai dit ,  aujourd'hui  , oui")
        XCTAssertEqual(PocketTTSFrenchText.normalize("L'été, à 15:30. Ça va ?"), "L'été, à 15:30. Ça va ?")
    }

    func testFallbackDoesNotSpeakAfterCancellation() {
        XCTAssertFalse(PocketTTSModelManager.permitsSystemFallback(for: CancellationError()))
        XCTAssertFalse(PocketTTSModelManager.permitsSystemFallback(for: VoiceAssistantError.interrupted))
        XCTAssertTrue(PocketTTSModelManager.permitsSystemFallback(for: PocketTTSError.invalidAudio))
    }
    func testProgressivePlaybackDrainsAndCancellationStops() async throws {
        let session = UUID()
        try await VoiceAudioSession.shared.activatePlayback(id: session)
        defer { Task { await VoiceAudioSession.shared.deactivate(id: session) } }
        let player = PocketTTSPlayer()
        let first = try player.beginStreaming()
        player.enqueue(Array(repeating: 0.1, count: 2400), id: first)
        player.enqueue(Array(repeating: 0.2, count: 2400), id: first)
        try await player.finishStreaming(id: first)
        let second = try player.beginStreaming()
        player.enqueue(Array(repeating: 0.2, count: 2400), id: second)
        player.cancelStreaming(id: second)
        do { try await player.finishStreaming(id: second); XCTFail("Cancelled playback must throw") }
        catch is CancellationError { }
        let third = try player.beginStreaming()
        player.enqueue(Array(repeating: 0.2, count: 2400), id: third)
        player.enqueue([.nan], id: third)
        do { try await player.finishStreaming(id: third); XCTFail("Invalid audio must fail") }
        catch { XCTAssertTrue(player.hasStreamingSamples(id: third)) }
    }

    /// Experimental six-layer export; opt in only with a verified local fixture.
    func testExperimentalFrenchSixLayerInference() async throws {
        guard let path = ProcessInfo.processInfo.environment["EUDES_EXPERIMENTAL_6L_FIXTURES"] else {
            throw XCTSkip("Set EUDES_EXPERIMENTAL_6L_FIXTURES to the verified six-layer pack.")
        }
        let directory = URL(fileURLWithPath: path).appendingPathComponent("v2.1/french")
        let snapshot = try PocketCoreMLVoice(data: Data(contentsOf: directory.appendingPathComponent("constants_bin/estelle.safetensors")), layerCount: 6)
        let cache = try snapshot.makeCache(splitKV: true)
        XCTAssertEqual(cache.count, 18)
        let collector = PocketStreamTestCollector()
        let engine = PocketCoreMLEngine(directory: directory, variant: .french6)
        let audio = try await engine.synthesize(text: "Bonjour, comment puis-je vous aider aujourd'hui ?", voice: "estelle") { collector.append($0) }
        XCTAssertEqual(audio.sampleRate, 24_000)
        XCTAssertGreaterThan(audio.samples.count, 12_000)
        XCTAssertTrue(audio.samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(audio.samples.map { abs($0) }.max() ?? 0, 0.01)
        XCTAssertGreaterThan(collector.chunks, 1)
        XCTAssertEqual(collector.samples, audio.samples)
        let data = try XCTUnwrap(WAVFile.encode(samples: audio.samples, sampleRate: audio.sampleRate))
        try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("experimental-6l-estelle.wav"), options: .atomic)

        // Siri/background must avoid GPU and ANE; exercise the actual CPU models.
        let backgroundEngine = PocketCoreMLEngine(directory: directory, variant: .french6, executionMode: .background)
        let backgroundAudio = try await backgroundEngine.synthesize(text: "Bonjour.", voice: "estelle") { _ in }
        XCTAssertGreaterThan(backgroundAudio.samples.count, 4_800)
        XCTAssertTrue(backgroundAudio.samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(backgroundAudio.samples.map { abs($0) }.max() ?? 0, 0.01)
    }

    /// Opt-in: verified public Core ML fixtures; never user recordings.
    func testFrenchInferenceWithPinnedExternalFixtures() async throws {
        guard let path = ProcessInfo.processInfo.environment["EUDES_COREML_FIXTURES"] ?? ProcessInfo.processInfo.environment["EUDES_FLUID_FIXTURES"] else {
            throw XCTSkip("Set EUDES_COREML_FIXTURES to a verified French Core ML model cache.")
        }
        let root = URL(fileURLWithPath: path)
        let manager = PocketTTSModelManager(directory: root)
        XCTAssertTrue(manager.isDownloaded, "Fixture must contain the complete pinned model and marker")
        let voices = ["estelle", "fantine", "alba"]
        let phrases = [
            "Bonjour. Je suis Estelle. Cette phrase est un test de synthèse vocale en français. Bonne journée.",
            "Bonjour, comment puis-je vous aider aujourd’hui ?",
            "J’ai préparé trois réponses ; choisissez celle que vous préférez."
        ]
        for (index, phrase) in phrases.enumerated() {
            let voice = try XCTUnwrap(PocketTTSVoices.allowed.first { $0.id == voices[index] })
            let streamed = PocketStreamTestCollector()
            let audio = try await manager.synthesize(text: phrase, voice: voice, rate: 0.5) { streamed.append($0) }
            XCTAssertEqual(audio.sampleRate, 24_000)
            XCTAssertGreaterThan(audio.samples.count, 24_000)
            XCTAssertTrue(audio.samples.allSatisfy { $0.isFinite })
            XCTAssertGreaterThan(audio.samples.map { abs($0) }.max() ?? 0, 0.01)
            XCTAssertGreaterThan(streamed.chunks, 1)
            XCTAssertTrue(streamed.samples == audio.samples)
            let data = try XCTUnwrap(WAVFile.encode(samples: audio.samples, sampleRate: audio.sampleRate))
            try data.write(to: root.appendingPathComponent("coreml-\(voice.id)-test-\(index).wav"), options: .atomic)
        }
    }

}

private final class PocketStreamTestCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Float] = []
    private var count = 0
    var samples: [Float] { lock.lock(); defer { lock.unlock() }; return stored }
    var chunks: Int { lock.lock(); defer { lock.unlock() }; return count }
    func append(_ samples: [Float]) { lock.lock(); defer { lock.unlock() }; stored += samples; count += 1 }
}


extension PocketTTSTests {
    func testCoreMLFloat16AudioAndStridedArrays() throws {
        let half = try MLMultiArray(shape: [1, 1, 3], dataType: .float16)
        half[0] = 0.25; half[1] = -0.5; half[2] = 1
        XCTAssertEqual(try PocketCoreMLTensor.values(half, count: 3), [0.25, -0.5, 1])
        half[1] = NSNumber(value: Float.nan)
        XCTAssertThrowsError(try PocketCoreMLTensor.values(half, count: 3))
        let memory = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        memory.initialize(from: [0.1, 99, 0.2, 99], count: 4)
        let strided = try MLMultiArray(dataPointer: memory, shape: [2], dataType: .float32,
                                      strides: [2], deallocator: { $0.assumingMemoryBound(to: Float.self).deallocate() })
        XCTAssertEqual(try PocketCoreMLTensor.values(strided, count: 2), [0.1, 0.2])
    }

    func testCoreMLVoiceCachePadsKAndVSeparately() throws {
        let voice = try PocketCoreMLVoice(data: coreMLVoiceFixture())
        XCTAssertEqual(voice.position, 1)
        let state = try voice.makeCache()
        let cache = try XCTUnwrap(state["cache0"])
        XCTAssertEqual(cache[0].floatValue, 0.25)
        XCTAssertEqual(cache[1023].floatValue, 0.25)
        XCTAssertEqual(cache[1024].floatValue, 0)
        XCTAssertEqual(cache[512 * 1024].floatValue, -0.5)
        XCTAssertEqual(cache[513 * 1024].floatValue, 0)
        XCTAssertEqual(state["position23"]?[0].intValue, 1)
    }

    func testCoreMLRejectsCorruptVoiceSnapshots() throws {
        XCTAssertThrowsError(try PocketCoreMLVoice(data: Data(repeating: 255, count: 8)))
        XCTAssertThrowsError(try PocketCoreMLVoice(data: coreMLVoiceFixture(offset: 2)))
        XCTAssertThrowsError(try PocketCoreMLVoice(data: coreMLVoiceFixture(corruptRange: true)))
        XCTAssertThrowsError(try PocketCoreMLVoice(data: coreMLVoiceFixture().dropLast()))
        XCTAssertThrowsError(try PocketCoreMLTensor.floats(Data([0, 0, 0])))
    }

    func testCoreMLChunkingRetainsTextAndReservesAudioSpace() throws {
        let text = Array(repeating: "Bonjour aujourd’hui à tous les amis", count: 30).joined(separator: " ")
        let encode: (String) -> [Int] = { Array(repeating: 1, count: $0.utf8.count) }
        let chunks = try PocketCoreMLText.chunks(text, voicePosition: 126, encode: encode)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(separator: " "), PocketTTSFrenchText.normalize(text))
        for chunk in chunks {
            let frames = Int(ceil((Double(chunk.split(separator: " ").count) + 2) * 12.5)) + 9
            XCTAssertLessThanOrEqual(126 + encode(chunk).count + frames, 512)
        }
        XCTAssertThrowsError(try PocketCoreMLText.chunks(String(repeating: "a", count: 1000), voicePosition: 126, encode: encode))
        XCTAssertThrowsError(try PocketCoreMLText.chunks("bonjour", voicePosition: 512, encode: encode))
    }

    func testCoreMLCancellationBeforeLoadingDoesNotTouchModelFiles() async throws {
        let engine = PocketCoreMLEngine(directory: URL(fileURLWithPath: "/missing-coreml-model"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.synthesize(text: "Bonjour", voice: "estelle") { _ in }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testCoreMLTokenizerRejectsTruncatedOrEmptyModels() {
        XCTAssertThrowsError(try PocketSentencePieceTokenizer(modelData: Data()))
        XCTAssertThrowsError(try PocketSentencePieceTokenizer(modelData: Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f])))
    }

    private func coreMLVoiceFixture(offset: Int64 = 1, corruptRange: Bool = false) throws -> Data {
        var payload = Data()
        var header: [String: Any] = [:]
        func add(_ key: String, _ dtype: String, _ shape: [Int], _ bytes: Data) {
            let start = payload.count
            payload.append(bytes)
            header[key] = ["dtype": dtype, "shape": shape,
                           "data_offsets": [corruptRange ? -1 : start, payload.count]]
        }
        let values = Array(repeating: Float(0.25), count: 1024) + Array(repeating: Float(-0.5), count: 1024)
        let floats = values.withUnsafeBytes { Data($0) }
        var littleOffset = offset.littleEndian
        let offsetData = withUnsafeBytes(of: &littleOffset) { Data($0) }
        for layer in 0..<24 {
            add("transformer.layers.\(layer).self_attn/cache", "F32", [2, 1, 1, 16, 64], floats)
            add("transformer.layers.\(layer).self_attn/offset", "I64", [1], offsetData)
        }
        let json = try JSONSerialization.data(withJSONObject: header)
        var length = UInt64(json.count).littleEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(json); result.append(payload)
        return result
    }
}
