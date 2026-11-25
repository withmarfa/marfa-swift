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
            removalThreshold: RemovalThreshold(files: 4, fraction: 0.5, ceiling: 3),
            additionThreshold: AdditionThreshold(files: 7, fraction: 0.5), outsideQuery: .hold,
            fullPassIntervalSeconds: 60)
        let crossed = FolderSettings(settings.core)
        #expect(crossed == settings)
        #expect(crossed.fullPassIntervalSeconds == 60)
        #expect(FolderSettings(FolderSettings().core).fullPassIntervalSeconds == nil)
        #expect(crossed.removalThreshold.ceiling == 3, "the removal threshold's ceiling")
        #expect(FolderSettings(FolderSettings().core).removalThreshold.ceiling == nil, "no ceiling is 100, not 0")
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
                    title: "Shelf", query: FolderQuery(types: ["core.note"], filter: "tags contains \"shelf\""),
                    fullPassIntervalSeconds: 60))
            #expect(made.version == 1 && made.state == .active)
            #expect(try await copy.items.folder(made.id)?.settings.title == "Shelf", "held at once")
            let renamed = try await copy.changeFolder(
                made.id, FolderSettingsChange(title: "Pantry"), baseVersion: made.version)
            #expect(renamed.version == 2 && renamed.settings.title == "Pantry")
            #expect(renamed.settings.fullPassIntervalSeconds == 60)
            let changed = try await copy.changeFolder(
                made.id, FolderSettingsChange(fullPassIntervalSeconds: 86_400), baseVersion: renamed.version)
            #expect(changed.settings.fullPassIntervalSeconds == 86_400)
            #expect(try await copy.items.folder(made.id)?.settings.fullPassIntervalSeconds == 86_400)
            #expect(renamed.settings.query.types == ["core.note"], "a setting the change did not name stays")

            let revoked = try await copy.revokeFolder(made.id)
            #expect(revoked.state == .revoked)
            #expect(try await copy.items.folder(made.id)?.state == .revoked)
            await #expect {
                _ = try await copy.changeFolder(made.id, FolderSettingsChange(title: "Again"), baseVersion: 2)
            } throws: { error in
                if case .validation(let code, _, _, _) = error as? MarfaError {
                    code == "invalid_transition"
                } else {
                    false
                }
            }
            #expect(try await copy.queue.all().allSatisfy { $0.itemId != made.id }, "nothing was queued")
            try await Task.sleep(for: .milliseconds(300))
            let written = Change(origin: .refreshed(.folderWritten), itemId: made.id, edgeId: nil)
            #expect(heard.all.filter { $0 == written }.count == 4, "the create, both changes and the revoke")
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
                if case .versionConflict = error as? MarfaError { true } else { false }
            }
            #expect(
                try await copy.items.folder(made.id)?.settings.title == "Twice", "the refused change left it as it was")
            _ = try await copy.revokeFolder(made.id)
        }

        @Test func aRemovalThresholdCeilingIsMadeReadBackAndKeptThroughAChange() async throws {
            let copy = try await Self.copy()
            let made = try await copy.createFolder(
                FolderSettings(
                    title: "Ceiling", query: FolderQuery(types: ["core.note"]),
                    removalThreshold: RemovalThreshold(files: 4, fraction: 0.5, ceiling: 3)))
            #expect(made.settings.removalThreshold == RemovalThreshold(files: 4, fraction: 0.5, ceiling: 3))
            #expect(try await copy.items.folder(made.id)?.settings.removalThreshold.ceiling == 3)
            let renamed = try await copy.changeFolder(
                made.id, FolderSettingsChange(title: "Ceiling kept"), baseVersion: made.version)
            #expect(renamed.settings.removalThreshold.ceiling == 3, "a change that leaves the threshold alone")
            let changed = try await copy.changeFolder(
                made.id, FolderSettingsChange(removalThreshold: RemovalThreshold(files: 5, ceiling: 7)),
                baseVersion: renamed.version)
            #expect(changed.settings.removalThreshold == RemovalThreshold(files: 5, fraction: nil, ceiling: 7))
            let unset = try await copy.changeFolder(
                made.id, FolderSettingsChange(removalThreshold: RemovalThreshold(files: 5)),
                baseVersion: changed.version)
            #expect(unset.settings.removalThreshold.ceiling == nil, "a threshold with no ceiling is the default of 100")
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
