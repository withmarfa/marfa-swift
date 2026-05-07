import Foundation
import Observation

/// `@Observable` view onto the calling user's ``Profile``, suitable for
/// SwiftUI consumers.
///
/// The store mirrors what's on the server — there's no SwiftData
/// persistence layer for `system.profile` (it's a virtual type joined
/// from the `users` table at request time). On every successful mutation
/// the namespace updates the in-memory ``profile`` so observing views
/// re-render without a separate refresh round-trip.
///
/// ## Lifecycle
///
/// `system.profile` is a virtual type, so server-side `item.*` SSE
/// events do not fire for it. Refresh is on-demand: call
/// ``refresh()`` on app launch or when re-entering a profile screen.
/// All mutations route through ``ProfileStore`` (not ``ProfileNamespace``
/// directly) when you want the observed state to stay in sync.
///
/// ## Usage
///
/// ```swift
/// let store = client.profileStore!
/// await store.refresh()
///
/// // SwiftUI:
/// struct ProfileView: View {
///     @State var store: ProfileStore
///     var body: some View {
///         if let profile = store.profile {
///             Text(profile.username ?? "")
///         }
///     }
/// }
/// ```
@Observable
@MainActor
public final class ProfileStore {

    /// The current profile. `nil` until ``refresh()`` succeeds.
    public private(set) var profile: Profile?

    /// `true` while a network call is in flight.
    public private(set) var isLoading: Bool = false

    /// The last error from ``refresh()`` or any mutation. Cleared on the
    /// next successful call.
    public private(set) var error: Error?

    private let namespace: ProfileNamespace

    public init(namespace: ProfileNamespace) {
        self.namespace = namespace
    }

    /// Fetches the current profile from the server. Sets ``isLoading``
    /// for the duration of the call and writes ``profile`` on success
    /// or ``error`` on failure. Does not throw — observe the published
    /// state instead.
    public func refresh() async {
        isLoading = true
        error = nil
        do {
            profile = try await namespace.get()
        } catch {
            self.error = error
        }
        isLoading = false
    }

    /// Updates the user's profile and writes the returned ``Profile``
    /// into the store. Throws the underlying ``MymeError`` so callers
    /// can surface validation errors to the user.
    @discardableResult
    public func update(_ input: UpdateProfileInput) async throws -> Profile {
        let updated = try await namespace.update(input)
        profile = updated
        return updated
    }

    /// Uploads an avatar image and writes the returned ``Profile`` into
    /// the store.
    @discardableResult
    public func uploadAvatar(_ data: Data, mimeType: String) async throws -> Profile {
        let updated = try await namespace.uploadAvatar(data, mimeType: mimeType)
        profile = updated
        return updated
    }

    /// Deletes the avatar (reverts to the deterministic placeholder)
    /// and writes the returned ``Profile`` into the store.
    @discardableResult
    public func deleteAvatar() async throws -> Profile {
        let updated = try await namespace.deleteAvatar()
        profile = updated
        return updated
    }
}
