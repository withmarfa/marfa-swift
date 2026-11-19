import Foundation
package import MarfaCore
import Synchronization

/// Renews a credential's access token when the server refuses it, for the core to call from its own threads.
///
/// Every renewal of one sign-in, in this process or another that shares the keychain, holds the same
/// ``RenewalLease`` from before it reads the refresh token until its request has ended, so one refresh token is
/// sent once: the next to ask finds the token already renewed and returns it without asking the server.
final class TokenRenewer: CredentialRenewer {
    private let credential: Credential

    init(_ credential: Credential) {
        self.credential = credential
    }

    func renew(refused: String) throws -> String {
        // The core asks from its own threads; this blocks on the lease and a request.
        if Thread.isMainThread { throw RenewalError.Failed(message: "a renewal never runs on the main thread") }
        let place = credential.place
        let transport = credential.transport
        let origin = place.account
        let lease: RenewalLease
        do {
            lease = try RenewalLease.take(place, transport)
        } catch is RenewalLease.Held {
            throw RenewalError.Unavailable(message: "another process is renewing the sign-in to \(origin)")
        } catch {
            throw RenewalError.Failed(message: "the keychain could not be read: \(error)")
        }
        let kept: KeptSignIn
        let sent: String
        let request: URLRequest
        do {
            guard let read = try read(place) else {
                throw RenewalError.Ended(message: "the app is not signed in to \(origin)")
            }
            if read.accessToken != refused {
                lease.release()
                return read.accessToken
            }
            guard let refreshToken = read.refreshToken else {
                try? place.drop()
                throw RenewalError.Ended(message: "the sign-in to \(origin) holds no refresh token")
            }
            request = try Self.refresh(at: read.tokenEndpoint, kept: read, sent: refreshToken)
            kept = read
            sent = refreshToken
        } catch {
            lease.release()
            throw error
        }
        return try ask(request, sent: sent, kept: kept, lease: lease, transport: transport)
    }

    /// Sends the renewal and waits for what it settles, for up to the transport's time limit.
    ///
    /// The requests run on after the wait gives up, holding the lease, until they answer or each reaches the
    /// request limit, so an answer that arrives late is still kept and no other renewal sends the same refresh
    /// token meanwhile. Only a request that never answers can leave the refresh token spent.
    ///
    /// A stored token endpoint the server no longer has answers 404 or 410 with no OAuth error. The renewal
    /// then reads the server's metadata again and sends the same request once to the endpoint it names, so a
    /// sign-in kept against an earlier address of the token endpoint still renews. Before that retry it checks
    /// again that it holds the lease and that the kept refresh token is the one it captured, and sends nothing
    /// if not.
    private func ask(
        _ request: URLRequest, sent: String, kept: KeptSignIn, lease: RenewalLease, transport: SignInTransport
    ) throws(RenewalError) -> String {
        let place = credential.place
        let origin = place.account
        let settled = Settled()
        let pending = Pending()
        guard
            let activity = BackgroundActivity.begin(
                "Renewing the sign-in", onExpiry: { pending.expire() })
        else {
            lease.release()
            throw .Unavailable(message: "the app is being suspended, so the sign-in was not renewed")
        }
        let finish: @Sendable (Result<String, RenewalError>) -> Void = { result in
            lease.release()
            settled.set(result)
            activity.end()
        }
        let step: @Sendable (URLRequest, @escaping @Sendable (Result<Answer, RenewalError>) -> Void) -> Void = {
            request, then in
            Self.send(request, transport: transport, pending: pending) { then(Self.received($0, origin: origin)) }
        }
        step(request) { first in
            let answer: Answer
            do throws(RenewalError) { answer = try first.get() } catch {
                finish(.failure(error))
                return
            }
            guard Self.tokenEndpointIsGone(answer) else {
                finish(Self.settle(answer, sent: sent, place: place, lease: lease, advertised: nil))
                return
            }
            guard let discoveryRequest = URL(string: "\(origin)/.well-known/oauth-authorization-server")
            else {
                finish(.failure(.Failed(message: "\(origin) is not an address a sign-in can use")))
                return
            }
            step(URLRequest(url: discoveryRequest)) { read in
                let advertised: Discovery
                let retry: URLRequest
                do throws(RenewalError) {
                    advertised = try Self.advertised(try read.get(), origin: origin)
                    retry = try Self.refresh(at: advertised.tokenEndpoint, kept: kept, sent: sent)
                } catch {
                    finish(.failure(error))
                    return
                }
                // Reading the metadata took time with the lease held, but nothing stops the lease lapsing in that
                // time, so the retry is admitted only while this renewal still holds it and the kept refresh
                // token is still the one it captured. Otherwise another holder has renewed or ended the sign-in.
                let admitted: Bool
                do {
                    admitted = try lease.whileHeld { try place.read()?.refreshToken == sent } ?? false
                } catch {
                    finish(.failure(.Failed(message: "the keychain could not be read: \(error)")))
                    return
                }
                guard admitted else {
                    finish(Self.settledElsewhere(sent: sent, place: place))
                    return
                }
                step(retry) { second in
                    do throws(RenewalError) {
                        let answer = try second.get()
                        finish(Self.settle(answer, sent: sent, place: place, lease: lease, advertised: advertised))
                    } catch { finish(.failure(error)) }
                }
            }
        }
        guard let result = settled.wait(transport.timeLimit) else {
            throw .Unavailable(message: "the server did not answer the renewal in time")
        }
        return try result.get()
    }

    /// Sends a request and calls `done` with its answer.
    ///
    /// The request is cancelled at the request limit or when the system ends the process's time, and one begun
    /// after that ends at once.
    private static func send(
        _ request: URLRequest, transport: SignInTransport, pending: Pending,
        done: @escaping @Sendable (Result<Answer, any Error>) -> Void
    ) {
        let task = transport.dataTask(for: request) { body, response, error in
            if let error {
                done(.failure(error))
            } else if let http = response as? HTTPURLResponse {
                done(.success(Answer(status: http.statusCode, body: body ?? Data(), headers: http.allHeaderFields)))
            } else {
                done(.failure(URLError(.badServerResponse)))
            }
        }
        guard pending.begin(task) else {
            task.cancel()
            done(.failure(URLError(.cancelled)))
            return
        }
        task.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + transport.requestLimit.seconds) { task.cancel() }
    }

    /// The request that renews `kept` with the refresh token `sent`, at `endpoint`.
    private static func refresh(at endpoint: String, kept: KeptSignIn, sent: String) throws(RenewalError)
        -> URLRequest
    {
        do {
            return try formRequest(
                endpoint, [("grant_type", "refresh_token"), ("refresh_token", sent), ("client_id", kept.clientId)])
        } catch {
            throw .Failed(message: error.description)
        }
    }

    /// The answer, or the renewal's failure where the request did not get one.
    private static func received(_ answered: Result<Answer, any Error>, origin: String) -> Result<
        Answer, RenewalError
    > {
        switch answered {
        case .success(let answer): return .success(answer)
        case .failure(let error as URLError) where error.code == .cancelled:
            return .failure(.Unavailable(message: "the server did not answer the renewal in time"))
        case .failure(let error as URLError):
            return .failure(.Unavailable(message: "the server could not be reached: \(error.localizedDescription)"))
        case .failure(let error): return .failure(.Failed(message: "the renewal failed: \(error.localizedDescription)"))
        }
    }

    /// Whether the server answered as one that has no such endpoint, as opposed to refusing the renewal.
    private static func tokenEndpointIsGone(_ answer: Answer) -> Bool {
        (answer.status == 404 || answer.status == 410) && answer.oauthError == nil
    }

    /// The metadata the server advertises now, read from its answer.
    ///
    /// A client error on the metadata read itself, such as a proxy's 403 or 404, does not prove the grant ended,
    /// so it fails the renewal and keeps the sign-in.
    private static func advertised(_ answer: Answer, origin: String) throws(RenewalError) -> Discovery {
        if answer.status == 429 || answer.status >= 500 {
            throw .Unavailable(message: "\(origin) could not give its sign-in metadata now (\(answer.status))")
        }
        do {
            return try Discovery.parse(answer, from: origin)
        } catch {
            throw .Failed(message: "\(origin) gave no sign-in metadata to renew with: \(error)")
        }
    }

    /// What a renewal's answer comes to, and the keychain written to match.
    ///
    /// The kept sign-in is written, or deleted, only while this renewal still holds the lease and the kept
    /// refresh token is still the one it sent. Otherwise, where another holder has written since, the token the
    /// keychain holds now is the answer, and where the keychain still holds the sent refresh token, the renewal
    /// is unavailable rather than answering the token the server refused.
    ///
    /// `advertised` is the metadata a renewal retried with, which its success keeps beside the new tokens. A
    /// retry that is refused with a client error that is no OAuth error ends the sign-in: the server has no
    /// token endpoint to renew it at.
    private static func settle(
        _ answer: Answer, sent: String, place: SignInPlace, lease: RenewalLease, advertised: Discovery?
    ) -> Result<String, RenewalError> {
        let origin = place.account
        switch (answer.status, answer.code) {
        case (200, _):
            guard let token = try? TokenAnswer.read(answer) else {
                return .failure(.Failed(message: "\(origin) answered a renewal this package cannot read"))
            }
            return written(sent: sent, place: place, lease: lease) { current in
                var renewed = current
                renewed.accessToken = token.accessToken
                renewed.refreshToken = token.refreshToken ?? current.refreshToken
                renewed.scope = token.scope ?? current.scope
                if let advertised {
                    renewed.tokenEndpoint = advertised.tokenEndpoint
                    renewed.revocationEndpoint = advertised.revocationEndpoint
                }
                do {
                    try place.keep(renewed)
                } catch {
                    // The server has spent the old refresh token, so the kept one cannot renew again.
                    try? place.drop()
                    return .failure(.Ended(message: "the renewed sign-in to \(origin) could not be kept: \(error)"))
                }
                return .success(renewed.accessToken)
            }
        case (_, "invalid_grant"), (_, "invalid_client"):
            return written(sent: sent, place: place, lease: lease) { _ in
                try? place.drop()
                return .failure(.Ended(message: "\(origin) ended the sign-in: \(answer.message)"))
            }
        case (429, _), (500..., _):
            return .failure(.Unavailable(message: "\(origin) could not renew the sign-in now (\(answer.status))"))
        case (400..<500, _) where advertised != nil && answer.oauthError == nil:
            return written(sent: sent, place: place, lease: lease) { _ in
                try? place.drop()
                return .failure(
                    .Ended(message: "\(origin) has no token endpoint to renew the sign-in at: \(answer.message)"))
            }
        default:
            return .failure(.Failed(message: "\(origin) refused to renew the sign-in: \(answer.message)"))
        }
    }

    private static func written(
        sent: String, place: SignInPlace, lease: RenewalLease,
        _ write: (KeptSignIn) -> Result<String, RenewalError>
    ) -> Result<String, RenewalError> {
        do {
            let decided = try lease.whileHeld { () throws -> Result<String, RenewalError>? in
                // A sign-out in this process does not wait for the lease, so the read and the write that follows
                // it are one step under the place's lock.
                try place.locked {
                    guard let current = try place.read(), current.refreshToken == sent else { return nil }
                    return write(current)
                }
            }
            if let decided = decided ?? nil { return decided }
            return settledElsewhere(sent: sent, place: place)
        } catch {
            return .failure(.Failed(message: "the keychain could not be read: \(error)"))
        }
    }

    /// What a renewal answers when it no longer holds the lease or the kept refresh token is no longer the one
    /// it sent: the token another holder wrote, and nothing sent.
    private static func settledElsewhere(sent: String, place: SignInPlace) -> Result<String, RenewalError> {
        do {
            guard let current = try place.read() else {
                return .failure(.Ended(message: "the app is no longer signed in to \(place.account)"))
            }
            // The lease was lost with the sent refresh token still kept, so nothing renewed the sign-in and its
            // access token is the one the server refused.
            guard current.refreshToken != sent else {
                return .failure(.Unavailable(message: "the renewal of the sign-in to \(place.account) lost its lease"))
            }
            return .success(current.accessToken)
        } catch {
            return .failure(.Failed(message: "the keychain could not be read: \(error)"))
        }
    }

    private func read(_ place: SignInPlace) throws(RenewalError) -> KeptSignIn? {
        do {
            return try place.read()
        } catch {
            throw .Failed(message: "the keychain could not be read: \(error)")
        }
    }
}

/// The request a renewal has in flight, so the system's expiry can cancel it and stop the next from starting.
private final class Pending: Sendable {
    private struct State {
        var task: URLSessionDataTask?
        var expired = false
    }

    private let state = Mutex(State())

    /// Takes `task` as the request in flight, or answers `false` when the process's time has ended.
    func begin(_ task: URLSessionDataTask) -> Bool {
        state.withLock { state in
            guard !state.expired else { return false }
            state.task = task
            return true
        }
    }

    func expire() {
        let task = state.withLock { state in
            state.expired = true
            return state.task
        }
        task?.cancel()
    }
}

/// A renewal's outcome, set once by its request and waited on by the renewal.
private final class Settled: Sendable {
    private let result = Mutex<Result<String, RenewalError>?>(nil)
    private let done = DispatchSemaphore(value: 0)

    func set(_ settled: Result<String, RenewalError>) {
        result.withLock { $0 = settled }
        done.signal()
    }

    func wait(_ limit: Duration) -> Result<String, RenewalError>? {
        guard done.wait(timeout: .now() + limit.seconds) == .success else { return nil }
        return result.withLock { $0 }
    }
}

/// Keeps the process from being suspended while a renewal's request runs, until ``end()``.
///
/// Where the system can suspend an app as soon as it leaves the screen, a request cut off mid-flight leaves
/// the lease to lapse with the refresh token sent, and another process would send it again.
final class BackgroundActivity: Sendable {
    private let ended = DispatchSemaphore(value: 0)

    private init() {}

    /// Answers `nil` when the system will not let the process run on, so the renewal sends nothing.
    /// `onExpiry` runs if the system must suspend the process before ``end()``.
    static func begin(_ reason: String, onExpiry: @escaping @Sendable () -> Void) -> BackgroundActivity? {
        let activity = BackgroundActivity()
        #if os(macOS)
        return activity
        #else
        let started = DispatchSemaphore(value: 0)
        let granted = Mutex<Bool?>(nil)
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
            if !expired {
                granted.withLock { $0 = true }
                started.signal()
                activity.ended.wait()
                return
            }
            let refused = granted.withLock { granted in
                guard granted == nil else { return false }
                granted = false
                return true
            }
            if refused { started.signal() } else { onExpiry() }
        }
        started.wait()
        return granted.withLock { $0 } == true ? activity : nil
        #endif
    }

    func end() {
        ended.signal()
    }
}
