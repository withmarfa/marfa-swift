import Foundation
import MarfaTypes
import Testing

@Test(arguments: ["marfa", "Marfa", "Bibliothèque <notes> 𐐀"])
func instanceDescriptionPreservesConfiguredName(name: String) throws {
    let body = try JSONSerialization.data(withJSONObject: [
        "name": name,
        "version": "test",
        "instance_id": "instance-name-wire-test",
        "contract": 0,
        "features": ["items"],
    ])
    let instance = try JSONDecoder().decode(Components.Schemas.InstanceDescription.self, from: body)
    let encoded = try JSONEncoder().encode(instance)
    let answer = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(answer["name"] as? String == name)
}
