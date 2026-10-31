import Foundation
internal import MarfaCore

/// One part of a `[[link]]`: its text and where it sits in the text that was read.
public struct LinkPart: Sendable, Hashable {
    public let text: String
    /// The part's place in the text, in UTF-16 code units, so a text view takes it as it is.
    public let range: NSRange

    public init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }

    init(_ core: MarfaCore.LinkPart) {
        self.init(text: core.text, range: Self.range(from: core.start, to: core.end))
    }

    static func range(from start: UInt64, to end: UInt64) -> NSRange {
        NSRange(location: Int(clamping: start), length: Int(clamping: end >= start ? end - start : 0))
    }
}

/// A `[[link]]` in a text, split as Marfa reads it.
public struct LinkParts: Sendable, Hashable {
    /// The whole link, brackets included.
    public let text: String
    /// Where the whole link sits, in UTF-16 code units.
    public let range: NSRange
    /// The text between the brackets, which ``Items/linkCandidates(of:in:)`` takes.
    public let target: String
    public let name: LinkPart
    public let heading: LinkPart?
    public let alias: LinkPart?

    public init(text: String, range: NSRange, target: String, name: LinkPart, heading: LinkPart?, alias: LinkPart?) {
        self.text = text
        self.range = range
        self.target = target
        self.name = name
        self.heading = heading
        self.alias = alias
    }

    init(_ core: MarfaCore.LinkParts) {
        self.init(
            text: core.text, range: LinkPart.range(from: core.start, to: core.end), target: core.target,
            name: LinkPart(core.name), heading: core.heading.map(LinkPart.init), alias: core.alias.map(LinkPart.init))
    }
}

/// Every link in `text`, in order and repeats included, with each part's place in the text.
///
/// This reads the text alone: it needs no working copy, so an editor can call it on every change. A backslash is part
/// of the text, not an escape. To see what a link could name, ask ``Items/linkCandidates(of:in:)`` with its `target`.
public func linkParts(in text: String) -> [LinkParts] {
    MarfaCore.linkParts(text: text).map(LinkParts.init)
}

/// How far a link's target resolves.
public enum LinkState: Sendable, Hashable, CaseIterable {
    /// Saving the link makes its edge to ``LinkCandidates/item``.
    case bound
    /// More than one item answers to the name.
    case ambiguous
    /// No item answers to the name.
    case unresolved

    init(_ core: MarfaCore.LinkState) {
        switch core {
        case .bound: self = .bound
        case .ambiguous: self = .ambiguous
        case .unresolved: self = .unresolved
        }
    }
}

/// The items a link's target could name, from the copy alone.
public struct LinkCandidates: Sendable, Hashable {
    /// The text between the link's brackets, as asked.
    public let target: String
    public let state: LinkState
    /// The item the link names, where ``state`` is ``LinkState/bound``.
    public let item: String?
    /// Every item outside the bin that the copy holds and the name answers to, by id, title or file path, and the
    /// bound item.
    public let candidates: [String]

    public init(target: String, state: LinkState, item: String?, candidates: [String]) {
        self.target = target
        self.state = state
        self.item = item
        self.candidates = candidates
    }

    init(_ core: MarfaCore.LinkCandidates) {
        self.init(target: core.target, state: LinkState(core.state), item: core.item, candidates: core.candidates)
    }
}

extension Items {
    /// What each of `targets` could name, in order, from the copy alone, with no request.
    ///
    /// A target is the text between a link's brackets, as ``linkParts(in:)`` gives it. With `item`, each target is
    /// read as a link in that item's body: ``LinkState/bound`` means saving it there makes its edge. Without `item`,
    /// only an ID the copy holds is bound; a name that one item answers to is ``LinkState/unresolved`` with that
    /// item among the ``LinkCandidates/candidates``. Throws `notFound` for an item the copy does not hold.
    ///
    /// ``links(in:)-(String)`` answers for the links in a body that is already saved, and this for a name that is
    /// still being typed.
    public func linkCandidates(of targets: [String], in item: String? = nil) async throws -> [LinkCandidates] {
        try await holder.run { core in
            try core.linkCandidates(item: item, targets: targets).map(LinkCandidates.init)
        }
    }
}
