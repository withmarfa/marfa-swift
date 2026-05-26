import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("MockTransport (test-support)")
struct MockTransportTests {

    @Test("enqueueEvents produces a stream that yields those events")
    func eventStreamEnqueue() async throws {
        let mock = MockTransport()
        mock.enqueueEvents([
            SSEEvent(id: "1", event: "item.created", data: "{\"id\":\"a\"}"),
            SSEEvent(id: "2", event: "item.updated", data: "{\"id\":\"b\"}"),
        ])

        var received: [SSEEvent] = []
        for try await event in mock.eventStream(path: "/events", query: nil, lastEventID: nil) {
            received.append(event)
        }

        #expect(received.count == 2)
        #expect(received[0].id == "1")
        #expect(received[1].event == "item.updated")
    }

    @Test("Without enqueueEvents, stream closes immediately")
    func emptyStreamCloses() async throws {
        let mock = MockTransport()
        var count = 0
        for try await _ in mock.eventStream(path: "/events", query: nil, lastEventID: nil) {
            count += 1
        }
        #expect(count == 0)
    }

    @Test("enqueueError surfaces on next request")
    func errorPropagates() async throws {
        let mock = MockTransport()
        mock.enqueueError(UnauthorizedError(message: "no key"))

        let config = ClientConfiguration(url: URL(string: "http://t")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)

        await #expect(throws: UnauthorizedError.self) {
            _ = try await client.items.get(id: "x")
        }
    }

    @Test("calls accessor is concurrent-safe")
    func concurrentCallsAccess() async throws {
        let mock = MockTransport()
        for _ in 0..<5 { mock.enqueueRaw(data: Data("{}".utf8)) }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try? await mock.rawRequest(
                        method: .get, path: "/x", body: nil, contentType: nil, query: nil
                    )
                }
            }
        }

        #expect(mock.calls.count == 5)
    }
}
