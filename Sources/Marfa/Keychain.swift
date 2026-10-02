import Foundation
import Security

/// Keys kept as generic passwords, under a service and account the app chooses.
public struct Keychain: Sendable {
    public struct Failure: Error, Hashable {
        public let status: OSStatus
    }

    /// On macOS, the user's default keychain, usually the login keychain.
    public static let system = Keychain(location: .system)

    private enum Location {
        case system
        #if os(macOS)
        case file(URL, password: String)
        #endif
    }

    private let location: Location

    #if os(macOS)
    /// A new keychain file outside the user's search list, for tests. `discard` removes it.
    ///
    /// Turns off keychain prompts for the whole process, the system keychain's included, and never turns
    /// them back on: a call that would ask a person fails instead.
    public static func isolated() throws -> Keychain {
        SecKeychainSetUserInteractionAllowed(false)
        let folder = FileManager.default.temporaryDirectory.appending(path: "marfa-keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "keys.keychain-db")
        let password = UUID().uuidString
        var created: SecKeychain?
        let status = SecKeychainCreate(file.path, UInt32(password.utf8.count), password, false, nil, &created)
        guard status == errSecSuccess, created != nil else {
            try? FileManager.default.removeItem(at: folder)
            throw Failure(status: status == errSecSuccess ? errSecNoSuchKeychain : status)
        }
        return Keychain(location: .file(file, password: password))
    }

    public var file: URL? {
        if case .file(let file, _) = location { file } else { nil }
    }

    /// Does nothing to the system keychain.
    public func discard() throws {
        guard case .file(let file, _) = location else { return }
        let deleted = Result { try Self.check(SecKeychainDelete(try opened())) }
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        try deleted.get()
    }

    // Opened for each call rather than held, so the value stays `Sendable` without holding a reference the
    // compiler cannot check. Unlocked with its own password, so a keychain that locked itself is never
    // unlocked by asking a person.
    private func opened() throws -> SecKeychain {
        guard case .file(let file, let password) = location else { throw Failure(status: errSecNoSuchKeychain) }
        var keychain: SecKeychain?
        try Self.check(SecKeychainOpen(file.path, &keychain))
        guard let keychain else { throw Failure(status: errSecNoSuchKeychain) }
        try Self.check(SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true))
        return keychain
    }
    #endif

    public func save(key: String, service: String, account: String) throws {
        let status = SecItemUpdate(
            try searching(service: service, account: account) as CFDictionary,
            [kSecValueData: Data(key.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.item(service: service, account: account)
            item[kSecValueData] = Data(key.utf8)
            #if os(macOS)
            if case .file = location { item[kSecUseKeychain] = try opened() }
            #endif
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
        #if os(macOS)
        if case .file = location { query[kSecMatchSearchList] = [try opened()] }
        #endif
        return query
    }

    private static func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw Failure(status: status) }
    }
}
