#if DEBUG
import Foundation

extension Credential {
    /// The credential for a sign-in kept in `keychain` as an approval would have kept it, for `MarfaTesting`.
    ///
    /// The sign-in is written and read back by the code a real one uses, and renews through `session`.
    package static func keeping(
        accessToken: String, refreshToken: String?, scopes: [String], server: URL, keychain: Keychain, service: String,
        session: URLSession, clientID: String = "marfa-testing"
    ) throws -> Credential {
        let authorization = try Authorization(
            server: server, client: .init(name: "", redirect: nil, scopes: scopes), keychain: keychain,
            service: service, transport: SignInTransport(session: session))
        let account = authorization.place.account
        try authorization.place.keep(
            KeptSignIn(
                clientId: clientID, grantTypes: refreshToken == nil ? [] : ["refresh_token"], redirect: nil,
                accessToken: accessToken, refreshToken: refreshToken, scope: scopes.joined(separator: " "),
                tokenEndpoint: "\(account)/oauth/token", revocationEndpoint: nil))
        guard let credential = try authorization.credential() else { throw SignInError.notSignedIn }
        return credential
    }
}
#endif
