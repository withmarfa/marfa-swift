import Foundation

/// Parses a non-2xx HTTP response body into a typed `MymeError` subclass.
///
/// Tries to decode the structured `APIErrorResponse` envelope first; falls
/// back to the raw UTF-8 body as the message if that fails. The HTTP status
/// code is the authoritative dispatch key — only it determines the subclass
/// returned.
func parseMymeError(
    data: Data,
    statusCode: Int,
    decoder: JSONDecoder = JSONDecoder()
) -> MymeError {
    let message: String
    let details: [String: JSONValue]?

    if let apiError = try? decoder.decode(APIErrorResponse.self, from: data) {
        message = apiError.error.message ?? apiError.error.code
        details = apiError.error.details
    } else if !data.isEmpty, let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
        message = raw
        details = nil
    } else {
        message = "Unknown error"
        details = nil
    }

    switch statusCode {
    case 400: return ValidationError(message: message, details: details)
    case 401: return UnauthorizedError(message: message, details: details)
    case 403: return ForbiddenError(message: message, details: details)
    case 404: return NotFoundError(message: message, details: details)
    default: return MymeError(code: "server_error", message: message, status: statusCode, details: details)
    }
}
