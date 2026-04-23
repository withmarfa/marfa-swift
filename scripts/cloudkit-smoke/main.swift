// CloudKit readiness smoke test for the v1 SwiftData schema.
//
// Builds a `ModelContainer` against a developer's CloudKit container.
// SwiftData validates the schema against CloudKit constraints at init
// time — `#Unique`, missing inverses, `.deny` rules, missing defaults,
// `description` collisions all surface here.
//
// The smoke test does NOT insert rows. Inserting requires the model
// types to be public (they're internal — only `MymeModelContainer` is
// SPI-exposed). Schema validation catches the bulk of CloudKit
// incompatibilities; for end-to-end "actually save under CloudKit
// mirroring" coverage, run the consumer app's Phase-2 integration
// tests against the same container.
//
// Not in CI — GitHub runners don't carry CloudKit entitlements. Run
// manually before tagging a release. See
// `Sources/MymeSDK/LocalStore/README.md` for the full procedure.
//
// Container ID is read from `MYME_CK_CONTAINER` — never hard-coded.

import Foundation
import SwiftData
@_spi(MymeSDKTestSupport) import MymeSDK

@main
struct CloudKitSmoke {
    static func main() {
        guard let containerID = ProcessInfo.processInfo.environment["MYME_CK_CONTAINER"],
              !containerID.isEmpty else {
            FileHandle.standardError.write(Data(
                "set MYME_CK_CONTAINER to a dev CloudKit container id (e.g. 'iCloud.com.example.myme')\n".utf8
            ))
            exit(1)
        }

        do {
            let url = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("cloudkit-smoke-\(UUID().uuidString).sqlite")

            let cfg = ModelConfiguration(
                "myme",
                schema: Schema(MymeSchemaV1.models),
                url: url,
                cloudKitDatabase: .private(containerID)
            )
            _ = try ModelContainer(
                for: Schema(MymeSchemaV1.models),
                migrationPlan: MymeMigrationPlan.self,
                configurations: cfg
            )

            print("OK — schema validated against CloudKit container \(containerID)")
            // Don't unlink the temp file; the container may still be
            // flushing on background queues. The OS evicts it.
            exit(0)
        } catch {
            FileHandle.standardError.write(Data(
                "ModelContainer init failed: \(error)\n".utf8
            ))
            exit(1)
        }
    }
}
