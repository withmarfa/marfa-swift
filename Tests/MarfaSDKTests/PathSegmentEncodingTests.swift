import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// Caller-supplied identifiers reach the wire as *one path segment each*.
///
/// **A path encoder is not a segment encoder, and the difference is the whole
/// defect.** `CharacterSet.urlPathAllowed` permits `/`, because a path is
/// allowed to contain separators — so encoding an id with it leaves a slash
/// splitting the id into two segments and addressing a route nobody asked for.
/// A segment encoder escapes the separator, which is why the assertions below
/// all name `%2F` rather than accepting a slash that survived.
///
/// The escaping matches JavaScript's `encodeURIComponent`, which is what the
/// platform's TypeScript client uses, so an id the two kits are both handed
/// produces the same request from either.
@Suite("Path segments are escaped", .timeLimit(.minutes(1)))
struct PathSegmentEncodingTests {

    /// A separator, a fragment marker, a query marker, a space and a percent,
    /// in one id. Raw, none of them is refused — see
    /// ``PathSegmentTransportTests`` for what the string parses into instead.
    private static let hostileId = "a/b#c?d e%f"
    private static let hostileIdEscaped = "a%2Fb%23c%3Fd%20e%25f"

    private func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    // MARK: - Direct client

    @Test("an id carrying reserved characters becomes one escaped segment")
    func itemIdIsEscaped() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.items.delete(id: Self.hostileId)

        #expect(mock.calls[0].method == .delete)
        #expect(mock.calls[0].path == "/items/\(Self.hostileIdEscaped)")
    }

    @Test("an id is escaped when the route continues past it")
    func itemIdIsEscapedMidPath() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.items.purge(id: Self.hostileId)

        #expect(mock.calls[0].path == "/items/\(Self.hostileIdEscaped)/purge")
    }

    /// A tag is the one segment on this surface that is user-authored rather
    /// than machine-minted, and it was already encoded — with the path
    /// encoder, so a tag with a slash in it still addressed two segments.
    @Test("a tag carrying a separator stays one segment")
    func tagIsEscapedAsASegment() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.metadata.removeTag(itemId: "itm_1", tag: "work/urgent")

        #expect(mock.calls[0].path == "/items/itm_1/tags/work%2Furgent")
    }

    /// The same double life as tags: encoded already, with the wrong encoder.
    @Test("an extension namespace carrying a separator stays one segment")
    func extensionNamespaceIsEscapedAsASegment() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.extensions.delete(itemId: "itm_1", namespace: "acme/crm")

        #expect(mock.calls[0].path == "/items/itm_1/extensions/acme%2Fcrm")
    }

    /// Two escaped segments in one path, so a fix that reaches only the first
    /// interpolation of a literal is caught.
    @Test("every interpolated segment of a route is escaped, not just the first")
    func everySegmentOfARouteIsEscaped() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.extensions.delete(itemId: Self.hostileId, namespace: "acme/crm")

        #expect(mock.calls[0].path == "/items/\(Self.hostileIdEscaped)/extensions/acme%2Fcrm")
    }

    /// **The one URL on this surface that no `path:` argument builds**, which
    /// is why the source scan below cannot see it and why it needs its own
    /// assertion. ``BlobsNamespace/url(hash:)`` hands an app a URL for an
    /// image loader rather than making a request, and it was composed with
    /// `appendingPathComponent` — the path set again, keeping `/`.
    @Test("the blob URL escapes its hash as a segment")
    func blobURLEscapesTheHash() {
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: MockTransport())

        #expect(client.blobs.url(hash: "sha256:abc").absoluteString == "http://test/blobs/sha256%3Aabc")
        #expect(client.blobs.url(hash: "a/b#c").absoluteString == "http://test/blobs/sha256%3Aa%2Fb%23c")
    }

    // MARK: - Replay

    /// The queue builds its own paths rather than calling back through the
    /// namespaces, so it is a second population of call sites and fails
    /// independently of the first.
    @Test("a replayed mutation escapes the id it addresses")
    func replayEscapesTheId() async throws {
        let (_, queue, transport, connManager, engine) = try await SyncEngineTestKit.makeFixture()
        try await queue.enqueueDeleteItem(id: Self.hostileId)
        transport.enqueue(EmptyResponse())

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()
        await engine.stop()

        let replayed = transport.calls.filter { $0.method == .delete }
        #expect(replayed.count == 1)
        #expect(replayed.first?.path == "/items/\(Self.hostileIdEscaped)")
    }

    // MARK: - The encoder itself

    /// `encodeURIComponent` leaves exactly these unescaped, so the whole set
    /// is asserted rather than sampled: this is the line the two kits agree
    /// on, and a character quietly added to it is a divergence nothing else
    /// would report.
    @Test("the unescaped set is encodeURIComponent's")
    func unescapedSetMatchesEncodeURIComponent() {
        let unescaped = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
        #expect(unescaped.escapedPathSegment == unescaped)
    }

    /// The reserved characters, spelled out rather than derived from the set
    /// above — a derived expectation restates the implementation and agrees
    /// with it however wrong it is.
    @Test("every reserved character escapes to its own byte")
    func reservedCharactersEscape() {
        #expect(" ".escapedPathSegment == "%20")
        #expect("/".escapedPathSegment == "%2F")
        #expect("#".escapedPathSegment == "%23")
        #expect("?".escapedPathSegment == "%3F")
        #expect("%".escapedPathSegment == "%25")
        #expect(":".escapedPathSegment == "%3A")
        #expect("@".escapedPathSegment == "%40")
        #expect("&".escapedPathSegment == "%26")
        #expect("=".escapedPathSegment == "%3D")
        #expect("+".escapedPathSegment == "%2B")
        #expect(";".escapedPathSegment == "%3B")
        #expect(",".escapedPathSegment == "%2C")
        #expect("$".escapedPathSegment == "%24")
        #expect("[".escapedPathSegment == "%5B")
        #expect("]".escapedPathSegment == "%5D")
    }

    /// `CharacterSet.alphanumerics` admits every Unicode letter, so an
    /// encoder built on it would put an accented identifier on the wire raw
    /// where the TypeScript client escapes it. This is what pins the choice
    /// to encode bytes instead.
    @Test("a non-ASCII scalar escapes as its UTF-8 bytes")
    func nonASCIIEscapesAsUTF8() {
        #expect("é".escapedPathSegment == "%C3%A9")
        #expect("日".escapedPathSegment == "%E6%97%A5")
    }

    /// Escaping happens once, at the interpolation. Stated as a test because
    /// it is the shape of the next defect here: a caller that escapes before
    /// handing a segment over gets `%252F` on the wire and a `404` that reads
    /// like a server problem.
    @Test("escaping is not idempotent, so nothing upstream may escape first")
    func escapingIsNotIdempotent() {
        #expect("a%2Fb".escapedPathSegment == "a%252Fb")
    }

    // MARK: - The rule, rather than the instances

    /// Nothing under `Sources/MarfaSDK` interpolates into a request path
    /// except through the segment encoder.
    ///
    /// The tests above pin six routes out of roughly seventy. This is what
    /// covers the rest, and more usefully what covers the route added next
    /// week: a new call site written the old way fails here rather than
    /// waiting for somebody to hand it an id with a slash in it.
    ///
    /// **What it reads, and what it therefore cannot see.** It looks only at
    /// `path:` arguments, so a path assembled into a local variable first is
    /// invisible to it, and so is a URL built any other way — the latter is
    /// not hypothetical, and ``blobURLEscapesTheHash`` covers the one place it
    /// happens. The check under-reports rather than inventing a violation, so
    /// its silence is weaker evidence than its complaint.
    ///
    /// **It is no longer defeated by a line wrap.** The first version scanned
    /// one line at a time, so a `path:` argument split across two lines was
    /// invisible — and `.swift-format` sets a 120-column limit, which two
    /// lines this change wrote already exceed. The next person to wrap one
    /// would have reopened the hole silently, which is the failure class this
    /// package keeps finding: a guard defeated by ordinary formatting. It now
    /// joins a `path:` argument with the lines that continue it before
    /// scanning, and reports the line the argument starts on.
    @Test("no request path interpolates an unescaped segment")
    func everyPathLiteralEscapesItsSegments() throws {
        var offenders: [String] = []
        var scannedLiterals = 0

        for file in try Self.sdkSourceFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (offset, line) in lines.enumerated() {
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                if trimmed.hasPrefix("//") { continue }
                // Join the lines that continue this one before scanning, so a
                // wrapped `path:` argument is read as the one expression it is.
                let joined = Self.logicalLine(startingAt: offset, in: lines)
                for literal in Self.pathLiterals(in: joined) {
                    scannedLiterals += 1
                    for expression in Self.interpolations(in: literal)
                    where !expression.hasSuffix(".escapedPathSegment") {
                        let name = file.lastPathComponent
                        offenders.append("\(name):\(offset + 1) — \\(\(expression)) in \"\(literal)\"")
                    }
                }
            }
        }

        // A scan that found nothing to scan passes vacuously, which is the
        // failure mode of every source-reading test. Pin a floor instead.
        #expect(scannedLiterals >= 60, "the path-literal scan matched almost nothing; it has stopped reading the sources")
        #expect(offenders.isEmpty, "unescaped segments interpolated into a request path:\n\(offenders.joined(separator: "\n"))")
    }

    // MARK: - Scanning

    /// The line at `index` joined with the lines that continue it.
    ///
    /// **Only where it matters.** A line carrying `path:` whose string literal
    /// does not close on that line is joined with what follows, up to a small
    /// bound, so a wrapped argument is scanned as the single expression it is.
    /// Everything else is returned untouched, which keeps the reported line
    /// number the line the argument starts on rather than wherever it ended.
    ///
    /// The bound exists so that an unterminated literal — which does not
    /// compile, but this reads sources rather than an AST — cannot swallow a
    /// whole file and turn one mistake into a scan of everything after it.
    private static func logicalLine(startingAt index: Int, in lines: [String]) -> String {
        guard let argument = lines[index].range(of: "path:") else { return lines[index] }
        var joined = lines[index]
        var tail = String(joined[argument.upperBound...])
        var cursor = index
        // Join forward until the argument holds a complete string literal.
        //
        // **Two quotes, not an odd count.** The first version joined only when
        // a literal was left open on the line, which is one of the two ways an
        // argument wraps and not the common one: `swift-format` breaks *before*
        // the literal, leaving `path:` alone on its line with no quote on it at
        // all. That version compiled, read plausibly, and caught nothing --
        // proved by wrapping a real call site and watching it still pass.
        while Self.quoteCount(in: tail) < 2, cursor + 1 < lines.count, cursor - index < 4 {
            cursor += 1
            let next = String(lines[cursor].drop { $0 == " " || $0 == "\t" })
            joined += " " + next
            tail += " " + next
        }
        return joined
    }

    /// Double quotes in `text`, ignoring escaped ones.
    ///
    /// An odd count means a string literal is still open at the end of the
    /// line, which is the signal that the argument continues below.
    private static func quoteCount(in text: String) -> Int {
        var count = 0
        var escaped = false
        for character in text {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { count += 1 }
        }
        return count
    }

    private static var packageRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    /// `Transport/` is excluded because it declares the `path:` parameter
    /// rather than passing a route to it, and because the encoder itself
    /// lives there.
    private static func sdkSourceFiles() throws -> [URL] {
        let sources = packageRoot.appendingPathComponent("Sources/MarfaSDK")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
            "Sources/MarfaSDK is not readable")
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .filter { !$0.path.contains("/MarfaSDK/Transport/") }
            .sorted { $0.path < $1.path }
    }

    /// The text of every string literal handed to a `path:` argument on `line`.
    private static func pathLiterals(in line: String) -> [String] {
        var literals: [String] = []
        var rest = Substring(line)
        while let marker = rest.range(of: "path: \"") {
            let body = rest[marker.upperBound...]
            guard let close = body.firstIndex(of: "\"") else { break }
            literals.append(String(body[..<close]))
            rest = body[body.index(after: close)...]
        }
        return literals
    }

    /// Every interpolated expression in `literal`, with the `\(` and `)`
    /// stripped. Nesting is tracked so `\(a(b))` yields `a(b)` rather than
    /// stopping at the inner parenthesis.
    private static func interpolations(in literal: String) -> [String] {
        var expressions: [String] = []
        var characters = Array(literal)[...]
        while let start = characters.firstIndex(where: { $0 == "\\" }),
              characters.index(after: start) < characters.endIndex,
              characters[characters.index(after: start)] == "(" {
            var depth = 0
            var index = characters.index(after: start)
            var expression = ""
            while index < characters.endIndex {
                let character = characters[index]
                if character == "(" {
                    depth += 1
                    if depth == 1 {
                        index = characters.index(after: index)
                        continue
                    }
                }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                expression.append(character)
                index = characters.index(after: index)
            }
            expressions.append(expression)
            guard index < characters.endIndex else { break }
            characters = characters[characters.index(after: index)...]
        }
        return expressions
    }
}

/// Records the URL of every request it is handed, and answers each with an
/// empty JSON object. Scoped to this suite's session, the way every other
/// stub in these tests is.
final class PathSegmentStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [String] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        seen = []
    }

    static var urls: [String] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request.url?.absoluteString ?? "<no url>")
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// **The `MockTransport` assertions above stop one layer short of the defect.**
/// They pin the path string the namespaces build; what the ticket is about is
/// the URL that leaves the process, and `buildURL` hands its result to
/// `URLComponents(string:)`, which *parses* rather than encodes. So the escape
/// has to survive that round trip, and a raw segment has to be shown failing
/// there — otherwise the encoder could be undone one layer down and every
/// assertion above would still pass.
@Suite("Escaped segments survive the transport", .serialized)
struct PathSegmentTransportTests {

    private func makeClient() -> MarfaClient {
        let config = ClientConfiguration(
            url: URL(string: "http://test")!,
            apiKey: "k",
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0, jitter: 0)
        )
        return MarfaClient(
            configuration: config,
            transport: URLSessionTransport(
                configuration: config, protocolClasses: [PathSegmentStubURLProtocol.self]
            )
        )
    }

    @Test("an escaped segment reaches the wire still escaped")
    func escapedSegmentReachesTheWire() async throws {
        PathSegmentStubURLProtocol.reset()

        try await makeClient().items.delete(id: "a/b#c?d e%f")

        let sent = try #require(PathSegmentStubURLProtocol.urls.first)
        #expect(sent == "http://test/items/a%2Fb%23c%3Fd%20e%25f")
    }

    /// The other half of the same claim, and **the reason this defect had to
    /// be found by reading rather than by a failure**: unescaped, the string
    /// is not refused. `URLComponents(string:)` repairs it — the space becomes
    /// `%20`, the bare percent becomes `%25` — and parses what is left, so the
    /// slash opens a segment and the `#` takes the rest into a fragment that
    /// never reaches the wire. The request is well-formed and goes to
    /// `/items/a/b`.
    ///
    /// Measured on Swift 6.3.3 / macOS 26.6 on 6 September 2026. Asserted
    /// against `buildURL`'s input directly, because no call site can produce a
    /// raw segment any more.
    @Test("an unescaped segment is not refused, it is silently re-routed")
    func unescapedSegmentParsesIntoADifferentRoute() throws {
        let raw = try #require(URLComponents(string: "http://test/items/a/b#c?d e%f"))
        #expect(raw.percentEncodedPath == "/items/a/b")
        #expect(raw.percentEncodedFragment == "c?d%20e%25f")

        let escaped = try #require(URLComponents(string: "http://test/items/a%2Fb%23c%3Fd%20e%25f"))
        #expect(escaped.percentEncodedPath == "/items/a%2Fb%23c%3Fd%20e%25f")
        #expect(escaped.percentEncodedFragment == nil)
    }
}
