import Foundation
import Marfa
import MarfaTypes

/// The owner's agreement to delete an app's data for good.
///
/// Deleting an app's data purges its items and types rather than moving them to the trash, so only a backup or an
/// export taken before brings them back. Tell the owner that, and pass ``ownerConfirmed`` only once they agree.
public enum PermanentDeletion: Sendable, Hashable {
    /// The owner was told the deletion cannot be undone except from a backup, and agreed to it.
    case ownerConfirmed
}

/// What happens to an app's data when the app is disconnected.
public enum AppDataOnDisconnect: Sendable, Hashable {
    /// The app's items and types stay, and its `app.<vendor>` namespaces stay with it.
    case keep
    /// The items and types of every `app.<vendor>` namespace the app holds are deleted for good in the same write
    /// that disconnects it.
    case remove(PermanentDeletion)
}

/// How a deletion of an `app.<vendor>` namespace's data ended, as the server answered it.
public struct AppDataRemoval: Sendable {
    /// The namespace, as `app.<vendor>`.
    public let vendor: String
    /// How many items the server answered as deleted, over every call it answered.
    public let removedItems: Int
    /// How many types the server answered as deleted, over every call it answered.
    public let removedTypes: Int
    /// How many items of the namespace the last answer said are left.
    public let remainingItems: Int
    /// Why the deletion stopped while items were left, or `nil` where it did not stop early.
    ///
    /// The call that failed may still have deleted a page at the server, so the counts above are a lower bound, and
    /// listing the namespace's data shows what is left.
    public let stoppedBy: MarfaError?

    /// Whether the server answered that nothing of the namespace is left.
    public var isComplete: Bool { stoppedBy == nil && remainingItems == 0 }
}

extension Client {
    /// A page of what an app keeps under the namespace `vendor`: each type registered under it, or held by an item,
    /// with its items counted by state, and a page of its items in every state, the trash included, oldest first.
    ///
    /// `vendor` is the namespace as `app.<vendor>`. Send the page's `nextCursor` as `cursor` for the next page; it is
    /// `nil` on the last. Needs `grants.manage`, or the owner's browser session. An app's own sign-in reads only the
    /// namespaces its app holds. Throws ``MarfaError/notFound(code:message:server:)`` for a namespace no app or owner
    /// holds, and ``MarfaError/validation(code:message:details:server:)`` for a name that is not an `app.<vendor>`
    /// namespace.
    public func appData(
        vendor: String, limit: Int? = nil, cursor: String? = nil
    ) async throws(MarfaError) -> Components.Schemas.AppVendorDataPage {
        try await answer("listAppVendorData") {
            try await listAppVendorData(path: .init(vendor: vendor), query: .init(limit: limit, cursor: cursor))
                .ok.body.json
        }
    }

    /// Deletes for good every item and type under the namespace `vendor`, in every state, the trash included.
    ///
    /// Only a backup or an export taken before brings the data back, so `confirmation` stands for the owner's
    /// agreement after being told that. The namespace stays with the app or the owner that holds it, and items
    /// outside it stay; an edge from one of them to a deleted item goes.
    ///
    /// The server deletes up to 1,000 items a call, and the types in the call that leaves none, so this sends the
    /// call again until the server answers that nothing is left. Throws when the first call fails, such as
    /// ``MarfaError/forbidden(code:message:server:)`` naming `items.purge`, `grants.manage` or `schema.write` as the
    /// `required_scope`, or `type_in_use` while a folder, view, webhook or table column outside the namespace names
    /// one of its types. A failure after a call the server answered, cancellation included, is not thrown: it comes
    /// back as ``AppDataRemoval/stoppedBy`` with what the server answered so far, so check
    /// ``AppDataRemoval/isComplete``.
    ///
    /// `instanceID` makes the server refuse with ``MarfaError/instanceChanged(message:server:)`` when another
    /// instance now answers at this address.
    public func removeAppData(
        vendor: String, _ confirmation: PermanentDeletion, expecting instanceID: String? = nil
    ) async throws(MarfaError) -> AppDataRemoval {
        var removedItems = 0
        var removedTypes = 0
        var remainingItems: Int?
        while true {
            let page: Components.Schemas.AppVendorDataRemoval
            do throws(MarfaError) {
                if remainingItems != nil, Task.isCancelled {
                    throw MarfaError.canceled(message: "deleting the data of \(vendor) was canceled")
                }
                page = try await answer("deleteAppVendorData") {
                    try await deleteAppVendorData(
                        path: .init(vendor: vendor), headers: .init(xMarfaInstanceId: instanceID)
                    ).ok.body.json
                }
            } catch {
                guard let remainingItems else { throw error }
                return AppDataRemoval(
                    vendor: vendor, removedItems: removedItems, removedTypes: removedTypes,
                    remainingItems: remainingItems, stoppedBy: error)
            }
            removedItems += page.removedItems
            removedTypes += page.removedTypes
            remainingItems = page.remainingItems
            if page.remainingItems == 0 {
                return AppDataRemoval(
                    vendor: vendor, removedItems: removedItems, removedTypes: removedTypes, remainingItems: 0,
                    stoppedBy: nil)
            }
            if page.removedItems == 0 {
                // Another call would be answered the same way, so the loop would never end.
                return AppDataRemoval(
                    vendor: vendor, removedItems: removedItems, removedTypes: removedTypes,
                    remainingItems: page.remainingItems,
                    stoppedBy: .invalid(
                        message: "the server deleted no item of \(vendor) while \(page.remainingItems) are left"))
            }
        }
    }

    /// Disconnects the app whose grant is `id`: its tokens and consent end.
    ///
    /// `revokingKeys` also revokes every key the app made, and every key those keys made, but an owner's key; without
    /// it they keep working. `data` says whether the app's data goes in the same write, which needs `items.purge`. The
    /// server refuses that removal with ``MarfaError/validation(code:message:details:server:)`` coded
    /// `bulk_cap_exceeded` while the app holds more than 1,000 items, and disconnects nothing; delete each of the
    /// grant's `vendors` with ``removeAppData(vendor:_:expecting:)`` first. Needs `grants.manage`.
    public func disconnect(
        grant id: String, revokingKeys: Bool = false, data: AppDataOnDisconnect = .keep
    ) async throws(MarfaError) {
        _ = try await answer("revokeAppGrant") {
            try await revokeAppGrant(
                path: .init(id: id),
                query: .init(revokeKeys: revokingKeys ? true : nil, removeData: data.removes ? true : nil)
            ).ok
        }
    }

    /// Ends the sign-in `id` at once, even when it is this client's own.
    ///
    /// For an app, `revokingKeys` also revokes every key it made but an owner's key, and `data` says whether its data
    /// goes in the same write, as ``disconnect(grant:revokingKeys:data:)`` says. The server refuses
    /// ``AppDataOnDisconnect/remove(_:)`` for a sign-in that is a browser or a key, and ends nothing. Needs
    /// `sign_ins.manage`. `instanceID` makes the server refuse with ``MarfaError/instanceChanged(message:server:)``
    /// when another instance now answers at this address.
    public func end(
        signIn id: String, revokingKeys: Bool = false, data: AppDataOnDisconnect = .keep,
        expecting instanceID: String? = nil
    ) async throws(MarfaError) {
        _ = try await answer("endSignIn") {
            try await endSignIn(
                path: .init(id: id),
                query: .init(revokeKeys: revokingKeys ? true : nil, removeData: data.removes ? true : nil),
                headers: .init(xMarfaInstanceId: instanceID)
            ).ok
        }
    }
}

extension AppDataOnDisconnect {
    fileprivate var removes: Bool {
        switch self {
        case .keep: false
        case .remove(.ownerConfirmed): true
        }
    }
}
