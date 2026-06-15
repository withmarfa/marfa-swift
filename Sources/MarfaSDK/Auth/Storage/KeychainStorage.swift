import Foundation
import Security

/// Keychain-backed ``SecureStorage`` for API keys and OAuth tokens.
///
/// Stores generic-password items under `kSecClass = kSecClassGenericPassword`
/// with the configured service and consumer-provided account. Values are
/// UTF-8 encoded before storage and decoded on retrieval.
///
/// ### Access groups
/// Supply `accessGroup` to share items with a main app's extensions
/// (share extension, widget, watch companion). Requires matching Keychain
/// Access Groups entitlements on all targets.
///
/// ### Thread safety
/// Actor-isolated: all Security framework calls funnel through the actor,
/// so concurrent callers serialize without explicit locking.
public actor KeychainStorage: SecureStorage {

    public let service: String
    public let accessGroup: String?

    public init(service: String = "marfa.sdk", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func set(_ value: String, for account: String) async throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.decodingFailed
        }

        var query = baseQuery(for: account)
        var attributes: [String: Any] = [kSecValueData as String: data]

        // SecItemUpdate if present, otherwise SecItemAdd.
        let statusGet = SecItemCopyMatching(query as CFDictionary, nil)
        if statusGet == errSecSuccess {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus != errSecSuccess {
                throw KeychainError.osStatus(updateStatus)
            }
        } else if statusGet == errSecItemNotFound {
            query[kSecValueData as String] = data
            attributes = query  // full attributes for add
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw KeychainError.osStatus(addStatus)
            }
        } else {
            throw KeychainError.osStatus(statusGet)
        }
    }

    public func get(for account: String) async throws -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.unexpected("Keychain returned non-Data for generic password")
            }
            guard let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.osStatus(status)
        }
    }

    public func delete(for account: String) async throws {
        let query = baseQuery(for: account)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.osStatus(status)
        }
    }

    // MARK: - Private

    private func baseQuery(for account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
