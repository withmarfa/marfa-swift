import Foundation

/// An `AsyncSequence` that iterates through all pages of a paginated API response.
///
/// Lazily fetches subsequent pages as the consumer iterates. Use this for
/// automatic pagination over large result sets:
///
///     for try await item in client.items.all(filters: .init(type: "core.note")) {
///         print(item.id)
///     }
public struct PaginatedSequence<T: Codable & Sendable>: AsyncSequence, Sendable {
    public typealias Element = T

    let fetchPage: @Sendable (String?) async throws -> PaginatedResult<T>

    public func makeAsyncIterator() -> Iterator {
        Iterator(fetchPage: fetchPage)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let fetchPage: @Sendable (String?) async throws -> PaginatedResult<T>
        var cursor: String? = nil
        var buffer: [T] = []
        var bufferIndex = 0
        var finished = false

        public mutating func next() async throws -> T? {
            // Return buffered items first
            if bufferIndex < buffer.count {
                let item = buffer[bufferIndex]
                bufferIndex += 1
                return item
            }

            // No more pages
            if finished { return nil }

            // Fetch next page
            let page = try await fetchPage(cursor)
            buffer = page.data
            bufferIndex = 0
            cursor = page.cursor

            if !page.hasMore || page.cursor == nil {
                finished = true
            }

            if bufferIndex < buffer.count {
                let item = buffer[bufferIndex]
                bufferIndex += 1
                return item
            }

            return nil
        }
    }
}
