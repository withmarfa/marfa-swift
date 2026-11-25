#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

/// How long a type's feed items stay in the feed, read from the catalog alone.
@Suite(.timeLimit(.minutes(1)))
struct TypeFeedWindowOffline {
    @Test(arguments: CopyKind.allCases)
    func aTypeWithNoFeedWindowKeepsItsFeedItems(kind: CopyKind) async throws {
        let copy = try await kind.open(declaring: [["id": "app.readinglist.entry"]])
        for id in ["core.note", "app.readinglist.entry"] {
            #expect(try await copy.catalog.itemType(id).feedDays == nil)
        }
        let windows = try await copy.catalog.itemTypes().compactMap(\.feedDays)
        #expect(windows.isEmpty)
        await copy.close()
    }

    @Test func theFakeAnswersTheWindowItIsGiven() async throws {
        let copy = WorkingCopy.fake(itemTypes: [
            ItemType(id: "app.readinglist.article", feedDays: 30),
            ItemType(id: "app.readinglist.entry"),
        ]).copy
        #expect(try await copy.catalog.itemType("app.readinglist.article").feedDays == 30)
        #expect(try await copy.catalog.itemType("app.readinglist.entry").feedDays == nil)
        let listed = try await copy.catalog.itemTypes().map { [$0.id: $0.feedDays] }
        #expect(listed.contains(["app.readinglist.article": 30]))
        await copy.close()
    }

    @Test func aTypeDeclaredUnderATypeWithAWindowHoldsIt() async throws {
        let copy = WorkingCopy.fake(itemTypes: [ItemType(id: "app.readinglist.article", feedDays: 30)]).copy
        try await copy.declareTypes([["id": "app.readinglist.clipping", "parent": "app.readinglist.article"]])
        #expect(try await copy.catalog.itemType("app.readinglist.clipping").feedDays == 30)
        await copy.close()
    }

    @Test func theFakeThrowsUnsupportedForADeclarationThatSetsAFeedWindow() async throws {
        let copy = try await CopyKind.makeFake().copy
        await #expect {
            try await copy.declareTypes([
                ["id": "app.readinglist.clip", "retention_policy": ["feed_days": 7]]
            ])
        } throws: { error in
            (error as? FakeCopyError)
                == .unsupported(call: "declareTypes with a retention policy in app.readinglist.clip")
        }
        #expect(try await copy.declaredTypes().isEmpty)
        await copy.close()
    }
}
#endif
