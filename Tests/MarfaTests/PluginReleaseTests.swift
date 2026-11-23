import CryptoKit
import Foundation
import Testing

@testable import Marfa
@testable import MarfaAPI

private let plain = ["Content-Type": "application/json"]

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A bundle written as a person might, with its keys in an order and spacing a decoder would not give back.
private let bundleText = """
    {
       "format": 1,
       "name": "reading",
       "title": "Reading",
       "description": "Keep what you read.",
       "mark": "lucide:book-open",
       "maker": "Acme",
       "marfa": "0.0.90",
       "version": "1.2.0",
       "types": [
          {"id": "common.reading.book", "label": "Book", "description": "A book.", "parent": "common.reading",
           "display_hints": {"icon": "lucide:book"}, "guidance": "One per book.", "fields": {}},
          {"id": "common.reading", "description": "Anything read.", "fields": {}}
       ],
       "edge_types": [{"id": "read-with", "label": "Read with", "reverse_label": "Read with", "cardinality": "many-to-many"}],
       "connector": {
          "source": "shelf", "source_name": "Shelf", "source_mark": "lucide:library",
          "kinds": [{"name": "book", "type": "common.reading.book", "direction": "in"}],
          "settings": [
             {"name": "feed", "label": "Feed", "kind": "text", "required": true},
             {"name": "token", "label": "Token", "kind": "text", "secret": true, "required": false},
             {"name": "order", "label": "Order", "kind": "choice", "required": false, "choices": ["new", "old"], "default": "new"}
          ],
          "edge_types": ["read-with"], "runs": {"on": "host"}
       }
    }

    """

private func indexText(for bundle: Data, sha256: String? = nil, name: String = "reading", format: Int = 1) -> String {
    """
    {"format": \(format), "plugins": [
      {"name": "\(name)", "title": "Reading", "description": "Keep what you read.", "mark": "lucide:book-open",
       "maker": "Acme", "marfa": "0.0.90", "version": "1.2.0", "has_connector": true,
       "bundle": "\(name).plugin.json", "sha256": "\(sha256 ?? digest(bundle))"},
      {"name": "other-one", "title": "Other", "description": "Another.", "mark": "lucide:box",
       "maker": "Acme", "marfa": "0.0.1", "version": "0.0.3", "has_connector": false,
       "bundle": "other-one.plugin.json", "sha256": "\(String(repeating: "ab", count: 32))"}
    ]}
    """
}

/// A release that serves `files` at its root and answers 404 for anything else.
private func release(_ files: [String: Data], at scripted: ScriptedAuthServer) throws -> PluginRelease {
    scripted.answer { request in
        guard request.method == "GET", let file = files[String(request.path.dropFirst())] else {
            return .raw(404, Data("no".utf8))
        }
        return .raw(200, file, headers: plain)
    }
    return try PluginRelease(address: scripted.origin, through: scripted.transport().session, timeout: .seconds(30))
}

private func failure<T: Sendable>(_ call: () async throws(PluginReleaseError) -> T) async -> PluginReleaseError? {
    do {
        _ = try await call()
        return nil
    } catch {
        return error
    }
}

@Suite(.timeLimit(.minutes(1)))
struct PluginReleaseTests {
    @Test func theIndexListsEachPluginWithItsVersionsAndDigest() async throws {
        let bundle = Data(bundleText.utf8)
        let scripted = ScriptedAuthServer()
        let source = try release(["plugins.json": Data(indexText(for: bundle).utf8)], at: scripted)
        let entries = try await source.index()
        #expect(entries.map(\.name) == ["reading", "other-one"])
        let reading = try #require(entries.first)
        #expect(reading.id == "reading")
        #expect(reading.title == "Reading")
        #expect(reading.mark == "lucide:book-open")
        #expect(reading.maker == "Acme")
        #expect(reading.marfa == PluginVersion("0.0.90"))
        #expect(reading.version == PluginVersion("1.2.0"))
        #expect(reading.hasConnector)
        #expect(reading.bundle == "reading.plugin.json")
        #expect(reading.sha256 == digest(bundle))
        #expect(entries.last?.hasConnector == false)
    }

    @Test func theRealReleaseIndexIsRead() async throws {
        let index = """
            {"format": 1, "plugins": [{"name": "tickets", "title": "Tickets",
             "description": "Track work and questions as tickets, from backlog to done, with epics, features, spikes and tasks.",
             "mark": "lucide:ticket", "maker": "WithMarfa", "marfa": "0.0.92", "version": "0.0.13",
             "has_connector": false, "bundle": "tickets.plugin.json",
             "sha256": "1c199b3255c05ded69fc1633fa41d45f67378dd89a93c5465c7f0cbfe27b51b6"}]}
            """
        let scripted = ScriptedAuthServer()
        let entries = try await release(["plugins.json": Data(index.utf8)], at: scripted).index()
        #expect(entries.count == 1)
        #expect(entries.first?.version == PluginVersion("0.0.13"))
    }

    @Test func aBundleIsReadWithItsBytesAndContentsOnceItsDigestMatches() async throws {
        let bundle = Data(bundleText.utf8)
        let scripted = ScriptedAuthServer()
        let source = try release(
            ["plugins.json": Data(indexText(for: bundle).utf8), "reading.plugin.json": bundle], at: scripted)
        let entry = try #require(try await source.index().first)
        let read = try await source.bundle(for: entry)
        #expect(read.bytes == bundle)
        #expect(read.entry == entry)
        let contents = read.contents
        #expect(contents.name == "reading" && contents.version == PluginVersion("1.2.0"))
        #expect(contents.marfa == PluginVersion("0.0.90"))
        #expect(contents.types.map(\.id) == ["common.reading.book", "common.reading"])
        let book = try #require(contents.types.first)
        #expect(book.label == "Book" && book.description == "A book." && book.parent == "common.reading")
        #expect(book.icon == "lucide:book" && book.guidance == "One per book.")
        #expect(contents.types.last?.guidance == nil)
        #expect(contents.edgeTypes.first?.reverseLabel == "Read with")
        let connector = try #require(contents.connector)
        #expect(connector.source == "shelf" && connector.sourceName == "Shelf")
        #expect(connector.kinds == [.init(name: "book", type: "common.reading.book", direction: "in")])
        #expect(connector.settings.map(\.name) == ["feed", "token", "order"])
        #expect(connector.settings.map(\.isSecret) == [false, true, false])
        #expect(connector.settings.map(\.isRequired) == [true, false, false])
        #expect(connector.settings.last?.choices == ["new", "old"])
        #expect(connector.settings.last?.defaultValue == .string("new"))
        #expect(connector.edgeTypes == ["read-with"])
    }

    @Test func aBundleWhoseDigestDiffersFromTheIndexIsRefused() async throws {
        let bundle = Data(bundleText.utf8)
        let tampered = Data(
            bundleText.replacingOccurrences(of: "Keep what you read.", with: "Keep what you wrote.").utf8)
        let scripted = ScriptedAuthServer()
        let source = try release(
            ["plugins.json": Data(indexText(for: bundle).utf8), "reading.plugin.json": tampered], at: scripted)
        let entry = try #require(try await source.index().first)
        let error = await failure { () async throws(PluginReleaseError) in try await source.bundle(for: entry) }
        #expect(error == .digestMismatch(file: "reading.plugin.json", found: digest(tampered), listed: digest(bundle)))
        // The witness: the bytes the index lists are taken.
        let honest = try release(
            ["plugins.json": Data(indexText(for: bundle).utf8), "reading.plugin.json": bundle], at: scripted)
        #expect(try await honest.bundle(for: entry).bytes == bundle)
    }

    @Test func aDigestInCapitalsMatchesAsTheCommandLineTakesIt() async throws {
        let bundle = Data(bundleText.utf8)
        let scripted = ScriptedAuthServer()
        let source = try release(
            [
                "plugins.json": Data(indexText(for: bundle, sha256: digest(bundle).uppercased()).utf8),
                "reading.plugin.json": bundle,
            ], at: scripted)
        let entry = try #require(try await source.index().first)
        #expect(try await source.bundle(for: entry).bytes == bundle)
    }

    @Test func aBundleThatHoldsAnotherPluginThanItsEntryIsRefused() async throws {
        let other = Data(
            bundleText.replacingOccurrences(of: "\"name\": \"reading\"", with: "\"name\": \"writing\"").utf8)
        let scripted = ScriptedAuthServer()
        let source = try release(
            ["plugins.json": Data(indexText(for: other).utf8), "reading.plugin.json": other], at: scripted)
        let entry = try #require(try await source.index().first)
        let error = await failure { () async throws(PluginReleaseError) in try await source.bundle(for: entry) }
        guard case .unreachable(_, let reason)? = error else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect(reason.contains("another plugin"))
    }

    @Test(arguments: [
        "https://user@example.test/releases",
        "https://user:secret@example.test/releases",
        "https://:secret@example.test/releases",
        "https://@example.test/releases",
    ]) func anAddressCarryingUserInfoIsRefusedBeforeAnyRequestWithoutNamingIt(address: String) async throws {
        let scripted = ScriptedAuthServer()
        let error = await failure { () async throws(PluginReleaseError) in
            let source = try PluginRelease(
                address: address, through: scripted.transport().session, timeout: .seconds(5))
            _ = try await source.index()
        }
        #expect(error == .addressCarriesCredentials)
        #expect("\(String(describing: error))".contains("secret") == false)
        #expect(scripted.requests.isEmpty)
    }

    @Test(arguments: [
        "ftp://example.test/releases", "file:///tmp/releases", "example.test/releases", "https://", "http:///x",
        "https://example.test/releases?token=1", "https://example.test/releases#frag", "not an address", "",
    ]) func anAddressThatIsNotHttpWithAHostAndNoQueryOrFragmentIsRefused(address: String) async throws {
        if address.isEmpty {
            // The witness: an empty address names no release and takes the default.
            let source = try PluginRelease(address: address)
            #expect(source.address == PluginRelease.latestAddress)
            return
        }
        let error = await failure { () async throws(PluginReleaseError) in
            _ = try PluginRelease(address: address)
        }
        #expect(error == .addressUnreadable, "\(address)")
    }

    @Test func theDefaultAddressIsTheLatestReleaseAndATrailingSlashIsDropped() throws {
        #expect(try PluginRelease().address == "https://github.com/withmarfa/plugins/releases/latest/download")
        #expect(try PluginRelease(address: "  \n").address == PluginRelease.latestAddress)
        #expect(try PluginRelease(address: "http://example.test:8080/dir//").address == "http://example.test:8080/dir")
    }

    @Test func noCredentialIsSent() async throws {
        let bundle = Data(bundleText.utf8)
        let scripted = ScriptedAuthServer()
        let source = try release(
            ["plugins.json": Data(indexText(for: bundle).utf8), "reading.plugin.json": bundle], at: scripted)
        let entry = try #require(try await source.index().first)
        _ = try await source.bundle(for: entry)
        #expect(scripted.requests.count == 2)
        for request in scripted.requests {
            let names = Set(request.headers.keys.map { $0.lowercased() })
            #expect(names.isDisjoint(with: ["authorization", "cookie", "proxy-authorization", "x-marfa-contract"]))
        }
    }

    @Test func aRedirectToAnAddressWithUserInfoOrFromHttpsToHttpIsRefused() async throws {
        let bundle = Data(bundleText.utf8)
        let index = Data(indexText(for: bundle).utf8)
        let scripted = ScriptedAuthServer()
        let host = try #require(scripted.url.host())
        for location in ["https://user:pw@\(host)/plugins.json", "http://\(host)/plugins.json"] {
            let source = try release([:], at: scripted)
            scripted.answer { _ in .raw(302, Data(), headers: ["Location": location]) }
            let error = await failure { () async throws(PluginReleaseError) in try await source.index() }
            guard case .unreachable(_, let reason)? = error else {
                Issue.record("\(location): \(String(describing: error))")
                continue
            }
            #expect(!reason.contains("pw"))
        }
        // The witness: a redirect to the same release is followed, with a relative address too.
        scripted.answer { request in
            request.path == "/plugins.json"
                ? .raw(302, Data(), headers: ["Location": "/moved/plugins.json"])
                : .raw(200, index, headers: plain)
        }
        let source = try PluginRelease(
            address: scripted.origin, through: scripted.transport().session, timeout: .seconds(30))
        #expect(try await source.index().count == 2)
    }

    @Test func aReleaseThatCannotBeReadIsUnreachableNamingItsAddress() async throws {
        let scripted = ScriptedAuthServer()
        let missing = try release([:], at: scripted)
        let notFound = await failure { () async throws(PluginReleaseError) in try await missing.index() }
        #expect(notFound == .unreachable(address: scripted.origin, reason: "answered 404 for plugins.json"))

        let bundle = Data(bundleText.utf8)
        for (text, why) in [
            ("not json", "not an index"),
            (indexText(for: bundle, format: 2), "index format 1"),
            (indexText(for: bundle, name: "Reading"), "unusable name"),
            (indexText(for: bundle, sha256: "abc"), "SHA-256"),
        ] {
            let source = try release(["plugins.json": Data(text.utf8)], at: scripted)
            let error = await failure { () async throws(PluginReleaseError) in try await source.index() }
            guard case .unreachable(let address, let reason)? = error else {
                Issue.record("\(why): \(String(describing: error))")
                continue
            }
            #expect(address == scripted.origin && reason.contains(why), "\(reason)")
        }

        let down = ScriptedAuthServer { _ in .failure(.cannotConnectToHost) }
        let unreachable = try PluginRelease(
            address: down.origin, through: down.transport().session, timeout: .seconds(5))
        let error = await failure { () async throws(PluginReleaseError) in try await unreachable.index() }
        guard case .unreachable(let address, _)? = error else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect(address == down.origin)
    }

    @Test func versionsAreReadAndComparedByTheirNumbers() {
        #expect(PluginVersion("0.0.10")! > PluginVersion("0.0.9")!)
        #expect(PluginVersion("1.0.0")! > PluginVersion("0.99.99")!)
        #expect(PluginVersion("2.3.4")?.description == "2.3.4")
        for text in ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.x", "1.2.-3", "v1.2.3", "1..3", "1.2.3 "] {
            #expect(PluginVersion(text) == nil, "\(text)")
        }
        let server = PluginVersion("0.0.90")!
        #expect(server.takes(PluginVersion("0.0.90")!))
        #expect(server.takes(PluginVersion("0.0.1")!))
        #expect(!server.takes(PluginVersion("0.0.91")!))
        #expect(PluginVersion("0.0.0")!.takes(PluginVersion("9.9.9")!))
        #expect(PluginVersion("0.0.0")!.isDevelopment && !server.isDevelopment)
    }
}
