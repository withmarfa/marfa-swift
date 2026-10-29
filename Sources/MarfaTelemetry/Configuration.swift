import Foundation

extension Telemetry {
    /// Why a ``Destination`` was refused.
    public enum ConfigurationError: Error, Sendable, Hashable {
        /// The host is not an `https` address, or an `http` address on this machine, or it carries a user name or
        /// password. The project token travels in what is sent, so it never goes in the clear or to a login.
        case hostNotAllowed
        /// The project token is empty or holds white space.
        case tokenNotAllowed
    }

    /// Where reports go: a PostHog host and the project token that names the project.
    ///
    /// The package carries no destination of its own. The app that is built to report supplies one, and an app
    /// built without one never calls ``Telemetry/configure(_:)``, so it sends nothing.
    public struct Destination: Sendable {
        let errorsURL: URL
        let logsURL: URL
        let token: String

        /// - Parameters:
        ///   - host: An `https` address such as `https://eu.i.posthog.com`, or an `http` address on this machine
        ///     for a test. A path on the host is kept, so a proxy under a path works.
        ///   - projectToken: The PostHog project token, which starts `phc_`. A personal API key is not one.
        public init(host: URL, projectToken: String) throws(ConfigurationError) {
            guard var parts = URLComponents(url: host, resolvingAgainstBaseURL: false),
                let name = parts.host?.lowercased(), !name.isEmpty,
                parts.user == nil, parts.password == nil
            else { throw .hostNotAllowed }
            switch parts.scheme?.lowercased() {
            case "https": break
            case "http" where ["localhost", "127.0.0.1", "::1", "[::1]"].contains(name): break
            default: throw .hostNotAllowed
            }
            guard !projectToken.isEmpty, !projectToken.contains(where: \.isWhitespace) else {
                throw .tokenNotAllowed
            }
            parts.query = nil
            parts.fragment = nil
            let base = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
            parts.path = base + "/i/v0/e/"
            guard let errorsURL = parts.url else { throw .hostNotAllowed }
            parts.path = base + "/i/v1/logs"
            guard let logsURL = parts.url else { throw .hostNotAllowed }
            self.errorsURL = errorsURL
            self.logsURL = logsURL
            self.token = projectToken
        }
    }

    /// Who is reporting, and where to.
    public struct Configuration: Sendable {
        let destination: Destination
        let serviceName: String
        let serviceVersion: String
        let instanceID: (@Sendable () -> String?)?

        /// - Parameters:
        ///   - destination: Where to send.
        ///   - serviceName: The app's name, such as `mapp`. It is fixed in the source, so no value read at run time
        ///     can become it.
        ///   - serviceVersion: The app's build version.
        ///   - instanceID: Answers the connected instance's `instance_id`, which the server's root description
        ///     gives and the contract treats as non-personal, or `nil` while no instance is connected. It is read
        ///     on a background task whenever something is sent, never on the caller's. Answer nothing else: an
        ///     address, a name or a key does not belong here.
        public init(
            destination: Destination, serviceName: StaticString, serviceVersion: String,
            instanceID: (@Sendable () -> String?)? = nil
        ) {
            self.destination = destination
            self.serviceName = "\(serviceName)"
            self.serviceVersion = serviceVersion
            self.instanceID = instanceID
        }
    }
}
