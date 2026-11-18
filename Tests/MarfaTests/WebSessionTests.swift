import AuthenticationServices
import Foundation
import Synchronization
import Testing

@testable import Marfa

/// A browser session that answers from a queue of its own, as the system's does.
@MainActor
private final class QueueSession: BrowserSession {
    enum Answer: Sendable {
        case returned(URL)
        case failed(String)
        case canceled
        case refusesToStart
    }

    private let completion: @Sendable (URL?, (any Error)?) -> Void
    private let answer: Answer
    private let queue = DispatchQueue(label: "so.marfa.tests.browser-session")

    init(answer: Answer, completion: @escaping @Sendable (URL?, (any Error)?) -> Void) {
        self.answer = answer
        self.completion = completion
    }

    func start() -> Bool {
        if case .refusesToStart = answer { return false }
        if case .canceled = answer { return true }
        reply(answer)
        return true
    }

    func cancel() {
        reply(.canceled)
    }

    private func reply(_ answer: Answer) {
        let completion = completion
        queue.async {
            switch answer {
            case .returned(let url): completion(url, nil)
            case .failed(let message): completion(nil, URLError(.badServerResponse, userInfo: ["why": message]))
            case .canceled: completion(nil, ASWebAuthenticationSessionError(.canceledLogin))
            case .refusesToStart: break
            }
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct WebSessionTests {
    private let address = URL(string: "https://marfa.example.com/oauth/authorize")!
    private let returned = URL(string: "so.marfa.tests:/signed-in?code=abc&state=xyz")!

    private func anchor() -> ASPresentationAnchor {
        #if canImport(AppKit)
        NSWindow()
        #else
        UIWindow()
        #endif
    }

    private func present(
        _ answer: QueueSession.Answer, _ anchor: ASPresentationAnchor
    ) async throws -> URL {
        try await WebSession.present(
            address, scheme: "so.marfa.tests", anchor: anchor, ephemeral: true,
            make: { _, _, _, _, completion in QueueSession(answer: answer, completion: completion) })
    }

    @Test func anApprovalTheSystemAnswersOnAQueueOfItsOwnReachesTheSignIn() async throws {
        #expect(try await present(.returned(returned), anchor()) == returned)
    }

    @Test func anErrorTheSessionAnswersWithReachesTheSignIn() async throws {
        await #expect {
            try await present(.failed("scripted"), anchor())
        } throws: { error in
            (error as? URLError)?.code == .badServerResponse
        }
    }

    @Test func aSessionThatCannotOpenSaysSo() async throws {
        await #expect {
            try await present(.refusesToStart, anchor())
        } throws: { error in
            guard case SignInError.unavailable = error else { return false }
            return true
        }
    }

    @Test func cancellingTheTaskCancelsTheSessionAndTheSignInIsCanceled() async throws {
        let task = Task { @MainActor in try await present(.canceled, anchor()) }
        // The session answers only once it is canceled, so the task is waiting on it.
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect {
            try await task.value
        } throws: { error in
            guard case SignInError.canceled = error else { return false }
            return true
        }
    }

    @Test func theSessionIsGivenThePresentationAnchorOfTheCall() async throws {
        let window = anchor()
        let given = Mutex<ASPresentationAnchor?>(nil)
        _ = try await WebSession.present(
            address, scheme: "so.marfa.tests", anchor: window, ephemeral: false,
            make: { url, scheme, _, context, completion in
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { _, _ in }
                given.withLock { $0 = context.presentationAnchor(for: session) }
                return QueueSession(answer: .returned(returned), completion: completion)
            })
        #expect(given.withLock { $0 } === window)
    }
}
