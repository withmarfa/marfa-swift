extension Telemetry {
    /// How serious a log record is.
    ///
    /// OTLP names the severity by number and text.
    public enum LogLevel: Sendable, Hashable {
        case debug, info, warn, error

        var number: Int {
            switch self {
            case .debug: 5
            case .info: 9
            case .warn: 13
            case .error: 17
            }
        }

        var text: String {
            switch self {
            case .debug: "DEBUG"
            case .info: "INFO"
            case .warn: "WARN"
            case .error: "ERROR"
            }
        }
    }

    /// A value a log record may carry: a number, a boolean, or text written in the source.
    ///
    /// There is no case for a `String` read at run time, so a note's words, a title, an id, a path or an
    /// error's message cannot be passed by accident. A literal converts by itself:
    /// `["pending": 3, "complete": true, "outcome": "ok"]`. Pass a count, a duration or a fixed word, and nothing
    /// that came from a person, a file or a server.
    public struct LogAttribute: Sendable, Hashable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
        ExpressibleByBooleanLiteral, ExpressibleByStringLiteral
    {
        enum Value: Sendable, Hashable {
            case int(Int)
            case double(Double)
            case bool(Bool)
            case word(String)
        }

        let value: Value

        public init(integerLiteral value: Int) { self.value = .int(value) }
        public init(floatLiteral value: Double) { self.value = .double(value) }
        public init(booleanLiteral value: Bool) { self.value = .bool(value) }
        public init(stringLiteral value: StaticString) { self.value = .word("\(value)") }

        /// A number computed at run time, such as a count.
        public init(_ value: Int) { self.value = .int(value) }
        /// A number computed at run time, such as a duration in seconds.
        ///
        /// A value that is not finite is not sent.
        public init(_ value: Double) { self.value = .double(value) }
        /// A flag computed at run time.
        public init(_ value: Bool) { self.value = .bool(value) }
    }
}
