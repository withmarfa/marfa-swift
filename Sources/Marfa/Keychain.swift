import Foundation
import Security

/// Keys and sign-ins kept as generic passwords, under a service and account the app chooses.
public struct Keychain: Sendable, Hashable {
    /// A Security framework call that did not succeed.
    ///
    /// Its text is the framework's message for the status, or the status number where the framework has none.
    public struct Failure: Error, Hashable, LocalizedError, CustomStringConvertible {
        public let status: OSStatus

        public init(status: OSStatus) {
            self.status = status
        }

        public var errorDescription: String? { description }

        public var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    /// The user's default keychain on macOS, usually the login keychain, and the app's own keychain on iOS.
    public static let system = Keychain(identity: "system")

    /// The data protection keychain, in `accessGroup`: a keychain access group or app group the app's
    /// entitlements name, such as `ABCDE12345.com.example.notes`, so an app and its extensions share what
    /// it keeps.
    public init(accessGroup: String) {
        self.init(identity: "group \(accessGroup)") { query, _ in
            query[kSecUseDataProtectionKeychain] = true
            query[kSecAttrAccessGroup] = accessGroup
        }
        dataProtection = true
    }

    /// Two keychains are equal when they name the same place; each one a test makes is a place of its own.
    let identity: String

    /// Whether items go to the data protection keychain, which honors an item's accessibility.
    private(set) var dataProtection: Bool = {
        #if os(macOS)
        false
        #else
        true
        #endif
    }()

    /// Where the items live in place of the Security framework, for a keychain a test makes.
    let backend: (any KeychainBackend)?

    /// Narrows a query, or a new item, to another keychain.
    let narrow: @Sendable (_ query: inout [CFString: Any], _ forNewItem: Bool) throws -> Void

    init(
        identity: String = UUID().uuidString,
        narrow: @escaping @Sendable (inout [CFString: Any], Bool) throws -> Void = { _, _ in }
    ) {
        self.identity = identity
        self.narrow = narrow
        backend = nil
    }

    /// A keychain whose items `backend` keeps, so no Security call is made.
    package init(identity: String = UUID().uuidString, backend: any KeychainBackend) {
        self.identity = identity
        self.backend = backend
        narrow = { _, _ in }
    }

    public static func == (lhs: Keychain, rhs: Keychain) -> Bool { lhs.identity == rhs.identity }
    public func hash(into hasher: inout Hasher) { hasher.combine(identity) }

    public func save(key: String, service: String, account: String) throws {
        try put(Data(key.utf8), service: service, account: account)
    }

    public func key(service: String, account: String) throws -> String? {
        try data(service: service, account: account).map { String(decoding: $0, as: UTF8.self) }
    }

    /// With no `account`, whether any account holds a key under `service`.
    ///
    /// Reads attributes only, never the secret, so it never prompts.
    public func holds(service: String, account: String? = nil) throws -> Bool {
        if let backend { return try backend.holds(service: service, account: account) }
        return try attributes(service: service, account: account) != nil
    }

    public func delete(service: String, account: String) throws {
        if let backend { return try backend.delete(service: service, account: account) }
        let status = SecItemDelete(try searching(service: service, account: account) as CFDictionary)
        if status != errSecItemNotFound { try Self.check(status) }
    }

    func data(service: String, account: String) throws -> Data? {
        if let backend { return try backend.data(service: service, account: account) }
        var query = try searching(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        try Self.check(status)
        return found as? Data
    }

    /// Replaces the item's data, or adds the item.
    ///
    /// A new item is readable after the device's first unlock, so a renewal can run in the background.
    func put(_ data: Data, service: String, account: String) throws {
        if let backend { return try backend.put(data, service: service, account: account) }
        let status = SecItemUpdate(
            try searching(service: service, account: account) as CFDictionary,
            [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.item(service: service, account: account)
            item[kSecValueData] = data
            if dataProtection { item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
            try narrow(&item, true)
            try Self.check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try Self.check(status)
        }
    }

    /// Adds an item labeled `label` only where none is kept under `service` and `account`.
    ///
    /// The keychain refuses a second item with the same service and account, whichever process adds it.
    /// Answers whether this call added it.
    func add(label: String, service: String, account: String) throws -> Bool {
        if let backend { return try backend.add(label: label, service: service, account: account) }
        var item = Self.item(service: service, account: account)
        item[kSecAttrLabel] = label
        item[kSecValueData] = Data()
        if dataProtection { item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
        try narrow(&item, true)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        try Self.check(status)
        return true
    }

    /// The label of the item kept under `service` and `account`, or `nil` where there is none.
    func label(service: String, account: String) throws -> String? {
        if let backend { return try backend.label(service: service, account: account) }
        guard let found = try attributes(service: service, account: account) else { return nil }
        return found[kSecAttrLabel as String] as? String ?? ""
    }

    /// Deletes the item only while it still carries `label`, so it never deletes one another process put
    /// there since.
    func delete(label: String, service: String, account: String) throws {
        if let backend { return try backend.delete(label: label, service: service, account: account) }
        var query = try searching(service: service, account: account)
        query[kSecAttrLabel] = label
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try Self.check(status) }
    }

    /// Changes the item's label from `from` to `to`, only while it still carries `from`.
    ///
    /// Answers whether it did: `false` when the item is gone or carries another label.
    func relabel(from: String, to: String, service: String, account: String) throws -> Bool {
        if let backend { return try backend.relabel(from: from, to: to, service: service, account: account) }
        var query = try searching(service: service, account: account)
        query[kSecAttrLabel] = from
        let status = SecItemUpdate(query as CFDictionary, [kSecAttrLabel: to] as CFDictionary)
        if status == errSecItemNotFound { return false }
        try Self.check(status)
        return true
    }

    private func attributes(service: String, account: String?) throws -> [String: Any]? {
        var query = try searching(service: service, account: account)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        try Self.check(status)
        return found as? [String: Any] ?? [:]
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

/// What a ``Keychain`` keeps its items in when it is not the Security framework: the operations the package
/// makes of the framework, which a test stands in for.
package protocol KeychainBackend: Sendable {
    func data(service: String, account: String) throws -> Data?
    func put(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
    /// With no `account`, whether any account holds an item under `service`.
    func holds(service: String, account: String?) throws -> Bool
    func add(label: String, service: String, account: String) throws -> Bool
    func label(service: String, account: String) throws -> String?
    func delete(label: String, service: String, account: String) throws
    func relabel(from: String, to: String, service: String, account: String) throws -> Bool
}
