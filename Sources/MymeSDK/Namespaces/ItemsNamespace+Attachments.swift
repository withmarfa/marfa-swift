import Foundation

// MARK: - items.createWithAttachments — atomic host + attachments helper

/// Input to ``ItemsNamespace/createWithAttachments(_:)`` (T-100).
///
/// Wraps the existing blob-upload + `items.bulk` pattern: upload each
/// attachment's blob, then issue one atomic bulk call containing the
/// host item and the `core.file.*` items with inline edges from each
/// attachment back to the host.
public struct CreateWithAttachmentsInput: Sendable {

    /// The host item — the thing the attachments are attached *to*
    /// (note, message, etc.). The helper may stamp an `id` into this
    /// before the bulk write if none is supplied; arbitrary `edges`
    /// on the host pass through unchanged into the bulk payload.
    public var item: BulkItemInput

    /// Attachments in caller-supplied order. The returned
    /// ``CreateWithAttachmentsResult/attachments`` array preserves the
    /// same order. An empty array is valid: the helper still issues one
    /// `items.bulk` call with just the host item (no uploads, no
    /// auto-edges).
    public var attachments: [Attachment]

    /// Edge type from each attachment back to the host. Defaults to
    /// `"attached-to"` (the canonical attachment edge — T-108).
    /// Override for app-specific semantics like `"cover-image"`.
    public var edgeType: String

    public init(
        item: BulkItemInput,
        attachments: [Attachment] = [],
        edgeType: String = "attached-to"
    ) {
        self.item = item
        self.attachments = attachments
        self.edgeType = edgeType
    }

    /// One attachment to upload + create alongside the host item.
    public struct Attachment: Sendable {
        /// Type id, e.g. `"core.file.image"`.
        public var type: String
        /// Raw blob bytes. Uploaded via `POST /blobs`.
        public var data: Data
        /// Sent as the `Content-Type` of the blob upload and stamped
        /// onto the attachment item's `mime_type` property automatically.
        public var mimeType: String
        /// Caller-supplied properties for this attachment item (e.g.
        /// `width` and `height` for `core.file.image`). The helper
        /// auto-fills `blob_ref` (= upload hash) and `mime_type` after
        /// upload; do not pre-populate them.
        public var properties: [String: JSONValue]
        /// Optional additional edges on the attachment item. The helper
        /// appends its own `[edgeType]: [hostId]` entry; if you pass a
        /// value for the same `edgeType`, your ids are merged with the
        /// host id (helper-added edges are additive, never stripping).
        public var edges: [String: [String]]
        /// Explicit attachment id (defaults to a client-minted UUIDv7).
        public var id: String?

        public init(
            type: String,
            data: Data,
            mimeType: String,
            properties: [String: JSONValue] = [:],
            edges: [String: [String]] = [:],
            id: String? = nil
        ) {
            self.type = type
            self.data = data
            self.mimeType = mimeType
            self.properties = properties
            self.edges = edges
            self.id = id
        }
    }
}

/// Outcome of ``ItemsNamespace/createWithAttachments(_:)``.
public struct CreateWithAttachmentsResult: Sendable {
    /// The host item, hydrated server-side after the bulk write.
    public let host: Item
    /// Attachment items in the same order as the input.
    public let attachments: [Item]

    public init(host: Item, attachments: [Item]) {
        self.host = host
        self.attachments = attachments
    }
}

public extension ItemsNamespace {

    /// Atomic host-item + attachment-item write with auto-edges. The
    /// canonical flow for "create a note and attach a photo" / "create a
    /// message with a video" — equivalent to the TS SDK's
    /// `client.items.createWithAttachments`.
    ///
    /// **Sequence.**
    /// 1. Upload every attachment's blob concurrently via
    ///    ``BlobsNamespace/upload(data:mimeType:onProgress:)``. Any
    ///    upload failure is surfaced as an annotated ``MymeError`` whose
    ///    underlying error becomes the chained cause.
    /// 2. Build one ``BulkInput`` containing the host item plus one
    ///    `core.file.*` item per attachment. Each attachment carries an
    ///    auto-`attached-to` edge to the host id (override the edge type
    ///    via ``CreateWithAttachmentsInput/edgeType``).
    /// 3. Issue a single `POST /items/bulk` with
    ///    `mode: .createOnly` and `atomic: true` so the host + every
    ///    attachment either all land or none do.
    /// 4. Hydrate the host + attachments via per-id reads (bulk returns
    ///    `BulkResultEntry { id, outcome }`, not the full ``Item``).
    ///
    /// **Failure modes.**
    /// - Blob upload failure → throws `blob_upload_failed` annotating
    ///   the failing index and type, with the underlying error chained
    ///   in the message. No items are created.
    /// - Bulk write `errored` outcome → throws ``ValidationError``
    ///   annotating the offending index. The orphaned blobs from
    ///   the upload step remain reachable by hash; the server's blob
    ///   GC reaps them once they are unreferenced for the configured
    ///   window.
    /// - Bulk write `skipped` outcome → throws ``ConflictError`` with
    ///   code `duplicate_id`. The helper guarantees a fresh create on
    ///   every call, so any `create_only` collision means a
    ///   caller-supplied ``BulkItemInput/id`` already exists.
    ///
    /// **Edge-merge semantics.** Caller-provided edges on the host item
    /// pass through unchanged. Caller-provided edges on an attachment
    /// with the same ``CreateWithAttachmentsInput/edgeType`` key have
    /// the host id *appended* to that array — helper-added edges are
    /// additive, never strip-and-replace.
    ///
    /// **Empty attachments.** Passing an empty `attachments` array is
    /// valid: the helper still issues a single bulk call with just the
    /// host item, lets callers use this method as a uniform entry point
    /// regardless of whether attachments are present.
    func createWithAttachments(
        _ input: CreateWithAttachmentsInput
    ) async throws -> CreateWithAttachmentsResult {
        // Local + synced modes don't have a clean "atomic across the
        // local store and the queue" story today (parked follow-on in
        // T-155). Reject loudly rather than partial-state on the local
        // side; callers that need pure-local attachments can fall back
        // to the per-call primitives until the dual-save atomicity work
        // lands.
        if localStore != nil {
            throw LocalModeUnsupportedError(
                operation: "items.createWithAttachments"
            )
        }

        // Step 1 — upload every blob concurrently. TaskGroup preserves
        // index ↔ result ordering via the (index, response) tuple so
        // the per-attachment assembly downstream is deterministic.
        let uploads = try await uploadAttachments(input.attachments)

        // Step 2 — build the bulk payload. Host first, then attachments
        // in declared order. Host id is stamped if absent so step 4 can
        // hydrate by id.
        let hostId = input.item.id ?? UUIDv7.generateString()
        var hostBulkItem = input.item
        hostBulkItem.id = hostId

        var attachmentIds: [String] = []
        attachmentIds.reserveCapacity(input.attachments.count)
        var attachmentBulkItems: [BulkItemInput] = []
        attachmentBulkItems.reserveCapacity(input.attachments.count)

        for (idx, attachment) in input.attachments.enumerated() {
            let attachmentId = attachment.id ?? UUIDv7.generateString()
            attachmentIds.append(attachmentId)

            // Auto-fill blob_ref + mime_type onto the attachment's
            // properties. Caller-supplied keys for these are
            // overwritten (the upload hash is authoritative).
            var properties = attachment.properties
            properties["blob_ref"] = .string(uploads[idx].hash)
            properties["mime_type"] = .string(attachment.mimeType)

            // Merge the auto-edge with caller-supplied edges of the
            // same type. Additive — host id appended, not overwriting.
            var mergedEdges = attachment.edges
            let existing = mergedEdges[input.edgeType] ?? []
            mergedEdges[input.edgeType] = existing + [hostId]

            attachmentBulkItems.append(
                BulkItemInput(
                    id: attachmentId,
                    type: attachment.type,
                    properties: properties,
                    edges: mergedEdges
                )
            )
        }

        let bulkInput = BulkInput(
            items: [hostBulkItem] + attachmentBulkItems,
            mode: .createOnly,
            atomic: true
        )

        // Step 3 — the single atomic bulk write.
        let bulkResult = try await bulk(bulkInput)

        // Step 4 — surface server-side errors before the hydrate step.
        // `atomic: true` means a single errored entry rolls the whole
        // batch back server-side; we still translate the outcome into
        // a typed throw for the caller.
        if let errored = bulkResult.results.first(where: { $0.outcome == .errored }) {
            let message = errored.error?.message ?? errored.reason ?? "unknown"
            throw ValidationError(
                message: "createWithAttachments: bulk write failed at index \(errored.index): \(message)",
                details: nil
            )
        }
        if let skipped = bulkResult.results.first(where: { $0.outcome == .skipped }) {
            throw ConflictError(
                message: "createWithAttachments: bulk write skipped at index \(skipped.index) (reason: \(skipped.reason ?? "unknown")). The helper requires fresh ids — if you passed an explicit `item.id`, it must not already exist.",
                details: nil
            )
        }

        // Step 5 — hydrate the items via per-id reads (concurrent).
        // Order is preserved by holding (index, item) tuples and
        // sorting on join.
        let hydrationOrder = [hostId] + attachmentIds
        let hydrated = try await withThrowingTaskGroup(
            of: (Int, Item).self
        ) { group in
            for (idx, id) in hydrationOrder.enumerated() {
                group.addTask { (idx, try await self.get(id: id)) }
            }
            var collected = Array<Item?>(repeating: nil, count: hydrationOrder.count)
            for try await (idx, item) in group {
                collected[idx] = item
            }
            return collected.compactMap { $0 }
        }

        guard hydrated.count == hydrationOrder.count, let host = hydrated.first else {
            throw MymeError(
                code: "internal_error",
                message: "createWithAttachments: host hydration returned no item",
                status: 500
            )
        }

        return CreateWithAttachmentsResult(
            host: host,
            attachments: Array(hydrated.dropFirst())
        )
    }

    /// Uploads every attachment's blob concurrently. Surfaces upload
    /// failures with the offending index annotated. Result order matches
    /// input order.
    private func uploadAttachments(
        _ attachments: [CreateWithAttachmentsInput.Attachment]
    ) async throws -> [BlobUploadResponse] {
        // `apiBaseURL` is populated for every non-pure-local client,
        // and the pure-local branch above short-circuits before reaching
        // upload. The fallback URL is only here to keep `BlobsNamespace`
        // constructible without a force-unwrap; it's never used by
        // `upload(...)` itself (only `url(hash:)` references it).
        let blobs = BlobsNamespace(
            transport: transport,
            apiBaseURL: apiBaseURL ?? URL(fileURLWithPath: "/dev/null"),
            cdnBaseURL: nil,
            mutationQueue: nil,
            isLocalMode: false
        )

        return try await withThrowingTaskGroup(
            of: (Int, BlobUploadResponse).self
        ) { group in
            for (idx, attachment) in attachments.enumerated() {
                group.addTask {
                    do {
                        let response = try await blobs.upload(
                            data: attachment.data,
                            mimeType: attachment.mimeType
                        )
                        return (idx, response)
                    } catch {
                        throw MymeError(
                            code: "blob_upload_failed",
                            message: "createWithAttachments: blob upload failed for attachments[\(idx)] (type=\(attachment.type)): \(error.localizedDescription)",
                            status: 502
                        )
                    }
                }
            }
            var collected = Array<BlobUploadResponse?>(repeating: nil, count: attachments.count)
            for try await (idx, response) in group {
                collected[idx] = response
            }
            return collected.compactMap { $0 }
        }
    }
}
