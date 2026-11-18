import AuthenticationServices
import Foundation
import ObjectiveC
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

/// The system's completion handler as the Objective-C runtime holds it.
private typealias SystemCompletion = @convention(block) (NSURL?, NSError?) -> Void

/// Holds the system's completion handler, which the runtime gives out as a value that is not `Sendable`.
private final class HeldCompletion: @unchecked Sendable {
    let call: SystemCompletion
    init(_ call: @escaping SystemCompletion) { self.call = call }
}

// Serialized because one test replaces methods of `ASWebAuthenticationSession` for as long as it runs.
@Suite(.timeLimit(.minutes(1)), .serialized)
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

    /// Crosses the Objective-C boundary the system's session calls back over.
    ///
    /// It runs the real `WebSession.system` and the real `ASWebAuthenticationSession` initializer, with `start`
    /// replaced so that no browser opens, and calls the completion handler the system was given from a queue of
    /// its own. A handler that is a main-actor closure stops the process at that call (signal 5), so a
    /// regression shows as the test run dying, not as one failed expectation.
    @Test func theCompletionHandlerTheSystemIsGivenRunsOnAnyQueue() async throws {
        let held = Mutex<HeldCompletion?>(nil)
        let initializer = NSSelectorFromString("initWithURL:callback:completionHandler:")
        let initialize = try #require(class_getInstanceMethod(ASWebAuthenticationSession.self, initializer))
        let start = try #require(
            class_getInstanceMethod(ASWebAuthenticationSession.self, NSSelectorFromString("start")))
        let originalInitialize = method_getImplementation(initialize)
        typealias Initialize = @convention(c) (AnyObject, Selector, NSURL, AnyObject, SystemCompletion) -> AnyObject
        let callOriginal = unsafeBitCast(originalInitialize, to: Initialize.self)
        let interceptInitialize:
            @convention(block) (AnyObject, NSURL, AnyObject, @escaping SystemCompletion) -> AnyObject =
                { receiver, url, callback, completion in
                    held.withLock { $0 = HeldCompletion(completion) }
                    return callOriginal(receiver, initializer, url, callback, completion)
                }
        let answerFromAnotherQueue: @convention(block) (AnyObject) -> Bool = { _ in
            let completion = held.withLock { $0! }
            DispatchQueue.global().async {
                completion.call(NSURL(string: "so.marfa.tests:/signed-in?code=abc&state=xyz"), nil)
            }
            return true
        }
        let initializeHook = imp_implementationWithBlock(interceptInitialize)
        let startHook = imp_implementationWithBlock(answerFromAnotherQueue)
        method_setImplementation(initialize, initializeHook)
        let originalStart = method_setImplementation(start, startHook)
        defer {
            method_setImplementation(initialize, originalInitialize)
            method_setImplementation(start, originalStart)
            imp_removeBlock(initializeHook)
            imp_removeBlock(startHook)
        }
        #expect(
            try await WebSession.present(address, scheme: "so.marfa.tests", anchor: anchor(), ephemeral: true)
                == returned)
    }
}
