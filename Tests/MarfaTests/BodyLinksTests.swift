import Foundation
import Testing

@testable import Marfa

/// A copy that never reached a server, which resolves what it holds and waits on the rest.
private func isInvalid(_ error: any Error) -> Bool {
    if case .invalid? = error as? MarfaError { true } else { false }
}

private func isNotFound(_ error: any Error) -> Bool {
    if case .notFound? = error as? MarfaError { true } else { false }
}

@Suite(.timeLimit(.minutes(1)))
struct BodyLinksOffline {
    static func note(_ body: String, in copy: WorkingCopy) async throws -> String {
        try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["title": "Host", "body": .string(body)]))
                .itemId)
    }

    @Test func anAttachedFileEmbedsAtTheEndOfTheBodyAndReadsBackAsItsOwnEdge() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let host = try await Self.note("First paragraph.", in: copy)
        let name = "clip-\(UUID()).mov"
        let embedded = try await copy.items.embed(file: Live.file("bytes", named: name), in: host)

        #expect(embedded.embed == "![[\(name)]]")
        #expect(embedded.attached.embed == embedded.embed)
        #expect(embedded.body.kind == .updateItem)
        let file = try #require(embedded.attached.item.itemId)
        let item = try #require(try await copy.items.get(host))
        #expect(item.body == "First paragraph.\n\n![[\(name)]]")

        let found = try await copy.items.links(in: host)
        #expect(found.links.isEmpty)
        #expect(found.embeds == [BodyName(text: "![[\(name)]]", name: name, target: .item(id: file))])
        #expect(try await copy.items.embedText(of: file, in: host) == embedded.embed)
        let edges = try await copy.edges.to(host).filter { $0.sourceId == file }
        #expect(edges.count == 1, "the embed made a second edge: \(edges)")
        await copy.close()
    }

    @Test func aBodyThatEndsInNewlinesGetsOneBlankLineAndAnEmptyOneGetsNoBlankLine() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let spaced = try await Self.note("Text.\n\n", in: copy)
        let plain = try await Self.note("Text.\n", in: copy)
        let empty = try await Self.note("", in: copy)
        for (host, body) in [(spaced, "Text.\n\n"), (plain, "Text.\n"), (empty, "")] {
            let name = "file-\(UUID()).mov"
            _ = try await copy.items.embed(file: Live.file("x", named: name), in: host)
            let separator = body.isEmpty ? "" : "\n\n"
            let expected = body.trimmingCharacters(in: .newlines) + separator + "![[\(name)]]"
            #expect(try await copy.items.get(host)?.body == expected)
        }
        await copy.close()
    }

    @Test func aLinkTheCopyCannotResolveIsPendingAndALinkInCodeIsText() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let host = try await Self.note("See [[Elsewhere|there]] and `[[In code]]`.", in: copy)
        let found = try await copy.items.links(in: host)
        #expect(found.links == [BodyName(text: "[[Elsewhere|there]]", name: "Elsewhere", target: .pending)])
        #expect(found.embeds.isEmpty)
        await copy.close()
    }

    @Test func aLinkByIdResolvesToTheItemTheCopyHolds() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let other = try await Self.note("", in: copy)
        let host = try await Self.note("See [[\(other)]].", in: copy)
        let found = try await copy.items.links(in: host)
        #expect(found.links == [BodyName(text: "[[\(other)]]", name: other, target: .item(id: other))])
        await copy.close()
    }

    @Test func anItemTheCopyDoesNotHoldHasNoLinks() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        await #expect { try await copy.items.links(in: "absent") } throws: { isNotFound($0) }
        await copy.close()
    }

    @Test func aFileThatIsNotAttachedHasNoEmbedText() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let host = try await Self.note("", in: copy)
        let other = try await Self.note("", in: copy)
        await #expect { try await copy.items.embedText(of: other, in: host) } throws: { isInvalid($0) }
        await copy.close()
    }

    @Test func aTitleNoEmbedCanNameLeavesTheFileAttachedAndTheBodyAsItWas() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let host = try await Self.note("Kept.", in: copy)
        for attachment in [Attachment(title: "a|b"), Attachment()] {
            let failure = try await #require(
                throws: EmbedFailure.self, "a title no embed can name was embedded"
            ) {
                _ = try await copy.items.embed(file: Live.file("x"), in: host, attachment)
            }
            #expect(isInvalid(failure.cause), "\(failure.cause)")
            let file = try #require(failure.attached.item.itemId)
            #expect(failure.attached.embed == nil)
            #expect(try await copy.items.get(file) != nil)
            #expect(try await copy.items.get(host)?.body == "Kept.")
        }
        let edges = try await copy.queue.all().filter { $0.kind == .createEdge }
        #expect(edges.count == 2, "each file should be attached once: \(edges)")
        await copy.close()
    }

    @Test func aBodyWithWindowsLineEndingsGetsOneBlankLine() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        for body in ["Text.\r\n", "Text.\r\n\r\n"] {
            let host = try await Self.note(body, in: copy)
            let name = "crlf-\(UUID()).mov"
            _ = try await copy.items.embed(file: Live.file("x", named: name), in: host)
            let held = try #require(try await copy.items.get(host)?.body)
            #expect(held.hasSuffix("![[\(name)]]"))
            #expect(!held.dropLast("![[\(name)]]".count).hasSuffix("\n\n\n"), "\(held.debugDescription)")
        }
        await copy.close()
    }

    @Test func aTextFileIsAttachedButItsNameIsANoteInABody() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let host = try await Self.note("Kept.", in: copy)
        let attached = try await copy.items.attach(to: host, file: Live.file("x"))
        #expect(attached.embed == nil)
        await #expect(throws: MarfaError.self) {
            _ = try await copy.items.embedText(of: attached.item.itemId ?? "", in: host)
        }
        await copy.close()
    }
}
