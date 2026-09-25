import Marfa
import SwiftUI

@main
struct SampleApp: App {
    @State private var model = Model(configuration: Configuration.fromLaunch())

    init() {
        if let phase = Configuration.fromLaunch().scenario {
            Task.detached {
                let passed = await Scenario.run(phase, configuration: Configuration.fromLaunch())
                exit(passed ? 0 : 1)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            NotesView(model: model)
                .task {
                    await model.open()
                    await model.listen()
                }
        }
    }
}

/// Where the sample's store is, the server it talks to, and whether it runs
/// a scenario rather than waiting for a person.
///
/// The server comes from `--server URL --key KEY` or `MARFA_API_URL` and
/// `MARFA_API_KEY`; without one the sample works offline and queues.
struct Configuration: Sendable {
    var store: URL
    var server: Server?
    var scenario: String?

    static func fromLaunch() -> Configuration {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let named = value("--server").flatMap(URL.init(string:)).flatMap { url in
            value("--key").map { Server(url: url, key: $0) }
        }
        let folder = URL.applicationSupportDirectory.appending(path: "MarfaSample")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Configuration(
            store: value("--store").map { URL(fileURLWithPath: $0) } ?? folder.appending(path: "notes.sqlite"),
            server: named ?? (try? Server.fromEnvironment()),
            scenario: value("--scenario"))
    }
}
