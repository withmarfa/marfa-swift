import Foundation
import Marfa
import MarfaTypes

/// Moving every item of one type to another, a job on the server.
///
/// A type's identifier never changes, so renaming a type is registering the new one, moving the items and deleting
/// the old one. Start a move with ``startMove(ofType:to:properties:)``, follow it with ``follow(moveJob:every:)`` and
/// read its `result`: `remaining` and `remainingHidden` say whether an item of the type is left, and
/// `settingsRewritten` says whether the folders, views and webhooks that name the type now name the new one.
extension Client {
    /// What a move would do, writing nothing: the items it would move and the settings that name the type.
    ///
    /// Throws what ``startMove(ofType:to:properties:)`` throws, apart from the refusals that come from running it.
    public func previewMove(ofType id: String, to target: String, properties: JSONObject? = nil) async throws
        -> Components.Schemas.TypeMoveDryRun
    {
        let body = try moveBody(to: target, properties: properties, dryRun: true)
        return try await answer("moveType") { try await moveType(path: .init(id: id), body: .json(body)).ok.body.json }
    }

    /// Starts moving every item of `id`, in any state the credential can see, to `target`, and answers the job.
    ///
    /// `properties` merge into each item as it moves, as a change to the item merges them, such as a field `target`
    /// requires; a `null` value removes a property. The job runs on the server whatever happens to this call.
    /// Throws `MarfaError.server` with the code `type_move_blocked` and the settings in its message when a setting
    /// names the type in a way a move cannot rewrite, and moves nothing.
    public func startMove(ofType id: String, to target: String, properties: JSONObject? = nil) async throws
        -> Components.Schemas.BulkActionJob
    {
        let body = try moveBody(to: target, properties: properties, dryRun: false)
        return try await answer("moveType") {
            try await moveType(path: .init(id: id), body: .json(body)).accepted.body.json
        }
    }

    /// Waits for the move job `id` to end, polling every `interval`, and answers the job with its `result`.
    ///
    /// A job ends as `completed`, `failed` or `canceled`. Cancelling the task that waits stops the wait and not the
    /// job; use ``cancel(moveJob:)`` for that.
    public func follow(moveJob id: String, every interval: Duration = .milliseconds(250)) async throws
        -> Components.Schemas.BulkActionJob
    {
        while true {
            let job = try await answer("getBulkActionJob") {
                try await getBulkActionJob(path: .init(id: id)).ok.body.json
            }
            switch job.status {
            case .queued, .inProgress: break
            case .completed, .failed, .canceled: return job
            }
            do {
                try await Task.sleep(for: interval)
            } catch {
                throw MarfaError.canceled(message: "waiting for the move job \(id) was canceled; the job was not")
            }
        }
    }

    /// Asks the server to stop the move job `id`, and answers the job as it stands.
    ///
    /// Items already moved stay moved and no setting is rewritten, so run the move again to finish it.
    public func cancel(moveJob id: String) async throws -> Components.Schemas.BulkActionJob {
        try await answer("cancelBulkActionJob") { try await cancelBulkActionJob(path: .init(id: id)).ok.body.json }
    }

    private func moveBody(to target: String, properties: JSONObject?, dryRun: Bool) throws
        -> Operations.MoveType.Input.Body.JsonPayload
    {
        let merged = try properties.map {
            try JSONDecoder().decode(
                Operations.MoveType.Input.Body.JsonPayload.PropertiesPayload.self,
                from: JSONEncoder().encode($0))
        }
        return .init(to: target, properties: merged, dryRun: dryRun)
    }
}
