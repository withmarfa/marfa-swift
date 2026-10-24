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
    func theMachineItselfAndHttpsRaiseNoNotice(address: String) throws {
        let server = try server(address)
        #expect(!server.isPlainHTTPToAnotherHost)
        #expect(server.takePlainHTTPNotice() == nil)
    }

    @Test(arguments: [
        "http://marfa.example", "http://localhost.example", "http://128.0.0.1", "http://0.0.0.0", "http://10.0.0.5",
        "http://[::2]", "http://[::ffff:10.0.0.5]", "http://[::ffff:127.0.0.1]", "HTTP://Marfa.Example:8600",
    ])
    func anyOtherPlainHttpAddressIsFlagged(address: String) throws {
        #expect(try server(address).isPlainHTTPToAnotherHost)
    }

    @Test func theNoticeComesOnceAndNamesOnlyTheOrigin() throws {
        let name = "marfa-\(UUID().uuidString.lowercased()).example"
        let first = try server("http://\(name):8600/path?q=1").takePlainHTTPNotice()
        #expect(first?.origin == "http://\(name):8600")
        #expect(first?.message.contains("http://\(name):8600") == true)
        #expect(first?.message.contains("path") == false)

        #expect(try server("http://\(name):8600").takePlainHTTPNotice() == nil, "asked again")
        #expect(try server("HTTP://\(name.uppercased()):8600/other").takePlainHTTPNotice() == nil, "the same origin")
        #expect(try server("http://\(name):8601").takePlainHTTPNotice() != nil, "another port is another address")
    }

    @Test func theDefaultPortIsNotShown() throws {
        let name = "marfa-\(UUID().uuidString.lowercased()).example"
        #expect(try server("http://\(name):80").takePlainHTTPNotice()?.origin == "http://\(name)")
    }
}
