import Foundation
import Testing

@testable import Marfa

@Suite
struct ServerCleartext {
    private func server(_ address: String) throws -> Server {
        Server(url: try #require(URL(string: address)), key: "unused")
    }

    @Test(arguments: [
        "http://localhost:8600", "http://LOCALHOST", "http://127.0.0.1", "http://127.1.2.3:80", "http://127.1",
        "http://[::1]:8600", "https://marfa.example", "https://10.0.0.5", "http://[0:0:0:0:0:0:0:1]",
    ])
    func theMachineItselfAndHttpsHaveNoPlainHTTPOrigin(address: String) throws {
        #expect(try server(address).plainHTTPOrigin == nil)
    }

    @Test(arguments: [
        ("http://marfa.example", "http://marfa.example"),
        ("http://localhost.example", "http://localhost.example"),
        ("http://128.0.0.1", "http://128.0.0.1"),
        ("http://0.0.0.0", "http://0.0.0.0"),
        ("http://10.0.0.5", "http://10.0.0.5"),
        ("http://[::2]", "http://[::2]"),
        ("http://[::ffff:10.0.0.5]", "http://[::ffff:10.0.0.5]"),
        ("http://[::ffff:127.0.0.1]", "http://[::ffff:127.0.0.1]"),
        ("HTTP://Marfa.Example:8600", "http://marfa.example:8600"),
    ])
    func anyOtherPlainHttpAddressNamesItsOrigin(address: String, origin: String) throws {
        #expect(try server(address).plainHTTPOrigin == origin)
    }

    @Test func theOriginNamesOnlySchemeHostAndPort() throws {
        #expect(try server("http://marfa.example:8600/path?q=1#top").plainHTTPOrigin == "http://marfa.example:8600")
        #expect(try server("http://marfa.example:80/other").plainHTTPOrigin == "http://marfa.example")
    }

    @Test func theSameOriginAnswersTheSameEveryTime() throws {
        let first = try server("http://marfa.example:8600").plainHTTPOrigin
        #expect(try server("http://marfa.example:8600").plainHTTPOrigin == first, "asked again")
        #expect(try server("http://marfa.example:8601").plainHTTPOrigin != first, "another port is another origin")
    }
}
