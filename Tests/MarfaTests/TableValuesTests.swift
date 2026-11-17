import MarfaCore
import Testing

@testable import Marfa

/// A row operation, and how it reaches the core.
@Suite struct RowOperations {
    @Test func eachOperationIsAnObjectInTheServersShape() {
        let put: JSONObject = ["op": "put", "values": ["a": 1]]
        #expect(RowOperation.put(values: ["a": 1]).core == put.core)
        let placed: JSONObject = ["op": "put", "id": "r", "values": [:]]
        #expect(RowOperation.put(id: "r", values: [:]).core == placed.core)
        let patch: JSONObject = ["op": "patch", "id": "r", "values": ["a": .null]]
        #expect(RowOperation.patch(id: "r", values: ["a": .null]).core == patch.core)
        let delete: JSONObject = ["op": "delete", "id": "r"]
        #expect(RowOperation.delete(id: "r").core == delete.core)
    }

    @Test func aColumnSortIsNamedAsTheServerSortsIt() {
        #expect(RowsQuery(sort: .column("note"), direction: .descending).core.sort == "values.note")
        #expect(RowsQuery(sort: .updatedAt).core.sort == "updated_at")
        #expect(RowsQuery(sort: .id).core.sort == "id")
        #expect(RowsQuery().core.sort == nil)
        #expect(RowsQuery(limit: -3).core.limit == 0)
    }
}
