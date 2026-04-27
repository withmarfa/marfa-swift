import Foundation

/// Parses a non-2xx HTTP response body into a typed `MymeError` subclass.
///
/// Decoding attempts the structured `APIErrorResponse` envelope first and
/// falls back to the raw UTF-8 body otherwise. Dispatch primarily uses
/// the HTTP status code, but the parsed `code` field can promote a
/// generic status into a more specific typed subclass — `version_bump_mismatch`
/// is the current example, surfaced via `SchemaVersionMismatchError`.
func parseMymeError(
    data: Data,
    statusCode: Int,
    decoder: JSONDecoder = JSONDecoder()
) -> MymeError {
    let message: String
    let details: [String: JSONValue]?
    let code: String?

    if let apiError = try? decoder.decode(APIErrorResponse.self, from: data) {
        message = apiError.error.message ?? apiError.error.code
        details = apiError.error.details
        code = apiError.error.code
    } else if !data.isEmpty, let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
        message = raw
        details = nil
        code = nil
    } else {
        message = "Unknown error"
        details = nil
        code = nil
    }

    if code == "version_bump_mismatch" {
        return SchemaVersionMismatchError(message: message, details: details)
    }

    switch statusCode {
    case 400: return ValidationError(message: message, details: details)
    case 401: return UnauthorizedError(message: message, details: details)
    case 403: return ForbiddenError(message: message, details: details)
    case 404: return NotFoundError(message: message, details: details)
    default: return MymeError(code: "server_error", message: message, status: statusCode, details: details)
    }
}
