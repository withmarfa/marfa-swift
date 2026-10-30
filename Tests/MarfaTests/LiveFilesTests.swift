import Foundation
import Testing

@testable import Marfa

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveFiles {
        @Test func anAttachedFileShowsItsSizeBeforeTheDrainAndTheServersAfter() async throws {
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: ["core.note", "core.file"], tier: .feed)
            let note = try #require(try await copy.items.create(Live.note("holds a file \(UUID())")).itemId)
            let text = "a file of known length \(UUID())"
            let attached = try await copy.items.attach(to: note, file: try Live.file(text))
            let file = try #require(attached.item.itemId)
            let length = Int64(Data(text.utf8).count)

            let queued = try #require(try await copy.items.get(file))
            #expect(queued.properties["size_bytes"]?.integer == length, "the copy shows no size before the drain")

            let drained = try await copy.queue.drain()
            #expect(drained.verdicts.map(\.verdict) == [.accepted, .accepted, .accepted, .accepted])
            let answered = try #require(try await copy.items.get(file))
            #expect(answered.properties["size_bytes"]?.integer == length)
            let served = try await Live.read("items/\(file)")
            #expect(served["item"]?.object?["properties"]?.object?["size_bytes"]?.integer == length)
        }

        @Test func everyTypeHydrationBringsAttachmentsToBeFetchedAndKeptOutsideTheBudget() async throws {
            let writer = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await writer.hydrate(types: ["core.note", "core.file"], tier: .feed)
            let note = try #require(try await writer.items.create(Live.note("keeps a file \(UUID())")).itemId)
            let text = String(repeating: "kept offline \(UUID())\n", count: 8)
            let attached = try await writer.items.attach(to: note, file: try Live.file(text))
            let hash = try #require(attached.upload.blob)
            #expect(try await writer.queue.drain().undelivered == 0)

            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server, fileBudget: .keepAll)
            let report = try await copy.hydrate(types: ["*"], tier: .all)
            #expect(report.types == ["*"] && report.pagesTotal >= report.pages && !report.resumed)
            let status = try await copy.status()
            #expect(status.hydration == .complete)
            #expect(status.sliceTypes == ["*"])
            let listed = try await copy.items.list(ListFilters(type: "core.note"))
            #expect(listed.completeness == .complete)
            #expect(listed.contains { $0.id == note })

            let before = try #require(status.fileCache.attachments)
            #expect(before.notHeld >= 1)
            #expect(before.notHeldByReason.contains { $0.reason == .notFetched && $0.attachments >= 1 })
            #expect(!(try await copy.blobs.isHeld(hash)))

            let fetched = try await copy.blobs.fetchKept()
            #expect(fetched.fetched >= 1 && fetched.fetchedBytes >= UInt64(text.utf8.count))
            #expect(try await copy.blobs.isHeld(hash))
            let after = try #require(try await copy.blobs.cache().attachments)
            #expect(after.held >= before.held + 1)
            #expect(after.notHeld < before.notHeld)

            // The budget leaves an attachment's bytes alone, and takes those of any other file.
            _ = try await copy.blobs.setBudget(.bytes(bytes: 1))
            _ = try await copy.blobs.trim()
            #expect(try await copy.blobs.isHeld(hash), "a trim took an attachment's bytes")
            #expect(try await copy.blobs.cache().setting == .bytes(bytes: 1))
        }

        @Test func everyTypeBesideAnotherTypeIsRefused() async throws {
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            await #expect {
                _ = try await copy.hydrate(types: ["*", "core.note"], tier: .all)
            } throws: { error in
                if case .invalid? = error as? MarfaError { true } else { false }
            }
            _ = try await copy.hydrate(types: ["*", "system.view"], tier: .all)
            #expect(try await copy.status().sliceTypes.contains("system.view"))
        }
    }
}

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveCopyGaps {
        @Test func theCatalogIsReadBeforeTheFirstFillAndTheCopyIsLeftAlone() async throws {
            // A fixed budget, since the default one follows the volume's free space, which other suites change.
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server, fileBudget: .keepAll)
            let before = try await copy.status()
            let catalog = try await copy.catalog.fromServer()
            #expect(catalog.itemTypes.contains { $0.id == "core.note" })
            #expect(!catalog.edgeTypes.isEmpty)
            #expect(try await copy.status() == before)
            await copy.close()
        }

        @Test func aFileAddedOnItsOwnReachesTheServerWithItsNonASCIIName() async throws {
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: ["core.file"], tier: .all)
            let name = "Résumé 写真 \(UUID())"
            let added = try await copy.items.addFile(try Live.file("bytes", named: name), tags: ["added-file"])
            let id = try #require(added.item.itemId)
            let drained = try await copy.queue.drain()
            #expect(drained.undelivered == 0 && drained.verdicts.allSatisfy { $0.verdict == .accepted })
            let served = try await Live.read("items/\(id)")
            #expect(served["item"]?.object?["properties"]?.object?["title"]?.string == name)
            await copy.close()
        }
    }
}
