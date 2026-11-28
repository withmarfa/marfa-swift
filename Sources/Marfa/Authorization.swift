import AuthenticationServices
import Foundation
import Synchronization

/// Signs an app in to one Marfa server, with the owner's approval, and keeps the sign-in in the keychain.
///
/// Each sign-in registers the app with the server as a native client for the grant it uses, and keeps the
/// registration with the tokens. A server never sees a client it did not register, so a sign-in after the server
/// was reset, restored or replaced works as the first one did. Only a confirmation sign-in, which ``Server``
/// starts when the server asks the owner to sign in again before an action, reuses the kept registration, since
/// it confirms the grant that registration holds.
///
/// Signing in again replaces the sign-in kept for the server and then ends the grant it held there, as
/// ``signOut()`` does, so each sign-in leaves one grant standing. A confirmation shares the grant of the
/// sign-in it confirms, so only the replaced access token is revoked. ``Credential/replacedGrantStands`` says
/// when the server did not confirm the replaced grant ended.
///
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
        ///
        /// ``init(name:redirect:scopes:permissions:)`` adds the instance permissions it names. A profile scope such
        /// as `profile.username:write`, which lets the app change the owner's username, is a scope like any other,
        /// so it belongs here.
        public var scopes: [String]

        /// - Parameter permissions: What the app asks for to look after the instance, which the owner's approval
        ///   page then shows as a switch each. They are added to `scopes`, and the owner may approve fewer: ask the
        ///   ``Credential`` with ``Credential/grants(_:)``.
        public init(
            name: String, redirect: URL? = nil, scopes: [String], permissions: [InstancePermission] = []
        ) {
            self.name = name
            self.redirect = redirect
            self.scopes = scopes + permissions.map(\.rawValue)
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
    /// Throws ``SignInError/notAServer`` when `server` is not an `http` or `https` address with a host, or holds a
    /// user or a password.
    public init(server: URL, client: Client, keychain: Keychain = .system, service: String) throws(SignInError) {
        try self.init(server: server, client: client, keychain: keychain, service: service, transport: .standard)
    }

    /// The sign-in the keychain holds for `place`, to sign in again with the registration it kept.
    init(server: URL, client: Client, place: SignInPlace, transport: SignInTransport) {
        self.server = server
        self.client = client
        self.place = place
        self.transport = transport
    }

    init(server: URL, client: Client, keychain: Keychain, service: String, transport: SignInTransport)
        throws(SignInError)
    {
        guard server.user() == nil, server.password() == nil, let origin = origin(of: server),
            let url = URL(string: origin)
        else { throw .notAServer }
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
    /// Once the sign-in is kept, it ends the grant of the sign-in it replaced, and the credential's
    /// ``Credential/replacedGrantStands`` says whether that grant still stands.
    ///
    /// Throws ``SignInError/canceled`` when the person closes the browser, ``SignInError/denied`` when they
    /// decline, ``SignInError/stateMismatch`` when the browser returns an approval this sign-in did not
    /// ask for, ``SignInError/issuerMismatch`` when the approval names another issuer than the server's,
    /// ``SignInError/noRedirect`` when the client names no redirect, and
    /// ``SignInError/heldElsewhere`` when another process sharing the keychain holds the sign-in too long to
    /// keep the approval. When the approval cannot be kept, for that or a keychain error, it asks the server to
    /// revoke it: by its refresh token, which ends its grant, or by its access token alone when it is a
    /// confirmation and the sign-in kept for the server shares, or may share, that grant. The error does not say
    /// whether the server confirmed it.
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
    ///
    /// `maxAge` asks the server to sign the person in again when they signed in longer ago than that many seconds,
    /// as the server's `insufficient_user_authentication` challenge names it (RFC 9470).
    func signIn(
        maxAge: UInt64? = nil,
        browser: @MainActor @Sendable (_ authorize: URL, _ scheme: String) async throws -> URL
    ) async throws -> Credential {
        guard let redirect = client.redirect, let scheme = redirect.scheme else { throw SignInError.noRedirect }
        let discovery = try await Discovery.read(place.account, transport)
        let registered = try await registration(discovery, for: "authorization_code", reusing: maxAge != nil)
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
            ] + (maxAge.map { [URLQueryItem(name: "max_age", value: String($0))] } ?? [])
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
        // The `iss` check covers a refusal too: a refusal from another server is not this server's answer.
        guard discovery.accepts(issuer: value("iss")) else { throw SignInError.issuerMismatch }
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
        let registered = try await registration(discovery, for: deviceCodeGrant, reusing: false)
        let started = try await send(
            try formRequest(
                discovery.deviceAuthorizationEndpoint,
                [("client_id", registered.clientId), ("scope", client.scope)]),
            transport)
        guard started.status == 200 else { throw started.refusal() }
        guard let object = started.object, let deviceCode = object["device_code"] as? String,
            let userCode = object["user_code"] as? String,
            let verification = (object["verification_uri"] as? String).flatMap(URL.init(string:)),
            let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue,
            expiresIn.isFinite, expiresIn >= 0, expiresIn <= DeviceSignIn.longestWait
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
    /// The keychain no longer holds the sign-in whatever the answer is. A server whose revocation address moved
    /// is asked again at the address its metadata names now, and one that holds no grant for the app's client
    /// counts as having ended it. A renewal of the sign-in under way, in this process or another, is waited for
    /// first, so the refresh token revoked is the newest one. A sign-in marked uncertain (a renewal cut off with
    /// no answer, or answered with tokens that could not be read) is revoked too, but the outcome is
    /// ``SignOutOutcome/notConfirmed`` whatever the server answers, because it may hold a rotated grant that no
    /// refresh token kept here names.
    ///
    /// Throws ``SignInError/heldElsewhere``, changing nothing, when another process sharing the keychain holds the
    /// sign-in too long.
    @discardableResult
    public func signOut() async throws -> SignOutOutcome {
        let place = place
        let transport = transport
        let kept = try await background {
            try place.exclusively(transport) { () throws -> KeptSignIn? in
                let kept = try place.read()
                try place.drop()
                return kept
            }
        }
        guard let kept else { return .nothingKept }
        // The server answers 200 to a revoked refresh token it has already rotated, so where a renewal may have
        // been answered with one that was lost, the answer proves nothing about the grant.
        let confirmed = await revoke(kept)
        return confirmed && !kept.uncertain ? .endedAtServer : .notConfirmed
    }

    /// Revokes the sign-in at the server, and answers whether the server confirmed that its grant ended.
    ///
    /// Revoking the refresh token ends the app's grant, with every token of its client, other sign-ins on the
    /// client included. With `endingGrant` off, or for a sign-in with no refresh token, only the access token
    /// is revoked, and the grant stands. A server that refuses the client as unknown holds no grant for it, so
    /// that counts as ended either way.
    ///
    /// A revocation address answered 404 or 410 with no OAuth error is read again from the server's metadata,
    /// and asked once at the address it names now, when that differs.
    private func revoke(_ kept: KeptSignIn, endingGrant: Bool = true) async -> Bool {
        guard let stored = kept.revocationEndpoint else { return false }
        let refreshToken = endingGrant ? kept.refreshToken : nil
        let (token, hint) = refreshToken.map { ($0, "refresh_token") } ?? (kept.accessToken, "access_token")
        let transport = transport
        func ask(_ endpoint: String) async -> Answer? {
            guard
                let request = try? formRequest(
                    endpoint, [("token", token), ("token_type_hint", hint), ("client_id", kept.clientId)])
            else { return nil }
            return try? await send(request, transport)
        }
        guard var answer = await ask(stored) else { return false }
        if (answer.status == 404 || answer.status == 410) && answer.oauthError == nil {
            guard let advertised = try? await Discovery.read(place.account, transport),
                let endpoint = advertised.revocationEndpoint, endpoint != stored,
                let again = await ask(endpoint)
            else { return false }
            answer = again
        }
        if answer.oauthError == "invalid_client" { return true }
        return refreshToken != nil && answer.status == 200
    }

    /// The client registered for this server that may use `grant`.
    ///
    /// A new one, unless `reusing` and a kept sign-in holds one registered for `grant`: only a confirmation
    /// reuses a registration, because the server that confirms the sign-in is the one that holds it, and any
    /// other sign-in cannot know that the server still has the kept client. A registration nothing has approved
    /// can be removed by the server, so one is never kept apart from a sign-in. Each registration names only the
    /// grant its flow uses, because the server tells the owner what kind of app it approved from the grants the
    /// app registered.
    private func registration(_ discovery: Discovery, for grant: String, reusing: Bool) async throws -> Registered {
        let place = place
        let redirect = grant == "authorization_code" ? client.redirect?.absoluteString : nil
        if reusing, let kept = try await background({ try place.read() }), kept.grantTypes.contains(grant),
            kept.redirect == redirect
        {
            return Registered(
                clientId: kept.clientId, grantTypes: kept.grantTypes, redirect: kept.redirect, reused: true)
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
        return Registered(clientId: clientId, grantTypes: grantTypes, redirect: redirect, reused: false)
    }

    /// A client registered for one sign-in flow.
    struct Registered: Sendable {
        let clientId: String
        let grantTypes: [String]
        let redirect: String?
        /// Whether it is the kept sign-in's registration, which a confirmation reuses and whose grant the sign-in
        /// it replaces may hold, rather than one registered for this sign-in alone.
        let reused: Bool
    }

    /// Whether a new sign-in may still be canceled, or is being written.
    private enum Admission { case open, canceled, admitted }

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
        // The tokens are in hand, and a cancel from here until the write is admitted changes nothing kept. The
        // write is admitted under the lock the cancellation takes, and made outside it, so a cancel never waits on
        // the keychain; a cancel after the admission is too late, and the sign-in stands.
        let admission = Mutex(Admission.open)
        let replaced: KeptSignIn?
        do {
            replaced = try await withTaskCancellationHandler {
                try await background {
                    try place.exclusively(transport) { () throws -> KeptSignIn? in
                        let replaced = try place.read()
                        let admitted = admission.withLock { admission in
                            guard admission == .open else { return false }
                            admission = .admitted
                            return true
                        }
                        guard admitted else { throw CancellationError() }
                        try place.keep(kept)
                        return replaced
                    }
                }
            } onCancel: {
                admission.withLock { admission in
                    if admission == .open { admission = .canceled }
                }
            }
        } catch {
            // The person approved a grant the app cannot use; ending it keeps it from standing at the server,
            // unless the sign-in kept now, or one the keychain cannot read, may share it on a reused client.
            var shared = false
            if registered.reused {
                do {
                    shared = try await background { try place.read() }?.clientId == kept.clientId
                } catch {
                    shared = true
                }
            }
            // A canceled task cannot send, so the revocation runs in a task that is not canceled with it.
            let authorization = self
            _ = await Task.detached { await authorization.revoke(kept, endingGrant: !shared) }.value
            throw error
        }
        var replacedGrantStands = false
        if let replaced {
            // Revoking the refresh token of a sign-in on the same client would end the new sign-in's grant too.
            let shared = replaced.clientId == kept.clientId
            let ended = await revoke(replaced, endingGrant: !shared)
            // A replaced sign-in whose refresh request got no answer may have been rotated at the server, which
            // ignores the revocation of a rotated token and still confirms it.
            replacedGrantStands = !shared && (!ended || replaced.uncertain)
        }
        return Credential(place: place, kept: kept, transport: transport, replacedGrantStands: replacedGrantStands)
    }
}

/// What ``Authorization/signOut()`` found.
public enum SignOutOutcome: Sendable, Hashable {
    /// The server confirmed that the grant ended.
    case endedAtServer
    /// The keychain held no sign-in.
    case nothingKept
    /// The sign-in is deleted here, but the server did not confirm that the grant ended, or a renewal that was
    /// cut off with no answer may have left it holding a grant the revocation did not name.
    case notConfirmed
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

    /// The longest a device code may be given to last, in seconds, which keeps every conversion of it in range.
    static let longestWait: Double = 24 * 60 * 60

    /// Asks the server at the interval it gives until the person decides, slowing by 5 seconds each time
    /// the server says `slow_down`, and keeps the sign-in once they approve.
    ///
    /// When the server cannot be reached or fails with a 5xx status, it doubles the interval and keeps
    /// asking, as RFC 8628 section 3.5 recommends, until the code expires.
    ///
    /// Once the sign-in is kept, it ends the grant of the sign-in it replaced, and the credential's
    /// ``Credential/replacedGrantStands`` says whether that grant still stands.
    ///
    /// Throws ``SignInError/denied`` when the person declines, ``SignInError/expired`` once the code
    /// expires, and ``SignInError/heldElsewhere`` when another process sharing the keychain holds the sign-in
    /// too long to keep the approval. When the approval cannot be kept, for that or a keychain error, it asks
    /// the server to revoke it by its refresh token, which ends its grant. The error does not say whether the
    /// server confirmed it.
    /// Cancel the task to stop waiting; it throws `CancellationError`.
    public func credential() async throws -> Credential {
        let transport = polling.authorization.transport
        var interval = polling.interval
        var pause = interval
        while true {
            let remaining = expiresAt.timeIntervalSince(transport.now())
            if remaining <= 0 { throw SignInError.expired }
            try await transport.sleep(min(pause, .milliseconds(Int64(min(remaining, Self.longestWait) * 1000))))
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
    /// The client ID the server registered for this sign-in, which the server reports as the maker of the records
    /// an app makes, such as a webhook's `maker.id`.
    ///
    /// A renewal and a confirmation keep it. Signing in again registers a new client, so the new credential's ID
    /// differs from the one it replaced, and records made under the old sign-in still carry the old ID. It
    /// is read when the credential is made, so a credential held across another sign-in keeps the ID it was
    /// made with. It identifies the client and is not a secret.
    public let clientID: String
    /// Whether the grant of the sign-in this one replaced still stands at the server.
    ///
    /// `true` only on a credential a sign-in returned, when it replaced a sign-in kept for the server on
    /// another registered client and the server did not confirm that the replaced grant ended, such as when
    /// it could not be reached. The new sign-in is kept either way. The replaced grant stands until the owner
    /// revokes it, so an app can tell the person to remove it from the server's connected apps.
    public let replacedGrantStands: Bool
    let place: SignInPlace
    let transport: SignInTransport

    init(place: SignInPlace, kept: KeptSignIn, transport: SignInTransport, replacedGrantStands: Bool = false) {
        server = URL(string: place.account) ?? URL(filePath: "/")
        scopes = (kept.scope ?? "").split(separator: " ").map(String.init)
        clientID = kept.clientId
        self.replacedGrantStands = replacedGrantStands
        self.place = place
        self.transport = transport
    }

    /// The access token kept now, which a renewal may have replaced since the credential was made.
    func accessToken() throws -> String? { try place.read()?.accessToken }

    /// Whether the owner approved `permission` for this sign-in.
    ///
    /// The owner may approve fewer permissions than the app asked for, so check before offering a control that
    /// needs one. This reads the approval kept with the credential; the server decides each call.
    public func grants(_ permission: InstancePermission) -> Bool { scopes.contains(permission.rawValue) }

    /// The sign-in that signs the owner in again with the registration this credential kept.
    ///
    /// Throws ``SignInError/noRedirect`` for a sign-in made with the device grant, which has no browser to return to,
    /// and ``SignInError/notSignedIn`` once the keychain no longer holds the sign-in.
    func reauthorization() throws -> Authorization {
        guard let kept = try place.read() else { throw SignInError.notSignedIn }
        guard let redirect = kept.redirect.flatMap(URL.init(string:)) else { throw SignInError.noRedirect }
        let scopes = (kept.scope ?? "").split(separator: " ").map(String.init)
        return Authorization(
            server: server, client: .init(name: "", redirect: redirect, scopes: scopes), place: place,
            transport: transport)
    }

    public static func == (lhs: Credential, rhs: Credential) -> Bool { lhs.place == rhs.place }
    public func hash(into hasher: inout Hasher) { hasher.combine(place) }

    /// Never shows a token.
    public var description: String { "Credential(\(server.absoluteString))" }
}

/// One of the fourteen instance permissions an app can ask for, by the name the server gives it.
///
/// The server's `connectors.host` is not here: only a connector host's own key holds it, and a sign-in that asks for it
/// is refused.
///
/// A permission opens the operations it names and no item; what an app reads and writes is the type, edge and
/// profile scopes it asks for. Ask for permissions in ``Authorization/Client/init(name:redirect:scopes:permissions:)``.
/// The approval page shows the owner a switch for each, and the owner may approve fewer.
public enum InstancePermission: String, Sendable, Hashable, CaseIterable {
    /// Reads the audit log.
    case auditRead = "audit.read"
    /// Lists, makes and restores backups, and adopts a backup folder.
    case backupsManage = "backups.manage"
    /// Manages blob bytes and copies across the instance, without reaching any item's content.
    case blobsManage = "blobs.manage"
    /// Reads and changes the instance's settings, and checks a change of address.
    case configManage = "config.manage"
    /// Reads and administers connector registrations, their runs and their endpoints, deletes registrations and
    /// clears a registration's retained state.
    case connectorsManage = "connectors.manage"
    /// Lists, narrows and revokes other apps' access.
    case grantsManage = "grants.manage"
    /// Updates the server, runs housekeeping, cancels bulk jobs and confirms the clock.
    case instanceMaintain = "instance.maintain"
    /// Reads the server's health, update status, what needs attention, metrics and housekeeping status.
    case instanceRead = "instance.read"
    /// Lists and empties the trash and purges trashed items.
    case itemsPurge = "items.purge"
    /// Lists and revokes every key, changes their metadata and narrows their access.
    case keysManage = "keys.manage"
    /// Makes keys within the app's own access, and lists, changes and revokes the keys within that access.
    case keysMint = "keys.mint"
    /// Removes and replaces type and edge type definitions the app's maps allow it to write.
    case schemaWrite = "schema.write"
    /// Lists, renames and ends the owner's sign-ins and passkeys, and gets the link that adds a passkey.
    case signInsManage = "sign_ins.manage"
    /// Reads, registers, changes and removes the outbound subscriptions that send the instance's events out.
    case webhooksManage = "webhooks.manage"
}

/// Why a sign-in did not finish.
///
/// None repeats a token.
public enum SignInError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Why the request for sign-in metadata failed.
    public enum DiscoveryTransportReason: Sendable, Hashable, CustomStringConvertible {
        /// The server name could not be resolved.
        case dnsFailure
        /// The connection failed or the request timed out.
        case connectionFailed
        /// The server certificate failed trust evaluation.
        case untrustedCertificate

        public var description: String {
            switch self {
            case .dnsFailure: "The server name could not be resolved."
            case .connectionFailed: "The server could not be contacted."
            case .untrustedCertificate: "The server certificate could not be trusted."
            }
        }
    }

    /// The person closed the browser before deciding.
    case canceled
    /// The person declined to approve the app.
    case denied
    /// The device code expired before the person decided.
    case expired
    /// The browser returned an approval whose `state` is not the one this sign-in sent, so it is refused.
    case stateMismatch
    /// The browser returned an approval whose `iss` is not the issuer the server named, or has none although the
    /// server says it sends one, so it is refused (RFC 9207).
    case issuerMismatch
    /// The keychain holds no sign-in for the server.
    case notSignedIn
    /// The address is not an `http` or `https` address with a host, or it holds a user or a password, so it names
    /// no server to sign in to.
    case notAServer
    /// The address is on another server than the one the sign-in is for.
    case otherServer
    /// A browser sign-in needs ``Authorization/Client/redirect``, an address with a scheme, and the client
    /// names none.
    case noRedirect
    /// The server refused, with the OAuth error `code`.
    case refused(code: String, message: String)
    /// A recognized transport failure while reading the server's sign-in metadata.
    case discoveryTransport(reason: DiscoveryTransportReason)
    /// The server could not be reached, or the browser could not open.
    case unavailable(message: String)
    /// Another process sharing the keychain, such as an app extension, held the sign-in too long, so the
    /// keychain was left as it was.
    case heldElsewhere
    /// The server answered something this package cannot use, or named another server as the one that signs
    /// in to it.
    case unreadable(message: String)

    public var description: String {
        switch self {
        case .canceled: "The sign-in was canceled."
        case .denied: "The app was not approved."
        case .expired: "The code expired before the app was approved."
        case .stateMismatch: "The approval was not for this sign-in."
        case .issuerMismatch: "The approval did not come from the server this sign-in is for."
        case .notSignedIn: "The app is not signed in to this server."
        case .notAServer: "The address is not an http or https server address."
        case .otherServer: "The sign-in is for another server."
        case .noRedirect: "The app names no redirect address for a browser sign-in."
        case .heldElsewhere: "Another process is using the sign-in."
        case .refused(let code, let message): "The server refused the sign-in (\(code)): \(message)"
        case .discoveryTransport(let reason): reason.description
        case .unavailable(let message), .unreadable(let message): message
        }
    }
}

/// A browser session that shows a sign-in page and answers once.
@MainActor
protocol BrowserSession: AnyObject {
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: BrowserSession {}

/// Presents one `ASWebAuthenticationSession` and keeps it, and its presentation context, alive until it
/// answers.
@MainActor
final class WebSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Makes the session for an address, answering through `completion` on whichever queue it likes.
    ///
    /// `completion` is `Sendable` so it does not inherit main-actor isolation. The system calls it on a queue
    /// of its own, where a main-actor closure stops the app.
    typealias Maker =
        @MainActor (
            _ url: URL, _ scheme: String, _ ephemeral: Bool, _ context: WebSession,
            _ completion: @escaping @Sendable (URL?, (any Error)?) -> Void
        ) -> any BrowserSession

    private let anchor: ASPresentationAnchor
    private var session: (any BrowserSession)?

    private init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor }
    }

    /// The system's session, which gives its context the presentation anchor.
    static let system: Maker = { url, scheme, ephemeral, context, completion in
        let session = ASWebAuthenticationSession(
            url: url, callback: .customScheme(scheme), completionHandler: completion)
        session.presentationContextProvider = context
        session.prefersEphemeralWebBrowserSession = ephemeral
        return session
    }

    /// The one answer a sign-in's continuation takes.
    ///
    /// Whoever gives it first counts: the session's completion handler, a browser that cannot open, or the
    /// cancellation of the task. Any later one is ignored.
    ///
    /// Not isolated to an actor, because the system calls the completion handler on a queue of its own, where a
    /// main-actor closure stops the app.
    final class Answer: Sendable {
        private enum State {
            case waiting
            case taken(CheckedContinuation<URL, any Error>)
            case given(Result<URL, any Error>)
            case done
        }

        private let state = Mutex(State.waiting)

        /// Takes the continuation, resuming it at once with an answer given before it existed.
        func take(_ continuation: CheckedContinuation<URL, any Error>) {
            let early: Result<URL, any Error>? = state.withLock { state in
                if case .given(let result) = state {
                    state = .done
                    return result
                }
                state = .taken(continuation)
                return nil
            }
            if let early { continuation.resume(with: early) }
        }

        func resume(returning url: URL) { give(.success(url)) }
        func resume(throwing error: any Error) { give(.failure(error)) }

        private func give(_ result: Result<URL, any Error>) {
            let taken: CheckedContinuation<URL, any Error>? = state.withLock { state in
                switch state {
                case .waiting:
                    state = .given(result)
                    return nil
                case .taken(let continuation):
                    state = .done
                    return continuation
                case .given, .done:
                    return nil
                }
            }
            taken?.resume(with: result)
        }

        /// What the system's session calls with its answer.
        var completion: @Sendable (URL?, (any Error)?) -> Void {
            { returned, error in
                if let returned {
                    self.resume(returning: returned)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    self.resume(throwing: SignInError.canceled)
                } else {
                    self.resume(throwing: error ?? SignInError.canceled)
                }
            }
        }
    }

    static func present(
        _ url: URL, scheme: String, anchor: ASPresentationAnchor, ephemeral: Bool, make: Maker = system
    ) async throws -> URL {
        let context = WebSession(anchor: anchor)
        let answer = Answer()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                answer.take(continuation)
                let started = make(url, scheme, ephemeral, context, answer.completion)
                context.session = started
                if !started.start() {
                    answer.resume(throwing: SignInError.unavailable(message: "The browser could not open."))
                }
            }
        } onCancel: {
            // The system does not promise that a canceled session calls its completion handler, so the
            // cancellation answers for it, and a handler that comes later finds the answer already given.
            answer.resume(throwing: SignInError.canceled)
            Task { @MainActor in context.session?.cancel() }
        }
    }
}
