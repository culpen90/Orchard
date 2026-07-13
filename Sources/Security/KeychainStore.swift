import Foundation
import Security

protocol APIKeyStoring: Sendable {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAPIKey() throws
}

struct KeychainStore: APIKeyStoring, Sendable {
    static let shared = KeychainStore()

    private let service: String
    private let account: String

    init(
        service: String = "com.culpen90.Orchard",
        account: String = "openrouter-api-key"
    ) {
        self.service = service
        self.account = account
    }

    func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard
            let data = result as? Data,
            let key = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.invalidData
        }
        return key
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw KeychainError.emptyKey
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            var item = baseQuery
            for (key, value) in attributes {
                item[key] = value
            }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw KeychainError(status: updateStatus)
        }
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum KeychainError: LocalizedError, Sendable {
    case emptyKey
    case invalidData
    case status(OSStatus)

    init(status: OSStatus) {
        self = .status(status)
    }

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            "Enter an OpenRouter API key first."
        case .invalidData:
            "The saved OpenRouter key could not be read."
        case .status(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                "Keychain error: \(message)"
            } else {
                "Keychain error (\(status))."
            }
        }
    }
}
