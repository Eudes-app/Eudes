import Foundation
import Security

struct PrivateStorage {
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("workspace.json") }

    init(directory: URL? = nil) throws {
        self.directory = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("EudesPrivate", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        try protect(self.directory)
    }

    func load() throws -> AppData {
        guard FileManager.default.fileExists(atPath: file.path) else { return AppData() }
        try protect(file)
        let data = try JSONDecoder().decode(AppData.self, from: Data(contentsOf: file))
        guard data.schemaVersion == 1 else { throw EudesError.storage("Version de données non prise en charge.") }
        return data
    }

    func save(_ data: AppData) throws {
        // A temporary write followed by an atomic rename; protected from creation.
        let encoded = try JSONEncoder().encode(data)
        try encoded.write(to: file, options: [.atomic, .completeFileProtection])
        try protect(file)
    }

    private func protect(_ value: URL) throws {
        var url = value
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }
}

struct KeychainStore {
    private let service = "fr.eudes.local.api-keys"

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }

    func read(_ id: UUID) throws -> String {
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { throw EudesError.keychain(status) }
        return value
    }

    func write(_ value: String, for id: UUID) throws {
        if value.isEmpty { try delete(id); return }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query(id).merging(attributes) { _, new in new }
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw EudesError.keychain(result) }
        } else if status != errSecSuccess { throw EudesError.keychain(status) }
    }

    func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw EudesError.keychain(status) }
    }
}
