import Foundation
import UIKit

/// iOS owns the transfer when Eudes is suspended. Only pinned catalog entries
/// can be scheduled; a downloaded file is staged and verified before use.
final class LocalModelDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = LocalModelDownloads()
    static let identifier = "fr.eudes.app.lfm3.background.v1"
    static let didChange = Notification.Name("EudesLocalModelDownloadsChanged")
    private let stateLock = NSLock()
    private var backgroundCompletion: (() -> Void)?
    private var sessionStorage: URLSession?
    private var finishedEvents = false
    private var startingModels: Set<String> = []
    private var session: URLSession {
        stateLock.lock(); defer { stateLock.unlock() }
        if let existing = sessionStorage { return existing }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let value = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        sessionStorage = value
        return value
    }

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eudes/LocalModels", isDirectory: true)
    }

    static func destination(model: LocalModelCatalog.Model, asset: LocalModelCatalog.Asset) -> URL {
        root.appendingPathComponent(model.id, isDirectory: true).appendingPathComponent(asset.filename)
    }

    /// Tous les fichiers du modèle occupent leur place finale : le seul critère de
    /// présence utilisable, une vérification d'empreinte pouvant rester sans conclusion.
    static func isInstalled(_ model: LocalModelCatalog.Model, at directory: URL = LocalModelDownloads.root) -> Bool {
        model.assets.allSatisfy { asset in
            let url = directory.appendingPathComponent(model.id, isDirectory: true)
                .appendingPathComponent(asset.filename)
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// A task description is a stable catalog identity, never a filesystem path.
    static func identity(model: LocalModelCatalog.Model, asset: LocalModelCatalog.Asset) -> String {
        "\(model.id)|\(asset.filename)"
    }

    static func resolve(_ description: String?) -> (LocalModelCatalog.Model, LocalModelCatalog.Asset)? {
        guard let description else { return nil }
        for model in LocalModelCatalog.models {
            for asset in model.assets where identity(model: model, asset: asset) == description {
                return (model, asset)
            }
        }
        return nil
    }

    private func beginStarting(_ id: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return startingModels.insert(id).inserted
    }

    private func endStarting(_ id: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        startingModels.remove(id)
    }

    /// Free space left for the app container, in bytes (0 when unknown).
    static func availableBytes() -> Int64 {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    func start(model: LocalModelCatalog.Model) async {
        guard beginStarting(model.id) else { return }
        defer { endStarting(model.id) }
        // L'installation garde le fichier téléchargé et sa copie finale : compter le double,
        // plus une marge, évite un téléchargement entier qui échoue à la fin.
        let needed = model.downloadBytes * 2 + 200_000_000
        let available = Self.availableBytes()
        if available > 0, available < needed {
            notify(error: "Espace insuffisant pour \(model.title) : \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) nécessaires, \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) disponibles.")
            return
        }
        let active = await session.allTasks
        for asset in model.assets {
            let identity = Self.identity(model: model, asset: asset)
            if active.contains(where: { $0.taskDescription == identity }) { continue }
            let destination = Self.destination(model: model, asset: asset)
            if (try? LocalModelFileStore.verify(destination, size: asset.size, sha256: asset.sha256)) != nil { continue }
            guard let url = model.url(for: asset) else { continue }
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            let task = session.downloadTask(with: request)
            task.taskDescription = identity
            task.resume()
        }
        notify()
    }

    func setPaused(_ paused: Bool, model: LocalModelCatalog.Model) async {
        for task in await session.allTasks where Self.resolve(task.taskDescription)?.0.id == model.id {
            if paused && task.state == .running { task.suspend() }
            else if !paused && task.state == .suspended { task.resume() }
        }
        notify()
    }

    func cancel(model: LocalModelCatalog.Model) async {
        for task in await session.allTasks where Self.resolve(task.taskDescription)?.0.id == model.id {
            task.cancel()
        }
        notify()
    }

    func tasks() async -> [URLSessionTask] { await session.allTasks }

    /// UIKit supplies this before a relaunched app reassociates its session.
    func reconnect(completion: @escaping () -> Void) {
        stateLock.lock()
        backgroundCompletion = completion
        let alreadyFinished = finishedEvents
        finishedEvents = false
        stateLock.unlock()
        _ = session
        if alreadyFinished { finishBackgroundEvents() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateLock.lock()
        if backgroundCompletion == nil { finishedEvents = true; stateLock.unlock(); return }
        stateLock.unlock()
        finishBackgroundEvents()
    }

    private func finishBackgroundEvents() {
        stateLock.lock()
        let callback = backgroundCompletion
        backgroundCompletion = nil
        stateLock.unlock()
        if let callback { DispatchQueue.main.async(execute: callback) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let (model, asset) = Self.resolve(downloadTask.taskDescription),
              let response = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode), response.url?.scheme?.lowercased() == "https" else {
            notify(error: "Le téléchargement du modèle a été refusé.")
            return
        }
        let destination = Self.destination(model: model, asset: asset)
        do {
            // The system deletes its temporary file as soon as this delegate returns.
            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: destination.deletingLastPathComponent().path)
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
            try manager.moveItem(at: location, to: staged)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: staged.path)
            defer { try? manager.removeItem(at: staged) }
            try LocalModelFileStore.installVerified(from: staged, at: destination, size: asset.size, sha256: asset.sha256)
            notify()
        } catch {
            DiagnosticLog.record(error, context: "vérification du modèle téléchargé")
            notify(error: "Impossible de vérifier le fichier du modèle : \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        notify()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError?, error.code != NSURLErrorCancelled else { notify(); return }
        notify(error: "Téléchargement interrompu : \(error.localizedDescription)")
    }

    private func notify(error: String? = nil) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil,
                                            userInfo: error.map { ["error": $0] })
        }
    }
}

final class LocalModelAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == LocalModelDownloads.identifier else { completionHandler(); return }
        LocalModelDownloads.shared.reconnect(completion: completionHandler)
    }
}
