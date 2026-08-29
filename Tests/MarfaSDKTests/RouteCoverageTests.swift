import Testing
import Foundation

/// The SDK wraps an HTTP API, and the two surfaces drift apart in both
/// directions at once. Nothing compared them until now.
///
/// **Declared but not wrapped.** An operation the platform adds reaches the
/// vendored snapshot on the next sync and then stops. No generator consumes
/// `paths`, so nothing notices; the wrapper is written when somebody happens
/// to need it, or never. Twenty-four operations sit here today.
///
/// **Called but not declared.** The more interesting direction, and the one
/// nothing was reporting. Fourteen paths the SDK calls appear nowhere in the
/// snapshot — concentrated in the admin surface, where the implemented and
/// specified surfaces are close to disjoint. These are live, working routes:
/// the platform registers them and its own TypeScript SDK calls several of
/// them. They are missing from the *document*, not from the server. So this
/// is a hole in what the platform's spec generation covers, not a stale
/// snapshot, and refreshing the snapshot does not shrink the list.
///
/// A one-directional check would have been worse than useless here. "SDK
/// paths are a subset of spec paths" fails on all fourteen at once for a
/// reason unrelated to route coverage, and buries the twenty-four it was
/// built to find. The two directions are reported separately because the
/// remedy differs: one is a wrapper to write, the other is a route to get
/// documented.
///
/// The comparison is against `scripts/openapi.json`, the snapshot committed
/// to this repository, because that is the only spec a test here can read.
/// The snapshot trails the platform's own document by a handful of
/// operations, so this measures drift against what was last synced, not
/// against the live server. That is the right frame: the snapshot is what
/// codegen reads, and a route absent from it is invisible to this repository
/// whatever the server does.
@Suite("SDK route coverage tracks the vendored spec")
struct RouteCoverageTests {

    // MARK: - Deliberate omissions

    /// Operations the spec declares that the SDK deliberately does not wrap,
    /// each with the reason it is absent.
    ///
    /// An entry here is a decision, not a backlog — with one honest
    /// exception. Several entries read "no decision on record", and that is
    /// a real answer rather than a placeholder: the surface around them was
    /// built without these and nothing in the repository says why. Those are
    /// the entries to revisit; the rest are settled. Inventing a rationale
    /// for them would have turned a visible gap into an invisible one, which
    /// is the failure this whole suite exists to prevent.
    ///
    /// Adding an entry is how you record "we looked and chose not to".
    /// Deleting one is how you record "we wrapped it".
    private static let deliberatelyUnwrapped: [String: String] = [

        // Ingress and third-party endpoints. The SDK is a client of the
        // Marfa API; these are called by somebody else entirely, and a
        // wrapper would model a caller that does not exist.

        "POST /webhooks/inbound/{}":
            "Delivery endpoint. An upstream service posts to it; the SDK is on the receiving side of what it produces, never the sending side.",

        "POST /lease-tokens/validate":
            "Introspection performed by the external service honoring a callback, to check a token it was handed. The SDK mints, lists and revokes lease tokens — it has no reason to introspect its own.",

        "POST /oauth2/register":
            "RFC 7591 dynamic client registration, unauthenticated and performed once when a client is provisioned. The SDK is configured with a client id rather than registering one at runtime, and a registration it made would be a credential nothing later deletes.",

        // Irreversible operator verbs. `AdminNamespace` wraps the reversible
        // half of the operator surface — suspend and unsuspend are both
        // there — and stops before the half that cannot be undone. That
        // boundary is legible from the shape of what is wrapped rather than
        // stated anywhere, so this reads the intent off the code.

        "POST /admin/accounts/{}/delete":
            "Immediate, irreversible deletion of an account and everything it owns. Deliberately left to the operator tooling that has a confirmation step; an app-facing client should not be one method call from it.",

        "POST /admin/spaces/{}/delete":
            "Same boundary as account deletion: immediate and irreversible, and the reversible equivalents (suspend, unsuspend) are wrapped.",

        // Streaming and bulk transfer the transport cannot express.

        "GET /export":
            "Streams the whole space as NDJSON, or a tar.gz archive with `format=archive`. `Transport` decodes a JSON body or returns a complete `Data` — neither models a stream, and buffering an entire space in memory is the wrong shape on the platforms this SDK targets. Wrapping it needs a streaming transport method first.",

        // Operator diagnostics with no app-side caller. Lower confidence
        // than the entries above: nothing rules a wrapper out, there is
        // simply no consumer for one on a device.

        "GET /audit":
            "Admin and space-admin read of the audit log. Belongs to an operator console; no app-side caller has wanted it.",

        "GET /admin/runtime/dead-letters":
            "Diagnostics for the local integration substrate — dispatches that exhausted their retry ladder. An operator surface, and one that reports on infrastructure a client app has no view of.",

        "POST /admin/runtime/dead-letters/{}/replay":
            "The remediation half of the dead-letter surface above, and out of scope for the same reason.",

        // No decision on record. Everything below is unwrapped and nothing
        // in the repository explains why. Listed so the check passes on a
        // clean tree, not because the absence has been justified.

        "GET /connections/{}/mapping":
            "No decision on record. The strongest candidate to close: with PUT and DELETE below it, this is a field the SDK can neither read nor write, so the connection surface is half built rather than deliberately narrow.",

        "PUT /connections/{}/mapping":
            "No decision on record. See the GET above — the trio should be wrapped or removed together.",

        "DELETE /connections/{}/mapping":
            "No decision on record. See the GET above — the trio should be wrapped or removed together.",

        "POST /connections/{}/inbound-webhooks":
            "No decision on record, and the same half-built shape as the mapping trio: listing a connection's inbound webhooks is wrapped, registering one is not.",

        "POST /connections/{}/pause":
            "No decision on record. The platform's TypeScript SDK wraps it, so this is a parity gap rather than a considered omission.",

        "POST /connections/{}/resume":
            "No decision on record. Wrapped by the TypeScript SDK; parity gap, same as pause.",

        "POST /connections/{}/run":
            "No decision on record. Triggers a connection immediately, alongside the pause and resume verbs above.",

        "GET /connections/{}/upgrade":
            "No decision on record. Reports what moving a connection to a newer manifest would change; the read half of the pair below.",

        "POST /connections/{}/upgrade":
            "No decision on record. Performs the manifest move the GET above previews.",

        "POST /admin/spaces":
            "No decision on record. Wrapped by the TypeScript SDK. Creation is not destructive, so the reversibility boundary that explains the delete entries above does not apply here.",

        "POST /admin/spaces/{}/keys":
            "No decision on record. Wrapped by the TypeScript SDK, and its natural pair — listing a space's keys — is wrapped here.",

        "POST /items/bulk-get":
            "No decision on record. Wrapped by the TypeScript SDK, and the SDK already carries the rest of the bulk surface.",

        "PATCH /keys/{}":
            "No decision on record. Wrapped by the TypeScript SDK. `KeysNamespace` covers create, list and revoke, so update is the one verb missing.",

        "DELETE /credentials/{}":
            "No decision on record. `CredentialsNamespace` can create a credential and then neither list nor delete it, which leaves callers no way to clean up what they made.",

        "PUT /auth/me/handle":
            "No decision on record. Claims or changes the user's public handle, which namespaces their published types.",
    ]

    /// Paths the SDK calls that the vendored snapshot does not declare, each
    /// with what is known about why.
    ///
    /// This is a different kind of entry from the map above and the two are
    /// kept apart deliberately. Nothing here is a missing wrapper — the
    /// wrapper exists and works. Each is a live route the platform serves
    /// and its own spec generation does not describe, verified by finding
    /// the route registered in the platform and absent from both this
    /// snapshot and the platform's current document.
    ///
    /// The fix for an entry here is upstream: get the route into the spec.
    /// It then moves out of this map on the next snapshot sync, and if the
    /// wrapper is right it simply stops being reported in either direction.
    ///
    /// An entry appearing here that is *not* a spec-coverage hole is a real
    /// failure worth chasing: it means the SDK calls a path the server does
    /// not serve, and every call through it 404s.
    private static let undeclaredUpstream: [String: String] = [

        // The admin surface. Implemented and specified are close to
        // disjoint here: every operation `AdminNamespace` wraps is missing
        // from the spec, while every admin operation the spec declares is
        // unwrapped. The two halves barely overlap.

        "GET /admin/spaces": "Admin surface is absent from the generated spec.",
        "GET /admin/spaces/{}": "Admin surface is absent from the generated spec.",
        "GET /admin/spaces/{}/keys": "Admin surface is absent from the generated spec.",
        "GET /admin/spaces/{}/metrics": "Admin surface is absent from the generated spec.",
        "POST /admin/spaces/{}/suspend": "Admin surface is absent from the generated spec.",
        "POST /admin/spaces/{}/unsuspend": "Admin surface is absent from the generated spec.",
        "POST /admin/account-deletion/purge-now": "Admin surface is absent from the generated spec.",

        // Account deletion. A three-step flow the SDK implements in full and
        // the spec describes at none of its steps.

        "POST /auth/account/delete": "Account-deletion flow is absent from the generated spec.",
        "GET /auth/account/delete/confirm": "Account-deletion flow is absent from the generated spec.",
        "POST /auth/account/delete/cancel": "Account-deletion flow is absent from the generated spec.",

        // Individually missing operations on paths that are otherwise
        // described, which is the shape that makes the gap easy to miss.

        "GET /spaces/{}/quotas":
            "Declared for the caller's own space (`/spaces/me/quotas`) but not for a space named by id, though the server serves both.",

        "PUT /spaces/{}/quotas":
            "Same path as the GET above and the same omission.",

        "HEAD /blobs/{}":
            "The blob existence check. `GET` and `DELETE` on this path are declared; `HEAD` is not, though the SDK and the sync engine both rely on it.",

        // The one entry here that is not really a gap.

        "GET /health":
            "Liveness probe, served outside the typed API surface. Its absence from the spec is correct rather than an omission — it has no request or response schema to describe — and `MarfaClient.health()` reads only the status code. Listed so the check does not report a hole that nobody should close.",
    ]

    // MARK: - Locating the sources

    /// The package root, walked up from this file. The snapshot is read from
    /// source rather than from a resource bundle: it is a codegen input, not
    /// a test resource, and this test wants the file `sync-openapi.sh`
    /// writes. The SDK sources are read the same way, for the same reason —
    /// they are the subject of the check, not an input to it.
    private var packageRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    /// Both surfaces normalize to the same shape so they can be compared:
    /// a Swift interpolation and a spec path parameter both become `{}`.
    /// The parameter's *name* is deliberately discarded — the spec calls it
    /// `{id}` where the SDK interpolates `connectionId`, and comparing names
    /// would report drift that does not exist.
    private static func normalize(_ path: String) -> String {
        var result = ""
        var depth = 0
        var index = path.startIndex
        while index < path.endIndex {
            let character = path[index]
            // `\(` opens an interpolation; `{` opens a spec parameter.
            let opensInterpolation =
                character == "\\" && path.index(after: index) < path.endIndex
                && path[path.index(after: index)] == "("
            if depth == 0, opensInterpolation {
                result += "{}"
                depth = 1
                index = path.index(index, offsetBy: 2)
                continue
            }
            if depth == 0, character == "{" {
                result += "{}"
                depth = 1
                index = path.index(after: index)
                continue
            }
            if depth > 0 {
                if character == "(" || character == "{" { depth += 1 }
                if character == ")" || character == "}" { depth -= 1 }
                index = path.index(after: index)
                continue
            }
            result.append(character)
            index = path.index(after: index)
        }
        // A query string on a literal path is not part of the route.
        if let cut = result.firstIndex(of: "?") { result = String(result[..<cut]) }
        return result
    }

    /// Every `.swift` file under `Sources/MarfaSDK`, minus `Transport/`.
    ///
    /// `Transport/` is excluded because it *declares* the request methods
    /// rather than calling them: its `method:`/`path:` occurrences are
    /// parameter lists and the `uploadMultipart` helper forwarding its own
    /// arguments, neither of which is a route the SDK calls.
    private func sdkSourceFiles() throws -> [URL] {
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

    /// One extracted call site: the operation it targets and where it lives.
    private struct CallSite {
        let key: String
        let location: String
    }

    private static func regex(_ pattern: String) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: pattern)
    }

    /// Every route the SDK calls, keyed `"METHOD /path"`.
    ///
    /// Extraction is a text scan rather than anything cleverer because there
    /// is no structural hook to use: `Transport` takes the path as a bare
    /// `String`, and the codegen never enumerates `paths` — it reads a
    /// registry of JSON pointers and has no concept of an operation.
    ///
    /// Two shapes are matched, and the second one matters. `method:` and
    /// `path:` adjacent covers `request`, `requestWithConflict`,
    /// `rawRequest`, `rawUpload` and `uploadMultipart`. But `eventStream`
    /// takes no `method:` at all — it is a GET by construction — so a scan
    /// looking only for the first shape would miss `GET /events` and then
    /// report it as an unwrapped operation. A false entry in the deliberate
    /// map is worse than no check: it is a wrapper that exists being
    /// recorded as one that was declined.
    private func routesCalledBySDK() throws -> [String: [String]] {
        let pairPattern = try Self.regex(#"method:\s*\.([a-zA-Z]+)\s*,\s*path:\s*"([^"]*)""#)
        let streamPattern = try Self.regex(#"\.eventStream\(\s*path:\s*"([^"]*)""#)

        var routes: [String: [String]] = [:]
        for file in try sdkSourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let whole = NSRange(text.startIndex..., in: text)
            let name = file.lastPathComponent

            for match in pairPattern.matches(in: text, range: whole) {
                guard
                    let methodRange = Range(match.range(at: 1), in: text),
                    let pathRange = Range(match.range(at: 2), in: text)
                else { continue }
                let key = String(text[methodRange]).uppercased()
                    + " " + Self.normalize(String(text[pathRange]))
                routes[key, default: []].append("\(name):\(Self.line(of: match.range.location, in: text))")
            }

            for match in streamPattern.matches(in: text, range: whole) {
                guard let pathRange = Range(match.range(at: 1), in: text) else { continue }
                let key = "GET " + Self.normalize(String(text[pathRange]))
                routes[key, default: []].append(
                    "\(name):\(Self.line(of: match.range.location, in: text)) (SSE)")
            }
        }
        return routes
    }

    /// `NSRange` locations are UTF-16 offsets; failure messages want line
    /// numbers, because "the scan cannot see this call site" is only
    /// actionable if it says which one.
    private static func line(of utf16Offset: Int, in text: String) -> Int {
        let index = String.Index(utf16Offset: utf16Offset, in: text)
        return text[text.startIndex..<index].filter { $0 == "\n" }.count + 1
    }

    /// Every operation the vendored snapshot declares, keyed the same way.
    private func routesDeclaredInSpec() throws -> [String: String] {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("scripts/openapi.json"))
        let spec = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "scripts/openapi.json is not a JSON object")
        let paths = try #require(
            spec["paths"] as? [String: Any],
            "the snapshot declares no paths, so there is nothing to compare")

        let verbs: Set<String> = ["get", "put", "post", "delete", "patch", "head", "options"]
        var declared: [String: String] = [:]
        for (path, item) in paths {
            guard let operations = item as? [String: Any] else { continue }
            for (verb, operation) in operations where verbs.contains(verb.lowercased()) {
                let key = verb.uppercased() + " " + Self.normalize(path)
                let summary = (operation as? [String: Any])?["summary"] as? String
                declared[key] = summary ?? ""
            }
        }
        return declared
    }

    // MARK: - The extraction has to be trustworthy before the check means anything

    /// A scan that silently stops matching turns both directions below into
    /// vacuous passes in one direction and noise in the other, which is
    /// indistinguishable from the drift they exist to catch. These are the
    /// floors that make a broken extraction fail loudly instead.
    @Test("extraction finds a plausible number of call sites and operations")
    func extractionIsNotVacuous() throws {
        let called = try routesCalledBySDK()
        let declared = try routesDeclaredInSpec()
        // Deliberately loose. The point is that the regexes still match and
        // the snapshot still parses, not to pin a number that moves with
        // every wrapper added.
        #expect(called.count >= 80, "route extraction found \(called.count) operations, which is too few to be right")
        #expect(declared.count >= 90, "the snapshot declares \(declared.count) operations, which is too few to be right")
        // The SSE stream is the call shape with no `method:` label. If this
        // is missing, the second pattern has stopped matching and `GET
        // /events` is about to be reported as an unwrapped operation.
        #expect(called["GET /events"] != nil, "the SSE call site was not extracted, so the scan is missing every method-less call")
    }

    /// Every `method:` argument in the scanned sources has to be one the
    /// pair pattern captured. A call site written in some other shape — a
    /// path held in a variable, arguments reordered, a new transport helper
    /// — would otherwise vanish from the scan, and a vanished call site
    /// reads exactly like a wrapper that was never written. Under-reporting
    /// is the failure mode this suite is built around, so it is checked
    /// rather than assumed.
    @Test("every transport call site matches the shape the scan expects")
    func everyCallSiteIsExtractable() throws {
        let pairPattern = try Self.regex(#"method:\s*\.([a-zA-Z]+)\s*,\s*path:\s*"([^"]*)""#)
        let anyMethodPattern = try Self.regex(#"method:\s*\."#)

        var unmatched: [String] = []
        for file in try sdkSourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let whole = NSRange(text.startIndex..., in: text)
            let captured = Set(pairPattern.matches(in: text, range: whole).map(\.range.location))
            for match in anyMethodPattern.matches(in: text, range: whole)
            where !captured.contains(match.range.location) {
                unmatched.append(
                    "\(file.lastPathComponent):\(Self.line(of: match.range.location, in: text))")
            }
        }
        #expect(
            unmatched.isEmpty,
            """
            these `method:` arguments are not followed by a literal `path:`, so the \
            route scan cannot see them and would under-report coverage: \(unmatched.sorted())
            """)
    }

    // MARK: - Direction one: declared, not wrapped

    @Test("every operation the spec declares is wrapped, or listed as deliberately not")
    func specOperationsAreWrapped() throws {
        let called = Set(try routesCalledBySDK().keys)
        let declared = try routesDeclaredInSpec()

        let unwrapped = Set(declared.keys)
            .subtracting(called)
            .subtracting(Self.deliberatelyUnwrapped.keys)
        #expect(
            unwrapped.isEmpty,
            """
            the spec declares operations the SDK neither wraps nor lists as \
            deliberately unwrapped. Wrap them, or add each to \
            `deliberatelyUnwrapped` with the reason:
            \(unwrapped.sorted().map { "  \($0)  — \(declared[$0] ?? "")" }.joined(separator: "\n"))
            """)

        // The map is a record of decisions about operations that exist. An
        // entry naming an operation the spec no longer declares is a
        // decision about nothing, and it hides the fact that the operation
        // went away.
        let phantom = Set(Self.deliberatelyUnwrapped.keys).subtracting(declared.keys)
        #expect(
            phantom.isEmpty,
            """
            `deliberatelyUnwrapped` lists operations the spec no longer declares. \
            Remove them: \(phantom.sorted())
            """)

        // An entry for something now wrapped is stale in the other
        // direction, and leaves a wrapper looking declined.
        let alreadyWrapped = Set(Self.deliberatelyUnwrapped.keys).intersection(called)
        #expect(
            alreadyWrapped.isEmpty,
            """
            `deliberatelyUnwrapped` lists operations the SDK does wrap. \
            Remove them: \(alreadyWrapped.sorted())
            """)
    }

    // MARK: - Direction two: called, not declared

    @Test("every route the SDK calls is declared, or listed as a known spec gap")
    func calledRoutesAreDeclared() throws {
        let called = try routesCalledBySDK()
        let declared = Set(try routesDeclaredInSpec().keys)

        let undeclared = Set(called.keys)
            .subtracting(declared)
            .subtracting(Self.undeclaredUpstream.keys)
        #expect(
            undeclared.isEmpty,
            """
            the SDK calls routes the vendored spec does not declare, and that are \
            not listed as known spec gaps. This is not a missing wrapper: either \
            the route is real and the spec does not describe it (get it documented \
            upstream, then add it to `undeclaredUpstream`), or the path is wrong \
            and these calls 404:
            \(undeclared.sorted().map { "  \($0)  called from \((called[$0] ?? []).sorted().joined(separator: ", "))" }.joined(separator: "\n"))
            """)

        // A gap that closed upstream should leave this map rather than sit
        // in it claiming a hole that no longer exists.
        let nowDeclared = Set(Self.undeclaredUpstream.keys).intersection(declared)
        #expect(
            nowDeclared.isEmpty,
            """
            `undeclaredUpstream` lists routes the spec now declares — the gap closed. \
            Remove them: \(nowDeclared.sorted())
            """)

        // And one the SDK no longer calls is a note about nothing.
        let nolongerCalled = Set(Self.undeclaredUpstream.keys).subtracting(called.keys)
        #expect(
            nolongerCalled.isEmpty,
            """
            `undeclaredUpstream` lists routes the SDK no longer calls. \
            Remove them: \(nolongerCalled.sorted())
            """)
    }
}
