import Foundation
import Testing

@testable import Marfa

private func refusal(_ error: any Error) -> (code: String, message: String)? {
    if case MarfaError.validation(let code, let message)? = error as? MarfaError { (code, message) } else { nil }
}

@Suite(.timeLimit(.minutes(1)))
struct FilterModel {
    @Test func aValueWithQuotesBackslashesCommasAndEmojiRoundTrips() throws {
        let value = #"He said "hi", \o/ 🎉👩‍👩‍👧 (really)"#
        let expression = FilterExpression(
            join: .any,
            conditions: [
                FilterCondition(field: .property("title"), operator: .eq, value: .text(value)),
                FilterCondition(field: .tags, operator: .contains, value: .text("a,b")),
            ])
        let text = try expression.encoded()
        #expect(try FilterExpression(decoding: text) == expression)
    }

    @Test func severalConditionsOfEveryKindOfFieldAreReadBack() throws {
        let expression = FilterExpression(
            join: .all,
            conditions: [
                FilterCondition(field: .system(.updatedAt), operator: .gte, value: .text("2026-01-01T00:00:00Z")),
                FilterCondition(field: .property("pages"), operator: .gt, value: .number(12.5)),
                FilterCondition(field: .property("done"), operator: .eq, value: .bool(true)),
                FilterCondition(field: .statusGroup, operator: .neq, value: .text("completed")),
                FilterCondition(field: .edge(type: "parent-of", direction: .backref), operator: .exists),
                FilterCondition(field: .property("cover"), operator: .notExists),
            ])
        let text = try expression.encoded()
        let read = try FilterExpression(decoding: text)
        #expect(read.conditions.count == 6)
        #expect(read == expression)
    }

    @Test func aSingleConditionReadsBackWithTheJoinAll() throws {
        let one = FilterCondition(field: .system(.type), operator: .eq, value: .text("core.note"))
        let read = try FilterExpression(decoding: FilterExpression(join: .any, conditions: [one]).encoded())
        #expect(read == FilterExpression(join: .all, conditions: [one]))
    }

    @Test func aTextOfExactlyTheLimitIsTakenAndOneUnitMoreIsRefusedWithTheServersCode() throws {
        func expression(units: Int) -> FilterExpression {
            let prefix = FilterExpression(
                conditions: [FilterCondition(field: .property("t"), operator: .eq, value: .text(""))])
            let overhead = (try? prefix.encoded().utf16.count) ?? 0
            return FilterExpression(
                conditions: [
                    FilterCondition(
                        field: .property("t"), operator: .eq,
                        value: .text(String(repeating: "x", count: units - overhead)))
                ])
        }
        #expect(try expression(units: 2_048).encoded().utf16.count == 2_048)
        #expect {
            try expression(units: 2_049).encoded()
        } throws: { error in
            guard let (code, message) = refusal(error) else { return false }
            return code == "validation_error" && !message.isEmpty
        }
    }

    @Test func aTextValueMayEndInABackslash() throws {
        let expression = FilterExpression(
            conditions: [FilterCondition(field: .property("t"), operator: .eq, value: .text(#"ends\"#))])
        #expect(try FilterExpression(decoding: expression.encoded()) == expression)
    }

    @Test func aFilterTheServerRefusesIsNotDecoded() {
        #expect { try FilterExpression(decoding: "not a filter ((") } throws: {
            refusal($0)?.code == "validation_error"
        }
    }

    @Test func aFieldListsTheOperatorsTheGrammarTakesOnIt() {
        #expect(FilterField.system(.id).operators.contains(.eq))
        let tags = FilterField.tags.operators
        #expect(!tags.isEmpty)
        #expect(FilterField.property("x").operators.contains(.exists))
    }

    @Test func anEncodedFilterIsTheTextAListingTakes() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        _ = try await copy.items.create(Draft(type: "core.note", properties: ["title": "Keep"]))
        _ = try await copy.items.create(Draft(type: "core.note", properties: ["title": "Skip"]))
        let text = try FilterExpression(
            conditions: [FilterCondition(field: .property("title"), operator: .eq, value: .text("Keep"))]
        ).encoded()
        let found = try await copy.items.list(ListFilters(type: "core.note", filter: text))
        #expect(found.map { $0.title } == ["Keep"])
        await copy.close()
    }
}
