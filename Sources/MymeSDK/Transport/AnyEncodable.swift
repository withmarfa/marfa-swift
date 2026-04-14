import Foundation

/// Type-erased `Encodable & Sendable` value used by transport mocks and
/// internals to pass arbitrary bodies through the encoding pipeline.
///
/// `package` access so `MymeSDKTestSupport` can reuse it without
/// `@testable import`.
package struct AnyEncodable: Encodable, Sendable {
    private let _encode: @Sendable (Encoder) throws -> Void

    package init(_ value: any Encodable & Sendable) {
        _encode = value.encode
    }

    package func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

/// Placeholder for endpoints that return no meaningful body (DELETE, etc.).
///
/// `package` access so test-support can enqueue void responses.
package struct EmptyResponse: Codable, Sendable {
    package init() {}
}
