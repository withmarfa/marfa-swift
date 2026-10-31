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
            do {
                request = try formRequest(
                    read.tokenEndpoint,
                    [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", read.clientId)])
            } catch {
                throw RenewalError.Failed(message: error.description)
            }
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
    /// The request runs on after the wait gives up, holding the lease, until it answers or reaches the
    /// request limit, so an answer that arrives late is still kept and no other renewal sends the same refresh
    /// token meanwhile. Only a request that never answers can leave the refresh token spent.
    private func ask(
        _ request: URLRequest, sent: String, kept: KeptSignIn, lease: RenewalLease, transport: SignInTransport
    ) throws(RenewalError) -> String {
        let place = credential.place
        let settled = Settled()
        let pending = Mutex<URLSessionDataTask?>(nil)
        guard
            let activity = BackgroundActivity.begin(
                "Renewing the sign-in", onExpiry: { pending.withLock { $0?.cancel() } })
        else {
            lease.release()
            throw .Unavailable(message: "the app is being suspended, so the sign-in was not renewed")
        }
        let task = transport.session.dataTask(with: request) { body, response, error in
            let answered: Result<Answer, any Error>
            if let error {
                answered = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                answered = .success(
                    Answer(status: http.statusCode, body: body ?? Data(), headers: http.allHeaderFields))
            } else {
                answered = .failure(URLError(.badServerResponse))
            }
            let result = Self.settle(answered, sent: sent, kept: kept, place: place, lease: lease)
            lease.release()
            settled.set(result)
            activity.end()
        }
        pending.withLock { $0 = task }
        task.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + transport.requestLimit.seconds) { task.cancel() }
        guard let result = settled.wait(transport.timeLimit) else {
            throw .Unavailable(message: "the server did not answer the renewal in time")
        }
        return try result.get()
    }

    /// What a renewal's answer comes to, and the keychain written to match.
    ///
    /// The kept sign-in is written, or deleted, only while this renewal still holds the lease and the kept
    /// refresh token is still the one it sent. Otherwise, where another holder has written since, the token the
    /// keychain holds now is the answer, and where the keychain still holds the sent refresh token, the renewal
    /// is unavailable rather than answering the token the server refused.
    private static func settle(
        _ answered: Result<Answer, any Error>, sent: String, kept: KeptSignIn, place: SignInPlace,
        lease: RenewalLease
    ) -> Result<String, RenewalError> {
        let origin = place.account
        let answer: Answer
        switch answered {
        case .success(let received): answer = received
        case .failure(let error as URLError) where error.code == .cancelled:
            return .failure(.Unavailable(message: "the server did not answer the renewal in time"))
        case .failure(let error as URLError):
            return .failure(.Unavailable(message: "the server could not be reached: \(error.localizedDescription)"))
        case .failure(let error): return .failure(.Failed(message: "the renewal failed: \(error.localizedDescription)"))
        }
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
                guard let current = try place.read(), current.refreshToken == sent else { return nil }
                return write(current)
            }
            if let decided = decided ?? nil { return decided }
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
