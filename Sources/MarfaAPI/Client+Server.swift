import Foundation
public import Marfa
@_exported public import MarfaTypes
import OpenAPIRuntime
import OpenAPIURLSession

extension Client {
    /// A client for `server`, which sends its key, or its credential's access token.
    ///
    /// For a server made from a credential, a refused access token is renewed once and the call sent again; once
    /// the server ends the sign-in, calls throw ``MarfaError/signedOut(origin:message:)``. A call never follows a
    /// redirect, so the credential reaches no other server.
    ///
    /// `timeout` is how long a call waits for the server to send more: for the answer to start, and again
    /// between the parts of a streamed body, which has no other limit. When it passes, the call throws
    /// ``MarfaError/network(message:)``. Raise it for a call whose answer comes only when its work is done, such
    /// as `runHousekeeping`.
    public init(_ server: Server, timeout: Duration = .seconds(30)) {
        self.init(server, through: nil, timeout: timeout)
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
