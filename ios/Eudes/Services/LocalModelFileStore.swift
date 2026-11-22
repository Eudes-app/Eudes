import CryptoKit
import Darwin
import Foundation

/// Verifies model files without loading multi-gigabyte weights into memory.
struct LocalModelFileStore {
    enum StoreError: Error, Equatable {
        case invalidSize, invalidDigest, changedDuringVerification
    }

    static func verify(_ url: URL, size: Int64, sha256: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let actual = attributes[.size] as? NSNumber, actual.int64Value == size else {
            throw StoreError.invalidSize
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        let actualDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualDigest == sha256.lowercased() else { throw StoreError.invalidDigest }
    }

    /// Cache only an unchanged file within the current process, and across launches
    /// when a store is provided. Replacement, modification, removal or a different
    /// expected digest forces a rehash.
    ///
    /// L'empreinte est liée au fichier par son inode et son `ctime` : un remplacement
    /// change l'inode, une réécriture change le `ctime`, que l'espace utilisateur ne
    /// peut pas antidater. Écrire ce cache demande le même accès au conteneur que
    /// remplacer le modèle, donc il n'ouvre aucune capacité nouvelle.
    struct VerificationCache {
        private struct Stamp: Codable, Equatable {
            let device: UInt64
            let inode: UInt64
            let size: Int64
            let modified: Date
            let changedSeconds: Int64
            let changedNanoseconds: Int64
        }
        private struct Entry: Codable {
            let stamp: Stamp
            let size: Int64
            let sha256: String
        }
        /// Clé = chemin absolu. Le fichier de cache ne contient que des empreintes.
        private var entries: [String: Entry] = [:]
        private let storeURL: URL?
        private var didLoad = false

        init(storeURL: URL? = nil) { self.storeURL = storeURL }

        /// Emplacement partagé entre lancements, à côté des modèles téléchargés.
        static var defaultStoreURL: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Eudes/model-verification.json")
        }

        private mutating func loadIfNeeded() {
            guard !didLoad else { return }
            didLoad = true
            guard let storeURL, let data = try? Data(contentsOf: storeURL),
                  let stored = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
            entries = stored
        }

        /// Le cache est une optimisation : un échec d'écriture ne doit jamais faire
        /// échouer une vérification. Les entrées dont le fichier a disparu sont retirées.
        private mutating func persist() {
            guard let storeURL else { return }
            entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        }

        private func stamp(_ url: URL) throws -> Stamp? {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return lstat(path, &info)
            }
            guard result == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return Stamp(device: device.uint64Value, inode: inode.uint64Value,
                         size: size.int64Value, modified: modified,
                         changedSeconds: Int64(info.st_ctimespec.tv_sec),
                         changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
        }

        /// Renvoie vrai quand l'empreinte enregistrée a été réutilisée sans relire
        /// le fichier : c'est la mesure du gain au lancement.
        @discardableResult
        mutating func verify(_ url: URL, size: Int64, sha256: String) throws -> Bool {
            try Task.checkCancellation()
            loadIfNeeded()
            let key = url.path
            let before = try stamp(url)
            if let before, let cached = entries[key], cached.stamp == before,
               cached.size == size, cached.sha256 == sha256.lowercased() { return true }
            if entries.removeValue(forKey: key) != nil { persist() }
            try LocalModelFileStore.verify(url, size: size, sha256: sha256)
            let after = try stamp(url)
            if let before, let after {
                guard before == after else { throw StoreError.changedDuringVerification }
                entries[key] = Entry(stamp: before, size: size, sha256: sha256.lowercased())
                persist()
            }
            return false
        }
    }

    /// The temporary file and destination must be on the same volume. Verification
    /// occurs before replacement, so a corrupt download cannot replace a good model.
    static func installVerified(from temporaryURL: URL, at destination: URL,
                                size: Int64, sha256: String) throws {
        try verify(temporaryURL, size: size, sha256: sha256)
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try manager.moveItem(at: temporaryURL, to: destination)
        }
        var directory = destination.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
}
