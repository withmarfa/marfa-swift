import Testing
import Foundation

/// The SDK wraps an HTTP API, and the two surfaces drift apart in both
/// directions at once. Nothing compared them until now.
///
/// **Declared but not wrapped.** An operation the platform adds reaches the
/// vendored snapshot on the next sync and then stops. No generator consumes
/// `paths`, so nothing notices; the wrapper is written when somebody happens
/// to need it, or never. Twenty-four operations sit here today — against the
/// snapshot. See the note on the snapshot below for why the honest figure is
/// twenty-eight.
///
/// **Called but not declared.** The more interesting direction, and the one
/// nothing was reporting. Fourteen paths the SDK calls appear nowhere in the
/// snapshot, concentrated in the admin surface. These are live, working
/// routes: the platform registers them and its own TypeScript SDK calls
/// several of them. They are missing from the *document*, not from the
/// server — and for two different reasons, nine of them deliberate. The map
/// below carries the reason per entry, because the remedy differs by cause
/// and for most of them the remedy is "nothing".
///
/// A one-directional check would have been worse than useless here. "SDK
/// paths are a subset of spec paths" fails on all fourteen at once for a
/// reason unrelated to route coverage, and buries the twenty-four it was
/// built to find. The two directions are reported separately.
///
/// **What the comparison is against.** `scripts/openapi.json`, the snapshot
/// committed to this repository, because that is the only spec a test here
/// can read. The snapshot trails the monorepo's committed `openapi.json`:
/// it declares 102 operations against that document's 106, missing
/// `GET /admin/platform-types/drift`, `GET /connections/upgrades/pending`,
/// `POST /admin/platform-types/{id}/remove` and
/// `POST /connections/{id}/upgrade/approve`. All four are unwrapped and none
/// appears in either map below, so the real count of unwrapped operations is
/// twenty-eight rather than the twenty-four this file can see. Both are
/// committed documents; neither was compared against a running server, so
/// twenty-eight is a floor rather than a settled figure.
///
/// Nothing closes that on its own. `scripts/sync-openapi.sh` is run by hand,
/// and the `freshness` CI job re-runs codegen *against the committed
/// snapshot* rather than re-syncing it — so a snapshot that trails stays
/// green indefinitely and this check under-reports by however far it has
/// drifted. That is a real limit of the check, not a detail: it measures
/// drift against what was last synced, and the sync is the unwatched step.
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
    /// with the reason the document does not carry it.
    ///
    /// This is a different kind of entry from the map above and the two are
    /// kept apart deliberately. Nothing here is a missing wrapper — the
    /// wrapper exists and works. Each is a live route the platform serves
    /// and its published document does not describe, verified by finding the
    /// route registered in the monorepo and absent from both this snapshot
    /// and the platform's current document.
    ///
    /// **There are two causes and they need opposite responses.** The
    /// monorepo's `packages/server/src/openapi-finalize.ts` shapes the
    /// reflected document into the published one, and it both *removes* and
    /// *adds*:
    ///
    /// - `INTERNAL_OPERATION_IDS` drops operations by operationId, described
    ///   there as "platform-internal — they still serve, but app developers
    ///   never call them". Nine of the fourteen below are on that list. They
    ///   are absent on purpose and there is nothing to fix; asking for them
    ///   to be documented is asking the platform to reverse a stated policy.
    /// - `EXTRA_PATHS` hand-writes operations for routes registered as plain
    ///   Hono handlers, which the `createRoute` reflection cannot see. It
    ///   carries `/events` and `/oauth2/register` today. The remaining five
    ///   below are that same shape and were not added to it. Whether that
    ///   was a decision or an oversight is not recorded anywhere, so those
    ///   entries say "no decision on record" rather than guessing.
    ///
    /// So an entry here is not evidence of a hole in spec generation, and
    /// "get it documented upstream" is the wrong instruction for nine of the
    /// fourteen. Read the entry before acting on it.
    ///
    /// An entry appearing here that is neither of those two shapes is a real
    /// failure worth chasing: it means the SDK calls a path the server does
    /// not serve, and every call through it 404s.
    private static let undeclaredUpstream: [String: String] = [

        // Excluded from the public reference on purpose. Each of these is
        // registered with `createRoute`, so the reflection does see it; the
        // finalizing pass then drops it by operationId. `AdminNamespace`
        // exists to drive exactly this internal surface, so the SDK calling
        // routes the public reference omits is the intended arrangement
        // rather than drift.

        "GET /admin/spaces":
            "Excluded from the public reference on purpose, by operationId `adminListSpaces`. Registered and served; dropped from the document as platform-internal.",

        "GET /admin/spaces/{}":
            "Excluded on purpose, by operationId `adminGetSpace`.",

        "GET /admin/spaces/{}/keys":
            "Excluded on purpose, by operationId `adminListSpaceKeys`.",

        "GET /admin/spaces/{}/metrics":
            "Excluded on purpose, by operationId `adminGetSpaceMetrics`.",

        "POST /admin/spaces/{}/suspend":
            "Excluded on purpose, by operationId `adminSuspendSpace`.",

        "POST /admin/spaces/{}/unsuspend":
            "Excluded on purpose, by operationId `adminUnsuspendSpace`.",

        "POST /admin/account-deletion/purge-now":
            "Excluded on purpose, by operationId `adminPurgePendingDeletions`.",

        "GET /spaces/{}/quotas":
            "Excluded on purpose, by operationId `getSpaceQuotas`. The exclusion list annotates it \"platform-admin, by space id\": the self-service `/spaces/me/quotas` is public and declared, and this by-id form is the internal one. Not the accidental omission the path shape suggests.",

        "PUT /spaces/{}/quotas":
            "Excluded on purpose, by operationId `updateSpaceQuotas`, alongside the GET above.",

        // Invisible to the reflection rather than excluded from it. These
        // are plain Hono handlers, and the document is built by reflecting
        // `createRoute` registrations. `EXTRA_PATHS` exists precisely to
        // hand-write operations for this shape and carries two routes
        // already; none of the five below was added to it, and nothing
        // upstream says whether that was decided or simply not done.

        "POST /auth/account/delete":
            "No decision on record. A plain Hono handler, so the reflection never sees it, and it was not added to the hand-written block that documents routes of exactly this shape.",

        "GET /auth/account/delete/confirm":
            "No decision on record. Same handler file and same reason as the initiate step above — the confirmation link the emailed token resolves to.",

        "POST /auth/account/delete/cancel":
            "No decision on record. Same handler file and same reason; the third step of a flow the document describes at none of its steps.",

        "HEAD /blobs/{}":
            "No decision on record. `createRoute` cannot express `HEAD`, so the handler is registered directly and carries a comment saying so, which puts it out of the reflection's reach. `GET /blobs/{hash}` is declared; there is no `DELETE` on this path in either document, and the server does not serve one.",

        "GET /health":
            "No decision on record. A plain Hono router mounted outside the typed API surface, invisible to the reflection for the same reason as the account-deletion trio. A liveness probe with no request or response schema is arguably right to leave undocumented — `MarfaClient.health()` reads only the status code — but nothing upstream states that, so this records the mechanism and not a rationale.",
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
    /// parameter lists and helpers forwarding their own arguments, neither
    /// of which is a route the SDK calls. That exclusion would hide a route
    /// literal written inside `Transport/`, so `noRouteLiteralsHideInTransport`
    /// below asserts there are none rather than assuming it.
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

    private func transportSourceFiles() throws -> [URL] {
        let transport = packageRoot.appendingPathComponent("Sources/MarfaSDK/Transport")
        let enumerator = try #require(
            FileManager.default.enumerator(at: transport, includingPropertiesForKeys: nil),
            "Sources/MarfaSDK/Transport is not readable")
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    private static func regex(_ pattern: String) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: pattern)
    }

    /// `NSRange` locations are UTF-16 offsets; failure messages want line
    /// numbers, because "the scan cannot see this call site" is only
    /// actionable if it says which one.
    private static func line(of utf16Offset: Int, in text: String) -> Int {
        let index = String.Index(utf16Offset: utf16Offset, in: text)
        return text[text.startIndex..<index].filter { $0 == "\n" }.count + 1
    }

    // MARK: - Reading Swift source well enough to be believed

    /// A copy of `source` with every comment character replaced by a space,
    /// newlines kept, and every other character left where it was.
    ///
    /// Offsets are preserved to the UTF-16 unit — a blanked character emits
    /// as many spaces as it occupied — so a range computed on the result is
    /// a range in the original file, and line numbers survive.
    ///
    /// Comments are stripped before anything else reads the source because
    /// prose otherwise reads as code. `Sources/MarfaSDK` today contains a
    /// sentence with "method:" in it and a doc comment showing
    /// `local(path: "/path/to/store.sqlite")`, and both would be reported as
    /// escaped call sites by the cross-checks below.
    ///
    /// **What this is not.** It is not a lexer. String literals are honored
    /// so a `//` inside one survives, `"""` blocks are skipped whole, and a
    /// single-line literal is closed at the newline so a misread cannot run
    /// past one line. Raw literals (`#"…"#`) and a nested string literal
    /// inside an interpolation are read as ordinary literals, which can
    /// misjudge where a literal ends — bounded to the rest of that line. The
    /// `"""` branch is the one misread that would not be bounded to a line.
    ///
    /// A mistake here is not covered evenly. `transport.…` call shapes are
    /// cross-checked against the *raw* file, so blanking one of those is
    /// reported rather than silent. The `method:` and `path:` cross-checks
    /// read this output instead, so a mistake that hides one of them — an
    /// HTTP call reached through some other binding — would go unreported,
    /// and the vacuity floors are all that stand behind it.
    private static func strippingComments(_ source: String) -> String {
        let characters = Array(source)
        var output: [Character] = []
        output.reserveCapacity(characters.count)

        func blank(_ character: Character) {
            if character == "\n" {
                output.append(character)
            } else {
                for _ in 0..<character.utf16.count { output.append(" ") }
            }
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil

            if character == "/", next == "/" {
                while index < characters.count, characters[index] != "\n" {
                    blank(characters[index])
                    index += 1
                }
                continue
            }

            if character == "/", next == "*" {
                // Swift block comments nest.
                var depth = 0
                while index < characters.count {
                    if characters[index] == "/", index + 1 < characters.count,
                        characters[index + 1] == "*" {
                        depth += 1
                        blank(characters[index])
                        blank(characters[index + 1])
                        index += 2
                        continue
                    }
                    if characters[index] == "*", index + 1 < characters.count,
                        characters[index + 1] == "/" {
                        depth -= 1
                        blank(characters[index])
                        blank(characters[index + 1])
                        index += 2
                        if depth == 0 { break }
                        continue
                    }
                    blank(characters[index])
                    index += 1
                }
                continue
            }

            if character == "\"", index + 2 < characters.count,
                characters[index + 1] == "\"", characters[index + 2] == "\"" {
                output.append(contentsOf: characters[index...(index + 2)])
                index += 3
                while index < characters.count {
                    if characters[index] == "\"", index + 2 < characters.count,
                        characters[index + 1] == "\"", characters[index + 2] == "\"" {
                        output.append(contentsOf: characters[index...(index + 2)])
                        index += 3
                        break
                    }
                    output.append(characters[index])
                    index += 1
                }
                continue
            }

            if character == "\"" {
                output.append(character)
                index += 1
                while index < characters.count, characters[index] != "\n" {
                    if characters[index] == "\\", index + 1 < characters.count {
                        output.append(characters[index])
                        output.append(characters[index + 1])
                        index += 2
                        continue
                    }
                    let inner = characters[index]
                    output.append(inner)
                    index += 1
                    if inner == "\"" { break }
                }
                continue
            }

            output.append(character)
            index += 1
        }
        return String(output)
    }

    /// One argument from a call's argument list, as written.
    private struct Argument {
        let label: String?
        let value: String
    }

    /// Splits the argument list opened by the `(` at `openParen`, returning
    /// the arguments and the index just past the matching `)`. `nil` means
    /// the list could not be read to a balanced close, which is reported
    /// rather than skipped.
    ///
    /// Expects comment-stripped text. Tracks paren, bracket and brace depth,
    /// string literals, and interpolations — an interpolation is code inside
    /// a literal, so `path: "/items/\(id)"` splits as one argument and not
    /// three.
    private static func argumentList(in text: String, openParenAt openParen: String.Index)
        -> (arguments: [Argument], end: String.Index)? {
        enum Mode { case code, string }
        var modes: [Mode] = [.code]
        var depths: [Int] = [1]
        var arguments: [Argument] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !trimmed.isEmpty else { return }
            arguments.append(labeled(trimmed))
        }

        var index = text.index(after: openParen)
        while index < text.endIndex {
            let character = text[index]
            switch modes[modes.count - 1] {
            case .code:
                if character == "\"" {
                    modes.append(.string)
                    current.append(character)
                    index = text.index(after: index)
                    continue
                }
                if character == "(" || character == "[" || character == "{" {
                    depths[depths.count - 1] += 1
                    current.append(character)
                    index = text.index(after: index)
                    continue
                }
                if character == ")" || character == "]" || character == "}" {
                    depths[depths.count - 1] -= 1
                    if depths[depths.count - 1] == 0 {
                        if modes.count == 1 {
                            flush()
                            return (arguments, text.index(after: index))
                        }
                        // Closes an interpolation; back inside the literal.
                        modes.removeLast()
                        depths.removeLast()
                        current.append(character)
                        index = text.index(after: index)
                        continue
                    }
                    current.append(character)
                    index = text.index(after: index)
                    continue
                }
                if character == ",", modes.count == 1, depths[0] == 1 {
                    flush()
                    index = text.index(after: index)
                    continue
                }
                current.append(character)
                index = text.index(after: index)
            case .string:
                if character == "\\" {
                    let next = text.index(after: index)
                    guard next < text.endIndex else { return nil }
                    if text[next] == "(" {
                        modes.append(.code)
                        depths.append(1)
                        current.append(character)
                        current.append(text[next])
                        index = text.index(after: next)
                        continue
                    }
                    current.append(character)
                    current.append(text[next])
                    index = text.index(after: next)
                    continue
                }
                if character == "\"" {
                    modes.removeLast()
                    current.append(character)
                    index = text.index(after: index)
                    continue
                }
                if character == "\n" { return nil }
                current.append(character)
                index = text.index(after: index)
            }
        }
        return nil
    }

    /// Splits `"label: value"` into its parts. A value that merely contains
    /// a colon (a ternary, a dictionary type) has no leading identifier and
    /// so keeps a `nil` label.
    private static func labeled(_ argument: String) -> Argument {
        var index = argument.startIndex
        while index < argument.endIndex,
            argument[index].isLetter || argument[index].isNumber || argument[index] == "_" {
            index = argument.index(after: index)
        }
        guard index > argument.startIndex, index < argument.endIndex, argument[index] == ":" else {
            return Argument(label: nil, value: argument)
        }
        let after = argument.index(after: index)
        guard after == argument.endIndex || argument[after] != ":" else {
            return Argument(label: nil, value: argument)
        }
        let value = String(argument[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Argument(label: String(argument[argument.startIndex..<index]), value: value)
    }

    /// The contents of `value` when it is exactly one string literal, and
    /// `nil` for anything else.
    ///
    /// `"/items/\(id)"` yields `/items/\(id)`. `"/items" + suffix` yields
    /// `nil`, and that case is the reason this function exists: reading only
    /// the leading literal produces `GET /items`, which is a route the spec
    /// declares, so a composed path aliases onto a legitimate operation and
    /// neither direction of the check fires. Wrong-but-loud is recoverable;
    /// that shape was neither.
    private static func soleStringLiteral(_ value: String) -> String? {
        guard value.first == "\"", value.count >= 2 else { return nil }
        var depth = 0
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            let character = value[index]
            if depth == 0 {
                if character == "\\" {
                    let next = value.index(after: index)
                    guard next < value.endIndex else { return nil }
                    if value[next] == "(" {
                        depth = 1
                        index = value.index(after: next)
                        continue
                    }
                    index = value.index(after: next)
                    continue
                }
                if character == "\"" {
                    // Anything after the closing quote is concatenation or an
                    // operator, so the argument is not a literal path.
                    guard value.index(after: index) == value.endIndex else { return nil }
                    return String(value[value.index(after: value.startIndex)..<index])
                }
            } else {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
            }
            index = value.index(after: index)
        }
        return nil
    }

    // MARK: - Recovering the call sites

    /// One `transport.<something>(…)` call recovered from source.
    private struct TransportCall {
        let callee: String
        let arguments: [Argument]
        let line: Int
        /// UTF-16 range of the whole call, for the cross-checks.
        let range: NSRange
    }

    private struct ScannedFile {
        let name: String
        /// The file as committed. The cross-check that nothing call-shaped
        /// escaped the scan reads this, so a comment-stripping mistake
        /// cannot hide a call site from it.
        let raw: String
        let stripped: String
        let calls: [TransportCall]
    }

    /// Every HTTP call the SDK makes **through `Transport`**, recovered by
    /// finding each `transport.<callee>(` and reading its argument list.
    ///
    /// **What this does not cover, and it is a whole subsystem.** The OAuth
    /// code builds `URLRequest`s directly and never touches `Transport`:
    /// `OAuthDiscovery`, `TokenProvider`, `DeviceFlow`, `MarfaAuth` and
    /// `MarfaSession` between them fetch the discovery document, the token
    /// endpoint, the device-authorization endpoint, the device-token
    /// endpoint and the revocation endpoint. All but the discovery document
    /// are URLs *read out of that document at runtime*, so there is no path
    /// literal in this repository to compare and no operation in the spec
    /// they would correspond to. `Passkey` is a third shape again: it hands
    /// `/auth/passkey/enroll` to a system browser rather than requesting it.
    /// None of that is in frame here, and "every route the SDK calls" would
    /// be a false description of what this returns.
    ///
    /// Within the `Transport` subsystem the coverage is checked rather than
    /// assumed — see `everyTransportCallIsReadable` and
    /// `nothingCallShapedEscapesTheScan`.
    private func scanSDKSources() throws -> [ScannedFile] {
        let receiver = try Self.regex(#"\btransport\s*\.\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\("#)
        var scanned: [ScannedFile] = []

        for file in try sdkSourceFiles() {
            let raw = try String(contentsOf: file, encoding: .utf8)
            let stripped = Self.strippingComments(raw)
            let whole = NSRange(stripped.startIndex..., in: stripped)
            var calls: [TransportCall] = []

            for match in receiver.matches(in: stripped, range: whole) {
                guard
                    let calleeRange = Range(match.range(at: 1), in: stripped),
                    let matchRange = Range(match.range, in: stripped)
                else { continue }
                let openParen = stripped.index(before: matchRange.upperBound)
                let parsed = Self.argumentList(in: stripped, openParenAt: openParen)
                let end = parsed?.end ?? matchRange.upperBound
                calls.append(
                    TransportCall(
                        callee: String(stripped[calleeRange]),
                        // A list that would not close reads as no arguments,
                        // which fails the readability check below by way of
                        // the missing `path:`.
                        arguments: parsed?.arguments ?? [],
                        line: Self.line(of: match.range.location, in: stripped),
                        range: NSRange(matchRange.lowerBound..<end, in: stripped)))
            }
            scanned.append(
                ScannedFile(
                    name: file.lastPathComponent, raw: raw, stripped: stripped, calls: calls))
        }
        return scanned
    }

    /// What a call site yielded: a route, or why it could not be read. The
    /// second case is never dropped — every caller either counts the route
    /// or reports the reason.
    private enum ReadCall {
        case route(String)
        case unreadable(String)
    }

    /// The route a call targets, or the reason it could not be read.
    private static func read(_ call: TransportCall) -> ReadCall {
        guard let path = call.arguments.first(where: { $0.label == "path" }) else {
            return .unreadable("no `path:` argument, so there is no route to read")
        }
        guard let literal = soleStringLiteral(path.value) else {
            return .unreadable("`path:` is not a single string literal (`\(path.value)`)")
        }

        if let method = call.arguments.first(where: { $0.label == "method" }) {
            let name = method.value.dropFirst()
            guard method.value.first == ".", !name.isEmpty,
                name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else {
                return .unreadable("`method:` is not a literal case (`\(method.value)`)")
            }
            return .route(name.uppercased() + " " + normalize(literal))
        }
        // `eventStream` takes no `method:` — it is a GET by construction.
        // Anything else without one has a defaulted or omitted verb, and a
        // route whose verb is a guess is worse than one that is reported.
        guard call.callee == "eventStream" else {
            return .unreadable("no `method:` argument, so the verb is defaulted or omitted")
        }
        return .route("GET " + normalize(literal))
    }

    /// Routes keyed `"METHOD /path"`, mapped to where each is called.
    private func routesCalledBySDK() throws -> [String: [String]] {
        var routes: [String: [String]] = [:]
        for file in try scanSDKSources() {
            for call in file.calls {
                guard case .route(let key) = Self.read(call) else { continue }
                let suffix = call.callee == "eventStream" ? " (SSE)" : ""
                routes[key, default: []].append("\(file.name):\(call.line)\(suffix)")
            }
        }
        return routes
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
    /// a vacuous pass in one direction and noise in the other, which is
    /// indistinguishable from the drift they exist to catch.
    ///
    /// These floors are the *last* line, not the first: a call site the scan
    /// cannot read is already reported by name and line below, so the only
    /// failure left for a floor to catch is the scan collapsing wholesale —
    /// a comment-stripping mistake that swallows a file, a receiver pattern
    /// that stops matching, an unreadable snapshot. The margin is a handful
    /// of routes so that removing a wrapper or two does not fail the suite,
    /// and no wider: the floors these replaced sat twelve below the real
    /// counts, which let a scan lose a whole namespace and stay green.
    @Test("extraction finds a plausible number of call sites and operations")
    func extractionIsNotVacuous() throws {
        let called = try routesCalledBySDK()
        let declared = try routesDeclaredInSpec()
        #expect(called.count >= 88, "route extraction found \(called.count) operations, which is too few to be right")
        #expect(declared.count >= 100, "the snapshot declares \(declared.count) operations, which is too few to be right")
        // The SSE stream is the call shape with no `method:` label. If this
        // is missing, `eventStream` has stopped being recognized and `GET
        // /events` is about to be reported as an unwrapped operation.
        #expect(called["GET /events"] != nil, "the SSE call site was not extracted, so the scan is missing every method-less call")
    }

    /// Every recovered `transport.…` call has to yield a route.
    ///
    /// **The guarantee, stated exactly.** Every call written as
    /// `transport.<callee>(…)` in the scanned sources is either read into a
    /// `METHOD /path` or named here with the reason it could not be. That
    /// covers the three shapes that previously slipped through both the scan
    /// and the guard that claimed to police it: a `method:` argument left to
    /// a default, a verb held in a variable, and a path composed from more
    /// than one literal — the last being the dangerous one, because its
    /// leading literal normalizes onto a route the spec declares and so
    /// neither direction fires.
    ///
    /// **What it does not guarantee.** An HTTP call that does not go through
    /// a binding spelled `transport` is outside this entirely; the OAuth
    /// `URLRequest` code is, by design. Under-reporting is the failure mode
    /// this suite is built around, so what is checked is stated rather than
    /// implied.
    @Test("every transport call site is read into a route, or reported")
    func everyTransportCallIsReadable() throws {
        var unreadable: [String] = []
        for file in try scanSDKSources() {
            for call in file.calls {
                if case .unreadable(let reason) = Self.read(call) {
                    unreadable.append("\(file.name):\(call.line) — \(reason)")
                }
            }
        }
        #expect(
            unreadable.isEmpty,
            """
            these transport calls could not be read into a route, so the scan would \
            under-report coverage. Write the call with a literal `method:` and a \
            single-literal `path:`, or teach the scan the new shape — do not park a \
            working wrapper in `deliberatelyUnwrapped`:
            \(unreadable.sorted().joined(separator: "\n"))
            """)
    }

    /// The scan is only as good as its scope, so the scope is checked too.
    ///
    /// Three ways a route could sit outside it: text that looks like a
    /// transport call but was not recovered (a comment-stripping mistake, or
    /// a call the receiver pattern misses), a `method:` or route-shaped
    /// `path:` argument outside every recovered call (an HTTP call reached
    /// through some other binding), and a route literal inside the
    /// `Transport/` directory the file scan deliberately skips — that last
    /// one is `noRouteLiteralsHideInTransport` below.
    @Test("nothing call-shaped escapes the scan")
    func nothingCallShapedEscapesTheScan() throws {
        let receiver = try Self.regex(#"\btransport\s*\.\s*[a-zA-Z_][a-zA-Z0-9_]*\s*\("#)
        let methodLabel = try Self.regex(#"\bmethod\s*:"#)
        let routePathLabel = try Self.regex(#"\bpath\s*:\s*"/"#)

        var escaped: [String] = []
        for file in try scanSDKSources() {
            let recovered = Set(file.calls.map(\.range.location))
            let covered = file.calls.map(\.range)
            func isCovered(_ location: Int) -> Bool {
                covered.contains { NSLocationInRange(location, $0) }
            }

            // Read from the raw file, not the stripped copy: a call site the
            // stripper wrongly blanked has to surface here rather than
            // vanish. A doc comment that spells a call as `transport.foo(`
            // fails this — write it as ``Transport/foo(method:path:)``.
            let rawWhole = NSRange(file.raw.startIndex..., in: file.raw)
            for match in receiver.matches(in: file.raw, range: rawWhole)
            where !recovered.contains(match.range.location) {
                escaped.append(
                    "\(file.name):\(Self.line(of: match.range.location, in: file.raw)) — call-shaped text the scan did not recover")
            }

            let whole = NSRange(file.stripped.startIndex..., in: file.stripped)
            for match in methodLabel.matches(in: file.stripped, range: whole)
            where !isCovered(match.range.location) {
                escaped.append(
                    "\(file.name):\(Self.line(of: match.range.location, in: file.stripped)) — `method:` argument outside any transport call")
            }
            for match in routePathLabel.matches(in: file.stripped, range: whole)
            where !isCovered(match.range.location) {
                escaped.append(
                    "\(file.name):\(Self.line(of: match.range.location, in: file.stripped)) — route-shaped `path:` argument outside any transport call")
            }
        }
        #expect(
            escaped.isEmpty,
            """
            these look like HTTP calls the route scan cannot account for. Either they \
            are routes going uncounted, or the scan needs teaching:
            \(escaped.sorted().joined(separator: "\n"))
            """)
    }

    /// `Transport/` is skipped by the file scan because it declares the
    /// request methods rather than calling them. That is true today and
    /// nothing enforced it, so this does.
    @Test("no route literals hide in the excluded Transport directory")
    func noRouteLiteralsHideInTransport() throws {
        let routeLiteral = try Self.regex(#""/[a-zA-Z]"#)
        var found: [String] = []
        for file in try transportSourceFiles() {
            let stripped = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            let whole = NSRange(stripped.startIndex..., in: stripped)
            for match in routeLiteral.matches(in: stripped, range: whole) {
                found.append(
                    "\(file.lastPathComponent):\(Self.line(of: match.range.location, in: stripped))")
            }
        }
        #expect(
            found.isEmpty,
            """
            `Sources/MarfaSDK/Transport` is excluded from the route scan on the \
            grounds that it holds no route literals. It now does, and those routes \
            are uncounted: \(found.sorted())
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
            not listed as known spec gaps. This is not a missing wrapper. Establish \
            which of three it is before recording it: the route is internal and \
            excluded from the public reference on purpose (record that, and change \
            nothing upstream), it is a plain handler the reflection cannot see \
            (record that too, and say whether leaving it undocumented was decided), \
            or the path is wrong and these calls 404:
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
