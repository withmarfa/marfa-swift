/// HTTP methods used by the Marfa API.
public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
}

extension HTTPMethod {
    /// The methods the server accepts an `Idempotency-Key` on. Internal, so
    /// it adds no public surface, and shared rather than restated: the
    /// keyed transport and the unkeyed convenience overload have to agree
    /// about what a write is, and two copies of that switch would drift.
    static func isWrite(_ method: HTTPMethod) -> Bool {
        switch method {
        case .post, .put, .patch, .delete: return true
        case .get, .head: return false
        }
    }
}
