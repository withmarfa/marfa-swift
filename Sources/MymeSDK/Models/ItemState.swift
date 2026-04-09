/// The lifecycle state of a Myme item.
public enum ItemState: String, Codable, Sendable, CaseIterable {
    case new
    case active
    case archived
    case trashed
}
