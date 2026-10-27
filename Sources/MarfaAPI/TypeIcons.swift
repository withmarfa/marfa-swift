import Marfa
import MarfaTypes

/// The icon the owner chooses for a type, kept on the server.
///
/// A read of the type, here or through a working copy's catalog, answers the owner's icon in place of the author's,
/// and a subtype that sets none inherits it. Both calls need `schema.write` and write on the type.
///
/// The answer is the type as the server now reads it, so an app can draw the new icon at once. A working copy's
/// `catalog` takes the change when its server stream next reopens, so another device shows it within about two
/// minutes.
extension Client {
    /// Sets the owner's icon for the item type `id`, one Marfa ships included, and answers the type as the server
    /// reads it now.
    ///
    /// `icon` is the kebab-case name of an icon in the Lucide release Marfa pins, such as `book-open`. The server
    /// refuses any other name with `MarfaError.validation` and the code `invalid_schema`.
    public func set(icon: String, forType id: String) async throws -> Components.Schemas.RegisteredType {
        try await answer("setTypeIcon") {
            try await setTypeIcon(path: .init(id: id), body: .json(.init(icon: icon))).ok.body.json._type
        }
    }

    /// Removes the owner's icon for the item type `id`, so the author's shows again.
    ///
    /// Answers the type as the server reads it now. Clearing a type with no owner icon succeeds and changes
    /// nothing.
    public func clearIcon(ofType id: String) async throws -> Components.Schemas.RegisteredType {
        try await answer("clearTypeIcon") { try await clearTypeIcon(path: .init(id: id)).ok.body.json._type }
    }
}
