import Darwin
import Foundation
import Marfa
import Testing

@Suite struct InstanceDescriptionTests {
    @Test(arguments: ["Bibliothèque <notes> 𐐀", "Marfa"])
    func readsThePublicDescription(name: String) async throws {
        for prefix in ["/instance", "/instance/"] {
            let (url, request) = try rootServer(body: description(name: name))
            let address = try #require(URL(string: "\(url.absoluteString)\(prefix)?ignored=1#fragment"))
            let server = Server(url: address, key: "marfa_k1_unused")
            let instance: InstanceDescription = try await server.instanceDescription()
            #expect(instance.name == name)
            #expect(instance.version == "build-test")
            #expect(instance.release == "0.0.14")
            #expect(instance.instanceId == "019a1950-3b30-7000-8000-000000000001")
            #expect(instance.contract == 0)
            #expect(instance.features == ["items", "webhooks"])
            let sent = try await request.value.lowercased()
            #expect(sent.hasPrefix("get /instance/ http/1.1\r\n"))
            #expect(sent.contains("accept: application/json\r\n"))
            #expect(!sent.contains("authorization:"))
        }
    }

    @Test func readsABuildWithoutARelease() async throws {
        let (url, request) = try rootServer(body: description(name: "Marfa", release: nil))
        let instance = try await Server(url: url, key: "").instanceDescription()
        #expect(instance.release == nil)
        _ = try await request.value
    }

    @Test(arguments: ["{}", "<html>page</html>", "{\"name\":false}"])
    func malformedAnswersFail(body: String) async throws {
        let (url, request) = try rootServer(body: body)
        await #expect {
            _ = try await Server(url: url, key: "").instanceDescription()
        } throws: { error in
            if case MarfaError.decoding = error { true } else { false }
        }
        _ = try await request.value
    }

    @Test func connectionFailureIsReported() async throws {
        let (url, request) = try rootServer(body: nil)
        await #expect {
            _ = try await Server(url: url, key: "").instanceDescription()
        } throws: { error in
            if case MarfaError.network = error { true } else { false }
        }
        _ = try await request.value
    }

    private func description(name: String, release: String? = "0.0.14") throws -> String {
        var fields: [String: Any] = [
            "name": name, "version": "build-test",
            "instance_id": "019a1950-3b30-7000-8000-000000000001", "contract": 0,
            "features": ["items", "webhooks"],
        ]
        if let release { fields["release"] = release }
        return String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }
}

/// A real HTTP connection, because the Rust transport does not use URLSession.
private func rootServer(body: String?) throws -> (URL, Task<String, any Error>) {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw socketError() }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    do {
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw socketError() }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        guard named == 0 else { throw socketError() }
    } catch {
        close(listener)
        throw error
    }
    let url = try #require(URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"))
    let request = Task {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try answerRoot(listener: listener, body: body) })
            }
        }
    }
    return (url, request)
}

private func answerRoot(listener: Int32, body: String?) throws -> String {
    defer { close(listener) }
    var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    guard poll(&ready, 1, 10000) > 0 else { throw POSIXError(.ETIMEDOUT) }
    let connection = accept(listener, nil, nil)
    guard connection >= 0 else { throw socketError() }
    defer { close(connection) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    guard setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
        throw socketError()
    }
    var bytes = [UInt8](repeating: 0, count: 4096)
    var request = Data()
    while !request.suffix(4).elementsEqual([13, 10, 13, 10]) {
        let count = recv(connection, &bytes, bytes.count, 0)
        guard count > 0 else { throw socketError() }
        request.append(contentsOf: bytes.prefix(count))
    }
    if let body {
        let response = Data(
            ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n\(body)").utf8)
        try response.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = send(connection, buffer.baseAddress?.advanced(by: sent), buffer.count - sent, 0)
                guard count > 0 else { throw socketError() }
                sent += count
            }
        }
    }
    return String(decoding: request, as: UTF8.self)
}

private func socketError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
