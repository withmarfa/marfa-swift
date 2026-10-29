import Foundation

/// The bytes of each kind of post.
///
/// Everything that reaches a body comes from a `StaticString`, a number, a boolean, the app's own configuration,
/// the machine's operating system and chip, a count of withheld reports, or a server refusal code that `FixedErrorText.isCode` accepts.
enum Wire {
    struct Context {
        let configuration: Telemetry.Configuration
        let distinctID: String
    }

    /// One `$exception` event, in the shape the `marfa` command line posts to PostHog's capture endpoint, without
    /// stack frames.
    static func exception(_ event: PendingException, _ context: Context) -> TelemetryRequest? {
        var properties: [String: Any] = [
            "$process_person_profile": false,
            "$geoip_disable": true,
            "$lib": context.configuration.serviceName,
            "$lib_version": context.configuration.serviceVersion,
            "$os": System.name,
            "$os_version": System.version,
            "arch": System.architecture,
            "service.name": context.configuration.serviceName,
            "service.version": context.configuration.serviceVersion,
            "$exception_list": [
                [
                    "type": event.type,
                    "value": event.sentence,
                    "mechanism": ["handled": true, "synthetic": false] as [String: Any],
                ] as [String: Any]
            ],
            "$exception_level": "error",
            "operation": event.operation,
            "dropped_since_last": event.dropped,
        ]
        if let code = event.code { properties["error_code"] = code }
        let body: [String: Any] = [
            "api_key": context.configuration.destination.token,
            "event": "$exception",
            "distinct_id": context.distinctID,
            "properties": properties,
        ]
        guard let data = encode(body) else { return nil }
        return TelemetryRequest(
            url: context.configuration.destination.errorsURL, headers: ["Content-Type": "application/json"], body: data)
    }

    /// A batch of log records as OTLP/HTTP JSON.
    static func logs(_ records: [PendingLog], dropped: Int, _ context: Context) -> TelemetryRequest? {
        let resource = [
            attribute("service.name", .word(context.configuration.serviceName)),
            attribute("service.version", .word(context.configuration.serviceVersion)),
            attribute("os.type", .word("darwin")),
            attribute("os.name", .word(System.name)),
            attribute("os.version", .word(System.version)),
            attribute("host.arch", .word(System.architecture)),
        ]
        let rendered: [[String: Any]] = records.enumerated().map { index, record in
            var attributes = record.attributes.compactMap { attribute($0.name, $0.value) }
            if index == 0, dropped > 0, let count = attribute("telemetry.dropped_records", .int(dropped)) {
                attributes.append(count)
            }
            let nanos = String(record.nanoseconds)
            return [
                "timeUnixNano": nanos,
                "observedTimeUnixNano": nanos,
                "severityNumber": record.level.number,
                "severityText": record.level.text,
                "body": ["stringValue": record.name],
                "attributes": attributes,
            ]
        }
        let body: [String: Any] = [
            "resourceLogs": [
                [
                    "resource": ["attributes": resource.compactMap { $0 }],
                    "scopeLogs": [["scope": ["name": "MarfaTelemetry"], "logRecords": rendered]],
                ]
            ]
        ]
        guard let data = encode(body) else { return nil }
        return TelemetryRequest(
            url: context.configuration.destination.logsURL,
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(context.configuration.destination.token)",
            ],
            body: data)
    }

    private static func attribute(_ key: String, _ value: Telemetry.LogAttribute.Value) -> [String: Any]? {
        switch value {
        case .int(let number): ["key": key, "value": ["intValue": String(number)]]
        case .double(let number): number.isFinite ? ["key": key, "value": ["doubleValue": number]] : nil
        case .bool(let flag): ["key": key, "value": ["boolValue": flag]]
        case .word(let word): ["key": key, "value": ["stringValue": word]]
        }
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    enum System {
        static let name: String = {
            #if os(macOS)
            "macOS"
            #else
            "iOS"
            #endif
        }()

        static let version: String = {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }()

        static let architecture: String = {
            #if arch(arm64)
            "arm64"
            #elseif arch(x86_64)
            "x86_64"
            #else
            "unknown"
            #endif
        }()
    }
}
