import Foundation
import Security

/// Where a working copy's slice comes from: a server, and the key that reaches it.
///
/// The key is held in memory for as long as the working copy is open and never
/// written by the package.
public struct Server: Sendable, Hashable {
    public var url: URL
    public var key: String

    public init(url: URL, key: String) {
        self.url = url
        self.key = key
    }
}

/// A key kept in the Keychain as a generic password.
public enum Keychain {
    /// The Keychain refused, with its own status.
    public struct Failure: Error, Hashable {
        public let status: OSStatus
    }

    /// Keeps `key`, replacing any key already kept under the same names.
    public static func save(key: String, service: String, account: String) throws {
        let query = self.query(service: service, account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: Data(key.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = Data(key.utf8)
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    /// The key kept under these names, or nothing where none is.
    public static func key(service: String, account: String) throws -> String? {
        var query = self.query(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return (found as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func query(service: String, account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    private static func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw Failure(status: status) }
    }
}
