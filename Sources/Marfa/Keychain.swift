import Foundation
import Security

/// Keys kept as generic passwords: in the system's keychain, or in a keychain file of a test's own.
public struct Keychain: Sendable {
    /// The Keychain refused, with its own status.
    public struct Failure: Error, Hashable {
        public let status: OSStatus
    }

    /// The keychain a person's keys live in: on macOS the login keychain, or whichever the user made the
    /// default.
    public static let system = Keychain(location: .system)

    private enum Location {
        case system
        #if os(macOS)
        case file(URL, password: String)
        #endif
    }

    private let location: Location

    #if os(macOS)
    /// A new keychain file in a folder of its own, for a test to keep keys in.
    ///
    /// It is not in the user's search list, so a search that names no keychain never finds it, and only calls
    /// through this value name it. Every call unlocks it with its own password first, so a keychain that
    /// locked itself meanwhile is never unlocked by asking a person. `discard` removes it.
    ///
    /// Refuses keychain prompts for the whole process, the system keychain's included, since a test must never
    /// wait on a person: a call that would ask one fails instead.
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

    /// The keychain file this value reads and writes, or nothing for the system's keychain.
    public var file: URL? {
        if case .file(let file, _) = location { file } else { nil }
    }

    /// Deletes an isolated keychain and its folder, the folder even where the keychain would not go.
    ///
    /// The system's keychain is never deleted.
    public func discard() throws {
        guard case .file(let file, _) = location else { return }
        let deleted = Result { try Self.check(SecKeychainDelete(try opened())) }
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        try deleted.get()
    }

    /// The keychain file, opened by its path and unlocked with its own password.
    ///
    /// Opened for each call rather than held, so the value stays `Sendable` without holding a reference the
    /// compiler cannot check.
    private func opened() throws -> SecKeychain {
        guard case .file(let file, let password) = location else { throw Failure(status: errSecNoSuchKeychain) }
        var keychain: SecKeychain?
        try Self.check(SecKeychainOpen(file.path, &keychain))
        guard let keychain else { throw Failure(status: errSecNoSuchKeychain) }
        try Self.check(SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true))
        return keychain
    }
    #endif

    /// Keeps `key`, replacing any key already kept under the same names.
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

    /// The key kept under these names, or nothing where none is.
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

    /// Whether a key is kept under `service`, for `account`, or for any account where none is named.
    ///
    /// Asks for the item's attributes and never its secret, which is what the Keychain guards, so asking never
    /// waits on a person.
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

    /// A query that reaches this keychain alone.
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
