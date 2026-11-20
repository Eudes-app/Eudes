import AVFoundation
import Foundation
import Observation
import Speech

enum AppleSpeechError: LocalizedError, Equatable {
    case unsupported, preparationRequired, preparationFailed

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "La transcription Apple locale en français est indisponible sur cet appareil. Réessaie plus tard."
        case .preparationRequired:
            "Ouvre Réglages → Assistant vocal dans Eudes et prépare la transcription Apple avant de l’utiliser avec Siri."
        case .preparationFailed:
            "Le modèle Apple n’a pas pu être préparé. Vérifie ta connexion et réessaie dans les réglages de l’assistant vocal."
        }
    }
}

enum AppleSpeechAssetState: Equatable {
    case unsupported, downloadRequired, ready
}

/// The small boundary allows lifecycle tests without downloading a system model.
@MainActor
protocol AppleSpeechTranscriptionBackend: AnyObject {
    var isAvailable: Bool { get }
    func assetState() async -> AppleSpeechAssetState
    func reserveAssets() async throws
    func installAssets() async throws
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String
}

/// Apple manages public model assets; captured audio remains in memory.
/// Only prepare(allowDownload: true) can request a model download. Neither a
/// background launch nor transcription can silently download or use a server.
@MainActor
@Observable
final class AppleSpeechModelManager: LocalSpeechTranscribing {
    static let shared = AppleSpeechModelManager()

    private(set) var isReady = false
    private(set) var isPreparing = false
    private(set) var isTranscribing = false
    private(set) var errorMessage: String?
    var isAvailable: Bool { backend.isAvailable }

    @ObservationIgnored private let backend: any AppleSpeechTranscriptionBackend
    @ObservationIgnored private var stateRevision = UUID()

    convenience init() {
        if #available(iOS 26, *) {
            self.init(backend: SystemAppleSpeechBackend())
        } else {
            self.init(backend: UnavailableAppleSpeechBackend())
        }
    }

    init(backend: any AppleSpeechTranscriptionBackend) {
        self.backend = backend
    }

    /// A cold Siri launch cannot depend on a cached isReady value. prepare(false)
    /// performs the asynchronous check against the current system asset inventory.
    func preflight() throws {
        guard backend.isAvailable else { throw AppleSpeechError.unsupported }
        guard !isPreparing, !isTranscribing else { throw VoiceAssistantError.interrupted }
    }

    func refreshAvailability() async {
        guard !isPreparing, !isTranscribing else { return }
        stateRevision = UUID()
        let revision = stateRevision
        let state = await backend.assetState()
        guard !Task.isCancelled, revision == stateRevision,
              !isPreparing, !isTranscribing else { return }
        isReady = state == .ready
        if state == .unsupported {
            errorMessage = AppleSpeechError.unsupported.localizedDescription
        } else if state == .ready {
            errorMessage = nil
        }
    }

    func prepare(allowDownload: Bool) async throws {
        try Task.checkCancellation()
        try preflight()
        stateRevision = UUID()
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        do {
            let state = await backend.assetState()
            try Task.checkCancellation()
            isReady = false
            switch state {
            case .unsupported:
                throw AppleSpeechError.unsupported
            case .ready:
                try await backend.reserveAssets()
                try Task.checkCancellation()
                isReady = true
                return
            case .downloadRequired:
                guard allowDownload else { throw AppleSpeechError.preparationRequired }
                try await backend.reserveAssets()
                try Task.checkCancellation()
                try await backend.installAssets()
                try Task.checkCancellation()
                let installedState = await backend.assetState()
                try Task.checkCancellation()
                guard installedState == .ready else { throw AppleSpeechError.preparationFailed }
                isReady = true
            }
        } catch is CancellationError {
            // Installation may finish independently in the system. Refresh its
            // actual state later instead of claiming this cancelled setup is ready.
            isReady = false
            throw CancellationError()
        } catch {
            isReady = false
            if Task.isCancelled { throw CancellationError() }
            let failure = (error as? AppleSpeechError) ?? .preparationFailed
            errorMessage = failure.localizedDescription
            throw failure
        }
    }

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        try Task.checkCancellation()
        guard buffer.frameLength > 0 else { throw VoiceAssistantError.noSpeech }
        try preflight()
        stateRevision = UUID()
        isTranscribing = true
        errorMessage = nil
        defer { isTranscribing = false }
        do {
            let state = await backend.assetState()
            try Task.checkCancellation()
            isReady = state == .ready
            guard state != .unsupported else { throw AppleSpeechError.unsupported }
            guard state == .ready else { throw AppleSpeechError.preparationRequired }
            try await backend.reserveAssets()
            try Task.checkCancellation()
            let text = try await backend.transcribe(buffer)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !text.isEmpty else { throw VoiceAssistantError.noSpeech }
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppleSpeechError {
            isReady = false
            errorMessage = error.localizedDescription
            throw error
        } catch let error as VoiceAssistantError {
            throw error
        } catch {
            throw VoiceAssistantError.recognitionFailed
        }
    }
}

@MainActor
private final class UnavailableAppleSpeechBackend: AppleSpeechTranscriptionBackend {
    var isAvailable: Bool { false }
    func assetState() async -> AppleSpeechAssetState { .unsupported }
    func reserveAssets() async throws { throw AppleSpeechError.unsupported }
    func installAssets() async throws { throw AppleSpeechError.unsupported }
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        throw AppleSpeechError.unsupported
    }
}

@available(iOS 26, *)
@MainActor
private final class SystemAppleSpeechBackend: AppleSpeechTranscriptionBackend {
    var isAvailable: Bool { SpeechTranscriber.isAvailable }

    private func makeTranscriber() async throws -> SpeechTranscriber {
        guard isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "fr-FR")) else {
            throw AppleSpeechError.unsupported
        }
        try Task.checkCancellation()
        // This preset emits finalized passages. No Siri service or remote
        // SFSpeechRecognizer fallback is created, including on older devices.
        return SpeechTranscriber(locale: locale, preset: .transcription)
    }

    func assetState() async -> AppleSpeechAssetState {
        guard let transcriber = try? await makeTranscriber() else { return .unsupported }
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .ready
        case .supported, .downloading: return .downloadRequired
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    func reserveAssets() async throws {
        guard isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "fr-FR")) else {
            throw AppleSpeechError.unsupported
        }
        try Task.checkCancellation()
        do {
            // Reserve even assets already installed by another app. Reservation
            // itself does not start an installation; repeated reservations are safe.
            _ = try await AssetInventory.reserve(locale: locale)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw AppleSpeechError.preparationFailed
        }
    }

    func installAssets() async throws {
        let transcriber = try await makeTranscriber()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try Task.checkCancellation()
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
    }

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        let transcriber = try await makeTranscriber()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleSpeechError.unsupported
        }
        try Task.checkCancellation()
        let buffers = try AppleSpeechAudioConversion.convert(buffer, to: format)
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        for converted in buffers {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        continuation.finish()

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultsTask = Task {
            do {
                var passages: [String] = []
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    let passage = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !passage.isEmpty { passages.append(passage) }
                }
                return passages.joined(separator: " ")
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                guard let lastSample = try await analyzer.analyzeSequence(inputs) else {
                    throw VoiceAssistantError.noSpeech
                }
                try Task.checkCancellation()
                try await analyzer.finalizeAndFinish(through: lastSample)
                let text = try await resultsTask.value
                try Task.checkCancellation()
                return text
            } catch {
                resultsTask.cancel()
                await analyzer.cancelAndFinishNow()
                _ = try? await resultsTask.value
                throw error
            }
        } onCancel: {
            resultsTask.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

/// Uses the format requested by SpeechAnalyzer rather than assuming 16 kHz.
/// Conversion is in memory and works on iOS 26 without iOS 27-only helpers.
enum AppleSpeechAudioConversion {
    static func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        guard input.frameLength > 0 else { throw VoiceAssistantError.noSpeech }
        guard input.format.sampleRate > 0, format.sampleRate > 0,
              input.format.channelCount > 0, format.channelCount > 0 else {
            throw VoiceAssistantError.audioUnavailable
        }
        if input.format == format { return [input] }
        guard let converter = AVAudioConverter(from: input.format, to: format) else {
            throw VoiceAssistantError.audioUnavailable
        }
        var inputOffset: AVAudioFrameCount = 0
        var invalidInput = false
        var buffers: [AVAudioPCMBuffer] = []
        while true {
            try Task.checkCancellation()
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                throw VoiceAssistantError.audioUnavailable
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requestedPackets, inputStatus in
                if inputOffset == input.frameLength {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let frameCount = min(requestedPackets, input.frameLength - inputOffset)
                guard frameCount > 0,
                      let portion = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: frameCount) else {
                    invalidInput = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                portion.frameLength = frameCount
                    let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
                let destination = UnsafeMutableAudioBufferListPointer(portion.mutableAudioBufferList)
                let bytesPerFrame = Int(input.format.streamDescription.pointee.mBytesPerFrame)
                let byteOffset = Int(inputOffset) * bytesPerFrame
                let byteCount = Int(frameCount) * bytesPerFrame
                guard bytesPerFrame > 0, source.count == destination.count else {
                    invalidInput = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                for channel in source.indices {
                    guard byteOffset + byteCount <= Int(source[channel].mDataByteSize),
                          let sourceData = source[channel].mData,
                          let destinationData = destination[channel].mData else {
                        invalidInput = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    destinationData.copyMemory(from: sourceData.advanced(by: byteOffset), byteCount: byteCount)
                }
                inputOffset += frameCount
                inputStatus.pointee = .haveData
                return portion
            }
            if invalidInput || conversionError != nil || status == .error { throw VoiceAssistantError.audioUnavailable }
            if output.frameLength > 0 { buffers.append(output) }
            if status == .endOfStream || status == .inputRanDry {
                guard !buffers.isEmpty else { throw VoiceAssistantError.noSpeech }
                return buffers
            }
            guard output.frameLength > 0 else { throw VoiceAssistantError.audioUnavailable }
        }
    }
}
