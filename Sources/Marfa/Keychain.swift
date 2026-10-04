import Foundation
import Security

/// Keys kept as generic passwords, under a service and account the app chooses.
public struct Keychain: Sendable {
    public struct Failure: Error, Hashable {
        public let status: OSStatus
    }

    /// On macOS, the user's default keychain, usually the login keychain.
    public static let system = Keychain()

    /// Narrows a query, or a new item, to a keychain other than the default. Tests use it; an app has no way to.
    let narrow: @Sendable (_ query: inout [CFString: Any], _ forNewItem: Bool) throws -> Void

    init(narrow: @escaping @Sendable (inout [CFString: Any], Bool) throws -> Void = { _, _ in }) {
        self.narrow = narrow
    }

    public func save(key: String, service: String, account: String) throws {
        let status = SecItemUpdate(
            try searching(service: service, account: account) as CFDictionary,
            [kSecValueData: Data(key.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.item(service: service, account: account)
            item[kSecValueData] = Data(key.utf8)
            try narrow(&item, true)
            try Self.check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try Self.check(status)
        }
    }

    public func key(service: String, account: String) throws -> String? {
        var query = try searching(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        try Self.check(status)
        return (found as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    /// With no `account`, whether any account holds a key under `service`.
    ///
    /// Reads attributes only, never the secret, so it never prompts.
    public func holds(service: String, account: String? = nil) throws -> Bool {
        var query = try searching(service: service, account: account)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return false }
        try Self.check(status)
        return true
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(try searching(service: service, account: account) as CFDictionary)
        if status != errSecItemNotFound { try Self.check(status) }
    }

    private static func item(service: String, account: String?) -> [CFString: Any] {
        var item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        if let account { item[kSecAttrAccount] = account }
        return item
    }

    private func searching(service: String, account: String?) throws -> [CFString: Any] {
        var query = Self.item(service: service, account: account)
        try narrow(&query, false)
        return query
    }

    private static func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw Failure(status: status) }
    }
}
