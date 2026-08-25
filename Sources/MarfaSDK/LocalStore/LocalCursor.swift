import Foundation

/// Pagination cursor for the local store.
///
/// Opaque to callers, like the server's, and carried in the same
/// `ListFilters.cursor` field — but it is **not** the server's cursor and the
/// two are not interchangeable. The server keysets over `(sort value, id)`.
/// This windows by offset.
///
/// That difference is deliberate and worth stating rather than discovering.
/// A keyset boundary was implemented here first, because matching the server
/// exactly is the better contract: it survives concurrent writes, where an
/// offset can skip a row or repeat one if the store is written to between
/// pages. It does not survive the compiler. Expressing "after this value, or
/// equal to it and after this id" inside `#Predicate` means naming a sort
/// column and both directions, and the macro pushes the type-checker past
/// what it will accept ("unable to type-check this expression in reasonable
/// time"). The predicate it would have to live in is shared by every reactive
/// query, so it is the last place to spend that budget.
///
/// **What this costs.** A caller that pages a local store while sync is
/// writing to it can miss a row or see one twice. A caller that pages a
/// quiescent store — an export, a migration, an enumeration on a client that
/// is not syncing — gets exactly the right rows. Nothing in the SDK pages a
/// store it is concurrently writing.
///
/// A cursor minted by one is rejected by the other rather than silently
/// misread: the shapes do not decode as each other, and the paging entry
/// points throw ``ValidationError`` on a cursor they cannot read.
struct LocalCursor: Codable, Equatable {
    /// Rows already returned. The next page starts here.
    let o: Int

    func encoded() -> String {
        // Encoding one Int into a fixed shape has no failure mode reachable
        // from here, so the empty fallback is unreachable rather than a
        // swallowed error, and a cursor is not worth a throwing API on every
        // caller for a branch that cannot be taken.
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.base64URL(data)
    }

    /// The offset a cursor names, or `nil` when it is not one of ours.
    ///
    /// Lenient because the shared descriptor builder is not a throwing
    /// context and does not page; the paging entry points call
    /// ``validated(_:)`` first so a bad cursor fails loudly where it matters
    /// rather than quietly returning page one forever.
    static func offset(decoding raw: String) -> Int? {
        guard let data = base64URLDecode(raw),
              let cursor = try? JSONDecoder().decode(LocalCursor.self, from: data),
              cursor.o >= 0
        else { return nil }
        return cursor.o
    }

    /// Throws when a non-empty cursor cannot be read. Silently starting over
    /// is the failure mode this whole change exists to remove: a caller
    /// looping on a cursor it cannot advance would page forever or truncate,
    /// and either way never learn why.
    static func validated(_ raw: String?) throws -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let offset = offset(decoding: raw) else {
            throw ValidationError(
                message: "Invalid pagination cursor. Local-store cursors come from a previous page of the same client; a cursor minted by the server cannot be used against a local store."
            )
        }
        return offset
    }

    // Foundation has no base64url codec. The transform is the standard one:
    // the two URL-unsafe alphabet characters are swapped and padding dropped,
    // which is what `Buffer.toString("base64url")` produces server side.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ raw: String) -> Data? {
        var s = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}
