import Foundation
import MarfaCore
import Synchronization

/// Renews a credential's access token when the server refuses it, for the core to call from its own threads.
///
/// Every renewer for one credential in the process waits on the same lock, and every process that shares the
/// keychain on the same lease, so one refresh token is spent once: the next to ask finds the token already
/// renewed and returns it without asking the server.
final class TokenRenewer: CredentialRenewer {
    private let credential: Credential

    init(_ credential: Credential) {
        self.credential = credential
    }

    func renew(refused: String) throws -> String {
        // The core asks from its own threads; this blocks on a lock, a lease and a request.
        if Thread.isMainThread { throw RenewalError.Failed(message: "a renewal never runs on the main thread") }
        let place = credential.place
        let transport = credential.transport
        let origin = place.account
        do {
            return try place.exclusively(transport) { () throws -> String in
                guard let kept = try read(place) else {
                    throw RenewalError.Ended(message: "the app is not signed in to \(origin)")
                }
                if kept.accessToken != refused { return kept.accessToken }
                guard let refreshToken = kept.refreshToken else {
                    drop(place)
                    throw RenewalError.Ended(message: "the sign-in to \(origin) holds no refresh token")
                }
                let answer = try post(
                    kept.tokenEndpoint,
                    [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", kept.clientId)],
                    transport)
                switch (answer.status, answer.code) {
                case (200, _):
                    break
                case (_, "invalid_grant"), (_, "invalid_client"):
                    drop(place)
                    throw RenewalError.Ended(message: "\(origin) ended the sign-in: \(answer.message)")
                case (429, _), (500..., _):
                    throw RenewalError.Unavailable(
                        message: "\(origin) could not renew the sign-in now (\(answer.status))")
                default:
                    throw RenewalError.Failed(message: "\(origin) refused to renew the sign-in: \(answer.message)")
                }
                guard let token = try? TokenAnswer.read(answer) else {
                    throw RenewalError.Failed(message: "\(origin) answered a renewal this package cannot read")
                }
                var renewed = kept
                renewed.accessToken = token.accessToken
                renewed.refreshToken = token.refreshToken ?? kept.refreshToken
                renewed.scope = token.scope ?? kept.scope
                do {
                    try place.keep(renewed)
                } catch {
                    // The server has spent the old refresh token, so the kept one cannot renew again.
                    drop(place)
                    throw RenewalError.Ended(message: "the renewed sign-in to \(origin) could not be kept: \(error)")
                }
                return renewed.accessToken
            }
        } catch let error as RenewalError {
            throw error
        } catch is SignInPlace.LeaseHeld {
            throw RenewalError.Unavailable(message: "another process is renewing the sign-in to \(origin)")
        } catch {
            throw RenewalError.Failed(message: "the keychain could not be read: \(error)")
        }
    }

    private func read(_ place: SignInPlace) throws(RenewalError) -> KeptSignIn? {
        do {
            return try place.read()
        } catch {
            throw .Failed(message: "the keychain could not be read: \(error)")
        }
    }

    private func drop(_ place: SignInPlace) {
        try? place.drop()
    }

    /// A blocking POST with its own time limit, which is safe here because the core calls off the main thread.
    private func post(_ url: String, _ fields: [(String, String)], _ transport: SignInTransport)
        throws(RenewalError) -> Answer
    {
        let request: URLRequest
        do {
            request = try formRequest(url, fields)
        } catch {
            throw .Failed(message: error.description)
        }
        let answered = Mutex<Result<Answer, any Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        let task = transport.session.dataTask(with: request) { body, response, error in
            let result: Result<Answer, any Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                result = .success(Answer(status: http.statusCode, body: body ?? Data(), headers: http.allHeaderFields))
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            answered.withLock { $0 = result }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + transport.timeLimit.seconds) == .timedOut {
            task.cancel()
            throw .Unavailable(message: "the server did not answer the renewal in time")
        }
        switch answered.withLock({ $0 }) {
        case .success(let answer): return answer
        case .failure(let error as URLError):
            throw .Unavailable(message: "the server could not be reached: \(error.localizedDescription)")
        case .failure(let error): throw .Failed(message: "the renewal failed: \(error.localizedDescription)")
        case nil: throw .Failed(message: "the renewal answered nothing")
        }
    }
}
