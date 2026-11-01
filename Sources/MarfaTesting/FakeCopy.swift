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
///   `items.get(_:includingBin:)`, `edges.get(_:)` for one ID or many,
///   `edges.from(_:)`, `edges.to(_:)`, `edges.ofType(_:)`, the four reads of
///   `catalog`, `catalog.fromServer()`, which throws `noServer` as a copy
///   without a server does, `declaredTypes()` and `status()`.
/// - Search: `search(_:filters:limit:)` and `search(_:inView:limit:)`, answered by SQLite's FTS5 with the
///   `porter unicode61` tokenizer, `bm25` ranking and `snippet` excerpts the core's index uses, so the hits,
///   their order, scores and excerpts are the core's. Each search indexes the rows outside the bin afresh in
///   an in-memory database, which costs a pass over the rows and needs a SQLite built with FTS5 (the system's
///   on Apple platforms). A `filter` throws ``FakeCopyError/unsupported(call:)``. The copy is never filling,
///   so `completeness` is always `.complete`.
/// - Writes: `items.create(_:)` without `sourceId`, including `state`, a
///   capture location and `edges`, `items.update(_:_:)`, including `occurredAt`,
///   `clearOccurredAt` and `clearProperties`, `items.updateAsRead(_:_:)`, `items.delete(_:)`,
///   `items.restore(_:)`, `items.transition(_:to:)`, `tags`, `metadata`,
///   `extensions`, `edges.create`, `edges.check(from:to:type:)`, `edges.update(_:_:)`, `edges.delete(_:)` and
///   `declareTypes(_:)`.
/// - Views: `createView`, `changeView`, `deleteView`, `items.views()`, `items.view(_:)`,
///   `items.list(inView:limit:offset:)` and `items.groups(inView:timeZone:)`, over the views it is given
///   or makes. A view write goes straight through, never into the queue, and a change based on an older version
///   merges or throws `versionConflict` as the server does. A view's `filter` is stored but not judged: listing,
///   grouping or searching that view throws ``FakeCopyError/unsupported(call:)``. A view's
///   `query.types` is not checked against the types the fake holds.
/// - The queue: `queue.all()`, `queue.drain()`, `queue.withdraw(_:)`,
///   `queue.discard(_:)`, `queue.forgetAnswered()`, with or without `ids`, and
///   `queue.takeAnswered()`.
/// - `changes()`, which tells the app's own writes, and the changes ``send(_:)``
///   puts on it, and `updates()`, which tells `.local` and the updates ``sendUpdate(_:)`` scripts.
///
/// - Scripted answers: `items.displays(for:)`, `items.displays(of:)` and `items.linkCandidates(of:in:)` need the
///   core's naming and link-matching rules, which the fake does not copy. They throw
///   ``FakeCopyError/unsupported(call:)`` until the test scripts the answer with ``displays`` or ``linkCandidates``.
///
/// Every other call throws ``FakeCopyError/unsupported(call:)``, including
/// `changes(since:most:)`, since the fake records no changes to name, and the
/// reads of body links.
///
/// The fake is not a second engine. A call, or an input to a call, that it
/// cannot match exactly and cheaply throws ``FakeCopyError/unsupported(call:)``
/// instead of being answered differently. That includes a `filter`, an
/// `occurredAt` outside the forms it checks, a capture coordinate that is out
/// of range or has no partner, a body that links to another item, a tag with
/// surrounding whitespace, a value for any field other than a string field, an
/// enum field that lists its values or a status field, which it judges, and
/// `declareTypes(_:)` with a status field or status words. A filter that names
/// `status_group` is a `filter`, so the fake does not answer it.
///
/// The fake judges a status word as the core does: it refuses `invalid_properties`
/// for a create that names a word the type does not declare, for an update that
/// changes the word to one, and for a move to a type that does not declare the
/// word the item holds. A stored word an update leaves alone stands. The fake
/// also differs from a real copy in these ways:
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
///   on, where the real copy sends it on the answer ahead of it. A transition
///   and a tag leave the version where it was. A delete queued
///   behind its own item's create is rebased to version 1 when that create is
///   taken, as the real copy does, and it is refused unsent only where the
///   real copy refuses one: a delete of an item it holds at version 0 with no
///   create unanswered.
/// - It knows only the types it was given and the ones the app declares, not
///   Marfa's built-in catalog. `edges.create`, `edges.check`,
///   `items.create(edges:)`, `edges.update` moving an end and `items.update` changing an item's type refuse as the
///   core does, from the types it holds, with the core's code and message: an end the edge type does not admit,
///   nesting under a flat edge type, an end in the bin and a cycle through held edges (an edge an update moves is
///   left out of that walk). A retype is refused when an edge the item holds would no longer fit its new type.
/// - A search finds an item again once it is restored from the bin, as the contract says. A real copy does not
///   until it reads the row again (withmarfa/marfa#2526).
///
/// The module compiles only in a debug build, so a release build holds none of it.
public final class FakeCopy: Sendable {
    /// The copy to hand to the code under test.
    public let copy: WorkingCopy

    private let core: InMemoryCore
    private let chooser = Chooser()
    private let scripted = Mutex(PublicAnswers())

    init(core: InMemoryCore) {
        self.core = core
        copy = WorkingCopy(core: core)
        core.chooseVerdicts { [chooser] write in chooser.verdict(Marfa.QueuedWrite(write))?.core }
    }

    private func script(_ change: (inout PublicAnswers) -> Void) {
        scripted.withLock { held in
            change(&held)
            core.scripted.withLock { $0 = held.inCoreTypes }
        }
    }

    /// Tells every stream `copy.changes()` handed out of `change`, as if the
    /// copy had made it.
    public func send(_ change: Marfa.Change) {
        copy.announce(change)
    }

    /// Delivers `update` as given through the copy's own ``WorkingCopy/updates()``, to every sequence held now.
    ///
    /// The update's connection, fill and `lastSynced` also become what later updates tell, so a test drives an
    /// app's handling of ``CopyUpdate``s through the code the app runs. The copy has no server, so it reports
    /// `.local` and does nothing else by itself: call this after `copy.updates()`, which resets the connection as
    /// its first sequence begins.
    ///
    /// ```swift
    /// var updates = fake.copy.updates().makeAsyncIterator()
    /// fake.sendUpdate(CopyUpdate(reread: .everything, connection: .offline(.noConnection(message: "off"))))
    /// ```
    public func sendUpdate(_ update: CopyUpdate) {
        copy.script(update)
    }

    /// Every write the copy received, in order, with the verdict it holds now.
    ///
    /// A write stays here after `queue.forgetAnswered()`, `queue.takeAnswered()`
    /// or `queue.discard(_:)` takes it out of the queue.
    public var writes: [Marfa.QueuedWrite] {
        core.writes.map(Marfa.QueuedWrite.init)
    }

    /// Scripts the name and preview `copy.items.displays(for:)` and `displays(of:)` answer, once for each input.
    ///
    /// The fake does not work out a name from the type's display hints, as the Rust core does, so the closure says
    /// what an item shows. Without one (the default), both calls throw ``FakeCopyError/unsupported(call:)``.
    ///
    /// ```swift
    /// fake.displays = { input in
    ///     ItemDisplay(name: input.properties["title"]?.string, preview: nil)
    /// }
    /// let shown = try await fake.copy.items.displays(of: [note])
    /// ```
    public var displays: (@Sendable (Marfa.ItemDisplayInput) -> Marfa.ItemDisplay)? {
        get { scripted.withLock { $0.displays } }
        set { script { $0.displays = newValue } }
    }

    /// Scripts what `copy.items.linkCandidates(of:in:)` answers for each target, with the `item` it was asked in.
    ///
    /// The fake does not match a link's name to the items it holds, so the closure gives the whole answer. The
    /// returned ``LinkCandidates/target`` is replaced by the one asked, so the answer stays in order. Without a
    /// closure (the default), the call throws ``FakeCopyError/unsupported(call:)``.
    ///
    /// ```swift
    /// fake.linkCandidates = { target, _ in
    ///     LinkCandidates(target: target, state: .bound, item: "item-1", candidates: ["item-1"])
    /// }
    /// ```
    public var linkCandidates: (@Sendable (_ target: String, _ item: String?) -> Marfa.LinkCandidates)? {
        get { scripted.withLock { $0.linkCandidates } }
        set { script { $0.linkCandidates = newValue } }
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

/// The answers an app scripted for the calls that need the Rust core's rules.
struct ScriptedAnswers {
    var displays: (@Sendable (MarfaCore.ItemDisplayInput) -> MarfaCore.ItemDisplay)?
    var linkCandidates: (@Sendable (_ target: String, _ item: String?) -> MarfaCore.LinkCandidates)?
}

/// The same answers in the package's public types, which is what an app scripts.
private struct PublicAnswers: Sendable {
    var displays: (@Sendable (Marfa.ItemDisplayInput) -> Marfa.ItemDisplay)?
    var linkCandidates: (@Sendable (_ target: String, _ item: String?) -> Marfa.LinkCandidates)?

    /// The closures as the core's own calls, so `InMemoryCore` answers in the core's types.
    var inCoreTypes: ScriptedAnswers {
        var answers = ScriptedAnswers()
        answers.displays = displays.map { (shown) -> @Sendable (MarfaCore.ItemDisplayInput) -> MarfaCore.ItemDisplay in
            { (input: MarfaCore.ItemDisplayInput) -> MarfaCore.ItemDisplay in
                let properties = Marfa.JSONObject(input.properties)
                let answer = shown(Marfa.ItemDisplayInput(type: input.type, properties: properties))
                return MarfaCore.ItemDisplay(name: answer.name, preview: answer.preview)
            }
        }
        answers.linkCandidates = linkCandidates.map {
            (found) -> @Sendable (String, String?) -> MarfaCore.LinkCandidates in
            { (target: String, item: String?) -> MarfaCore.LinkCandidates in
                let answer = found(target, item)
                let state: MarfaCore.LinkState =
                    switch answer.state {
                    case .bound: .bound
                    case .ambiguous: .ambiguous
                    case .unresolved: .unresolved
                    }
                return MarfaCore.LinkCandidates(
                    target: target, state: state, item: answer.item, candidates: answer.candidates)
            }
        }
        return answers
    }
}

private final class Chooser: Sendable {
    /// Holds the function in a struct field.
    ///
    /// Held as the `Mutex`'s own value, each read came back inside one more conversion wrapper, so the call for
    /// the thousandth write of a drain stood on a thousand wrappers and overflowed the stack.
    private struct Chosen: Sendable {
        var call: @Sendable (Marfa.QueuedWrite) -> Marfa.Verdict?
    }

    private let chosen = Mutex(Chosen { _ in .accepted })

    var verdict: @Sendable (Marfa.QueuedWrite) -> Marfa.Verdict? {
        get { chosen.withLock { $0.call } }
        set { chosen.withLock { $0.call = newValue } }
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
    ///   - views: The saved views it holds, each as an item of type `system.view` at the version given.
    ///   - displays: The answer to `items.displays`, as ``FakeCopy/displays`` sets it. `nil` leaves the call unsupported.
    ///   - linkCandidates: The answer to `items.linkCandidates`, as ``FakeCopy/linkCandidates`` sets it. `nil` leaves it
    ///     unsupported.
    public static func fake(
        items: [Marfa.Item] = [], edges: [Marfa.Edge] = [], itemTypes: [Marfa.ItemType] = [],
        edgeTypes: [Marfa.EdgeType] = [],
        views: [SavedView] = [],
        displays: (@Sendable (Marfa.ItemDisplayInput) -> Marfa.ItemDisplay)? = nil,
        linkCandidates: (@Sendable (_ target: String, _ item: String?) -> Marfa.LinkCandidates)? = nil
    ) -> FakeCopy {
        let fake = FakeCopy(
            core: InMemoryCore(
                items: items.map(\.core) + views.map(\.held), edges: edges.map(\.core),
                itemTypes: itemTypes.map(\.held),
                edgeTypes: edgeTypes.map(\.held)))
        fake.displays = displays
        fake.linkCandidates = linkCandidates
        return fake
    }
}

extension SavedView {
    fileprivate var held: MarfaCore.Item {
        let at = Minted.now()
        let properties = Properties.served(settings.json.core)
        return MarfaCore.Item(
            id: id, type: InMemoryCore.viewType, properties: properties, state: state.core, tier: .library,
            version: version,
            schemaVersion: 1, source: "device", sourceId: nil, occurredAt: at, createdAt: at, updatedAt: at, tags: [],
            title: Properties.string(properties, "title"), body: nil)
    }
}

extension Marfa.ItemType {
    fileprivate var held: MarfaCore.ItemType {
        MarfaCore.ItemType(
            id: id, label: label, plural: plural, description: description, parent: parent, version: version,
            fields: fields.map(\.held), titleField: titleField, bodyField: bodyField, icon: icon, linkField: linkField,
            roles: roles, compatibleWith: compatibleWith)
    }
}

extension Marfa.TypeField {
    fileprivate var held: MarfaCore.TypeField {
        MarfaCore.TypeField(
            name: name, fieldType: type, required: required, label: label, description: description,
            declaredBy: declaredBy,
            definition: definition.core)
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
            properties: properties.map(\.held), shipped: shipped, acyclic: acyclic, flat: flat)
    }
}
#endif
