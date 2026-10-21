import AuthenticationServices
import Foundation

/// Signs an app in to one Marfa server, with the owner's approval, and keeps the sign-in in the keychain.
///
/// The app registers with the server as a native client the first time it signs in, for the grant that
/// sign-in uses, and the registration is kept with the tokens. It registers again after it signs out or the
/// sign-in ends, and when it signs in another way than the kept registration allows.
/// Sign in with a browser through ``signIn(presentingFrom:prefersEphemeralWebBrowserSession:)`` or
/// ``signIn(using:)``, or, without a browser, through ``startDeviceSignIn()``. Then open a copy with
/// ``Server/init(url:credential:)``: the copy renews the access token with the kept refresh token whenever the
/// server refuses it.
///
/// A refresh token can be spent once, so renewals of one sign-in run one at a time: across every copy and
/// ``Folders`` in the process, and across processes that share the keychain, such as an app and its extensions
/// using one ``Keychain/init(accessGroup:)``. A renewal that finds the token already renewed uses the new one
/// without asking the server.
public struct Authorization: Sendable {
    /// How the app introduces itself to the server.
    public struct Client: Sendable, Hashable {
        /// The name the approval page shows the owner.
        public var name: String
        /// Where the browser returns the approval, or `nil` for an app that signs in only through the device grant.
        ///
        /// A private-use URI whose scheme is a reverse domain name the app's developer controls, with a path and
        /// no host, such as `com.example.notes:/signed-in`. The app claims the scheme in its `CFBundleURLTypes`.
        public var redirect: URL?
        /// The scopes the app asks for, such as `core.note:read` and `core.note:write`. `offline_access` is
        /// added, so the server issues a refresh token.
        public var scopes: [String]

        public init(name: String, redirect: URL? = nil, scopes: [String]) {
            self.name = name
            self.redirect = redirect
            self.scopes = scopes
        }

        var scope: String {
            var asked: [String] = []
            for scope in scopes + ["offline_access"] where !asked.contains(scope) { asked.append(scope) }
            return asked.joined(separator: " ")
        }
    }

    /// The server's origin.
    public let server: URL
    public let client: Client
    let place: SignInPlace
    let transport: SignInTransport

    /// Signs in to the server at `server`, keeping the sign-in in `keychain` under `service`, with the
    /// server's origin as the account.
    ///
    /// Choose a `service` of the app's own, such as its bundle identifier, so no other app's items share it.
    ///
    /// Throws ``SignInError/notAServer`` when `server` is not an `http` or `https` address with a host.
    public init(server: URL, client: Client, keychain: Keychain = .system, service: String) throws(SignInError) {
        try self.init(server: server, client: client, keychain: keychain, service: service, transport: .standard)
    }

    init(server: URL, client: Client, keychain: Keychain, service: String, transport: SignInTransport)
        throws(SignInError)
    {
        guard let origin = origin(of: server), let url = URL(string: origin) else { throw .notAServer }
        self.server = url
        self.client = client
        place = SignInPlace(keychain: keychain, service: service, account: origin)
        self.transport = transport
    }

    /// The sign-in kept for the server, or `nil` when the app has not signed in, signed out, or the sign-in
    /// ended.
    public func credential() throws -> Credential? {
        try place.read().map { Credential(place: place, kept: $0, transport: transport) }
    }

    /// Signs in through the system's web authentication session, which shows the server's sign-in and
    /// approval pages over `anchor`.
    ///
    /// Throws ``SignInError/canceled`` when the person closes the browser, ``SignInError/denied`` when they
    /// decline, ``SignInError/stateMismatch`` when the browser returns an approval this sign-in did not
    /// ask for, ``SignInError/noRedirect`` when the client names no redirect, and
    /// ``SignInError/unavailable(message:)`` when another process sharing the keychain holds the sign-in too
    /// long to keep the approval, after which the approved grant is revoked at the server.
    @MainActor
    public func signIn(
        presentingFrom anchor: ASPresentationAnchor, prefersEphemeralWebBrowserSession: Bool = false
    ) async throws -> Credential {
        try await signIn { url, scheme in
            try await WebSession.present(
                url, scheme: scheme, anchor: anchor, ephemeral: prefersEphemeralWebBrowserSession)
        }
    }

    /// The authorization code flow with PKCE (RFC 7636) and `state`, with `browser` showing the
    /// authorization address and answering the address the server returned to.
    func signIn(
        browser: @MainActor @Sendable (_ authorize: URL, _ scheme: String) async throws -> URL
    ) async throws -> Credential {
        guard let redirect = client.redirect, let scheme = redirect.scheme else { throw SignInError.noRedirect }
        let discovery = try await Discovery.read(place.account, transport)
        let registered = try await registration(discovery, for: "authorization_code")
        let clientId = registered.clientId
        let proof = ProofKey()
        let state = randomText()
        guard var authorize = URLComponents(string: discovery.authorizationEndpoint) else {
            throw SignInError.unreadable(message: "\(discovery.authorizationEndpoint) is not an address")
        }
        authorize.queryItems =
            (authorize.queryItems ?? []) + [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: clientId),
                URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
                URLQueryItem(name: "scope", value: client.scope),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: proof.challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
        // A form reads `+` as a space, and `URLComponents` leaves it as it is.
        authorize.percentEncodedQuery = authorize.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let address = authorize.url else {
            throw SignInError.unreadable(message: "\(discovery.authorizationEndpoint) is not an address")
        }
        let returned = try await browser(address, scheme)
        let answer = URLComponents(url: returned, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { answer.first { $0.name == name }?.value }
        // Nothing else in the answer is read before its state is: an answer to another request may carry a
        // code an attacker holds.
        guard value("state") == state else { throw SignInError.stateMismatch }
        if let error = value("error") {
            if error == "access_denied" { throw SignInError.denied }
            throw SignInError.refused(code: error, message: value("error_description") ?? error)
        }
        guard let code = value("code"), !code.isEmpty else {
            throw SignInError.unreadable(message: "the approval returned no code")
        }
        let exchanged = try await send(
            try formRequest(
                discovery.tokenEndpoint,
                [
                    ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect.absoluteString),
                    ("client_id", clientId), ("code_verifier", proof.verifier),
                ]), transport)
        guard exchanged.status == 200 else { throw exchanged.refusal() }
        return try await keep(TokenAnswer.read(exchanged), registered: registered, discovery: discovery)
    }

    /// Starts the device grant (RFC 8628), for an app that cannot show a browser: show the person
    /// ``DeviceSignIn/userCode`` and ``DeviceSignIn/verificationURL``, then wait on
    /// ``DeviceSignIn/credential()``.
    public func startDeviceSignIn() async throws -> DeviceSignIn {
        let discovery = try await Discovery.read(place.account, transport)
        let registered = try await registration(discovery, for: deviceCodeGrant)
        let started = try await send(
            try formRequest(
                discovery.deviceAuthorizationEndpoint,
                [("client_id", registered.clientId), ("scope", client.scope)]),
            transport)
        guard started.status == 200 else { throw started.refusal() }
        guard let object = started.object, let deviceCode = object["device_code"] as? String,
            let userCode = object["user_code"] as? String,
            let verification = (object["verification_uri"] as? String).flatMap(URL.init(string:)),
            let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue
        else { throw SignInError.unreadable(message: "the device code answer is not one this package reads") }
        let complete = (object["verification_uri_complete"] as? String).flatMap(URL.init(string:))
        for page in [verification, complete].compactMap(\.self) where origin(of: page) != place.account {
            throw SignInError.unreadable(message: "\(place.account) sends the person to \(page), off its own address")
        }
        let interval = max(1, (object["interval"] as? NSNumber)?.intValue ?? 5)
        return DeviceSignIn(
            userCode: userCode, verificationURL: verification, verificationURLComplete: complete,
            expiresAt: transport.now().addingTimeInterval(expiresIn),
            polling: DeviceSignIn.Polling(
                authorization: self, discovery: discovery, registered: registered, deviceCode: deviceCode,
                interval: .seconds(interval)))
    }

    /// Ends the sign-in: deletes its tokens and registration from the keychain, then revokes the refresh
    /// token at the server, which ends the app's grant there.
    ///
    /// Answers whether the server confirmed the revocation. The keychain no longer holds the sign-in either
    /// way; on `false`, the grant stands at the server until the owner revokes it. Throws
    /// ``SignInError/unavailable(message:)``, changing nothing, when another process sharing the keychain
    /// holds the sign-in too long.
    @discardableResult
    public func signOut() async throws -> Bool {
        let place = place
        let transport = transport
        let kept = try await background {
            try place.exclusively(transport) { () throws -> KeptSignIn? in
                let kept = try place.read()
                try place.drop()
                return kept
            }
        }
        guard let kept else { return false }
        return await revoke(kept)
    }

    /// Revokes the sign-in at the server, and answers whether the server confirmed it.
    ///
    /// Revoking the refresh token ends the app's grant there; a sign-in with none revokes its access token.
    private func revoke(_ kept: KeptSignIn) async -> Bool {
        guard let revocation = kept.revocationEndpoint else { return false }
        let (token, hint) =
            kept.refreshToken.map { ($0, "refresh_token") } ?? (kept.accessToken, "access_token")
        do {
            let answer = try await send(
                try formRequest(
                    revocation, [("token", token), ("token_type_hint", hint), ("client_id", kept.clientId)]),
                transport)
            return answer.status == 200
        } catch {
            return false
        }
    }

    /// The client registered for this server that may use `grant`.
    ///
    /// The kept one while a sign-in holds it and it was registered for `grant`, so a grant names it, and a
    /// new one otherwise. A registration nothing has approved can be removed by the server, so one is never
    /// kept apart from a sign-in. Each registration names only the grant its flow uses, because the server
    /// tells the owner what kind of app it approved from the grants the app registered.
    private func registration(_ discovery: Discovery, for grant: String) async throws -> Registered {
        let place = place
        let redirect = grant == "authorization_code" ? client.redirect?.absoluteString : nil
        if let kept = try await background({ try place.read() }), kept.grantTypes.contains(grant),
            kept.redirect == redirect
        {
            return Registered(clientId: kept.clientId, grantTypes: kept.grantTypes, redirect: kept.redirect)
        }
        let grantTypes = [grant, "refresh_token"]
        var metadata: [String: Any] = [
            "client_name": client.name,
            "application_type": "native",
            "token_endpoint_auth_method": "none",
            "scope": client.scope,
            "grant_types": grantTypes,
            "response_types": redirect == nil ? [String]() : ["code"],
        ]
        if let redirect { metadata["redirect_uris"] = [redirect] }
        guard let at = URL(string: discovery.registrationEndpoint) else {
            throw SignInError.unreadable(message: "\(discovery.registrationEndpoint) is not an address")
        }
        var request = URLRequest(url: at)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        let answer = try await send(request, transport)
        guard answer.status == 201 || answer.status == 200 else { throw answer.refusal() }
        guard let clientId = answer.object?["client_id"] as? String, !clientId.isEmpty else {
            throw SignInError.unreadable(message: "the registration answered no client_id")
        }
        return Registered(clientId: clientId, grantTypes: grantTypes, redirect: redirect)
    }

    /// A client registered for one sign-in flow.
    struct Registered: Sendable {
        let clientId: String
        let grantTypes: [String]
        let redirect: String?
    }

    fileprivate func keep(_ token: TokenAnswer, registered: Registered, discovery: Discovery) async throws
        -> Credential
    {
        let kept = KeptSignIn(
            clientId: registered.clientId, grantTypes: registered.grantTypes, redirect: registered.redirect,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken, scope: token.scope ?? client.scope,
            tokenEndpoint: discovery.tokenEndpoint, revocationEndpoint: discovery.revocationEndpoint)
        let place = place
        let transport = transport
        do {
            try await background { try place.exclusively(transport) { try place.keep(kept) } }
        } catch {
            // The person approved a grant the app cannot use; ending it keeps it from standing at the server.
            _ = await revoke(kept)
            throw error
        }
        return Credential(place: place, kept: kept, transport: transport)
    }
}

/// A device grant waiting for the person to approve it on another device.
public struct DeviceSignIn: Sendable {
    /// The code the person types on the approval page.
    public let userCode: String
    /// The approval page, where the person signs in and types ``userCode``.
    public let verificationURL: URL
    /// The approval page with ``userCode`` filled in, for a QR code or a link, where the server gives one.
    public let verificationURLComplete: URL?
    /// When the code expires, and ``credential()`` throws ``SignInError/expired``.
    public let expiresAt: Date

    struct Polling: Sendable {
        let authorization: Authorization
        let discovery: Discovery
        let registered: Authorization.Registered
        let deviceCode: String
        let interval: Duration
    }

    let polling: Polling

    /// Asks the server at the interval it gives until the person decides, slowing by 5 seconds each time
    /// the server says `slow_down`, and keeps the sign-in once they approve.
    ///
    /// When the server cannot be reached or fails with a 5xx status, it doubles the interval and keeps
    /// asking, as RFC 8628 section 3.5 recommends, until the code expires.
    ///
    /// Throws ``SignInError/denied`` when the person declines, ``SignInError/expired`` once the code
    /// expires, and ``SignInError/unavailable(message:)`` when another process sharing the keychain holds
    /// the sign-in too long to keep the approval, after which the approved grant is revoked at the server.
    /// Cancel the task to stop waiting; it throws `CancellationError`.
    public func credential() async throws -> Credential {
        let transport = polling.authorization.transport
        var interval = polling.interval
        var pause = interval
        while true {
            let remaining = expiresAt.timeIntervalSince(transport.now())
            if remaining <= 0 { throw SignInError.expired }
            try await transport.sleep(min(pause, .milliseconds(Int64(remaining * 1000))))
            pause = interval
            let answer: Answer
            do {
                answer = try await send(
                    try formRequest(
                        polling.discovery.tokenEndpoint,
                        [
                            ("grant_type", deviceCodeGrant), ("device_code", polling.deviceCode),
                            ("client_id", polling.registered.clientId),
                        ]), transport)
            } catch .canceled {
                throw CancellationError()
            } catch .unavailable {
                interval *= 2
                pause = interval
                continue
            }
            if answer.status == 200 {
                return try await polling.authorization.keep(
                    TokenAnswer.read(answer), registered: polling.registered, discovery: polling.discovery)
            }
            switch (answer.status, answer.code) {
            case (_, "authorization_pending"): continue
            case (_, "slow_down"):
                interval += .seconds(5)
                pause = interval
            case (429, _): pause = max(interval, answer.retryAfter ?? .zero)
            case (_, "access_denied"): throw SignInError.denied
            case (_, "expired_token"): throw SignInError.expired
            case (500..., _):
                interval *= 2
                pause = interval
            default: throw answer.refusal()
            }
        }
    }
}

/// A sign-in kept in the keychain, which a ``Server`` sends and renews.
public struct Credential: Sendable, Hashable, CustomStringConvertible {
    /// The origin of the server the sign-in is for.
    public let server: URL
    /// The scopes the owner approved, which may be fewer than the app asked for.
    public let scopes: [String]
    let place: SignInPlace
    let transport: SignInTransport

    init(place: SignInPlace, kept: KeptSignIn, transport: SignInTransport) {
        server = URL(string: place.account) ?? URL(filePath: "/")
        scopes = (kept.scope ?? "").split(separator: " ").map(String.init)
        self.place = place
        self.transport = transport
    }

    /// The access token kept now, which a renewal may have replaced since the credential was made.
    func accessToken() throws -> String? { try place.read()?.accessToken }

    public static func == (lhs: Credential, rhs: Credential) -> Bool { lhs.place == rhs.place }
    public func hash(into hasher: inout Hasher) { hasher.combine(place) }

    /// Never shows a token.
    public var description: String { "Credential(\(server.absoluteString))" }
}

/// Why a sign-in did not finish.
///
/// None repeats a token.
public enum SignInError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The person closed the browser before deciding.
    case canceled
    /// The person declined to approve the app.
    case denied
    /// The device code expired before the person decided.
    case expired
    /// The browser returned an approval whose `state` is not the one this sign-in sent, so it is refused.
    case stateMismatch
    /// The keychain holds no sign-in for the server.
    case notSignedIn
    /// The address is not an `http` or `https` address with a host, so it names no server to sign in to.
    case notAServer
    /// The address is on another server than the one the sign-in is for.
    case otherServer
    /// A browser sign-in needs ``Authorization/Client/redirect``, an address with a scheme, and the client
    /// names none.
    case noRedirect
    /// The server refused, with the OAuth error `code`.
    case refused(code: String, message: String)
    /// The server could not be reached.
    case unavailable(message: String)
    /// The server answered something this package cannot use, or named another server as the one that signs
    /// in to it.
    case unreadable(message: String)

    public var description: String {
        switch self {
        case .canceled: "The sign-in was canceled."
        case .denied: "The app was not approved."
        case .expired: "The code expired before the app was approved."
        case .stateMismatch: "The approval was not for this sign-in."
        case .notSignedIn: "The app is not signed in to this server."
        case .notAServer: "The address is not an http or https server address."
        case .otherServer: "The sign-in is for another server."
        case .noRedirect: "The app names no redirect address for a browser sign-in."
        case .refused(let code, let message): "The server refused the sign-in (\(code)): \(message)"
        case .unavailable(let message), .unreadable(let message): message
        }
    }
}

/// Presents one `ASWebAuthenticationSession` and keeps it, and its presentation context, alive until it
/// answers.
@MainActor
private final class WebSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?

    private init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor }
    }

    static func present(_ url: URL, scheme: String, anchor: ASPresentationAnchor, ephemeral: Bool) async throws
        -> URL
    {
        let context = WebSession(anchor: anchor)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                let started = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { returned, error in
                    if let returned {
                        continuation.resume(returning: returned)
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(throwing: SignInError.canceled)
                    } else {
                        continuation.resume(throwing: error ?? SignInError.canceled)
                    }
                }
                started.presentationContextProvider = context
                started.prefersEphemeralWebBrowserSession = ephemeral
                context.session = started
                if !started.start() {
                    continuation.resume(throwing: SignInError.unavailable(message: "The browser could not open."))
                }
            }
        } onCancel: {
            Task { @MainActor in context.session?.cancel() }
        }
    }
}
