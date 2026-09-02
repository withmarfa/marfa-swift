import Testing
import Foundation
@testable import MarfaSDK

@Suite("Error parsing")
struct ErrorParsingTests {

    @Test("400 with structured body → ValidationError")
    func validationError() {
        let body = #"{"error":{"code":"validation_error","status":400,"message":"Missing field: title"}}"#
        let error = parseMarfaError(data: Data(body.utf8), statusCode: 400)

        #expect(error is ValidationError)
        #expect(error.status == 400)
        #expect(error.code == "validation_error")
        #expect(error.message == "Missing field: title")
    }

    @Test("400 carrying a distinct code keeps it rather than being flattened")
    func validationErrorKeepsADistinctCode() {
        // Most 400s are the generic validation failure, but some carry their
        // whole meaning in the code. `bulk_atomic_rollback` is the one that
        // forced this: it says a page was rolled back and puts the entry and
        // the reason in `details`, so a caller reading `validation_error`
        // cannot tell it from any other bad request.
        let body = #"{"error":{"code":"bulk_atomic_rollback","status":400,"message":"Bulk upsert rolled back on item 1","details":{"index":1,"code":"invalid_type"}}}"#
        let error = parseMarfaError(data: Data(body.utf8), statusCode: 400)

        #expect(error is ValidationError)
        #expect(error.status == 400)
        #expect(error.code == "bulk_atomic_rollback")
        #expect(error.details?["code"] == .string("invalid_type"))
        // Still permanent: the status decides that, and nothing here moved it.
        #expect(error.isPermanent)
    }

    @Test("400 with no code of its own still reads as validation_error")
    func validationErrorDefaultsWhenNoCodeIsSent() {
        // The body a caller gets when the server sent no structured error at
        // all. The default has to survive, or every unstructured 400 starts
        // reporting an empty code.
        let error = parseMarfaError(data: Data("not json".utf8), statusCode: 400)

        #expect(error is ValidationError)
        #expect(error.code == "validation_error")
    }

    @Test("401 → UnauthorizedError")
    func unauthorized() {
        let body = #"{"error":{"code":"unauthorized","message":"Invalid token"}}"#
        let error = parseMarfaError(data: Data(body.utf8), statusCode: 401)

        #expect(error is UnauthorizedError)
        #expect(error.status == 401)
        #expect(error.message == "Invalid token")
    }

    @Test("403 → ForbiddenError")
    func forbidden() {
        let body = #"{"error":{"code":"forbidden","message":"Admin only"}}"#
        let error = parseMarfaError(data: Data(body.utf8), statusCode: 403)

        #expect(error is ForbiddenError)
        #expect(error.status == 403)
        #expect(error.message == "Admin only")
    }

    @Test("404 → NotFoundError")
    func notFound() {
        let body = #"{"error":{"code":"not_found","message":"Item missing"}}"#
        let error = parseMarfaError(data: Data(body.utf8), statusCode: 404)

        #expect(error is NotFoundError)
        #expect(error.status == 404)
        #expect(error.message == "Item missing")
    }

    @Test("422 with code version_bump_mismatch → SchemaVersionMismatchError")
    func versionBumpMismatch() {
        let body = #"{"error":{"code":"version_bump_mismatch","status":422,"message":"minor bump required for additive change"}}"#
        let error = parseMarfaError(data: Data(body.utf8), statusCode: 422)

        #expect(error is SchemaVersionMismatchError)
        #expect(error.status == 422)
        #expect(error.code == "version_bump_mismatch")
        #expect(error.isPermanent)
    }

    @Test("5xx → base MarfaError with correct status")
    func serverError() {
        let body = #"{"error":{"code":"internal","message":"Database down"}}"#
        let error = parseMarfaError(data: Data(body.utf8), statusCode: 503)

        #expect(type(of: error) == MarfaError.self)
        #expect(error.status == 503)
        #expect(error.code == "server_error")
        #expect(error.message == "Database down")
    }

    @Test("Malformed JSON body falls back to raw UTF-8 message")
    func malformedBody() {
        let body = "Internal Server Error"
        let error = parseMarfaError(data: Data(body.utf8), statusCode: 500)

        #expect(error.status == 500)
        #expect(error.message == "Internal Server Error")
    }

    @Test("Empty body produces 'Unknown error' message")
    func emptyBody() {
        let error = parseMarfaError(data: Data(), statusCode: 502)

        #expect(error.status == 502)
        #expect(error.message == "Unknown error")
    }

    @Test("Structured body falls back to code when message absent")
    func noMessageField() {
        let body = #"{"error":{"code":"rate_limited"}}"#
        let error = parseMarfaError(data: Data(body.utf8), statusCode: 429)

        #expect(error.status == 429)
        #expect(error.message == "rate_limited")
    }

    @Test("Details field passed through from APIErrorResponse")
    func detailsPassthrough() {
        let body = #"{"error":{"code":"validation_error","message":"Invalid","details":{"field":"title"}}}"#
        let error = parseMarfaError(data: Data(body.utf8), statusCode: 400)

        #expect(error.details?["field"] == .string("title"))
    }
}
