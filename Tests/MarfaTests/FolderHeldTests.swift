#if os(macOS)
import Foundation
import Marfa
import Testing

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(3)))
    struct LiveHeldFiles {
        let folders = FolderFixture.folders

        /// Two folders on the computer, the first holding a note for each name, then each file deleted and held.
        private func holdingDeletes(
            _ names: [String]
        ) async throws -> (first: URL, second: URL, items: [String: String]) {
            let first = FolderFixture.directory()
            _ = try await folders.add(first, following: try await FolderFixture.settings())
            let second = FolderFixture.directory()
            _ = try await folders.add(second, following: try await FolderFixture.settings())
            try await folders.confirmFirstSync(in: first)
            try await folders.confirmFirstSync(in: second)
            for name in names { try FolderFixture.note(name, in: first) }
            _ = try await FolderFixture.sync(first)
            _ = try await FolderFixture.sync(second)
            let status = try await folders.status(of: first).files
            var items: [String: String] = [:]
            for name in names {
                items[name] = try #require(status.first { $0.path == "\(name).md" }?.itemId)
                try FileManager.default.removeItem(at: first.appending(path: "\(name).md"))
            }
            _ = try await FolderFixture.sync(first)
            // The rename grace is five seconds of the clock: a file missing for less is not decided yet.
            try await Task.sleep(for: .seconds(6))
            _ = try await FolderFixture.sync(first)
            return (first, second, items)
        }

        @Test func aDeleteHeldWhileAnotherFolderIsOnTheComputerIsListedAndSettledEachWay() async throws {
            let names = ["Trash", "Keep", "Back"]
            let (first, second, items) = try await holdingDeletes(names)
            let held = try await folders.heldFiles(in: first)
            #expect(held.map(\.path) == names.sorted().map { "\($0).md" })
            for file in held {
                #expect(file.item == items[String(file.path.dropLast(3))])
                #expect(!file.missingSince.isEmpty && !file.reason.isEmpty)
            }

            let status = try await folders.status(of: first).files.filter { $0.state == .held }
            #expect(status.map(\.path).sorted() == held.map(\.path))
            for file in held {
                let shown = try #require(status.first { $0.path == file.path })
                #expect(shown.hold == .unsure && shown.reason == file.reason && shown.itemId == file.item)
            }
            #expect(try await folders.heldFiles(in: second).isEmpty)
            await #expect(throws: MarfaError.self) { try await folders.heldFiles(in: first.appending(path: "nowhere")) }

            let trashed = try await folders.trashHeld(in: first, paths: ["Trash.md"])
            #expect(trashed.trashed == ["Trash.md"] && trashed.notSettled.isEmpty)
            #expect(try await folders.heldFiles(in: first).map(\.path) == ["Back.md", "Keep.md"])

            let kept = try await folders.keepHeld(in: first, paths: ["Keep.md"], writeBack: false)
            #expect(kept.kept == ["Keep.md"] && kept.writtenBack.isEmpty && kept.notSettled.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: first.appending(path: "Keep.md").path()))

            let back = try await folders.keepHeld(in: first, paths: ["Back.md"], writeBack: true)
            #expect(back.kept == ["Back.md"] && back.writtenBack == ["Back.md"] && back.notWrittenBack.isEmpty)
            #expect(FileManager.default.fileExists(atPath: first.appending(path: "Back.md").path()))
            #expect(try await folders.heldFiles(in: first).isEmpty)

            _ = try await FolderFixture.sync(first)
            let copy = try await WorkingCopy.open(store: Live.store(), server: try #require(Live.server))
            _ = try await copy.hydrate(types: ["core.note"], tier: .library)
            #expect(try await copy.items.bin().items.map(\.id).contains(try #require(items["Trash"])))
            #expect(try await copy.items.get(try #require(items["Keep"]))?.state == .active)
            #expect(try await copy.items.get(try #require(items["Back"]))?.state == .active)
            await copy.close()
        }

        @Test func aFileBackAtItsPathIsNotSettledAndStaysHeld() async throws {
            let (first, _, _) = try await holdingDeletes(["Returned"])
            try FolderFixture.note("Returned", in: first)
            let trashed = try await folders.trashHeld(in: first, paths: ["Returned.md"])
            #expect(trashed.trashed.isEmpty)
            let notSettled = try #require(trashed.notSettled.first)
            #expect(notSettled.path == "Returned.md" && notSettled.reason.contains("a file is at its path again"))
            #expect(try await folders.heldFiles(in: first).map(\.path) == ["Returned.md"])

            let kept = try await folders.keepHeld(in: first, paths: ["Returned.md"], writeBack: true)
            #expect(kept.writtenBack.isEmpty)
            #expect(kept.notSettled.map(\.path) == ["Returned.md"])
            #expect(try await folders.heldFiles(in: first).map(\.path) == ["Returned.md"])
        }

        @Test func keepingWithWriteBackAnItemTheQueryNoLongerHoldsWritesNothing() async throws {
            let (first, _, items) = try await holdingDeletes(["Left"])
            let copy = try await WorkingCopy.open(store: Live.store(), server: try #require(Live.server))
            _ = try await copy.hydrate(types: ["core.note"], tier: .library)
            let id = try #require(items["Left"])
            _ = try await copy.metadata.replaceTags(of: id, with: ["elsewhere"])
            _ = try await copy.queue.drain()
            await copy.close()
            _ = try await FolderFixture.sync(first)

            let kept = try await folders.keepHeld(in: first, paths: ["Left.md"], writeBack: true)
            #expect(kept.kept == ["Left.md"] && kept.writtenBack.isEmpty && kept.notSettled.isEmpty)
            let refused = try #require(kept.notWrittenBack.first)
            #expect(refused.path == "Left.md" && refused.flag == "outside_query" && refused.item == id)
            #expect(try await folders.heldFiles(in: first).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: first.appending(path: "Left.md").path()))
        }
    }
}
#endif
