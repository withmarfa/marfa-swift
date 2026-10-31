#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

/// Search on a copy that never reached a server, on the real copy and the fake alike.
@Suite(.timeLimit(.minutes(1)))
struct SearchOffline {
    struct Held {
        let copy: WorkingCopy
        /// An item's title by its ID, since the two copies make different IDs.
        var titles: [String: String] = [:]

        func titled(_ hits: Rows<SearchHit>) -> [String] { hits.map { titles[$0.item.id] ?? $0.item.id } }
    }

    static let notes: [(title: String, body: String, tags: [String])] = [
        ("Zebra crossing", "stripes on the road", []),
        ("Field notes", "a zebra herd near the river", []),
        ("Plain", "nothing to see", ["zebras"]),
        ("Morning run", "ran five miles before it was light", ["fitness"]),
        ("Runner", "the club runner won", []),
        ("Marsh", "a marshland walk", []),
        ("Landscape", "marsh landscape painting", []),
        ("Quoted", "he said \"quiet landscape\" twice <b>& more</b>", []),
    ]

    static func open(_ kind: CopyKind) async throws -> Held {
        var held = Held(copy: try await kind.open())
        for note in notes {
            let id = try await ItemsOffline.note(note.title, in: held.copy, body: note.body, tags: note.tags)
            held.titles[id] = note.title
        }
        return held
    }

    @Test(arguments: CopyKind.allCases)
    func aWordFindsTheItemsWhoseTitleBodyOrTagsHoldIt(kind: CopyKind) async throws {
        let held = try await Self.open(kind)
        let found = try await held.copy.search("zebra")
        #expect(Set(held.titled(found)) == ["Zebra crossing", "Field notes", "Plain"])
        #expect(found.completeness == .complete)
        let excerpts = Dictionary(uniqueKeysWithValues: found.map { (held.titles[$0.item.id] ?? "", $0.snippet) })
        #expect(excerpts["Zebra crossing"] == "<mark>Zebra</mark> crossing")
        #expect(excerpts["Field notes"] == "a <mark>zebra</mark> herd near the river")
        #expect(found.allSatisfy { $0.score > 0 })
        await held.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func theExcerptReadsAsRunsWithTheMatchMarkedAndTheTextUnescaped(kind: CopyKind) async throws {
        let held = try await Self.open(kind)
        let hit = try #require(try await held.copy.search("quiet landscape").first)
        #expect(hit.snippet.contains("&lt;b&gt;"), "the snippet stays the HTML the copy wrote")
        let runs = hit.excerpt.runs
        #expect(runs.filter(\.isMatch).map(\.text).joined(separator: "|").lowercased().contains("quiet"))
        #expect(hit.excerpt.text.contains("<b>& more</b>"), "escapes read as the characters")
        #expect(!hit.excerpt.text.contains("<mark>"))
        await held.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aWordIsMatchedByItsStemAndTheLastWordAsAPrefix(kind: CopyKind) async throws {
        let held = try await Self.open(kind)
        #expect(Set(held.titled(try await held.copy.search("run"))) == ["Morning run", "Runner"])
        #expect(Set(held.titled(try await held.copy.search("zebr"))) == ["Zebra crossing", "Field notes", "Plain"])
        #expect(Set(held.titled(try await held.copy.search("runn"))) == ["Runner"])
        #expect(Set(held.titled(try await held.copy.search("ZEBRA CROSS"))) == ["Zebra crossing"])
        let excerpts = try await held.copy.search("ran five miles").map(\.snippet)
        #expect(excerpts == ["<mark>ran</mark> <mark>five</mark> <mark>miles</mark> before it was light"])
        await held.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func everyWordButTheLastMatchesWholeAndAQuotedQueryIsAPhrase(kind: CopyKind) async throws {
        let held = try await Self.open(kind)
        #expect(Set(held.titled(try await held.copy.search("marsh landscape"))) == ["Landscape"])
        #expect(Set(held.titled(try await held.copy.search("marsh land"))) == ["Landscape"])
        #expect(try await held.copy.search("marshland landscape").isEmpty)
        #expect(Set(held.titled(try await held.copy.search("\"quiet landscape\""))) == ["Quoted"])
        #expect(try await held.copy.search("\"landscape quiet\"").isEmpty)
        #expect(try await held.copy.search("\"quiet land\"").isEmpty)
        await held.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aQueryWithNoWordFindsNothing(kind: CopyKind) async throws {
        let held = try await Self.open(kind)
        for query in ["", "   ", "\t\n", "\u{FEFF}"] {
            #expect(try await held.copy.search(query).isEmpty, "\(query.debugDescription)")
        }
        await held.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func punctuationIsTextAndNeverSearchSyntax(kind: CopyKind) async throws {
        let held = try await Self.open(kind)
        for query in ["!!!", "-", "*", "\"", "\"\"", "zebra OR", "title:zebra"] {
            #expect(try await held.copy.search(query).isEmpty, "\(query)")
        }
        for query in ["-zebra", "zebra*", "(zebra", "zebra)"] {
            let answer = try await held.copy.search(query)
            #expect(Set(held.titled(answer)) == ["Zebra crossing", "Field notes", "Plain"], "\(query)")
        }
        await held.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anExcerptIsEscapedHTMLWithOnlyMarksAsMarkup(kind: CopyKind) async throws {
        let held = try await Self.open(kind)
        let found = try await held.copy.search("twice")
        let escaped = "he said &quot;quiet landscape&quot; <mark>twice</mark> &lt;b&gt;&amp; more&lt;/b&gt;"
        #expect(found.map(\.snippet) == [escaped])
        await held.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aLimitSmallerThanTheHitsKeepsTheBestOnes(kind: CopyKind) async throws {
        let held = try await Self.open(kind)
        let all = try await held.copy.search("zebra", limit: 20)
        #expect(all.count == 3)
        let two = try await held.copy.search("zebra", limit: 2)
        #expect(two.map(\.item.id) == all.prefix(2).map(\.item.id))
        #expect(try await held.copy.search("zebra", limit: 0).isEmpty)
        await held.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func theBinIsNeverSearchedAndTheStateFiltersNarrow(kind: CopyKind) async throws {
        let held = try await Self.open(kind)
        let crossing = try #require(held.titles.first { $0.value == "Zebra crossing" }?.key)
        let field = try #require(held.titles.first { $0.value == "Field notes" }?.key)
        _ = try await held.copy.items.transition(crossing, to: .archived)
        _ = try await held.copy.items.delete(field)

        #expect(Set(held.titled(try await held.copy.search("zebra"))) == ["Plain"])
        #expect(
            Set(held.titled(try await held.copy.search("zebra", filters: SearchFilters(states: [.archived]))))
                == ["Zebra crossing"])
        #expect(
            Set(held.titled(try await held.copy.search("zebra", filters: SearchFilters(allStates: true))))
                == ["Zebra crossing", "Plain"])
        #expect(try await held.copy.search("zebra", filters: SearchFilters(states: [.trashed])).isEmpty)

        await held.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func theOtherFiltersNarrowAsTheyDoAList(kind: CopyKind) async throws {
        let held = try await Self.open(kind)
        let tagged = try await held.copy.search("zebra", filters: SearchFilters(tags: ["zebras"]))
        #expect(Set(held.titled(tagged)) == ["Plain"])
        #expect(try await held.copy.search("zebra", filters: SearchFilters(tags: ["zebras", "absent"])).isEmpty)
        let typed = try await held.copy.search("zebra", filters: SearchFilters(types: ["core.note"]))
        #expect(typed.count == 3)
        #expect(try await held.copy.search("zebra", filters: SearchFilters(types: ["core.task"])).isEmpty)
        #expect(try await held.copy.search("zebra", filters: SearchFilters(tier: .feed)).isEmpty)
        #expect(try await held.copy.search("zebra", filters: SearchFilters(tier: .library)).count == 3)
        await held.copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aTypeSearchesTheStringPropertiesItDeclaresUnlessItMarksThemUnsearchable(kind: CopyKind) async throws {
        let copy = try await kind.open(declaring: [
            [
                "id": "app.test.entry",
                "fields": [
                    "note": ["type": "string"],
                    "secret": ["type": "string", "searchable": false],
                    "count": ["type": "integer"],
                ],
            ]
        ])
        let made = try await copy.items.create(
            Draft(
                type: "app.test.entry",
                properties: [
                    "title": "T",
                    "note": "visible wombat",
                    "secret": "hidden quokka",
                    "count": 7,
                    "undeclared": "stray numbat",
                ]
            )
        )
        let id = try #require(made.itemId)
        #expect(try await copy.search("wombat").map(\.item.id) == [id])
        #expect(try await copy.search("quokka").isEmpty)
        #expect(try await copy.search("numbat").isEmpty)
        await copy.close()
    }

    @Test func bothCopiesAnswerTheSameHitsInTheSameOrderWithTheSameExcerpts() async throws {
        let real = try await Self.open(.real)
        let fake = try await Self.open(.fake)
        let queries = [
            "zebra", "zebr", "run", "runn", "marsh", "marsh land", "land", "the", "a", "stripes road", "ran five",
            "\"quiet landscape\"", "\"marsh landscape\"", "river zebra", "notes field", "nothing zebras",
        ]
        for query in queries {
            let one = try await real.copy.search(query)
            let other = try await fake.copy.search(query)
            #expect(real.titled(one) == fake.titled(other), "\(query)")
            #expect(one.map(\.snippet) == other.map(\.snippet), "\(query)")
            #expect(one.completeness == other.completeness, "\(query)")
            #expect(zip(one, other).allSatisfy { abs($0.score - $1.score) < 1e-9 }, "\(query)")
        }
        await real.copy.close()
        await fake.copy.close()
    }
}
#endif
