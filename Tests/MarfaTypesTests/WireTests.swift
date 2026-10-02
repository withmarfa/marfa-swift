import Foundation
import MarfaTypes
import Testing

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
    let next = try JSONDecoder().decode(
        Components.Schemas.ItemPage.self, from: Data(#"{"data":[],"next_cursor":"c1"}"#.utf8))
    #expect(next.nextCursor == "c1")
}

private let live: (url: URL, key: String)? = {
    let environment = ProcessInfo.processInfo.environment
    // The same reading as `Server.fromEnvironment`, which this target cannot import.
    guard let text = environment["MARFA_API_URL"], !text.isEmpty, let key = environment["MARFA_API_KEY"], !key.isEmpty,
        let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()),
        !(url.host() ?? "").isEmpty
    else { return nil }
    return (url, key)
}()

@Test(.enabled(if: ProcessInfo.processInfo.environment["MARFA_LIVE_REQUIRED"] != nil))
func theLiveTestHasAServerWhereItIsRequired() {
    #expect(live != nil, "MARFA_LIVE_REQUIRED is set, and MARFA_API_URL or MARFA_API_KEY is not")
}

@Test(.enabled(if: live != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"))
func thePinnedServerAnswersInTheseTypes() async throws {
    let (url, key) = try #require(live)
    let (rootBody, _) = try await URLSession.shared.data(from: url)
    let root = try JSONDecoder().decode(Operations.GetInstance.Output.Ok.Body.JsonPayload.self, from: rootBody)
    #expect(root.contract == marfaContractVersion)

    let title = "Wire \(UUID())"
    var create = URLRequest(url: url.appending(path: "items"))
    create.httpMethod = "POST"
    create.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    create.setValue("application/json", forHTTPHeaderField: "Content-Type")
    create.httpBody = Data(#"{"type":"core.note","properties":{"title":"\#(title)","body":""}}"#.utf8)
    let (_, created) = try await URLSession.shared.data(for: create)
    try #require((created as? HTTPURLResponse)?.statusCode == 201)

    let items = url.appending(path: "items").appending(queryItems: [
        .init(name: "type", value: "core.note"), .init(name: "limit", value: "100"),
    ])
    var request = URLRequest(url: items)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let (pageBody, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Marfa-Contract")
    #expect(header == String(marfaContractVersion))
    let page = try JSONDecoder().decode(Components.Schemas.ItemPage.self, from: pageBody)
    let titles = page.data.compactMap { row -> String? in
        guard case .Item(let item) = row else { return nil }
        return item.properties.additionalProperties["title"].flatMap { $0.value as? String }
    }
    #expect(titles.contains(title), "the page read as \(page.data.count) row(s), none the note sent")
}
