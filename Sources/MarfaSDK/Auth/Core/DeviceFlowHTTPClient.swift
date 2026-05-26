import Foundation

/// Minimal HTTP seam for ``DeviceFlow`` start + polling endpoints.
///
/// ``DeviceFlow`` operates against the OAuth issuer's `/auth/device` and
/// `/auth/device/token` endpoints — neither of which is shaped like the
/// rest of the Marfa typed-API surface. Bodies are form-encoded, responses
/// carry RFC 8628 OAuth error envelopes, and no bearer token is in play
/// (this is the flow that *gets* the token). ``DeviceFlow`` takes this
/// one-method seam instead of the heavier ``Transport`` protocol, and
/// `URLSession` conforms naturally so the default path is unchanged.
///
/// Tests inject a fake conformer to script responses and assert request
/// shape — see `FakeDeviceFlowHTTPClient` in `MarfaSDKTestSupport`.
public protocol DeviceFlowHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: DeviceFlowHTTPClient {}
