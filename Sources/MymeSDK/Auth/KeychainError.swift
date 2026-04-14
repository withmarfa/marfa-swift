import Foundation

/// Typed errors surfaced by ``KeychainStorage``.
public enum KeychainError: Error, Equatable, Sendable {
    /// Underlying Security framework call failed with the given OSStatus.
    case osStatus(OSStatus)

    /// A stored item was retrieved but could not be decoded as UTF-8.
    case decodingFailed

    /// Security framework returned unexpected shape (no Data, no CFTypeRef).
    case unexpected(String)
}

extension KeychainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            return "Keychain error (OSStatus \(status))"
        case .decodingFailed:
            return "Keychain value could not be decoded as UTF-8"
        case .unexpected(let message):
            return "Keychain error: \(message)"
        }
    }
}
