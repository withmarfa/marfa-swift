import Foundation
import Marfa
import MarfaCore
import Synchronization

/// A working copy with no store, no server and no call into the Rust core, for an app's tests and
/// previews.
///
/// ``copy`` is a real ``WorkingCopy``: its argument checks, change feed and
/// value conversion are the ones the app ships. Only the engine beneath it is
/// a fake, which keeps items, edges and types in memory. An app's view model
/// takes a `WorkingCopy`, and a test or a preview hands it this one.
///
/// ```swift
/// let fake = WorkingCopy.fake(items: [note])
/// let model = NotesModel(copy: fake.copy)
/// ```
///
/// The fake serves these calls:
///
/// - Reads: `items.list(_:sort:)` without `filter`, `occurredAfter` or
///   `occurredBefore`, `items.get(_:)`, `edges.from(_:)`, `edges.to(_:)`,
///   `edges.ofType(_:)`, the four reads of `catalog`, `declaredTypes()` and
///   `status()`.
/// - Writes: `items.create(_:)` without `sourceId`, `items.update(_:_:)`,
///   `items.updateAsRead(_:_:)`, `items.delete(_:)`, `items.restore(_:)`,
///   `items.transition(_:to:)`, `tags`, `metadata`, `extensions`, `edges.create`,
///   `edges.update(_:_:)`, `edges.delete(_:)` and `declareTypes(_:)`.
/// - The queue: `queue.all()`, `queue.drain()`, `queue.withdraw(_:)`,
///   `queue.discard(_:)` and `queue.forgetAnswered()`, with or without `ids`.
/// - `changes()`, which tells the app's own writes, and the changes ``send(_:)``
///   puts on it.
///
/// Every other call throws ``FakeCopyError/unsupported(call:)``.
///
/// The fake differs from a real copy in these ways:
///
/// - A drain answers each write with the verdict ``verdict`` chooses, as the
///   server would. A verdict records the answer; it does not change a row.
/// - A write is checked for the ids, versions, types, required fields, edge
///   ends and nesting limit the real copy checks it for. The fake does not
///   check a property's kind, a tag's form or an edge type's constraints.
/// - A body's links and embeds queue no edges of their own.
/// - It knows only the types it was given and the ones the app declares, not
///   Marfa's built-in catalog.
public final class FakeCopy: Sendable {
    /// The copy to hand to the code under test.
    public let copy: WorkingCopy

    private let core: InMemoryCore
    private let chooser = Chooser()

    init(core: InMemoryCore) {
        self.core = core
        copy = WorkingCopy(core: core)
        core.chooseVerdicts { [chooser] write in chooser.verdict(Marfa.QueuedWrite(write))?.core }
    }

    /// Tells every stream `copy.changes()` handed out of `change`, as if the
    /// copy had made it.
    public func send(_ change: Marfa.Change) {
        copy.announce(change)
    }

    /// Every write the copy received, in order, with the verdict it holds now.
    ///
    /// A write stays here after `queue.forgetAnswered()` or `queue.discard(_:)`
    /// takes it out of the queue.
    public var writes: [Marfa.QueuedWrite] {
        core.writes.map(Marfa.QueuedWrite.init)
    }

    /// Chooses the verdict of each write a drain offers.
    ///
    /// Returning `nil` leaves the write unanswered, as when the server is lost.
    /// The default accepts every write.
    ///
    /// A write behind one left unanswered waits, and a write behind one that
    /// was refused, blocked or dead is refused without being offered.
    public var verdict: @Sendable (Marfa.QueuedWrite) -> Marfa.Verdict? {
        get { chooser.verdict }
        set { chooser.verdict = newValue }
    }
}

private final class Chooser: Sendable {
    private let chosen = Mutex<@Sendable (Marfa.QueuedWrite) -> Marfa.Verdict?> { _ in .accepted }

    var verdict: @Sendable (Marfa.QueuedWrite) -> Marfa.Verdict? {
        get { chosen.withLock { $0 } }
        set { chosen.withLock { $0 = newValue } }
    }
}

/// What a fake working copy cannot do.
public enum FakeCopyError: Error, Sendable, Hashable, LocalizedError {
    /// The call is not one the fake serves; `call` names it as the working
    /// copy does, such as `hydrate` or `items.bin`.
    case unsupported(call: String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let call): "the fake working copy does not support \(call)"
        }
    }
}

extension WorkingCopy {
    /// A working copy that serves what it is given from memory.
    ///
    /// - Parameters:
    ///   - items: The items the copy holds, as a hydration would have left them.
    ///   - edges: The edges it holds.
    ///   - itemTypes: The item types its catalog holds. A create of a type
    ///     outside them and the app's declarations throws `unknownType`.
    ///   - edgeTypes: The edge types its catalog holds.
    public static func fake(
        items: [Item] = [], edges: [Edge] = [], itemTypes: [Marfa.ItemType] = [], edgeTypes: [Marfa.EdgeType] = []
    ) -> FakeCopy {
        FakeCopy(
            core: InMemoryCore(
                items: items, edges: edges, itemTypes: itemTypes.map(\.held), edgeTypes: edgeTypes.map(\.held)))
    }
}

extension Marfa.ItemType {
    fileprivate var held: MarfaCore.ItemType {
        MarfaCore.ItemType(
            id: id, label: label, description: description, parent: parent, version: version,
            fields: fields.map(\.held), titleField: titleField, bodyField: bodyField, linkField: linkField,
            roles: roles, compatibleWith: compatibleWith)
    }
}

extension Marfa.TypeField {
    fileprivate var held: MarfaCore.TypeField {
        MarfaCore.TypeField(
            name: name, fieldType: type, required: required, description: description, declaredBy: declaredBy,
            definition: definition)
    }
}

extension Marfa.EdgeType {
    fileprivate var held: MarfaCore.EdgeType {
        let placed: MarfaCore.EdgeWrittenAt =
            switch writtenAt {
            case .source: .source
            case .target: .target
            case .none: .none
            }
        return MarfaCore.EdgeType(
            id: id, label: label, description: description, cardinality: cardinality, reverseName: reverseName,
            writtenAt: placed, sourceTypeConstraints: sourceTypeConstraints,
            targetTypeConstraints: targetTypeConstraints, cascadeOnDelete: cascadeOnDelete,
            properties: properties.map(\.held), shipped: shipped)
    }
}
