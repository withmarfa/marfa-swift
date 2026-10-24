import Foundation
import HTTPTypes
import Marfa
@_spi(Generated) import OpenAPIRuntime

/// Sends what the generated client asks for, and throws every failure as a ``MarfaError``.
struct Sender: Sendable {
    private let universal: UniversalClient
    private let origin: String

    var converter: Converter { universal.converter }

    init(
        serverURL: URL, configuration: Configuration, transport: any ClientTransport,
        middlewares: [any ClientMiddleware]
    ) {
        universal = UniversalClient(
            serverURL: serverURL, configuration: configuration, transport: transport, middlewares: middlewares)
        origin = Marfa.origin(of: serverURL) ?? serverURL.absoluteString
    }

    func send<Input: Sendable, Output: Sendable>(
        input: Input,
        forOperation operationID: String,
        serializer: @Sendable (Input) throws -> (HTTPRequest, HTTPBody?),
        deserializer: @Sendable (HTTPResponse, HTTPBody?) async throws -> Output
    ) async throws(MarfaError) -> Output {
        do {
            return try await universal.send(
                input: input, forOperation: operationID, serializer: serializer, deserializer: deserializer)
        } catch let error as ClientError {
            if let known = failure(error.underlyingError, origin: origin) { throw known }
            if error.response == nil {
                throw .invalid(message: "the request to \(origin) could not be made: \(error.causeDescription)")
            }
            throw .decoding(message: "\(origin) answered \(operationID) in a form this build cannot read")
        } catch {
            throw failure(error, origin: origin) ?? .invalid(message: "\(operationID) failed: \(error)")
        }
    }
}
