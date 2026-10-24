import Foundation
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1))) struct FolderSettingsOffline {
    @Test func settingsCrossTheBindingAndBackUnchanged() throws {
        let settings = FolderSettings(
            title: "Recipes",
            query: FolderQuery(
                types: ["core.note"], tier: .all, states: [.archived], filter: "tags contains \"recipe\"",
                beneath: "parent"),
            defaults: FolderDefaults(
                type: "core.note", tier: .feed, properties: ["rating": 3, "cuisine": "any"], tags: ["new"],
                edges: ["about": ["topic"]]),
            include: ["*.md"], ignore: ["drafts/"], firstPlacement: ["core.note": "Notes"],
            removalThreshold: RemovalThreshold(files: 4, fraction: 0.5))
        let crossed = FolderSettings(settings.core)
        #expect(crossed == settings)
        #expect(crossed.query.tier == .all, "a query of both tiers")
        #expect(FolderSettings(FolderSettings().core).query.tier == nil, "no tier is the library tier, not a tier")
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

    @Test func aFolderTheCopyDoesNotHoldReadsAsNone() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        #expect(try await copy.items.folder("01a00000-0000-7000-8000-000000000001") == nil)
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

        @Test func aFolderIsMadeReadChangedAndRevokedThroughACopy() async throws {
            let copy = try await Self.copy()
            let heard = Heard(copy.changes())

            let made = try await copy.createFolder(
                FolderSettings(
                    title: "Shelf", query: FolderQuery(types: ["core.note"], filter: "tags contains \"shelf\"")))
            #expect(made.version == 1 && made.state == .active)
            #expect(try await copy.items.folder(made.id)?.settings.title == "Shelf", "held at once")
            let renamed = try await copy.changeFolder(
                made.id, FolderSettingsChange(title: "Pantry"), baseVersion: made.version)
            #expect(renamed.version == 2 && renamed.settings.title == "Pantry")
            #expect(renamed.settings.query.types == ["core.note"], "a setting the change did not name stays")

            let revoked = try await copy.revokeFolder(made.id)
            #expect(revoked.state == .revoked)
            #expect(try await copy.items.folder(made.id)?.state == .revoked)
            await #expect {
                _ = try await copy.changeFolder(made.id, FolderSettingsChange(title: "Again"), baseVersion: 2)
            } throws: { error in
                if case .validation(let code, _) = error as? MarfaError { code == "invalid_transition" } else { false }
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
                FolderSettings(title: "Once", query: FolderQuery(types: ["core.note"])), idempotencyKey: key)
            let again = try await copy.createFolder(
                FolderSettings(title: "Once", query: FolderQuery(types: ["core.note"])), idempotencyKey: key)
            #expect(again.id == made.id)
            let renamed = try await copy.changeFolder(made.id, FolderSettingsChange(title: "Twice"), baseVersion: 1)
            #expect(renamed.version == 2)
            let merged = try await copy.changeFolder(
                made.id, FolderSettingsChange(query: FolderQuery(types: ["core.task"])), baseVersion: 1)
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

        @Test func aQueryOfBothTiersIsMadeAndReadBackAtBoth() async throws {
            let copy = try await Self.copy()
            let made = try await copy.createFolder(
                FolderSettings(title: "Both", query: FolderQuery(types: ["core.note"], tier: .all)))
            #expect(made.settings.query.tier == .all)
            #expect(try await copy.items.folder(made.id)?.settings.query.tier == .all)
            let narrowed = try await copy.changeFolder(
                made.id, FolderSettingsChange(query: FolderQuery(types: ["core.note"], tier: .library)), baseVersion: 1)
            #expect(narrowed.settings.query.tier == .library)
            _ = try await copy.revokeFolder(made.id)
        }

        @Test func settingsNoFolderFollowsAreRefusedBeforeTheyAreSent() async throws {
            let copy = try await Self.copy()
            await #expect {
                _ = try await copy.createFolder(
                    FolderSettings(title: "Typo", query: FolderQuery(types: ["core.note"], filter: "title eq 1")))
            } throws: { error in
                if case .validation = error as? MarfaError { true } else { false }
            }
            await #expect {
                _ = try await copy.createFolder(
                    FolderSettings(title: "Back", query: FolderQuery(filter: "backref[parent-of] exists")))
            } throws: { error in
                if case .invalid(let message) = error as? MarfaError { message.contains("backref") } else { false }
            }
        }
    }
}
