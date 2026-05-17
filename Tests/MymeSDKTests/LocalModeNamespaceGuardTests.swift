import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

/// Regression suite for the latent bug where ``TypesNamespace``,
/// ``KeysNamespace``, and ``WebhooksNamespace`` would hit the transport
/// unconditionally on a pure-local client. The placeholder
/// `local://offline` URL caused `URLSession` to throw an opaque
/// "unsupported URL" error rather than a typed SDK error. Each method
/// must now throw ``LocalModeUnsupportedError`` before touching the
/// transport. One representative method per namespace is enough — the
/// guard is identical across every method in the struct, mirroring the
/// existing ``BlobsNamespace`` coverage.
@Suite("Local-mode namespace guards")
struct LocalModeNamespaceGuardTests {

    @Test("types.get throws LocalModeUnsupportedError on local client") func typesGetThrowsOnLocalClient() async throws {
        let client = try await MymeSDKTest.makeInMemoryClient()
        do {
            _ = try await client.types.get(id: "core.note")
            Issue.record("expected LocalModeUnsupportedError")
        } catch let e as LocalModeUnsupportedError {
            #expect(e.operation == "types.get")
            #expect(e.status == 501)
        }
    }

    @Test("keys.list throws LocalModeUnsupportedError on local client") func keysListThrowsOnLocalClient() async throws {
        let client = try await MymeSDKTest.makeInMemoryClient()
        do {
            _ = try await client.keys.list()
            Issue.record("expected LocalModeUnsupportedError")
        } catch let e as LocalModeUnsupportedError {
            #expect(e.operation == "keys.list")
            #expect(e.status == 501)
        }
    }

    @Test("webhooks.list throws LocalModeUnsupportedError on local client") func webhooksListThrowsOnLocalClient() async throws {
        let client = try await MymeSDKTest.makeInMemoryClient()
        do {
            _ = try await client.webhooks.list()
            Issue.record("expected LocalModeUnsupportedError")
        } catch let e as LocalModeUnsupportedError {
            #expect(e.operation == "webhooks.list")
            #expect(e.status == 501)
        }
    }

    @Test("tenants.getConfig throws LocalModeUnsupportedError on local client") func tenantsGetConfigThrowsOnLocalClient() async throws {
        let client = try await MymeSDKTest.makeInMemoryClient()
        do {
            _ = try await client.tenants.getConfig()
            Issue.record("expected LocalModeUnsupportedError")
        } catch let e as LocalModeUnsupportedError {
            #expect(e.operation == "tenants.getConfig")
            #expect(e.status == 501)
        }
    }

    @Test("tenants.quotas.getOwn throws LocalModeUnsupportedError on local client") func tenantsQuotasGetOwnThrowsOnLocalClient() async throws {
        let client = try await MymeSDKTest.makeInMemoryClient()
        do {
            _ = try await client.tenants.quotas.getOwn()
            Issue.record("expected LocalModeUnsupportedError")
        } catch let e as LocalModeUnsupportedError {
            #expect(e.operation == "tenants.quotas.getOwn")
            #expect(e.status == 501)
        }
    }
}
