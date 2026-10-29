import Foundation
import Marfa
import Testing

@testable import MarfaTelemetry

@Suite(.timeLimit(.minutes(1)))
struct Reports {
    @Test func anExceptionHasTheShapeTheCommandLinePosts() async throws {
        let recorder = Recorder()
        let telemetry = try configured(recorder)
        let error = MarfaError.notFound(code: "item_not_found", message: "Note \"My secret diary\" in /Users/x/notes")
        #expect(error.message.contains("secret"))

        telemetry.report(error, during: "drain")
        await telemetry.flush()

        let request = try #require(recorder.requests.first)
        #expect(recorder.requests.count == 1)
        #expect(request.url.absoluteString == "https://eu.i.posthog.com/i/v0/e/")
        let event = try object(request)
        #expect(event["api_key"] as? String == "phc_test")
        #expect(event["event"] as? String == "$exception")
        #expect((event["distinct_id"] as? String)?.count == 32)
        let properties = try #require(event["properties"] as? [String: Any])
        #expect(properties["$process_person_profile"] as? Bool == false)
        #expect(properties["$geoip_disable"] as? Bool == true)
        #expect(properties["$lib"] as? String == "mapp")
        #expect(properties["$lib_version"] as? String == "1.2.3")
        #expect(properties["service.name"] as? String == "mapp")
        #expect(properties["service.version"] as? String == "1.2.3")
        #expect(properties["service.instance.id"] as? String == "instance-1")
        #expect(properties["$exception_level"] as? String == "error")
        #expect(properties["operation"] as? String == "drain")
        #expect(properties["error_code"] as? String == "item_not_found")
        for key in ["$os", "$os_version", "arch"] {
            #expect(properties[key] is String, "\(key)")
        }
        let list = try #require(properties["$exception_list"] as? [[String: Any]])
        let exception = try #require(list.first)
        #expect(list.count == 1)
        #expect(exception["type"] as? String == "not_found")
        #expect(exception["value"] as? String == "the server has nothing at what the request named")
        #expect(exception["stacktrace"] == nil)
        let mechanism = try #require(exception["mechanism"] as? [String: Any])
        #expect(mechanism["handled"] as? Bool == true)
        #expect(mechanism["synthetic"] as? Bool == false)
        let text = String(decoding: request.body, as: UTF8.self)
        for value in ["secret", "diary", "/Users", "notes"] {
            #expect(!text.contains(value), "\(value)")
        }
    }

    @Test func anAppsOwnErrorCarriesOnlyItsFixedText() async throws {
        let recorder = Recorder()
        let telemetry = try configured(recorder)
        telemetry.report(type: "editor_ended", sentence: "the editor's web process ended", during: "editing")
        await telemetry.flush()

        let request = try #require(recorder.requests.first)
        let properties = try #require(try object(request)["properties"] as? [String: Any])
        let exception = try #require((properties["$exception_list"] as? [[String: Any]])?.first)
        #expect(exception["type"] as? String == "editor_ended")
        #expect(exception["value"] as? String == "the editor's web process ended")
        #expect(properties["error_code"] == nil)
    }

    @Test func aServerCodeIsSentOnlyWhenItHasTheShapeOfOne() {
        let shaped = MarfaError.server(status: 500, code: "internal_error", message: "")
        #expect(shaped.fixedText.code == "internal_error")
        for code in ["Note abc 123", "01a1648c-0824", "", String(repeating: "a", count: 49), "/Users/x"] {
            let text = MarfaError.validation(code: code, message: "").fixedText
            #expect(text.code == "validation", "\(code)")
        }
        #expect(MarfaError.closed(message: "/Users/x").fixedText.code == "closed")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct Switch {
    @Test func offSendsNothingAndTurningItOffDropsWhatWasQueued() async throws {
        let recorder = Recorder()
        let telemetry = try configured(recorder, enabled: false)
        telemetry.log("while_off")
        telemetry.report(type: "while_off", sentence: "off", during: "test")
        await telemetry.flush()
        #expect(recorder.requests.isEmpty)

        telemetry.isEnabled = true
        telemetry.log("queued_then_dropped")
        telemetry.isEnabled = false
        telemetry.isEnabled = true
        await telemetry.flush()
        #expect(recorder.requests.isEmpty)

        telemetry.log("kept")
        await telemetry.flush()
        let sent = try #require(recorder.requests.first)
        #expect(try records(sent).map { ($0["body"] as? [String: Any])?["stringValue"] as? String } == ["kept"])
    }

    @Test func anUnconfiguredReporterSendsNothingEvenWhenOn() async throws {
        let recorder = Recorder()
        let telemetry = Telemetry(transport: recorder)
        telemetry.isEnabled = true
        telemetry.log("nowhere")
        telemetry.report(type: "nowhere", sentence: "nowhere", during: "test")
        await telemetry.flush()
        #expect(recorder.requests.isEmpty)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct Logs {
    @Test func aBatchIsOtlpJsonWithTheResourceAndTheBearerToken() async throws {
        let recorder = Recorder()
        let telemetry = try configured(recorder)
        telemetry.log(
            "drain_finished", level: .warn,
            attributes: ["pending": 3, "ratio": 0.5, "complete": true, "outcome": "ok", "bad": Telemetry.LogAttribute(.nan)])
        await telemetry.flush()

        let request = try #require(recorder.requests.first)
        #expect(request.url.absoluteString == "https://eu.i.posthog.com/i/v1/logs")
        #expect(request.headers["Authorization"] == "Bearer phc_test")
        #expect(request.headers["Content-Type"] == "application/json")
        let resourceLogs = try #require(try object(request)["resourceLogs"] as? [[String: Any]])
        let resource = try #require(resourceLogs.first?["resource"] as? [String: Any])
        let attributes = try #require(resource["attributes"] as? [[String: Any]])
        let named = Dictionary(
            uniqueKeysWithValues: attributes.compactMap { item in
                (item["key"] as? String).map { ($0, (item["value"] as? [String: Any])?["stringValue"] as? String) }
            })
        #expect(named["service.name"] == "mapp")
        #expect(named["service.version"] == "1.2.3")
        #expect(named["service.instance.id"] == "instance-1")
        #expect(named["os.type"] == "darwin")
        #expect(named["os.version"] != nil)

        let record = try #require(try records(request).first)
        #expect(record["severityNumber"] as? Int == 13)
        #expect(record["severityText"] as? String == "WARN")
        #expect((record["body"] as? [String: Any])?["stringValue"] as? String == "drain_finished")
        #expect((record["timeUnixNano"] as? String).flatMap { UInt64($0) } != nil)
        let values = Dictionary(
            uniqueKeysWithValues: (record["attributes"] as? [[String: Any]] ?? []).compactMap { item in
                (item["key"] as? String).map { ($0, item["value"] as? [String: Any] ?? [:]) }
            })
        #expect(values["pending"]?["intValue"] as? String == "3")
        #expect(values["ratio"]?["doubleValue"] as? Double == 0.5)
        #expect(values["complete"]?["boolValue"] as? Bool == true)
        #expect(values["outcome"]?["stringValue"] as? String == "ok")
        #expect(values["bad"] == nil)
    }

    @Test func recordsGoOutAtFiftyAndOnFlushAndAfterTheInterval() async throws {
        let recorder = Recorder()
        let telemetry = try configured(recorder)
        for _ in 0..<49 { telemetry.log("a") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.requests.isEmpty)

        telemetry.log("a")
        try await eventually("the fiftieth record sends a batch") { recorder.requests.count == 1 }
        let first = try #require(recorder.requests.first)
        #expect(try records(first).count == 50)

        for _ in 0..<3 { telemetry.log("b") }
        await telemetry.flush()
        #expect(recorder.requests.count == 2)
        #expect(try records(recorder.requests[1]).count == 3)

        let quick = Recorder()
        let timed = try configured(quick, interval: .milliseconds(50))
        timed.log("c")
        try await eventually("the interval sends a batch") { quick.requests.count == 1 }
        await timed.flush()
        #expect(quick.requests.count == 1)
    }

    @Test func theQueueKeepsFiveHundredAndTheNextBatchCountsWhatItDropped() async throws {
        let recorder = Recorder(holdingFirst: true)
        let telemetry = try configured(recorder)
        for _ in 0..<50 { telemetry.log("first") }
        try await eventually("the first batch is held") { recorder.requests.count == 1 }

        for index in 0..<650 { telemetry.log("next", attributes: ["n": Telemetry.LogAttribute(index)]) }
        recorder.release()
        try await eventually("the queue goes out") { recorder.requests.count == 2 }

        let batch = try records(recorder.requests[1])
        #expect(batch.count == 500)
        func attribute(_ record: [String: Any], _ key: String) -> String? {
            let items = record["attributes"] as? [[String: Any]] ?? []
            return items.first { $0["key"] as? String == key }
                .flatMap { ($0["value"] as? [String: Any])?["intValue"] as? String }
        }
        #expect(attribute(batch[0], "n") == "150")
        #expect(attribute(batch[0], "telemetry.dropped_records") == "150")
        #expect(attribute(batch[1], "telemetry.dropped_records") == nil)
        await telemetry.flush()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct Destinations {
    @Test func onlyHttpsOrALoopbackIsAccepted() throws {
        #expect(try destination("https://eu.i.posthog.com").token == "phc_test")
        #expect(try destination("http://127.0.0.1:8123").errorsURL.absoluteString == "http://127.0.0.1:8123/i/v0/e/")
        #expect(try destination("http://localhost").logsURL.absoluteString == "http://localhost/i/v1/logs")
        #expect(
            try destination("https://proxy.example/ingest/?key=x#top").logsURL.absoluteString
                == "https://proxy.example/ingest/i/v1/logs")
        for host in [
            "http://eu.i.posthog.com", "http://10.0.0.5", "http://localhost.example", "ftp://eu.i.posthog.com",
            "https://user:pass@eu.i.posthog.com", "https://user@eu.i.posthog.com", "eu.i.posthog.com", "https://",
        ] {
            #expect(throws: Telemetry.ConfigurationError.hostNotAllowed, "\(host)") { _ = try destination(host) }
        }
        for token in ["", "phc_a b", "phc_a\n"] {
            #expect(throws: Telemetry.ConfigurationError.tokenNotAllowed, "\(token)") {
                _ = try Telemetry.Destination(host: URL(string: "https://eu.i.posthog.com")!, projectToken: token)
            }
        }
    }
}
