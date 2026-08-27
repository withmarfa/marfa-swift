import Foundation
import SwiftData

extension LocalStore {

    /// The `sync_state` row recording which account populated this store.
    ///
    /// It lives beside `last_event_id` and `last_full_sync_at` because it
    /// answers the same kind of question — what has already happened to this
    /// file — and because that table needs no schema migration to gain a key.
    ///
    /// Read and written here rather than on ``MutationQueue``, which owns the
    /// other two, for a reason that decides whether the feature works at all: a
    /// client built by ``MarfaClient/local(path:)`` has **no** mutation queue.
    /// Putting the claim there would make it unreadable in exactly the mode a
    /// consumer is in when it needs to ask.
    private static var accountClaimKey: String { "account_identity" }

    /// The account this store was claimed by, or `nil` if none ever did.
    func accountClaim() throws -> MarfaAccountIdentity? {
        let key = Self.accountClaimKey
        let predicate = #Predicate<SyncStateModel> { $0.key == key }
        var descriptor = FetchDescriptor<SyncStateModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let raw = try modelContext.fetch(descriptor).first?.value,
              let data = raw.data(using: .utf8)
        else { return nil }
        // A row that will not decode is treated as no claim rather than as an
        // error. The honest answer then is `unclaimed`, which is the cautious
        // one on both of the paths that ask: it blocks an upload and does not
        // trigger a wipe.
        return try? JSONDecoder().decode(MarfaAccountIdentity.self, from: data)
    }

    /// Record that this store belongs to `identity`.
    func setAccountClaim(_ identity: MarfaAccountIdentity) throws {
        let encoded = try JSONEncoder().encode(identity)
        guard let value = String(data: encoded, encoding: .utf8) else {
            throw LocalStoreError.encodingFailure("account_identity")
        }
        let key = Self.accountClaimKey
        let predicate = #Predicate<SyncStateModel> { $0.key == key }
        var descriptor = FetchDescriptor<SyncStateModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.value = value
        } else {
            let model = SyncStateModel()
            model.key = key
            model.value = value
            modelContext.insert(model)
        }
        try modelContext.save()
    }

    /// Forget which account this store belongs to.
    func clearAccountClaim() throws {
        let key = Self.accountClaimKey
        let predicate = #Predicate<SyncStateModel> { $0.key == key }
        var descriptor = FetchDescriptor<SyncStateModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(model)
        try modelContext.save()
    }
}
