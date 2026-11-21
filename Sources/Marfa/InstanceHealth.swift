import Foundation

/// How an instance, one of its components or its housekeeping is doing, as the server names it.
public enum HealthStatus: Sendable, Hashable {
    /// Serving normally.
    case ok
    /// Serving, but something is slow, low or unknown.
    case degraded
    /// Something refused.
    case down
    /// A status this build does not know, as the server names it.
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "ok": self = .ok
        case "degraded": self = .degraded
        case "down": self = .down
        default: self = .other(rawValue)
        }
    }

    /// The status as the server names it.
    public var rawValue: String {
        switch self {
        case .ok: "ok"
        case .degraded: "degraded"
        case .down: "down"
        case .other(let name): name
        }
    }
}

/// What the server's `GET /health` answers: whether the instance is serving and how each part it depends on is.
///
/// A caller holding no credential, a credential without `instance.read` or a token the server no longer accepts
/// gets the status, each component's status and latency and the backup status. A credential holding `instance.read` also gets each failing
/// component's `error`, the rest of ``InstanceHealth/Backups`` and ``InstanceHealth/housekeeping``, which stay
/// `nil` otherwise.
public struct InstanceHealth: Sendable, Hashable {
    /// One part the instance depends on.
    public struct Component: Sendable, Hashable {
        public let status: HealthStatus
        /// How long the check took, in milliseconds.
        public let latencyMs: Int?
        /// What went wrong, for a credential holding `instance.read`.
        public let error: String?

        public init(status: HealthStatus, latencyMs: Int? = nil, error: String? = nil) {
            self.status = status
            self.latencyMs = latencyMs
            self.error = error
        }
    }

    /// Each part the server checks.
    public struct Components: Sendable, Hashable {
        /// Whether the database answers a read.
        public let database: Component
        /// Whether the database commits a write.
        public let databaseWrite: Component
        /// Whether the disk has room to write.
        public let disk: Component
        /// Whether the blob store on disk answers.
        public let blobStorage: Component

        public init(database: Component, databaseWrite: Component, disk: Component, blobStorage: Component) {
            self.database = database
            self.databaseWrite = databaseWrite
            self.disk = disk
            self.blobStorage = blobStorage
        }
    }

    /// Whether and how the instance backs itself up.
    public struct Backups: Sendable, Hashable {
        public enum Status: Sendable, Hashable {
            /// On schedule, with the last backup whole.
            case ok
            /// Files the last backup names have no recorded copy.
            case incomplete
            /// A run failed or lost files, a store refuses copies, or a part is damaged.
            case failing
            /// None is scheduled.
            case off
            /// A status this build does not know, as the server names it.
            case other(String)

            public init(rawValue: String) {
                switch rawValue {
                case "ok": self = .ok
                case "incomplete": self = .incomplete
                case "failing": self = .failing
                case "off": self = .off
                default: self = .other(rawValue)
                }
            }
        }

        public enum Reason: Sendable, Hashable {
            /// No destination is set.
            case noBackupDestination
            /// `backup_interval_seconds` is 0.
            case turnedOff
            /// The destination set cannot be used.
            case destinationUnusable
            /// A reason this build does not know, as the server names it.
            case other(String)

            public init(rawValue: String) {
                switch rawValue {
                case "no_backup_destination": self = .noBackupDestination
                case "turned_off": self = .turnedOff
                case "destination_unusable": self = .destinationUnusable
                default: self = .other(rawValue)
                }
            }
        }

        public enum Destination: Sendable, Hashable {
            /// The backup folder `backup_path` names.
            case folder
            /// The object store `object_store_bucket` names.
            case bucket
            /// A destination this build does not know, as the server names it.
            case other(String)

            public init(rawValue: String) {
                switch rawValue {
                case "folder": self = .folder
                case "bucket": self = .bucket
                default: self = .other(rawValue)
                }
            }
        }

        public let status: Status
        /// Why backups are off or failing.
        public let reason: Reason?
        /// Where backups go, for `instance.read` and a destination in the settings.
        public let destination: Destination?
        /// The name of the last backup put, for `instance.read`.
        public let lastBackup: String?
        /// When the last backup was put, for `instance.read`, or `nil` when the time is unreadable.
        public let lastBackupAt: Date?
        /// How many runs in a row failed or lost files, for `instance.read`.
        public let failures: Int?
        /// What went wrong in the last failed run, for `instance.read`.
        public let lastError: String?
        /// When the last failed run ended, for `instance.read`, or `nil` when the time is unreadable.
        public let lastFailedAt: Date?
        /// How many files waited for their copy when replication last ran, for `instance.read` and a destination.
        public let copiesWaiting: Int?
        /// How many files the last backup names with no recorded copy, for `instance.read` and a destination.
        public let lastBackupFilesWaiting: Int?
        /// Why the destination is not taking copies, for `instance.read`.
        public let storeError: String?
        /// How many parts a check found altered or unreadable, for `instance.read` and a destination.
        public let damagedParts: Int?

        public init(
            status: Status, reason: Reason? = nil, destination: Destination? = nil, lastBackup: String? = nil,
            lastBackupAt: Date? = nil, failures: Int? = nil, lastError: String? = nil, lastFailedAt: Date? = nil,
            copiesWaiting: Int? = nil, lastBackupFilesWaiting: Int? = nil, storeError: String? = nil,
            damagedParts: Int? = nil
        ) {
            self.status = status
            self.reason = reason
            self.destination = destination
            self.lastBackup = lastBackup
            self.lastBackupAt = lastBackupAt
            self.failures = failures
            self.lastError = lastError
            self.lastFailedAt = lastFailedAt
            self.copiesWaiting = copiesWaiting
            self.lastBackupFilesWaiting = lastBackupFilesWaiting
            self.storeError = storeError
            self.damagedParts = damagedParts
        }
    }

    /// What needs attention in the background work.
    public struct Housekeeping: Sendable, Hashable {
        /// A job whose last run failed.
        public struct FailedJob: Sendable, Hashable {
            public let name: String
            /// When the run finished, or `nil` when the server gave no time this build can read.
            public let at: Date?
            public let error: String?

            public init(name: String, at: Date?, error: String?) {
                self.name = name
                self.at = at
                self.error = error
            }
        }

        /// Why the jobs that delete old records do nothing.
        public struct Hold: Sendable, Hashable {
            public enum Reason: Sendable, Hashable {
                /// The server's clock is more than 7 days later than the trusted time.
                case clockAhead
                /// A reason this build does not know, as the server names it.
                case other(String)

                public init(rawValue: String) {
                    switch rawValue {
                    case "clock_ahead": self = .clockAhead
                    default: self = .other(rawValue)
                    }
                }
            }

            public let reason: Reason
            /// What the server's clock reads, or `nil` when the server gave no time this build can read.
            public let clockAt: Date?
            /// The trusted time, or `nil` when the server gave no time this build can read.
            public let trustedAt: Date?
            /// When the hold ends if the clock runs without jumping until then, or `nil` when the server gave no
            /// time this build can read.
            public let endsAt: Date?

            public init(reason: Reason, clockAt: Date?, trustedAt: Date?, endsAt: Date?) {
                self.reason = reason
                self.clockAt = clockAt
                self.trustedAt = trustedAt
                self.endsAt = endsAt
            }
        }

        /// Every job whose last run failed, or `nil` when the schedule could not be read in time.
        public let failed: [FailedJob]?
        /// The keys of stored settings that no longer read, which the instance runs on their defaults.
        public let unreadableSettings: [String]
        /// Why deleting jobs are held, or `nil` when they run.
        public let held: Hold?

        public init(failed: [FailedJob]?, unreadableSettings: [String], held: Hold?) {
            self.failed = failed
            self.unreadableSettings = unreadableSettings
            self.held = held
        }
    }

    /// Where the server runs, where its settings name it.
    public struct Placement: Sendable, Hashable {
        public let region: String?
        public let location: String?
        public let country: String?

        public init(region: String? = nil, location: String? = nil, country: String? = nil) {
            self.region = region
            self.location = location
            self.country = country
        }
    }

    public let status: HealthStatus
    /// Whether the instance has an owner, or `nil` when it could not read its database to tell.
    public let claimed: Bool?
    public let components: Components
    public let placement: Placement?
    /// The build the instance runs, when it is known.
    public let version: String?
    public let backups: Backups
    /// What needs attention in the background work, for `instance.read`.
    public let housekeeping: Housekeeping?

    public init(
        status: HealthStatus, claimed: Bool?, components: Components, placement: Placement? = nil,
        version: String? = nil, backups: Backups, housekeeping: Housekeeping? = nil
    ) {
        self.status = status
        self.claimed = claimed
        self.components = components
        self.placement = placement
        self.version = version
        self.backups = backups
        self.housekeeping = housekeeping
    }
}

extension Server {
    /// Reads the instance's health.
    ///
    /// The server answers this without a credential, so a server made with an empty key can call it before an app
    /// is signed in or granted anything: an empty key sends no `Authorization` header. A server whose sign-in has
    /// ended sends none either, and reads the open fields rather than throwing
    /// ``MarfaError/signedOut(origin:message:)``.
    ///
    /// With a key or sign-in that holds `instance.read`, the answer also carries the components' errors, the
    /// backups' detail and ``InstanceHealth/housekeeping``. The server treats a token it no longer accepts, such as
    /// an expired access token, like no token: it answers `200` with only the open fields and no refusal, and this
    /// never renews the token. A caller that needs the detail reads it after an authenticated call, which renews
    /// the sign-in.
    ///
    /// An instance that is down answers `503` with the same body, and this returns it with ``InstanceHealth/status``
    /// `.down`, so a down component can be shown. An unreachable server, any other refusal or a body that is not
    /// a health report throws a ``MarfaError``.
    public func health(timeout: Duration = Server.defaultTimeout) async throws(MarfaError) -> InstanceHealth {
        let data = try await send(
            "GET", "/health", timeout: timeout, openWhenSignedOut: true,
            accepting: { status, body in
                status == 503 && (try? JSONDecoder().decode(HealthWire.self, from: body)) != nil
            })
        let wire: HealthWire = try decode(data)
        return InstanceHealth(wire)
    }
}

private struct HealthWire: Decodable {
    struct Component: Decodable {
        let status: String
        let latencyMs: Int?
        let error: String?
        enum CodingKeys: String, CodingKey {
            case status, error
            case latencyMs = "latency_ms"
        }
    }

    struct Components: Decodable {
        let database: Component
        let databaseWrite: Component
        let disk: Component
        let blobStorage: Component
        enum CodingKeys: String, CodingKey {
            case database, disk
            case databaseWrite = "database_write"
            case blobStorage = "blob_storage"
        }
    }

    struct Backups: Decodable {
        let status: String
        let reason: String?
        let destination: String?
        let lastBackup: String?
        let lastBackupAt: String?
        let failures: Int?
        let lastError: String?
        let lastFailedAt: String?
        let copiesWaiting: Int?
        let lastBackupFilesWaiting: Int?
        let storeError: String?
        let damagedParts: Int?
        enum CodingKeys: String, CodingKey {
            case status, reason, destination, failures
            case lastBackup = "last_backup"
            case lastBackupAt = "last_backup_at"
            case lastError = "last_error"
            case lastFailedAt = "last_failed_at"
            case copiesWaiting = "copies_waiting"
            case lastBackupFilesWaiting = "last_backup_files_waiting"
            case storeError = "store_error"
            case damagedParts = "damaged_parts"
        }
    }

    struct Housekeeping: Decodable {
        struct Failed: Decodable {
            let name: String
            let at: String?
            let error: String?
        }
        struct Held: Decodable {
            let reason: String
            let clockAt: String
            let trustedAt: String
            let endsAt: String
            enum CodingKeys: String, CodingKey {
                case reason
                case clockAt = "clock_at"
                case trustedAt = "trusted_at"
                case endsAt = "ends_at"
            }
        }
        let failed: [Failed]?
        let unreadableSettings: [String]
        let held: Held?
        enum CodingKeys: String, CodingKey {
            case failed, held
            case unreadableSettings = "unreadable_settings"
        }
    }

    struct Placement: Decodable {
        let region: String?
        let location: String?
        let country: String?
    }

    let status: String
    let claimed: Bool?
    let components: Components
    let placement: Placement?
    let version: String?
    let backups: Backups
    let housekeeping: Housekeeping?
}

extension InstanceHealth {
    fileprivate init(_ wire: HealthWire) {
        func time(_ text: String?) -> Date? { text.flatMap { ItemDate.parse($0)?.date } }
        func component(_ wire: HealthWire.Component) -> Component {
            Component(status: HealthStatus(rawValue: wire.status), latencyMs: wire.latencyMs, error: wire.error)
        }
        let backups = wire.backups
        self.init(
            status: HealthStatus(rawValue: wire.status), claimed: wire.claimed,
            components: Components(
                database: component(wire.components.database),
                databaseWrite: component(wire.components.databaseWrite), disk: component(wire.components.disk),
                blobStorage: component(wire.components.blobStorage)),
            placement: wire.placement.map { Placement(region: $0.region, location: $0.location, country: $0.country) },
            version: wire.version,
            backups: Backups(
                status: .init(rawValue: backups.status), reason: backups.reason.map(Backups.Reason.init(rawValue:)),
                destination: backups.destination.map(Backups.Destination.init(rawValue:)),
                lastBackup: backups.lastBackup, lastBackupAt: time(backups.lastBackupAt), failures: backups.failures,
                lastError: backups.lastError, lastFailedAt: time(backups.lastFailedAt),
                copiesWaiting: backups.copiesWaiting, lastBackupFilesWaiting: backups.lastBackupFilesWaiting,
                storeError: backups.storeError, damagedParts: backups.damagedParts),
            housekeeping: wire.housekeeping.map { housekeeping in
                Housekeeping(
                    failed: housekeeping.failed?.map { .init(name: $0.name, at: time($0.at), error: $0.error) },
                    unreadableSettings: housekeeping.unreadableSettings,
                    held: housekeeping.held.map {
                        .init(
                            reason: .init(rawValue: $0.reason), clockAt: time($0.clockAt),
                            trustedAt: time($0.trustedAt), endsAt: time($0.endsAt))
                    })
            })
    }
}
