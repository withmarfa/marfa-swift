/// Decides which exceptions are sent, so a failure that repeats in a loop reports a few times and not thousands.
///
/// At most one exception for each `type` and `operation` in 60 seconds, and at most 30 in an hour in all. An
/// exception that is withheld does not restart either wait, and the next one sent carries how many were withheld
/// before it.
struct ExceptionLimiter {
    static let repeatInterval: Duration = .seconds(60)
    static let hourlyLimit = 30
    static let hour: Duration = .seconds(3600)

    private struct Key: Hashable {
        let type: String
        let operation: String
    }

    private var lastSent: [Key: ContinuousClock.Instant] = [:]
    private var sentInTheHour: [ContinuousClock.Instant] = []
    private var withheld = 0

    /// The count of exceptions withheld since the previous one sent when this one may be sent, and `nil` when it
    /// is withheld.
    mutating func admit(type: String, operation: String, at now: ContinuousClock.Instant) -> Int? {
        lastSent = lastSent.filter { now - $0.value < Self.repeatInterval }
        sentInTheHour.removeAll { now - $0 >= Self.hour }
        let key = Key(type: type, operation: operation)
        guard lastSent[key] == nil, sentInTheHour.count < Self.hourlyLimit else {
            withheld += 1
            return nil
        }
        lastSent[key] = now
        sentInTheHour.append(now)
        defer { withheld = 0 }
        return withheld
    }

    /// Counts an exception that was never queued for another reason.
    mutating func withhold() { withheld += 1 }

    /// Forgets the count, not the waits, since a count belongs to the reports that were dropped with the queue.
    mutating func forgetWithheld() { withheld = 0 }
}
