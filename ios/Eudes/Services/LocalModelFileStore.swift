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

    /// Cache only an unchanged file within the current process. Replacement,
    /// modification, removal or a different expected digest forces a rehash.
    struct VerificationCache {
        private struct Stamp: Equatable {
            let device: UInt64
            let inode: UInt64
            let size: Int64
            let modified: Date
            let changedSeconds: Int64
            let changedNanoseconds: Int64
        }
        private struct Entry {
            let stamp: Stamp
            let size: Int64
            let sha256: String
        }
        private var entries: [URL: Entry] = [:]

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

        mutating func verify(_ url: URL, size: Int64, sha256: String) throws {
            try Task.checkCancellation()
            let before = try stamp(url)
            if let before, let cached = entries[url], cached.stamp == before,
               cached.size == size, cached.sha256 == sha256.lowercased() { return }
            entries[url] = nil
            try LocalModelFileStore.verify(url, size: size, sha256: sha256)
            let after = try stamp(url)
            if let before, let after {
                guard before == after else { throw StoreError.changedDuringVerification }
                entries[url] = Entry(stamp: before, size: size, sha256: sha256.lowercased())
            }
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
