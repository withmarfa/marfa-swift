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

struct Configuration: Sendable {
    var store: URL
    var server: Server?
    var scenario: String?

    private static func environmentServer() -> Server? {
        do {
            return try Server.fromEnvironment()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return nil
        }
    }

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
            server: named ?? environmentServer(),
            scenario: value("--scenario"))
    }
}
