import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Tests for ``MarfaSDKTest`` helpers in ``MarfaSDKTestSupport`` —
/// specifically the in-memory client factory that consumer apps adopt
/// to avoid the file-backed multi-container pattern.
@Suite("MarfaSDKTest helpers")
struct TestSupportHelpersTests {

    @Test("makeInMemoryClient returns a working pure-local client")
    func makeInMemoryClientWorks() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let created = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("hello")])
        )
        let fetched = try await client.items.get(id: created.id)
        #expect(fetched.id == created.id)
        #expect(fetched.properties["body"] == .string("hello"))
    }

    @Test("makeInMemoryClient returns independent clients on each call")
    func makeInMemoryClientIsolation() async throws {
        let a = try await MarfaSDKTest.makeInMemoryClient()
        let b = try await MarfaSDKTest.makeInMemoryClient()

        let itemInA = try await a.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("a")])
        )

        // The item must not be visible from `b` — distinct containers.
        await #expect(throws: NotFoundError.self) {
            _ = try await b.items.get(id: itemInA.id)
        }
    }

    /// Loops 20 iterations of `makeInMemoryClient()` + create + reactive
    /// query refetch in sequence. Proves the consumer-app crash pattern
    /// (`"Failed to cast model MarfaSDK.MarfaItemModel… to MarfaItemModel"`)
    /// cannot regress through this helper: each call gets a fresh
    /// in-memory container, and reactive queries on it observe the write.
    @MainActor
    @Test("makeInMemoryClient survives 20 sequential clients with reactive queries")
    func makeInMemoryClientStress() async throws {
        for i in 0..<20 {
            let client = try await MarfaSDKTest.makeInMemoryClient()
            guard let store = client.makeStore() else {
                Issue.record("Expected non-nil store on iteration \(i)")
                return
            }

            _ = try await client.items.create(
                CreateItemInput(type: "core.note", properties: ["body": .string("n\(i)")])
            )

            let query = store.query()
            try await waitForCondition(timeout: .seconds(2), description: "query.items.count >= 1") {
                query.items.count >= 1
            }
            #expect(query.items.count == 1)
            query.stop()
        }
    }
}
