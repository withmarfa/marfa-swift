import Foundation

/// Cursor-based paginated result wrapper from the Myme API.
///
/// Hand-written because the OpenAPI spec inlines this shape per endpoint
/// rather than exposing it as a named component — codegen cannot produce a
/// generic from the inlined occurrences. Consumers use concrete
/// instantiations (`PaginatedResult<Item>`, `PaginatedResult<AuditEntry>`,
/// etc.) at call sites.
public struct PaginatedResult<T: Sendable>: Sendable {
    public let data: [T]
    public let cursor: String?
    public let hasMore: Bool

    public init(data: [T], cursor: String? = nil, hasMore: Bool) {
        self.data = data
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

/// Codable conformance lights up only when the element is itself Codable
/// — wire decoding (`Item`, `AuditEntry`, etc.) goes through here, while
/// in-memory results of typed-wrapper namespaces (`Connection`,
/// `Activity`, …) can use the same envelope without forcing a synthetic
/// Codable conformance on every domain model.
extension PaginatedResult: Codable where T: Codable {
    enum CodingKeys: String, CodingKey {
        case data, cursor
        case hasMore = "has_more"
    }
}
