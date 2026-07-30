import Foundation

// MARK: - MarfaItemModel ↔ Item

extension MarfaItemModel {
    /// Constructs an immutable wire `Item` from this model. The wire type
    /// crosses actor boundaries; `@Model` instances do not.
    func toWireItem() -> Item {
        Item(
            captureLatitude: captureLatitude,
            captureLongitude: captureLongitude,
            createdAt: createdAt,
            device: device,
            edges: nil,
            id: id,
            properties: properties,
            schemaVersion: schemaVersion,
            source: source,
            sourceId: sourceId,
            state: state,
            tier: tier,
            timestamp: timestamp,
            type: type,
            updatedAt: updatedAt,
            version: version
        )
    }

    /// Returns a fresh, unattached model populated from a wire `Item`.
    /// The caller is responsible for `modelContext.insert(...)`.
    static func make(from item: Item) -> MarfaItemModel {
        let model = MarfaItemModel()
        model.apply(item)
        return model
    }

    /// Mutates this model in place from a wire `Item`. Used by upsert paths
    /// that fetch-or-create: existing rows are mutated; new rows are
    /// `make(from:)`-constructed and inserted.
    func apply(_ item: Item) {
        id = item.id
        type = item.type
        state = item.state
        properties = item.properties
        source = item.source
        sourceId = item.sourceId
        tier = item.tier
        version = item.version
        schemaVersion = item.schemaVersion
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        timestamp = item.timestamp
        device = item.device
        captureLatitude = item.captureLatitude
        captureLongitude = item.captureLongitude
    }
}

// MARK: - MarfaEdgeModel ↔ Edge

extension MarfaEdgeModel {
    func toWireEdge() -> Edge {
        Edge(
            createdAt: createdAt,
            edgeType: edgeType,
            id: id,
            properties: properties,
            sourceId: sourceId,
            spaceId: spaceId,
            targetId: targetId,
            updatedAt: updatedAt
        )
    }

    static func make(from edge: Edge) -> MarfaEdgeModel {
        let model = MarfaEdgeModel()
        model.apply(edge)
        return model
    }

    func apply(_ edge: Edge) {
        id = edge.id
        sourceId = edge.sourceId
        targetId = edge.targetId
        edgeType = edge.edgeType
        properties = edge.properties
        spaceId = edge.spaceId
        createdAt = edge.createdAt
        updatedAt = edge.updatedAt
    }
}

// MARK: - MarfaMetadataModel ↔ Metadata

extension MarfaMetadataModel {
    func toWireMetadata() -> Metadata {
        Metadata(
            extensions: extensions,
            itemId: itemId,
            tags: tags
        )
    }

    static func make(from metadata: Metadata) -> MarfaMetadataModel {
        let model = MarfaMetadataModel()
        model.apply(metadata)
        return model
    }

    func apply(_ metadata: Metadata) {
        itemId = metadata.itemId
        tags = metadata.tags
        extensions = metadata.extensions
    }
}
