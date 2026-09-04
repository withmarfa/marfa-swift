import Foundation
import SwiftData

/// The model shapes stores written by V1 and V2 builds actually hold, frozen
/// so the live classes are free to move.
///
/// A versioned schema is only useful if the old version keeps hashing the way
/// the old version hashed. One of the two versions therefore has to own frozen
/// copies of the model classes, and which one is a choice with a large
/// difference in cost. Freezing the *new* version would mean pointing
/// ``LocalStore``, ``MutationQueue``, every reactive query and every test at
/// copies nested inside a schema namespace. Freezing the *old* version, as
/// here, leaves every one of those references where it is: the live classes at
/// the top level are always the current shape, and history lives in this file.
///
/// **The arrangement rests on nesting being invisible to Core Data**, which is
/// a property rather than an assumption: an entity is identified by its name,
/// and its version hash is computed from that name and its property
/// descriptions, with no input from where the Swift type happens to live.
/// `SchemaMigrationTests` pins it by writing a store through these copies and
/// comparing what lands in the store's own metadata against a store written
/// through the top-level classes.
///
/// V1 and V2 share these copies because they differ only in whether
/// ``DroppedMutationModel`` is present at all — none of the six models common
/// to both changed shape between them.
///
/// Nothing in here is ever edited. A change to a live model is a new version
/// with a new set of frozen copies, not an edit to an old one.
enum FrozenV2 {

    @Model
    final class MarfaItemModel {
        var id: String = ""
        var type: String = ""
        var stateRaw: String = ItemState.active.rawValue
        var propertiesData: Data = Data("{}".utf8)
        var source: String = ""
        var sourceId: String?
        var tierRaw: String = ""
        var version: Int = 1
        var schemaVersion: Int = 1
        var createdAt: String = ""
        var updatedAt: String = ""
        var timestamp: String = ""
        var device: String?
        var captureLatitude: Double?
        var captureLongitude: Double?

        @Relationship(deleteRule: .cascade, inverse: \MarfaMetadataModel.item)
        var metadata: MarfaMetadataModel?

        init() {}

        #Index<MarfaItemModel>([\.id], [\.type, \.stateRaw], [\.updatedAt])
    }

    @Model
    final class MarfaMetadataModel {
        var itemId: String = ""
        var tagsData: Data = Data("[]".utf8)
        var extensionsData: Data = Data("{}".utf8)
        var item: MarfaItemModel?

        init() {}

        #Index<MarfaMetadataModel>([\.itemId])
    }

    @Model
    final class MarfaEdgeModel {
        var id: String = ""
        var sourceId: String = ""
        var targetId: String = ""
        var edgeType: String = ""
        var propertiesData: Data = Data("{}".utf8)
        var spaceId: String?
        var createdAt: String = ""
        var updatedAt: String = ""

        init() {}

        #Index<MarfaEdgeModel>(
            [\.id],
            [\.sourceId, \.edgeType],
            [\.targetId, \.edgeType]
        )
    }

    @Model
    final class PendingMutationModel {
        var id: String = ""
        var kindRaw: String = ""
        var payloadJson: String = "{}"
        var sourceId: String?
        var localId: String?
        var createdAt: String = ""
        var attemptCount: Int = 0
        var lastError: String?
        var stateRaw: String = PendingMutationState.pending.rawValue

        init() {}

        #Index<PendingMutationModel>([\.createdAt], [\.localId], [\.kindRaw])
    }

    @Model
    final class SyncStateModel {
        var key: String = ""
        var value: String = ""

        init() {}

        #Index<SyncStateModel>([\.key])
    }

    @Model
    final class PendingBlobModel {
        var contentHash: String = ""
        @Attribute(.externalStorage) var data: Data = Data()
        var mimeType: String = ""

        init() {}

        #Index<PendingBlobModel>([\.contentHash])
    }

    @Model
    final class DroppedMutationModel {
        var id: String = ""
        var kindRaw: String = ""
        var payloadJson: String = "{}"
        var localId: String?
        var enqueuedAt: String = ""
        var droppedAt: String = ""
        var attemptCount: Int = 0
        var errorStatus: Int = 0
        var errorCode: String = ""
        var errorMessage: String = ""
        var errorDetailsJson: String?

        init() {}

        #Index<DroppedMutationModel>([\.droppedAt], [\.localId])
    }

    /// The six models every V1 store holds. V2 adds
    /// ``FrozenV2/DroppedMutationModel`` to this list.
    static var sharedModels: [any PersistentModel.Type] {
        [
            MarfaItemModel.self,
            MarfaEdgeModel.self,
            MarfaMetadataModel.self,
            PendingMutationModel.self,
            SyncStateModel.self,
            PendingBlobModel.self,
        ]
    }
}
