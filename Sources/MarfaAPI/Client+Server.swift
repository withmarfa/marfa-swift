public import Foundation
public import Marfa
@_exported public import MarfaTypes
import OpenAPIRuntime
import OpenAPIURLSession

extension Client {
    /// A client for `server`, which sends its key, or its credential's access token.
    ///
    /// For a server made from a credential, a refused access token is renewed once and the call sent again; once
    /// the server ends the sign-in, calls throw ``MarfaError/signedOut(origin:message:)``. A call never follows a
    /// redirect, so the credential reaches no other server, and waits up to 30 seconds for each answer.
    public init(_ server: Server) {
        self.init(server, through: nil, timeout: .seconds(30))
    }

    /// `base` stands in for the session a request would otherwise go through, for a test to script it.
    init(_ server: Server, through base: URLSession?, timeout: Duration) {
        let connection = Connection(base: base ?? server.signInSession, timeout: timeout)
        self.init(
            serverURL: server.url,
            transport: URLSessionTransport(configuration: .init(session: connection.session)),
            middlewares: [Access(server: server, connection: connection)])
    }
}
