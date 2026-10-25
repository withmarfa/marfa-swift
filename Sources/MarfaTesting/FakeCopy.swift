#if DEBUG
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
/// - Reads: `items.list(_:sort:)` without `filter`, including `source`, the
///   updated and occurred ranges and a sort on a property, `items.get(_:)`,
///   `edges.from(_:)`, `edges.to(_:)`, `edges.ofType(_:)`, the four reads of
///   `catalog`, `catalog.fromServer()`, which throws `noServer` as a copy
///   without a server does, `declaredTypes()` and `status()`.
/// - Writes: `items.create(_:)` without `sourceId`, including `state`, a
///   capture location and `edges`, `items.update(_:_:)`, including `occurredAt`
///   and `clearOccurredAt`, `items.updateAsRead(_:_:)`, `items.delete(_:)`,
///   `items.restore(_:)`, `items.transition(_:to:)`, `tags`, `metadata`,
///   `extensions`, `edges.create`, `edges.update(_:_:)`, `edges.delete(_:)` and
///   `declareTypes(_:)`.
/// - The queue: `queue.all()`, `queue.drain()`, `queue.withdraw(_:)`,
///   `queue.discard(_:)` and `queue.forgetAnswered()`, with or without `ids`.
/// - `changes()`, which tells the app's own writes, and the changes ``send(_:)``
///   puts on it.
///
/// Every other call throws ``FakeCopyError/unsupported(call:)``.
///
/// The fake is not a second engine. A call, or an input to a call, that it
/// cannot match exactly and cheaply throws ``FakeCopyError/unsupported(call:)``
/// instead of being answered differently. That includes a `filter`, an
/// `occurredAt` outside the forms it checks, a capture coordinate that is out
/// of range or has no partner, a body that links to another item, a tag with
/// surrounding whitespace, and a value for any field but a string field it can
/// judge. It also differs from a real copy in these ways:
///
/// - A drain answers each write with the verdict ``verdict`` chooses, one drain
///   at a time. A refused write puts back the row it changed, as the real copy
///   shows it after the server refused; a write that depends on a refused or
///   dead one is refused unsent, and one that depends on a blocked or
///   unanswered one waits.
/// - A row or edge it makes is at version 0 until a drain takes the create,
///   which gives it version 1, and an edit a drain takes, accepted or merged,
///   moves the row to the next version, as the real copy shows the answers. A
///   write waiting behind another is answered on the version it was queued
///   on, where the real copy sends it on the answer ahead of it, and an edge's
///   edit and a transition leave the version where it was.
/// - It knows only the types it was given and the ones the app declares, not
///   Marfa's built-in catalog, and it does not check an edge type's
///   constraints.
///
/// The module compiles only in a debug build, so a release build holds none of it.
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
            id: id, label: label, reverseLabel: reverseLabel, description: description, cardinality: cardinality,
            reverseName: reverseName,
            writtenAt: placed, sourceTypeConstraints: sourceTypeConstraints,
            targetTypeConstraints: targetTypeConstraints, cascadeOnDelete: cascadeOnDelete,
            properties: properties.map(\.held), shipped: shipped)
    }
}
#endif
