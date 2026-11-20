import AVFoundation
import XCTest
@testable import Eudes

final class BackgroundVoiceAudioTests: XCTestCase {
    func testMeterReportsOnlyWhileEnabledAndNeverAfterTurnIsDiscarded() throws {
        let router = BackgroundVoiceCaptureRouter()
        let values = MeterEvents()
        let id = UUID()
        router.begin(id: id, sampleRate: 1_000, onLevel: { _, value in values.append(value) }) { _ in }
        router.append(try buffer(value: 0.5, count: 100))
        XCTAssertTrue(values.values.isEmpty)
        router.setMeteringEnabled(true)
        router.append(try buffer(value: 0.5, count: 100))
        XCTAssertGreaterThan(values.values.last ?? 0, 0)
        let count = values.values.count
        router.setMeteringEnabled(false)
        router.append(try buffer(value: 0.5, count: 100))
        XCTAssertEqual(values.values.count, count)
        router.discard(id: id)
        router.setMeteringEnabled(true)
        router.append(try buffer(value: 0.5, count: 100))
        XCTAssertEqual(values.values.count, count)
    }
    func testAudioOutsideListeningIsDiscardedAndCannotBecomeNextQuestion() throws {
        let router = BackgroundVoiceCaptureRouter()
        router.append(try buffer(value: 0.4, count: 100))
        let id = UUID()
        router.begin(id: id, sampleRate: 1_000) { _ in }
        router.append(try buffer(value: 0, count: 100))
        XCTAssertFalse(router.heardSpeech(id: id))
        let capture = try XCTUnwrap(router.take(id: id))
        let result = try XCTUnwrap(capture.finish())
        XCTAssertEqual(result.frameLength, 100)
        XCTAssertEqual(result.floatChannelData?[0][0], 0)
        router.append(try buffer(value: 0.8, count: 100))
        XCTAssertNil(router.take(id: id))
    }

    func testSilenceFinishesOnceAndLateBuffersAreNotRetained() throws {
        let router = BackgroundVoiceCaptureRouter()
        let events = CaptureEvents()
        let id = UUID()
        router.begin(id: id, sampleRate: 1_000) { events.append($0) }
        router.append(try buffer(value: 0.4, count: 100))
        router.append(try buffer(value: 0, count: 2_500))
        router.append(try buffer(value: 0.4, count: 100))
        XCTAssertEqual(events.values, [id])
        let result = try XCTUnwrap(router.take(id: id)?.finish())
        XCTAssertEqual(result.frameLength, 2_600)
    }

    func testLateCancellationCannotDiscardNewTurn() throws {
        let router = BackgroundVoiceCaptureRouter()
        let old = UUID()
        router.begin(id: old, sampleRate: 1_000) { _ in }
        router.append(try buffer(value: 0.4, count: 100))
        router.discard(id: old)
        let next = UUID()
        router.begin(id: next, sampleRate: 1_000) { _ in }
        router.discard(id: old)
        router.append(try buffer(value: 0.7, count: 100))
        XCTAssertNil(router.take(id: old))
        let capture = try XCTUnwrap(router.take(id: next))
        XCTAssertTrue(capture.heardSpeech)
        let result = try XCTUnwrap(capture.finish())
        XCTAssertEqual(result.frameLength, 100)
        XCTAssertEqual(result.floatChannelData?[0][0], 0.7)
    }

    func testCaptureRemainsBoundedIfMainActorDeadlineIsDelayed() throws {
        let router = BackgroundVoiceCaptureRouter()
        let events = CaptureEvents()
        let id = UUID()
        router.begin(id: id, sampleRate: 1_000) { events.append($0) }
        router.append(try buffer(value: 0.4, count: 46_000))
        router.append(try buffer(value: 0.4, count: 46_000))
        XCTAssertEqual(events.values, [id])
        let result = try XCTUnwrap(router.take(id: id)?.finish())
        XCTAssertEqual(result.frameLength, 45_000)
    }

    private func buffer(value: Float, count: Int) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 1_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.initialize(repeating: value, count: count)
        return buffer
    }
}

private final class MeterEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []
    var values: [Float] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: Float) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
}

private final class CaptureEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID] = []
    var values: [UUID] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ id: UUID) { lock.lock(); defer { lock.unlock() }; storage.append(id) }
}
