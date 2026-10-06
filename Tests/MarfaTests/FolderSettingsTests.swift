import Foundation
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1))) struct FolderSettingsOffline {
    @Test func settingsCrossTheBindingAndBackUnchanged() throws {
        let settings = FolderSettings(
            title: "Recipes",
            search: FolderSearch(
                types: ["core.note"], tier: .feed, states: [.archived], filter: "tags contains \"recipe\"",
                beneath: "parent"),
            defaults: FolderDefaults(
                type: "core.note", tier: .feed, properties: ["rating": 3, "cuisine": "any"], tags: ["new"],
                edges: ["about": ["topic"]]),
            include: ["*.md"], ignore: ["drafts/"], firstPlacement: ["core.note": "Notes"],
            removalThreshold: RemovalThreshold(files: 4, fraction: 0.5))
        let crossed = try FolderSettings(try settings.core())
        #expect(crossed == settings)
        #expect(crossed.defaults.properties.keys == ["rating", "cuisine"], "the defaults' key order")
    }

    @Test func aCopyWithNoServerWritesNoFolderAndQueuesNothing() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        await #expect {
            _ = try await copy.createFolder(FolderSettings(title: "Offline"))
        } throws: { error in
            if case .noServer = error as? MarfaError { true } else { false }
        }
        #expect(try await copy.queue.all().isEmpty)
    }

    @Test func aFolderTheCopyDoesNotHoldIsNotHeldAndReadsAsNone() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        #expect(try await copy.items.folder("01a00000-0000-7000-8000-000000000001") == nil)
        await #expect {
            _ = try await copy.items.list(inFolder: "01a00000-0000-7000-8000-000000000001")
        } throws: { error in
            if case .notFound(let code, _) = error as? MarfaError { code == "not_held" } else { false }
        }
    }
}

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveFolderSettings {
        static func copy(_ types: [String] = ["core.note", "system.folder"], tier: SliceTier = .library)
            async throws -> WorkingCopy
        {
            let copy = try await WorkingCopy.open(store: Live.store(), server: Live.server)
            _ = try await copy.hydrate(types: types, tier: tier)
            return copy
        }

        @Test func aFolderIsMadeReadListedSearchedChangedAndRevokedThroughACopy() async throws {
            let copy = try await Self.copy()
            let tag = "shelf\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
            let note = try #require(
                try await copy.items.create(
                    Draft(
                        type: "core.note", properties: ["title": "Marmalade", "body": "oranges"], tags: [tag],
                        tier: .library)
                ).itemId)
            _ = try await copy.queue.drain()
            let heard = Heard(copy.changes())

            let made = try await copy.createFolder(
                FolderSettings(
                    title: "Shelf", search: FolderSearch(types: ["core.note"], filter: "tags contains \"\(tag)\"")))
            #expect(made.version == 1 && made.state == .active)
            #expect(try await copy.items.folder(made.id)?.settings.title == "Shelf", "held at once")
            #expect(try await copy.items.list(inFolder: made.id).map(\.id) == [note])
            #expect(try await copy.search("marmalade", inFolder: made.id).map(\.item.id) == [note])
            let renamed = try await copy.changeFolder(
                made.id, FolderSettingsChange(title: "Pantry"), baseVersion: made.version)
            #expect(renamed.version == 2 && renamed.settings.title == "Pantry")
            #expect(renamed.settings.search.types == ["core.note"], "a setting the change did not name stays")

            let revoked = try await copy.revokeFolder(made.id)
            #expect(revoked.state == .revoked)
            #expect(try await copy.items.folder(made.id)?.state == .revoked)
            await #expect {
                _ = try await copy.changeFolder(made.id, FolderSettingsChange(title: "Again"), baseVersion: 2)
            } throws: { error in
                if case .validation(let code, _) = error as? MarfaError { code == "invalid_transition" } else { false }
            }
            await #expect {
                _ = try await copy.items.list(inFolder: made.id)
            } throws: { error in
                if case .invalid = error as? MarfaError { true } else { false }
            }
            #expect(try await copy.queue.all().allSatisfy { $0.itemId != made.id }, "nothing was queued")
            try await Task.sleep(for: .milliseconds(300))
            let written = Change(origin: .refreshed(.folderWritten), itemId: made.id, edgeId: nil)
            #expect(heard.all.filter { $0 == written }.count == 3, "each of the create, the change and the revoke")
        }

        @Test func aStaleChangeIsRefusedAndARepeatedCreateAnswersTheFirstFolder() async throws {
            let copy = try await Self.copy()
            let key = "folder-\(UUID().uuidString.lowercased())"
            let made = try await copy.createFolder(
                FolderSettings(title: "Once", search: FolderSearch(types: ["core.note"])), idempotencyKey: key)
            let again = try await copy.createFolder(
                FolderSettings(title: "Once", search: FolderSearch(types: ["core.note"])), idempotencyKey: key)
            #expect(again.id == made.id)
            let renamed = try await copy.changeFolder(made.id, FolderSettingsChange(title: "Twice"), baseVersion: 1)
            #expect(renamed.version == 2)
            let merged = try await copy.changeFolder(
                made.id, FolderSettingsChange(search: FolderSearch(types: ["core.task"])), baseVersion: 1)
            #expect(merged.version == 3 && merged.settings.title == "Twice", "a setting the other change did not touch")
            await #expect {
                _ = try await copy.changeFolder(made.id, FolderSettingsChange(title: "Thrice"), baseVersion: 1)
            } throws: { error in
                if case .server(let status, let code, _) = error as? MarfaError {
                    status == 409 && code == "version_conflict"
                } else {
                    false
                }
            }
            #expect(
                try await copy.items.folder(made.id)?.settings.title == "Twice", "the refused change left it as it was")
            _ = try await copy.revokeFolder(made.id)
        }

        @Test func aSearchTheCopyCannotAnswerWholeIsRefusedNeverListedInPart() async throws {
            let copy = try await Self.copy()
            let every = try await copy.createFolder(FolderSettings(title: "Everything"))
            await #expect {
                _ = try await copy.items.list(inFolder: every.id)
            } throws: { error in
                if case .invalid(let message) = error as? MarfaError {
                    message.contains("does not take")
                } else {
                    false
                }
            }
            _ = try await copy.revokeFolder(every.id)
        }

        @Test func settingsNoFolderFollowsAreRefusedBeforeTheyAreSent() async throws {
            let copy = try await Self.copy()
            await #expect {
                _ = try await copy.createFolder(
                    FolderSettings(title: "Back", search: FolderSearch(filter: "backref[parent-of] exists")))
            } throws: { error in
                if case .invalid(let message) = error as? MarfaError { message.contains("backref") } else { false }
            }
        }
    }
}
