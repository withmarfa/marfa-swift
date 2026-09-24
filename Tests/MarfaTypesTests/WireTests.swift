import Foundation
import MarfaTypes
import Testing

/// A row of an item page reads as the generated item, its snake-case names
/// reaching their Swift spellings.
@Test func aPageOfItemsReadsEachRow() throws {
    let item =
        #"{"id":"i1","type":"core.note","state":"active","tier":"library","properties":{"title":"A note"},"created_at":"2026-09-24T00:00:00Z","updated_at":"2026-09-24T00:00:00Z","occurred_at":"2026-09-24T00:00:00Z","version":1,"source":"s","schema_version":1}"#
    let page = try JSONDecoder().decode(
        Components.Schemas.ItemPage.self, from: Data(#"{"data":[\#(item)],"next_cursor":null}"#.utf8))
    guard case .Item(let row)? = page.data.first else {
        Issue.record("the row read as \(String(describing: page.data.first))")
        return
    }
    #expect(row.id == "i1")
    #expect(row.schemaVersion == 1)
    #expect(page.nextCursor == nil)
}

/// The server a live test reads, named by `MARFA_API_URL` and `MARFA_API_KEY`.
private let live: (url: URL, key: String)? = {
    let environment = ProcessInfo.processInfo.environment
    guard let url = environment["MARFA_API_URL"].flatMap(URL.init(string:)), let key = environment["MARFA_API_KEY"]
    else { return nil }
    return (url, key)
}()

/// The pinned server's own answers read as the types generated from its
/// document: the root names the contract they were generated for, and a
/// page of items decodes whole.
@Test(.enabled(if: live != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"))
func thePinnedServerAnswersInTheseTypes() async throws {
    let (url, key) = try #require(live)
    let (rootBody, _) = try await URLSession.shared.data(from: url)
    let root = try JSONDecoder().decode(Operations.GetInstance.Output.Ok.Body.JsonPayload.self, from: rootBody)
    #expect(root.contract == marfaContractVersion)

    let items = url.appending(path: "items").appending(queryItems: [.init(name: "limit", value: "5")])
    var request = URLRequest(url: items)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let (pageBody, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Marfa-Contract")
    #expect(header == String(marfaContractVersion))
    _ = try JSONDecoder().decode(Components.Schemas.ItemPage.self, from: pageBody)
}
