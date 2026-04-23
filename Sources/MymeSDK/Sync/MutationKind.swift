import Foundation

/// The kind of mutation queued for replay against the Myme server.
///
/// Lifted out of the legacy `PendingMutationRecord.Kind` so that
/// `PendingMutationModel` (the SwiftData `@Model`) can persist the case as
/// a String rawValue while the actor and the SyncEngine continue to switch
/// on the typed enum. New mutation kinds must be appended to the end of
/// this enum (CloudKit-mirrored stores enforce additive-only schemas).
public enum MutationKind: String, Codable, Sendable, CaseIterable {
    case createItem
    case updateItem
    case deleteItem
    case restoreItem
    case transitionItem
    case purgeItem
    case createEdge
    case updateEdge
    case deleteEdge
    case setMetadata
    case mergeMetadata
    case addTags
    case removeTag
    case setExtension
    case deleteExtension
    case uploadBlob
}
