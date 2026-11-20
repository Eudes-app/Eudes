import AVFoundation
import CryptoKit
import Foundation
import Network
import Observation

/// Spoken replies can use the built-in iOS voices or the on-device PocketTTS model.
enum SpeechOutputEngine: String, CaseIterable, Identifiable {
    case system, pocketTTS

    static let preferenceKey = "voice.speech.engine"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized: "Système iOS")
        case .pocketTTS: String(localized: "PocketTTS · local")
        }
    }

    static func selected(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }
}

/// A pinned remote asset on Hugging Face; the revision makes the download immutable.
struct RemoteFile: Sendable, Equatable {
    let repo: String
    let revision: String
    let path: String

    var url: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!
    }

    var fileName: String { (path as NSString).lastPathComponent }
}

/// The 25 PocketTTS preset voices whose source recordings are CC0 or CC-BY-4.0.
/// `cosette` (Expresso, CC-NC-4.0) and `jean` (EARS, CC-NC-4.0) are deliberately
/// excluded so the shipped app stays usable commercially.
struct PocketTTSVoice: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let source: RemoteFile
    let license: String

    var remoteFile: RemoteFile { source }
    var fileName: String { id + "." + (source.fileName as NSString).pathExtension }
}

enum PocketTTSVoices {
    static let preferenceKey = "voice.pocket.voice"
    static let defaultID = "estelle"
    static let nonCommercialExcluded = ["cosette", "jean"]

    private static let voicesRepo = "kyutai/tts-voices"
    private static let voicesRevision = "323332d33f997de8394f24a193e1a76df720e01a"
    private static let pocketRepo = "kyutai/pocket-tts"
    private static let pocketRevision = "64ab7d24c479d736a83b8cc666c4a776fca30fda"
    private static let cmlRevision = "2dd944b099d06bb9edbd221fef138685711d9bf0"
    private static let estelleRevision = "1fc7395b7e012e2bbebfca14b942a4ef62ccc899"

    static let allowed: [PocketTTSVoice] = [
        PocketTTSVoice(id: "alba", displayName: "Alba", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "alba-mackenna/casual.wav"), license: "CC0"),
        PocketTTSVoice(id: "anna", displayName: "Anna", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "vctk/p228_023_enhanced.wav"), license: "CC-BY-4.0 (VCTK)"),
        PocketTTSVoice(id: "vera", displayName: "Vera", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "vctk/p229_023_enhanced.wav"), license: "CC-BY-4.0 (VCTK)"),
        PocketTTSVoice(id: "fantine", displayName: "Fantine", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "vctk/p244_023_enhanced.wav"), license: "CC-BY-4.0 (VCTK)"),
        PocketTTSVoice(id: "charles", displayName: "Charles", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "vctk/p254_023_enhanced.wav"), license: "CC-BY-4.0 (VCTK)"),
        PocketTTSVoice(id: "paul", displayName: "Paul", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "vctk/p259_023_enhanced.wav"), license: "CC-BY-4.0 (VCTK)"),
        PocketTTSVoice(id: "eponine", displayName: "Éponine", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "vctk/p262_023_enhanced.wav"), license: "CC-BY-4.0 (VCTK)"),
        PocketTTSVoice(id: "azelma", displayName: "Azelma", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "vctk/p303_023_enhanced.wav"), license: "CC-BY-4.0 (VCTK)"),
        PocketTTSVoice(id: "george", displayName: "George", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "vctk/p315_023_enhanced.wav"), license: "CC-BY-4.0 (VCTK)"),
        PocketTTSVoice(id: "mary", displayName: "Mary", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "vctk/p333_023_enhanced.wav"), license: "CC-BY-4.0 (VCTK)"),
        PocketTTSVoice(id: "jane", displayName: "Jane", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "vctk/p339_023_enhanced.wav"), license: "CC-BY-4.0 (VCTK)"),
        PocketTTSVoice(id: "michael", displayName: "Michael", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "vctk/p360_023_enhanced.wav"), license: "CC-BY-4.0 (VCTK)"),
        PocketTTSVoice(id: "eve", displayName: "Ève", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "vctk/p361_023_enhanced.wav"), license: "CC-BY-4.0 (VCTK)"),
        PocketTTSVoice(id: "marius", displayName: "Marius", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "voice-donations/Selfie.wav"), license: "CC0"),
        PocketTTSVoice(id: "javert", displayName: "Javert", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "voice-donations/Butter.wav"), license: "CC0"),
        PocketTTSVoice(id: "bill_boerst", displayName: "Bill Boerst", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "voice-zero/bill_boerst.wav"), license: "CC0"),
        PocketTTSVoice(id: "peter_yearsley", displayName: "Peter Yearsley", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "voice-zero/peter_yearsley.wav"), license: "CC0"),
        PocketTTSVoice(id: "stuart_bell", displayName: "Stuart Bell", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "voice-zero/stuart_bell.wav"), license: "CC0"),
        PocketTTSVoice(id: "caro_davy", displayName: "Caro Davy", source: RemoteFile(repo: voicesRepo, revision: voicesRevision, path: "voice-zero/caro_davy.wav"), license: "CC0"),
        PocketTTSVoice(id: "giovanni", displayName: "Giovanni", source: RemoteFile(repo: pocketRepo, revision: pocketRevision, path: "common_voice_it_36520747-enhanced-v2.mp3"), license: "CC-BY-4.0"),
        PocketTTSVoice(id: "lola", displayName: "Lola", source: RemoteFile(repo: pocketRepo, revision: pocketRevision, path: "common_voice_es_19762977-enhanced-v2.mp3"), license: "CC-BY-4.0"),
        PocketTTSVoice(id: "juergen", displayName: "Jürgen", source: RemoteFile(repo: pocketRepo, revision: pocketRevision, path: "de-DE-juergen.mp3"), license: "CC-BY-4.0"),
        PocketTTSVoice(id: "rafael", displayName: "Rafael", source: RemoteFile(repo: pocketRepo, revision: pocketRevision, path: "g-Vi8PgmSY0-enhanced-v2.wav"), license: "CC-BY-4.0"),
        PocketTTSVoice(id: "estelle", displayName: "Estelle", source: RemoteFile(repo: voicesRepo, revision: estelleRevision, path: "unmute-prod-website/developpeuse-3.wav"), license: "CC0"),
    ]

    static func selected(defaults: UserDefaults = .standard) -> PocketTTSVoice {
        let stored = defaults.string(forKey: preferenceKey) ?? ""
        return allowed.first { $0.id == stored } ?? allowed.first { $0.id == defaultID }!
    }
}

/// The French-capable PocketTTS Core ML export (CC-BY-4.0, derived from kyutai/pocket-tts),
/// pinned to an immutable Hugging Face revision.
enum PocketTTSModel {
    static let repo = "FluidInference/pocket-tts-coreml"
    static let revision = PocketCoreMLManifest.revision
    static let approximateBytes = PocketCoreMLManifest.bytes
}

/// Overall transfer progress; preparation and cancellation remain indeterminate.
enum ModelDownloadStage: Equatable {
    case listing
    case downloading(Double)
    case preparing
    case cancelling

    mutating func record(_ fraction: Double) {
        guard fraction.isFinite else { return }
        let fraction = min(max(fraction, 0), 1)
        switch self {
        case .listing: self = .downloading(fraction)
        case .downloading(let previous): self = .downloading(max(previous, fraction))
        case .preparing, .cancelling: break
        }
    }
}

/// Detects a cellular path so large model downloads always ask before using mobile data.
enum NetworkMonitor {
    static var cellularProbe: @Sendable () async -> Bool = { await Self.probeCurrentPath() }

    static func usesCellular() async -> Bool { await cellularProbe() }

    static func requiresCellularConfirmation(usesCellular: Bool) -> Bool { usesCellular }

    private static func probeCurrentPath() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = NetworkProbeOnce()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.usesInterfaceType(.cellular))
            }
            monitor.start(queue: DispatchQueue(label: "eudes.network.probe"))
        }
    }
}

private final class NetworkProbeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

enum PocketTTSError: LocalizedError {
    case incompatibleModel, invalidAudio, playbackFailed

    var errorDescription: String? {
        switch self {
        case .incompatibleModel:
            String(localized: "Le modèle PocketTTS est incomplet ou incompatible. Tu peux utiliser les voix iOS pour continuer, puis supprimer et télécharger à nouveau le modèle.")
        case .invalidAudio:
            String(localized: "PocketTTS n’a pas produit de son lisible. Essaie une autre voix ou utilise les voix iOS.")
        case .playbackFailed:
            String(localized: "La lecture de la voix PocketTTS a échoué. Réessaie ou utilise les voix iOS.")
        }
    }
}

struct PocketTTSAudio: Sendable {
    let samples: [Float]
    let sampleRate: Int
}

enum PocketTTSVariant: String, CaseIterable, Identifiable {
    case french24, french6
    static let preferenceKey = "voice.pocket.modelVariant"
    var id: String { rawValue }
    var title: String { self == .french24 ? "Français · 24 couches" : "Français · 6 couches expérimental" }
}

/// Downloads the model and the commercial-safe reference voices once, then runs
/// PocketTTS fully on-device through Core ML. The complete pinned asset set is required before initialization.
@MainActor
@Observable
final class PocketTTSModelManager {
    static let shared = PocketTTSModelManager()
    static let markerName = ".eudes-verified-pocket-tts-french-v1"

    private(set) var variant: PocketTTSVariant
    private(set) var isDownloaded = false
    private(set) var hasLegacyModel = false
    private(set) var isDownloading = false
    private(set) var downloadStage: ModelDownloadStage = .listing
    private(set) var errorMessage: String?
    @ObservationIgnored private var downloadTask: Task<Void, Error>?
    @ObservationIgnored private var downloadAttempt: UUID?
    @ObservationIgnored private var coreMLManager: PocketCoreMLEngine?
    @ObservationIgnored private var coreMLExecutionMode: PocketCoreMLEngine.ExecutionMode?
    @ObservationIgnored private var generationTask: Task<PocketTTSAudio, Error>?
    @ObservationIgnored private let player = PocketTTSPlayer()
    private let directory: URL

    // Keep the existing cache path so verified Core ML downloads remain usable.
    private var coreMLDirectory: URL { directory.appendingPathComponent(variant == .french24 ? "FluidAudio-v1" : "PocketFrench6-v1", isDirectory: true) }
    private var repositoryDirectory: URL { coreMLDirectory.appendingPathComponent("Models/pocket-tts", isDirectory: true) }
    private var marker: URL { coreMLDirectory.appendingPathComponent(Self.markerName) }

    init(directory: URL? = nil) {
        self.variant = PocketTTSVariant(rawValue: UserDefaults.standard.string(forKey: PocketTTSVariant.preferenceKey) ?? "") ?? .french24
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eudes/PocketTTS", isDirectory: true)
        isDownloaded = (try? String(contentsOf: marker, encoding: .utf8)) == revision && assetsExist()
        hasLegacyModel = Self.legacyAssetsExist(in: self.directory)
    }

    private static func legacyAssetsExist(in directory: URL) -> Bool {
        ["model", "voices", ".eudes-verified-pocket-tts-french-v1"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    func removeLegacyModel() throws {
        guard !isDownloading, generationTask == nil else { throw VoiceAssistantError.interrupted }
        for item in ["model", "voices", ".eudes-verified-pocket-tts-french-v1"] {
            let target = directory.appendingPathComponent(item)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
        hasLegacyModel = false
    }

    private var assets: [PocketCoreMLManifest.Asset] { variant == .french24 ? PocketCoreMLManifest.assets : PocketFrenchSixManifest.assets }
    private var revision: String { variant == .french24 ? PocketTTSModel.revision : PocketFrenchSixManifest.revision }
    private var repo: String { variant == .french24 ? PocketTTSModel.repo : PocketFrenchSixManifest.repo }
    private var bytes: Int64 { variant == .french24 ? PocketCoreMLManifest.bytes : PocketFrenchSixManifest.bytes }
    var availableVoices: [PocketTTSVoice] {
        guard variant == .french6 else { return PocketTTSVoices.allowed }
        let ids = Set(PocketFrenchSixManifest.assets.filter { $0.path.hasSuffix(".safetensors") }.map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent })
        return PocketTTSVoices.allowed.filter { ids.contains($0.id) }
    }
    var estimatedDownloadMegabytes: Int64 { (bytes + 999_999) / 1_000_000 }

    func selectVariant(_ newValue: PocketTTSVariant) {
        guard variant != newValue, !isDownloading, generationTask == nil else { return }
        cancelSpeak()
        coreMLManager = nil
        coreMLExecutionMode = nil
        variant = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: PocketTTSVariant.preferenceKey)
        isDownloaded = (try? String(contentsOf: marker, encoding: .utf8)) == revision && assetsExist()
        errorMessage = nil
        downloadStage = .listing
    }

    private func assetsExist() -> Bool {
        assets.allSatisfy { asset in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: repositoryDirectory.appendingPathComponent(asset.path).path),
                  let size = attributes[.size] as? NSNumber else { return false }
            return size.int64Value == asset.size
        }
    }

    func download() async {
        guard !isDownloading, !isDownloaded else { return }
        isDownloading = true
        errorMessage = nil
        downloadStage = .listing
        let attempt = UUID()
        downloadAttempt = attempt
        let delegate = FileDownloadDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = Task { @MainActor in
            defer { session.invalidateAndCancel() }
            try FileManager.default.createDirectory(at: repositoryDirectory, withIntermediateDirectories: true)
            var root = coreMLDirectory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            var completed: Int64 = 0
            for asset in self.assets {
                try Task.checkCancellation()
                let target = repositoryDirectory.appendingPathComponent(asset.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let url = URL(string: "https://huggingface.co/\(self.repo)/resolve/\(self.revision)/\(asset.path)") else { throw URLError(.badURL) }
                let prior = completed
                let totalBytes = self.bytes
                delegate.onProgress = { [weak self] _, written, _ in
                    let fraction = Double(prior + min(max(written, 0), asset.size)) / Double(totalBytes)
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadAttempt == attempt else { return }
                        self.downloadStage.record(fraction)
                    }
                }
                try await delegate.download(task: session.downloadTask(with: url), to: target)
                let verification = Task.detached(priority: .utility) { try Self.validAsset(target, asset: asset) }
                let valid = try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
                guard valid else { throw URLError(.cannotDecodeContentData) }
                completed += asset.size
                downloadStage.record(Double(completed) / Double(self.bytes))
            }
            try Task.checkCancellation()
            downloadStage = .preparing
            guard assetsExist() else { throw VoiceAssistantError.synthesisUnavailable }
            try Data(revision.utf8).write(to: marker, options: .atomic)
        }
        downloadTask = task
        do {
            try await task.value
            guard downloadAttempt == attempt else { throw CancellationError() }
            isDownloaded = true
        } catch {
            if !(error is CancellationError) {
                DiagnosticLog.record(error, context: "préparation Core ML")
            }
            try? FileManager.default.removeItem(at: coreMLDirectory)
            isDownloaded = false
            if downloadAttempt == attempt, !(error is CancellationError) {
                errorMessage = "Impossible de télécharger ou vérifier PocketTTS. Vérifie la connexion et l’espace disponible, puis réessaie."
            }
        }
        downloadAttempt = nil
        downloadTask = nil
        isDownloading = false
    }

    nonisolated static func validAsset(_ url: URL, asset: PocketCoreMLManifest.Asset) throws -> Bool {
        guard asset.algorithm == "sha256" || asset.algorithm == "gitSHA1" else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256()
        var sha1 = Insecure.SHA1()
        if asset.algorithm == "gitSHA1" { sha1.update(data: Data("blob \(asset.size)\0".utf8)) }
        var size: Int64 = 0
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            size += Int64(block.count)
            guard size <= asset.size else { return false }
            if asset.algorithm == "sha256" { sha256.update(data: block) } else { sha1.update(data: block) }
        }
        guard size == asset.size else { return false }
        let digest = asset.algorithm == "sha256" ? sha256.finalize().map { String(format: "%02x", $0) }.joined()
            : sha1.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == asset.digest
    }

    func cancelDownload() {
        guard let downloadTask else { return }
        downloadAttempt = nil
        downloadStage = .cancelling
        downloadTask.cancel()
    }

    func removeModel() throws {
        guard !isDownloading, generationTask == nil else { throw VoiceAssistantError.interrupted }
        cancelSpeak()
        coreMLManager = nil
        coreMLExecutionMode = nil
        // Remove only the selected variant; preserve the other model and legacy data.
        if FileManager.default.fileExists(atPath: coreMLDirectory.path) { try FileManager.default.removeItem(at: coreMLDirectory) }
        isDownloaded = false
        errorMessage = nil
        downloadStage = .listing
    }

    func speak(_ text: String, rate: Double, executionMode: PocketCoreMLEngine.ExecutionMode = .foreground) async throws {
        let selected = PocketTTSVoices.selected()
        let voice = availableVoices.first { $0.id == selected.id } ?? availableVoices.first { $0.id == PocketTTSVoices.defaultID }!
        try await playProgressively(text: text, voice: voice, rate: rate, executionMode: executionMode)
    }

    func cancelSpeak() { generationTask?.cancel(); player.cancel(); player.cancelAllStreaming() }

    func recordSpeechFailure(_ error: Error) {
        errorMessage = error.localizedDescription + " " + String(localized: "La réponse est lue avec la voix iOS.")
    }

    static func permitsSystemFallback(for error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? VoiceAssistantError, case .interrupted = error { return false }
        return true
    }

    func preview(_ voice: PocketTTSVoice) async throws {
        try Task.checkCancellation()
        let sessionID = UUID()
        do {
            try await VoiceAudioSession.shared.activatePlayback(id: sessionID)
            try Task.checkCancellation()
            try await playProgressively(text: "Bonjour, je suis la voix \(voice.displayName).", voice: voice, rate: 0.5)
            await VoiceAudioSession.shared.deactivate(id: sessionID)
        } catch {
            await VoiceAudioSession.shared.deactivate(id: sessionID)
            throw error
        }
    }

    private func playProgressively(text: String, voice: PocketTTSVoice, rate: Double,
                                   executionMode: PocketCoreMLEngine.ExecutionMode = .foreground) async throws {
        guard isDownloaded, !isDownloading, assetsExist() else { throw VoiceAssistantError.synthesisUnavailable }
        guard generationTask == nil else { throw VoiceAssistantError.interrupted }
        let id = try player.beginStreaming(rate: rate)
        let streamPlayer = player
        let task = Task { @MainActor in
            try await self.synthesize(text: text, voice: voice, rate: rate, executionMode: executionMode) { samples in
                streamPlayer.enqueue(samples, id: id)
            }
        }
        generationTask = task
        defer { generationTask = nil }
        do {
            _ = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            try await player.finishStreaming(id: id)
            // A completed playback supersedes an earlier speech warning.
            errorMessage = nil
        } catch {
            let alreadyPlayed = player.hasStreamingSamples(id: id)
            player.cancelStreaming(id: id)
            if alreadyPlayed, !(error is CancellationError) { throw VoiceAssistantError.interrupted }
            throw error
        }
    }

    /// Streaming frames and optional aggregation, also used by integration tests.
    func synthesize(text: String, voice: PocketTTSVoice, rate: Double,
                    executionMode: PocketCoreMLEngine.ExecutionMode = .foreground,
                    onSamples: (@MainActor ([Float]) -> Void)? = nil) async throws -> PocketTTSAudio {
        guard isDownloaded, !isDownloading, assetsExist(), availableVoices.contains(voice) else {
            throw VoiceAssistantError.synthesisUnavailable
        }
        let normalized = PocketTTSFrenchText.normalize(text)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceAssistantError.noSpeech }
        try Task.checkCancellation()
        let manager: PocketCoreMLEngine
        if let cached = coreMLManager, coreMLExecutionMode == executionMode { manager = cached }
        else {
            let path = variant == .french24 ? "v2.1/french_24l" : "v2.1/french"
            let candidate = PocketCoreMLEngine(directory: repositoryDirectory.appendingPathComponent(path), variant: variant == .french24 ? .french24 : .french6, executionMode: executionMode)
            coreMLManager = candidate
            coreMLExecutionMode = executionMode
            manager = candidate
        }
        return try await manager.synthesize(text: normalized, voice: voice.id) { samples in
            await onSamples?(samples)
        }
    }
}

/// Aggregates per-file download progress into one bounded, monotonic fraction.
private final class DownloadProgressAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private let totalFiles: Int
    private var doneFiles = 0
    private var currentKey: ObjectIdentifier?
    private var currentWritten: Int64 = 0
    private var currentTotal: Int64 = 0

    init(totalFiles: Int) { self.totalFiles = max(totalFiles, 1) }

    var fraction: Double {
        lock.lock(); defer { lock.unlock() }
        let current = currentTotal > 0 ? min(Double(currentWritten) / Double(currentTotal), 1) : 0
        return min(Double(doneFiles) + current, Double(totalFiles)) / Double(totalFiles)
    }

    func fileProgress(key: ObjectIdentifier, written: Int64, total: Int64) {
        lock.lock(); defer { lock.unlock() }
        currentKey = key
        currentWritten = written
        currentTotal = total
    }

    func fileDone() {
        lock.lock(); defer { lock.unlock() }
        doneFiles += 1
        currentKey = nil
        currentWritten = 0
        currentTotal = 0
    }
}

private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var completions: [ObjectIdentifier: CheckedContinuation<URL, Error>] = [:]
    var onProgress: (@Sendable (ObjectIdentifier, Int64, Int64) -> Void)?

    func download(task: URLSessionDownloadTask, to destination: URL) async throws {
        let key = ObjectIdentifier(task)
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                lock.lock()
                destinations[key] = destination
                completions[key] = continuation
                lock.unlock()
                if Task.isCancelled { task.cancel() } else { task.resume() }
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress?(ObjectIdentifier(downloadTask), totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let key = ObjectIdentifier(downloadTask)
        lock.lock()
        let destination = destinations.removeValue(forKey: key)
        let completion = completions.removeValue(forKey: key)
        lock.unlock()
        guard let destination else {
            completion?.resume(throwing: VoiceAssistantError.synthesisUnavailable)
            return
        }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            completion?.resume(returning: destination)
        } catch {
            completion?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = ObjectIdentifier(task)
        lock.lock()
        let completion = completions.removeValue(forKey: key)
        lock.unlock()
        if let error { completion?.resume(throwing: error) }
    }
}

/// Plays synthesized PCM as an in-memory WAV; works with the existing audio session
/// in both the foreground assistant and the background Siri session.
@MainActor
final class PocketTTSPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var playbackID: UUID?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    private var streamID: UUID?
    private var streamEngine: AVAudioEngine?
    private var streamNode: AVAudioPlayerNode?
    private var streamRateNode: AVAudioUnitTimePitch?
    private var streamPending = 0
    private var streamFinished = false
    private var streamContinuation: CheckedContinuation<Void, Error>?
    private var streamHadSamples = false
    private var streamFailure: Error?
    private var lastStreamWithSamples: UUID?
    private var streamFrames = 0
    private var streamTimeout: Task<Void, Never>?

    func beginStreaming(rate: Double = 0.5) throws -> UUID {
        guard streamID == nil else { throw VoiceAssistantError.interrupted }
        let id = UUID()
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1) else {
            throw PocketTTSError.playbackFailed
        }
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = Float(min(max(rate / 0.5, 0.5), 2.0))
        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.start()
        node.play()
        streamID = id
        lastStreamWithSamples = nil
        streamEngine = engine
        streamNode = node
        streamRateNode = pitch
        streamPending = 0
        streamFinished = false
        streamHadSamples = false
        streamFailure = nil
        streamFrames = 0
        return id
    }

    func enqueue(_ samples: [Float], id: UUID) {
        guard streamID == id, streamFailure == nil, !samples.isEmpty else { return }
        guard samples.count <= Int(UInt32.max), samples.allSatisfy({ $0.isFinite }),
              let node = streamNode,
              let buffer = AVAudioPCMBuffer(pcmFormat: node.outputFormat(forBus: 0), frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            streamFailure = PocketTTSError.invalidAudio
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { if let base = $0.baseAddress { channel.update(from: base, count: samples.count) } }
        streamHadSamples = true
        streamFrames += samples.count
        streamPending += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.streamBufferFinished(id: id) }
        }
    }

    private func streamBufferFinished(id: UUID) {
        guard streamID == id else { return }
        streamPending -= 1
        if streamFinished && streamPending == 0 { endStreaming(id: id, error: nil) }
    }

    func finishStreaming(id: UUID) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard streamID == id, !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if let error = streamFailure { endStreaming(id: id, error: error); continuation.resume(throwing: error); return }
                guard streamHadSamples else { endStreaming(id: id, error: PocketTTSError.invalidAudio); continuation.resume(throwing: PocketTTSError.invalidAudio); return }
                streamContinuation = continuation
                streamFinished = true
                let timeout = max(30.0, Double(streamFrames) / 24_000 / Double(streamRateNode?.rate ?? 1) + 15.0)
                streamTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.endStreaming(id: id, error: PocketTTSError.playbackFailed)
                }
                if streamPending == 0 { endStreaming(id: id, error: nil) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelStreaming(id: id) } }
    }

    func hasStreamingSamples(id: UUID) -> Bool {
        (streamID == id && streamHadSamples) || lastStreamWithSamples == id
    }
    func cancelStreaming(id: UUID) { endStreaming(id: id, error: CancellationError()) }
    func cancelAllStreaming() { if let id = streamID { cancelStreaming(id: id) } }
    private func endStreaming(id: UUID, error: Error?) {
        guard streamID == id else { return }
        streamTimeout?.cancel()
        streamTimeout = nil
        if streamHadSamples { lastStreamWithSamples = id }
        streamNode?.stop()
        streamEngine?.stop()
        streamNode = nil
        streamRateNode = nil
        streamEngine = nil
        streamID = nil
        streamPending = 0
        let continuation = streamContinuation
        streamContinuation = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    func play(audio: PocketTTSAudio, timeout: Double) async throws {
        guard let data = WAVFile.encode(samples: audio.samples, sampleRate: audio.sampleRate) else {
            throw PocketTTSError.invalidAudio
        }
        try Task.checkCancellation()
        cancel()
        let id = UUID()
        playbackID = id
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        self.player = player
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    guard self?.playbackID == id else { return }
                    self?.finish(error: PocketTTSError.playbackFailed)
                }
                guard player.play() else {
                    finish(error: PocketTTSError.playbackFailed)
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.playbackID == id else { return }
                self?.cancel()
            }
        }
    }

    func cancel() {
        player?.stop()
        finish(error: CancellationError())
    }

    private func finish(error: Error?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        player?.stop()
        player = nil
        playbackID = nil
        if let continuation {
            self.continuation = nil
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: ()) }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.finish(error: flag ? nil : PocketTTSError.playbackFailed)
        }
    }
}

enum WAVFile {
    static func encode(samples: [Float], sampleRate: Int) -> Data? {
        guard !samples.isEmpty, samples.count <= (Int(UInt32.max) - 36) / 2,
              sampleRate > 0, sampleRate <= Int(UInt32.max) / 2,
              samples.allSatisfy({ $0.isFinite }) else { return nil }
        let frameCount = UInt32(samples.count)
        let dataSize = frameCount * 2
        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))
        func append(_ value: UInt32, _ size: Int) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0.prefix(size)) }
        }
        func append(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); append(36 + dataSize, 4); data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8)); append(16, 4); append(1, 2); append(1, 2)
        append(UInt32(sampleRate), 4); append(UInt32(sampleRate) * 2, 4); append(2, 2); append(16, 2)
        data.append(Data("data".utf8)); append(dataSize, 4)
        for sample in samples {
            let clamped = min(max(sample, -1), 1)
            append(UInt16(bitPattern: Int16(clamped * 32_767)))
        }
        return data
    }
}


/// Text substitutions from the French PocketTTS configuration. This only
/// changes the string sent to speech synthesis; the conversation is untouched.
enum PocketTTSFrenchText {
    static func normalize(_ text: String) -> String {
        var result = text
        for (source, replacement) in [("’", "'"), ("‘", "'"), ("–", ","),
                                      (";", ","), ("\"", ""), ("“", ""), ("”", ""),
                                      ("„", ""), ("«", ""), ("»", ""), ("(", ""),
                                      (")", ""), ("[", ""), ("]", "")] {
            result = result.replacingOccurrences(of: source, with: replacement)
        }
        return result.replacingOccurrences(of: "(?<![0-9]):(?![0-9])", with: ",", options: .regularExpression)
    }
}


/// Pinned Core ML asset inventory. Hashes are SHA-256 for LFS and Git blob SHA-1 otherwise.
enum PocketCoreMLManifest {
    static let revision = "c2e998e269e4d4b51f74061faddb8450cd8f9a9a"
    struct Asset: Sendable { let path: String; let size: Int64; let algorithm: String; let digest: String }
    static let assets: [Asset] = [
        Asset(path: "encoder_recover_pinv.bin", size: 131072, algorithm: "sha256", digest: "45f5dd6690b45600d780cde86878a935502c3fa101bbff5d06ac4499ec9e3b8d"),
        Asset(path: "v2.1/french_24l/cond_prefill.mlmodelc/analytics/coremldata.bin", size: 243, algorithm: "sha256", digest: "133f57c0224610fb3a6ee728aa914049c20ca2ff6798778e4e3ccc25a0acb557"),
        Asset(path: "v2.1/french_24l/cond_prefill.mlmodelc/coremldata.bin", size: 3519, algorithm: "sha256", digest: "851fd8269184aac7f2286d4439692c02f86ab392fe635ff45a39f8243e1fd44e"),
        Asset(path: "v2.1/french_24l/cond_prefill.mlmodelc/model.mil", size: 958705, algorithm: "gitSHA1", digest: "7028cd94630c33bb5143ac20b6b86ca016eb1d25"),
        Asset(path: "v2.1/french_24l/cond_prefill.mlmodelc/weights/weight.bin", size: 586381056, algorithm: "sha256", digest: "67d8d4f5360674983ff849bf4d218d657f2f21e81a0fa28007f12f98b46078c1"),
        Asset(path: "v2.1/french_24l/constants_bin/alba.safetensors", size: 24777760, algorithm: "sha256", digest: "81ef74464398d6db16c2734276293806845f755725a6b16feb4108b9ae781731"),
        Asset(path: "v2.1/french_24l/constants_bin/anna.safetensors", size: 31265824, algorithm: "sha256", digest: "8ec25e248cfe30c473bd3ceae408a7178eae072c40e45ccb1ed588b005d6c386"),
        Asset(path: "v2.1/french_24l/constants_bin/azelma.safetensors", size: 31855648, algorithm: "sha256", digest: "15db40136e4c33f8e4964ccf999b2bccba17f5897bd08406a4d789a33bb9d1b5"),
        Asset(path: "v2.1/french_24l/constants_bin/bill_boerst.safetensors", size: 26940448, algorithm: "sha256", digest: "9a8ea532c38b4b5b346be3c5cb5468b47534ba5ba1e2e500bd1701f802665f90"),
        Asset(path: "v2.1/french_24l/constants_bin/bos_before_voice.bin", size: 4096, algorithm: "sha256", digest: "3db3c1dd0a65207fd53125249496a772147e2c41a0e7b0664ff71c5ced7729eb"),
        Asset(path: "v2.1/french_24l/constants_bin/bos_emb.bin", size: 128, algorithm: "sha256", digest: "062f9c68cf2477920027c247050aaa5e6ad4a070192102a730ae6c327e7b7e76"),
        Asset(path: "v2.1/french_24l/constants_bin/caro_davy.safetensors", size: 21042200, algorithm: "sha256", digest: "1e645422e06d262288b42e51c873206ad365ceef9649d9c02d24231e6881f205"),
        Asset(path: "v2.1/french_24l/constants_bin/charles.safetensors", size: 24777760, algorithm: "sha256", digest: "5ba86d5829734b5f6ac378ea87e893d1d242cdafb8dfaa6c9bd14ac219e1fe47"),
        Asset(path: "v2.1/french_24l/constants_bin/eponine.safetensors", size: 27726880, algorithm: "sha256", digest: "dc37497d3d2c6ebaf3b43390e4518c9995f0a9a34839d9b3cedac0505963e6fd"),
        Asset(path: "v2.1/french_24l/constants_bin/estelle.safetensors", size: 33035296, algorithm: "sha256", digest: "f1fa8ea7ea7f39f4d9a14c403ea3bd97af17e63e1e64ca9c8484efaedca93170"),
        Asset(path: "v2.1/french_24l/constants_bin/eve.safetensors", size: 26154016, algorithm: "sha256", digest: "caaa3ac419951d927ee40bdba22b3a5273f3d23564b2d573e1ec81a24c77051d"),
        Asset(path: "v2.1/french_24l/constants_bin/fantine.safetensors", size: 26154016, algorithm: "sha256", digest: "f19a024716b9132a310f9c1e1b750e11878a5079d6abbe9a01df6a78034f3db3"),
        Asset(path: "v2.1/french_24l/constants_bin/george.safetensors", size: 24974368, algorithm: "sha256", digest: "f98dd4400b5dca15a1a17c7ca7a9a31525c9e6acf03bd90e58da06bf2aec222e"),
        Asset(path: "v2.1/french_24l/constants_bin/giovanni.safetensors", size: 18486272, algorithm: "sha256", digest: "3c3a5311b3187f270883271e61f8fbd7a3a12c47140a759c0d05f83a37876de2"),
        Asset(path: "v2.1/french_24l/constants_bin/jane.safetensors", size: 29496352, algorithm: "sha256", digest: "799d8323c8808977f3d7f6faca208c29c8e737c2e16242d6a351a47997d6df89"),
        Asset(path: "v2.1/french_24l/constants_bin/javert.safetensors", size: 24777760, algorithm: "sha256", digest: "be49b3147a5a7a819fa190b5e44e471eef8b92cd18a6ed2594edff3996ba95bc"),
        Asset(path: "v2.1/french_24l/constants_bin/juergen.safetensors", size: 24974368, algorithm: "sha256", digest: "7c695bf10e8ea551f3151fe3c5de787fa5a6353665aab190be14dd6cd1320c93"),
        Asset(path: "v2.1/french_24l/constants_bin/lola.safetensors", size: 23794712, algorithm: "sha256", digest: "b9fcbf24e36171e260bde32f2834421658fa68d4d19f50e013f44122b96ebc3f"),
        Asset(path: "v2.1/french_24l/constants_bin/marius.safetensors", size: 24777760, algorithm: "sha256", digest: "6e2e12dc9a7650b3e3d5a28be9a2550ced91c5a11d5de9021efc6107dcc78587"),
        Asset(path: "v2.1/french_24l/constants_bin/mary.safetensors", size: 24777760, algorithm: "sha256", digest: "ad3d85829605e0b28e509c65350198c15f2a0592a39bf88063b4d01b4085c8b8"),
        Asset(path: "v2.1/french_24l/constants_bin/michael.safetensors", size: 29103136, algorithm: "sha256", digest: "2d1dc47d55c149d79701c6d8e9c7f8efab7dfd397616526969b138a05619d0b4"),
        Asset(path: "v2.1/french_24l/constants_bin/paul.safetensors", size: 27923488, algorithm: "sha256", digest: "5dd222567a9c167ed3c39ea5f336e5ab0fcd51be653d2de68d9a8f9db19757c2"),
        Asset(path: "v2.1/french_24l/constants_bin/peter_yearsley.safetensors", size: 14947320, algorithm: "sha256", digest: "997e18754aa28223e48fe19f8b4025b55cd5098b06cb36a4ab842c0325ad6ddc"),
        Asset(path: "v2.1/french_24l/constants_bin/rafael.safetensors", size: 24777760, algorithm: "sha256", digest: "faf602de5907c0d022a551b97dd35d886cda71e4762afb5fd2db1a0bd3bb4326"),
        Asset(path: "v2.1/french_24l/constants_bin/speaker_proj_weight.bin", size: 131072, algorithm: "sha256", digest: "5d8976cbbbf96bdf96ef6b205a1e5fd5e79e8fb03793c475fd4ca66a2c4a8a9c"),
        Asset(path: "v2.1/french_24l/constants_bin/stuart_bell.safetensors", size: 21042200, algorithm: "sha256", digest: "38793a0909ca62261d774d2ef09bba0120c552e67690153f4b061426fa36c791"),
        Asset(path: "v2.1/french_24l/constants_bin/text_embed_table.bin", size: 16388096, algorithm: "sha256", digest: "8db4694230c0fd8e705dd731b57aa6e41d380c034b593f82b1560273c678d15b"),
        Asset(path: "v2.1/french_24l/constants_bin/tokenizer.model", size: 60173, algorithm: "sha256", digest: "521c85bdb2da10618f4be52021ed1cb2a7a6299b040708487f133193f7b305e2"),
        Asset(path: "v2.1/french_24l/constants_bin/vera.safetensors", size: 26940448, algorithm: "sha256", digest: "8533421ac10c6b169bb6271a16f50a1e851bddfe914ab8a7509a5b7908a9686e"),
        Asset(path: "v2.1/french_24l/flow_decoder_fused.mlmodelc/analytics/coremldata.bin", size: 243, algorithm: "sha256", digest: "b83a8ae055446657c1bb78a915622efdec5d796d3438331e5879aa0050dd223b"),
        Asset(path: "v2.1/french_24l/flow_decoder_fused.mlmodelc/coremldata.bin", size: 413, algorithm: "sha256", digest: "b77b677b547d6ce2ee01d58dc20e75cd5a5ecf2ce86b0cb82a32bfc1c6aec496"),
        Asset(path: "v2.1/french_24l/flow_decoder_fused.mlmodelc/model.mil", size: 333331, algorithm: "gitSHA1", digest: "c64a1f34555e7bbf9c8d4502d29f9ef52dd6b0ec"),
        Asset(path: "v2.1/french_24l/flow_decoder_fused.mlmodelc/weights/weight.bin", size: 19012608, algorithm: "sha256", digest: "7feb662b6fb8571b8699c2a70bfaa7b178b9d5dab8e52c2d2b435a68ce60861a"),
        Asset(path: "v2.1/french_24l/flowlm_stepv2.mlmodelc/analytics/coremldata.bin", size: 243, algorithm: "sha256", digest: "d20222b9d25c929804d534f19b9f51daad549805cb010d9b5f0dd970272ef3f6"),
        Asset(path: "v2.1/french_24l/flowlm_stepv2.mlmodelc/coremldata.bin", size: 3561, algorithm: "sha256", digest: "4e5930318538862799470bd2cc790a6cc6079e9ba9d35249d74fc0850217b096"),
        Asset(path: "v2.1/french_24l/flowlm_stepv2.mlmodelc/metadata.json", size: 32730, algorithm: "gitSHA1", digest: "629da9a69819375413a6c11a7789eb2ca4f04e28"),
        Asset(path: "v2.1/french_24l/flowlm_stepv2.mlmodelc/model.mil", size: 972951, algorithm: "gitSHA1", digest: "abdebe0ef22e1c1977cf3ba08456089a8623718d"),
        Asset(path: "v2.1/french_24l/flowlm_stepv2.mlmodelc/weights/weight.bin", size: 303797056, algorithm: "sha256", digest: "a9bca994f15518be8b91c0c0cae1fa01dfcd9aa1ed03467210be5941ef040576"),
        Asset(path: "v2.1/french_24l/manifest.json", size: 739, algorithm: "gitSHA1", digest: "fc7da98920126d1261a9c47517b1303db1599db7"),
        Asset(path: "v2.1/french_24l/mimi_decoder.mlmodelc/analytics/coremldata.bin", size: 243, algorithm: "sha256", digest: "53b41de86399328f57b5db0ac2cbfda4f9016f07b484adf9ec050f0a5ff07b23"),
        Asset(path: "v2.1/french_24l/mimi_decoder.mlmodelc/coremldata.bin", size: 1777, algorithm: "sha256", digest: "de15f7cc799bcdefd8e4474a0befe1161788a3e9aa68b4b448af10939cf35e46"),
        Asset(path: "v2.1/french_24l/mimi_decoder.mlmodelc/metadata.json", size: 16844, algorithm: "gitSHA1", digest: "f66f9e7ff5be2ffbc44c8300f3501f67a77afaf6"),
        Asset(path: "v2.1/french_24l/mimi_decoder.mlmodelc/model.mil", size: 107403, algorithm: "gitSHA1", digest: "c96d4668e23dbb8f1f9e9d85b199ffa213c5c6b1"),
        Asset(path: "v2.1/french_24l/mimi_decoder.mlmodelc/weights/weight.bin", size: 41768256, algorithm: "sha256", digest: "06dbd8b6f8fd4ffefd443aa5bb8b1927cb6d71f7bbac1117ada13938964d2b0b"),
    ]
    static let bytes = assets.reduce(Int64(0)) { $0 + $1.size }
}


/// October 2026 French six-layer Core ML export, pinned to an immutable revision.
enum PocketFrenchSixManifest {
    static let repo = "lineofflight/pocket-tts-coreml"
    static let revision = "f056529a59b35950bfb67750b7e6a021e9db8376"
    static let assets: [PocketCoreMLManifest.Asset] = [
        .init(path: "constants_bin/mimi_init_state/attn0_cache.bin", size: 1048576, algorithm: "sha256", digest: "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58"),
        .init(path: "constants_bin/mimi_init_state/attn0_end_offset.bin", size: 4, algorithm: "sha256", digest: "df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119"),
        .init(path: "constants_bin/mimi_init_state/attn0_offset.bin", size: 4, algorithm: "sha256", digest: "df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119"),
        .init(path: "constants_bin/mimi_init_state/attn1_cache.bin", size: 1048576, algorithm: "sha256", digest: "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58"),
        .init(path: "constants_bin/mimi_init_state/attn1_end_offset.bin", size: 4, algorithm: "sha256", digest: "df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119"),
        .init(path: "constants_bin/mimi_init_state/attn1_offset.bin", size: 4, algorithm: "sha256", digest: "df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119"),
        .init(path: "constants_bin/mimi_init_state/conv0_first.bin", size: 4, algorithm: "sha256", digest: "e00e5eb9444182f352323374ef4e08ebcb784725fdd4fd612d7730540b3e0c8c"),
        .init(path: "constants_bin/mimi_init_state/conv0_prev.bin", size: 12288, algorithm: "sha256", digest: "f3cc103136423a57975750907ebc1d367e2985ac6338976d4d5a439f50323f4a"),
        .init(path: "constants_bin/mimi_init_state/conv_final_first.bin", size: 4, algorithm: "sha256", digest: "e00e5eb9444182f352323374ef4e08ebcb784725fdd4fd612d7730540b3e0c8c"),
        .init(path: "constants_bin/mimi_init_state/conv_final_prev.bin", size: 512, algorithm: "sha256", digest: "076a27c79e5ace2a3d47f9dd2e83e4ff6ea8872b3c2218f66c92b89b55f36560"),
        .init(path: "constants_bin/mimi_init_state/convtr0_partial.bin", size: 6144, algorithm: "sha256", digest: "fd9243e1ba57263ed469c3bdbd7ade6ec5254e7ed924a9f5737fa44749933cc0"),
        .init(path: "constants_bin/mimi_init_state/convtr1_partial.bin", size: 2560, algorithm: "sha256", digest: "8ce8ba8e726ee8925e6560d86ac35be1097691d1cfac888e6bd20e804ea9eb15"),
        .init(path: "constants_bin/mimi_init_state/convtr2_partial.bin", size: 1024, algorithm: "sha256", digest: "5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef"),
        .init(path: "constants_bin/mimi_init_state/res0_conv0_first.bin", size: 4, algorithm: "sha256", digest: "e00e5eb9444182f352323374ef4e08ebcb784725fdd4fd612d7730540b3e0c8c"),
        .init(path: "constants_bin/mimi_init_state/res0_conv0_prev.bin", size: 2048, algorithm: "sha256", digest: "e5a00aa9991ac8a5ee3109844d84a55583bd20572ad3ffcd42792f3c36b183ad"),
        .init(path: "constants_bin/mimi_init_state/res0_conv1_first.bin", size: 4, algorithm: "sha256", digest: "e00e5eb9444182f352323374ef4e08ebcb784725fdd4fd612d7730540b3e0c8c"),
        .init(path: "constants_bin/mimi_init_state/res0_conv1_prev.bin", size: 0, algorithm: "sha256", digest: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        .init(path: "constants_bin/mimi_init_state/res1_conv0_first.bin", size: 4, algorithm: "sha256", digest: "e00e5eb9444182f352323374ef4e08ebcb784725fdd4fd612d7730540b3e0c8c"),
        .init(path: "constants_bin/mimi_init_state/res1_conv0_prev.bin", size: 1024, algorithm: "sha256", digest: "5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef"),
        .init(path: "constants_bin/mimi_init_state/res1_conv1_first.bin", size: 4, algorithm: "sha256", digest: "e00e5eb9444182f352323374ef4e08ebcb784725fdd4fd612d7730540b3e0c8c"),
        .init(path: "constants_bin/mimi_init_state/res1_conv1_prev.bin", size: 0, algorithm: "sha256", digest: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        .init(path: "constants_bin/mimi_init_state/res2_conv0_first.bin", size: 4, algorithm: "sha256", digest: "e00e5eb9444182f352323374ef4e08ebcb784725fdd4fd612d7730540b3e0c8c"),
        .init(path: "constants_bin/mimi_init_state/res2_conv0_prev.bin", size: 512, algorithm: "sha256", digest: "076a27c79e5ace2a3d47f9dd2e83e4ff6ea8872b3c2218f66c92b89b55f36560"),
        .init(path: "constants_bin/mimi_init_state/res2_conv1_first.bin", size: 4, algorithm: "sha256", digest: "e00e5eb9444182f352323374ef4e08ebcb784725fdd4fd612d7730540b3e0c8c"),
        .init(path: "constants_bin/mimi_init_state/res2_conv1_prev.bin", size: 0, algorithm: "sha256", digest: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        .init(path: "constants_bin/mimi_init_state/upsample_partial.bin", size: 32768, algorithm: "sha256", digest: "c35020473aed1b4642cd726cad727b63fff2824ad68cedd7ffb73c7cbd890479"),
        .init(path: "v2.1/french/cond_prefill_ane.mlmodelc/analytics/coremldata.bin", size: 243, algorithm: "sha256", digest: "0988194a38f3cf19777207a6a453b9425d974a9ad3a86a43d1a3f9fcb9dfa33f"),
        .init(path: "v2.1/french/cond_prefill_ane.mlmodelc/coremldata.bin", size: 1388, algorithm: "sha256", digest: "ca5d0adfaac4af9b52b64afe1e87823b39aa89bbc54a50867417459ed72ecf38"),
        .init(path: "v2.1/french/cond_prefill_ane.mlmodelc/model.mil", size: 136095, algorithm: "sha256", digest: "51e6c389501bddfdb15cc1a10d9fff5b072f07060962850b74fac3ee678b53a9"),
        .init(path: "v2.1/french/cond_prefill_ane.mlmodelc/weights/weight.bin", size: 132187392, algorithm: "sha256", digest: "c1f22cfe799ed2317582d0a3b027ac22b356353231a3826ead41c56f712e4a3b"),
        .init(path: "v2.1/french/constants_bin/alba.safetensors", size: 6244152, algorithm: "sha256", digest: "4c80b1438668290542068bbc9515abd2c267f4cc86764c6633fcde395d1b2681"),
        .init(path: "v2.1/french/constants_bin/anna.safetensors", size: 7620408, algorithm: "sha256", digest: "7a7fae31e4b0e16102cb2514f96189cdb57c8403f5f7aba2b37aa942e2d03488"),
        .init(path: "v2.1/french/constants_bin/azelma.safetensors", size: 7178040, algorithm: "sha256", digest: "d5f6e1176878323101cecf7595c3a8fd998048a0a5eefb864dbfcc0e453065f8"),
        .init(path: "v2.1/french/constants_bin/bos_emb.bin", size: 128, algorithm: "sha256", digest: "e5e2df4cfc1c389e629ab5fd641d8922529d186950b8045de6b5469cbe9ceeec"),
        .init(path: "v2.1/french/constants_bin/charles.safetensors", size: 6195000, algorithm: "sha256", digest: "956942f32745023f512ca99a45514648c8bbf4a4edc5bb5fdcb7c1a5dd5fbf97"),
        .init(path: "v2.1/french/constants_bin/eponine.safetensors", size: 6932280, algorithm: "sha256", digest: "8e216220a7e8a69f7aa01ec85db2e63a445f9af6b907c43640a53a1889e6125b"),
        .init(path: "v2.1/french/constants_bin/estelle.safetensors", size: 7571256, algorithm: "sha256", digest: "d9efd55657f74ba9483caec23f9fd1d155e121b058feef86af3760d54ea8aa15"),
        .init(path: "v2.1/french/constants_bin/eve.safetensors", size: 6145848, algorithm: "sha256", digest: "b642a43b786fb60571656814cc66f9c24f8a457ea9f727903ea97d647d5ceedb"),
        .init(path: "v2.1/french/constants_bin/fantine.safetensors", size: 6440760, algorithm: "sha256", digest: "2ebba7baef8586851c589226e58414b21386a20dbac4c45746cd4317e51ff57b"),
        .init(path: "v2.1/french/constants_bin/george.safetensors", size: 5900088, algorithm: "sha256", digest: "b7513caf686418ec303dfd87dc6ddbcc020df9bf5964cb4afcd0b72b602afa6f"),
        .init(path: "v2.1/french/constants_bin/giovanni.safetensors", size: 4130608, algorithm: "sha256", digest: "b43d37b9ac7c48cb47d7d4bb5b320635b31d4e9d2ff036453414f634305c7896"),
        .init(path: "v2.1/french/constants_bin/jane.safetensors", size: 7325496, algorithm: "sha256", digest: "1482685d8a1a22a7294df650f61293bab353445710e26a60ae057cbf4ad85221"),
        .init(path: "v2.1/french/constants_bin/javert.safetensors", size: 6145848, algorithm: "sha256", digest: "de53da3263a749289bfed884faab4aba87541133828af506412f88becd3adbc1"),
        .init(path: "v2.1/french/constants_bin/juergen.safetensors", size: 6096696, algorithm: "sha256", digest: "e511d635b210ca69ca8be39bce6e6dc0f269d6fb1eca7b5c2ccb2e2fd6fde1c8"),
        .init(path: "v2.1/french/constants_bin/lola.safetensors", size: 5457720, algorithm: "sha256", digest: "751ff3e4cf0a917cf520e8ece16960d588b350b2dcb7463ce5c2ea1d4ee1666a"),
        .init(path: "v2.1/french/constants_bin/marius.safetensors", size: 6244152, algorithm: "sha256", digest: "f2b741148f2bc01f617e0aedfc5767f477b150b36f98490fa49f8ed0a39556fd"),
        .init(path: "v2.1/french/constants_bin/mary.safetensors", size: 5949240, algorithm: "sha256", digest: "8d5d4f03bce7660da0ea81d96f8a0ea0913685b21fbbbd7bba714242822368dc"),
        .init(path: "v2.1/french/constants_bin/michael.safetensors", size: 7128888, algorithm: "sha256", digest: "7dc7c44c71e514fcec8203a310676c410b3a68280dd52f6d60c424d51a8b638a"),
        .init(path: "v2.1/french/constants_bin/paul.safetensors", size: 6833976, algorithm: "sha256", digest: "85d2f623d5de93dbc33b56f7cbdb90bfaf100c1a7a0958848326223bc7cda5ed"),
        .init(path: "v2.1/french/constants_bin/text_embed_table.bin", size: 16388096, algorithm: "sha256", digest: "c52d5c2fa9acb3734a513b537fb53ecf70e6d77a1755918849c87ac1900d344d"),
        .init(path: "v2.1/french/constants_bin/tokenizer.model", size: 60690, algorithm: "sha256", digest: "dd8dc8cfad3c4b3711a8629ede27d5be934eb98bcb00462bf91ed40fb8f6f38a"),
        .init(path: "v2.1/french/constants_bin/vera.safetensors", size: 6686520, algorithm: "sha256", digest: "dca0db2aa7d5e63dab39a1826f7a4833b6852057eebb1ce21f4cd0945dce9870"),
        .init(path: "v2.1/french/flow_decoder_fused.mlmodelc/analytics/coremldata.bin", size: 243, algorithm: "sha256", digest: "baa1bcdc305fe1e0d6eddbc47ffef67c098cd3f6ee33b2d6d2548f26add9e4c1"),
        .init(path: "v2.1/french/flow_decoder_fused.mlmodelc/coremldata.bin", size: 412, algorithm: "sha256", digest: "f2459f814a0cdd6932dec489d18ff3af160252e7a14065328c9a14a8c1f22ee8"),
        .init(path: "v2.1/french/flow_decoder_fused.mlmodelc/model.mil", size: 332924, algorithm: "sha256", digest: "68e717dc9820793828a8f2fdfddc1848008d7bf663a8ef684f67d9e70cfa2bc7"),
        .init(path: "v2.1/french/flow_decoder_fused.mlmodelc/weights/weight.bin", size: 19012608, algorithm: "sha256", digest: "0620c21174e467666388f8cc3436d20d47d60af991a9658a9781558a12300727"),
        .init(path: "v2.1/french/flowlm_step_ane.mlmodelc/analytics/coremldata.bin", size: 243, algorithm: "sha256", digest: "08675ac4adb8db449229d2756804c721e6ec92780f5cf437051fffcdbcdcaf2f"),
        .init(path: "v2.1/french/flowlm_step_ane.mlmodelc/coremldata.bin", size: 1414, algorithm: "sha256", digest: "1b3e50765e7055edc251aed8d32d9446e7caca0d7baacc63bd759d7923a9da74"),
        .init(path: "v2.1/french/flowlm_step_ane.mlmodelc/model.mil", size: 156947, algorithm: "sha256", digest: "c7a89b44317d1f2d697e5acb22dcc58d907f50e36fb6dbe879b28ecde462b438"),
        .init(path: "v2.1/french/flowlm_step_ane.mlmodelc/weights/weight.bin", size: 151136960, algorithm: "sha256", digest: "447e3bb8f70c12a2286a0bf5820414f3a2913966597dda37e32a7a23ebfd3655"),
        .init(path: "v2.1/french/mimi_decoder.mlmodelc/analytics/coremldata.bin", size: 243, algorithm: "sha256", digest: "dfcbe919c2d93b86d6eebc2bf076e913f736c71b44986c409271a3a176015da7"),
        .init(path: "v2.1/french/mimi_decoder.mlmodelc/coremldata.bin", size: 1777, algorithm: "sha256", digest: "87fbefd3e3ae95b62af2213eb8ec0007ca974277800ccbeb0445f890b8627bd7"),
        .init(path: "v2.1/french/mimi_decoder.mlmodelc/metadata.json", size: 16844, algorithm: "sha256", digest: "d47ae73c27cff777636b6f5138c55f498248918ba8a4de0448018bc3a987b4b6"),
        .init(path: "v2.1/french/mimi_decoder.mlmodelc/model.mil", size: 107431, algorithm: "sha256", digest: "7ef1af4bbe0d141d9d2e26163eff9d7cdb8f51529808adec83eb27924617a2ac"),
        .init(path: "v2.1/french/mimi_decoder.mlmodelc/weights/weight.bin", size: 41768256, algorithm: "sha256", digest: "54e73ee04b38c2ffaaf6d18e864c1491f9a7d4ce44cbe7eefa6e37ab5dc2a665"),
    ]
    static let bytes = assets.reduce(Int64(0)) { $0 + $1.size }
}
