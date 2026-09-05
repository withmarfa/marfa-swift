import Foundation

/// Parses a non-2xx HTTP response body into a typed `MarfaError` subclass.
///
/// Decoding attempts the structured `APIErrorResponse` envelope first and
/// falls back to the raw UTF-8 body otherwise. Dispatch primarily uses
/// the HTTP status code, but the parsed `code` field can promote a
/// generic status into a more specific typed subclass — `version_bump_mismatch`
/// is the current example, surfaced via `SchemaVersionMismatchError`.
func parseMarfaError(
    data: Data,
    statusCode: Int,
    decoder: JSONDecoder = JSONDecoder()
) -> MarfaError {
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
    // A 400 keeps the code the server sent, for the same reason a 409 does:
    // the status says a request was refused and the code says what about it
    // was wrong. `bulk_atomic_rollback` is the case that forced this — it
    // arrives as a 400 whose entire content is the code and the `details`
    // beneath it, and reporting it as `validation_error` left the engine
    // unable to tell a rolled-back page from any other bad request.
    case 400: return ValidationError(code: code ?? "validation_error", message: message, details: details)
    case 401: return UnauthorizedError(message: message, details: details)
    // A 403 keeps its code for the same reason a 400 and a 409 do. It is not
    // decoration: `space_suspended` is the one 403 a queued write must survive,
    // and collapsing every 403 to `forbidden` made it unrecognizable.
    case 403: return ForbiddenError(code: code ?? "forbidden", message: message, details: details)
    case 404: return NotFoundError(message: message, details: details)
    // A 409 reaching here is one the caller could not read as a version
    // conflict: `URLSessionTransport` decodes `ConflictResponse` first and
    // only falls through when the body carries none. What is left is a
    // plain refusal whose whole content is its code — `conflict`,
    // `type_mismatch`, `source_id_conflict` — which is what tells a caller
    // whether the id is somebody else's or the type disagrees. Substituting
    // a generic code here loses the only thing the response said, and the
    // dropped-mutation log stores this code for an app to show.
    case 409: return MarfaError(code: code ?? "conflict", message: message, status: 409, details: details)
    default: return MarfaError(code: "server_error", message: message, status: statusCode, details: details)
    }
}
