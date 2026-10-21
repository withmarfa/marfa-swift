import Foundation
import Security

@testable import Marfa

/// A new keychain file outside the user's search list, removed when `body` ends.
///
/// Turns off keychain prompts for the whole test process, the login keychain's included, and never turns
/// them back on: a call that would ask a person fails instead.
func inIsolatedKeychain(_ body: (Keychain, URL) throws -> Void) throws {
    let isolated = try IsolatedKeychain()
    defer { isolated.remove() }
    try body(isolated.keychain, isolated.file)
}

/// As `inIsolatedKeychain(_:)`, for a body that awaits.
func inIsolatedKeychainAsync(_ body: (Keychain, URL) async throws -> Void) async throws {
    let isolated = try IsolatedKeychain()
    defer { isolated.remove() }
    try await body(isolated.keychain, isolated.file)
}

private struct IsolatedKeychain {
    let folder: URL
    let file: URL
    let created: SecKeychain
    let keychain: Keychain

    init() throws {
        SecKeychainSetUserInteractionAllowed(false)
        var allowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&allowed)
        precondition(!allowed.boolValue, "a keychain call in this process could wait on a person")

        folder = FileManager.default.temporaryDirectory.appending(path: "marfa-keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "keys.keychain-db")
        self.file = file
        let password = UUID().uuidString

        var created: SecKeychain?
        let status = SecKeychainCreate(file.path, UInt32(password.utf8.count), password, false, nil, &created)
        guard status == errSecSuccess, let created else {
            try? FileManager.default.removeItem(at: folder)
            throw Keychain.Failure(status: status)
        }
        self.created = created

        // Opened for each call rather than held, so the closure stays `Sendable` without a reference the
        // compiler cannot check. Unlocked with its own password, so a keychain that locked itself is never
        // unlocked by asking a person.
        keychain = Keychain { query, forNewItem in
            var opened: SecKeychain?
            try check(SecKeychainOpen(file.path, &opened))
            guard let opened else { throw Keychain.Failure(status: errSecNoSuchKeychain) }
            try check(SecKeychainUnlock(opened, UInt32(password.utf8.count), password, true))
            if forNewItem {
                query[kSecUseKeychain] = opened
            } else {
                query[kSecMatchSearchList] = [opened]
            }
        }
    }

    func remove() {
        SecKeychainDelete(created)
        try? FileManager.default.removeItem(at: folder)
    }
}

private func check(_ status: OSStatus) throws {
    if status != errSecSuccess { throw Keychain.Failure(status: status) }
}
