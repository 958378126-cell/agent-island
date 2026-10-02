import Foundation

/// All mutable Agent Island data lives outside the source checkout.
/// The repository only contains fixtures and examples; a real install uses
/// Application Support unless an explicit environment override is supplied.
enum RuntimePaths {
    static let applicationName = "AgentIsland"

    static var applicationSupportDirectory: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = base.appendingPathComponent(applicationName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var tasksURL: URL { applicationSupportDirectory.appendingPathComponent("tasks.jsonl") }
    static var connectorsURL: URL { applicationSupportDirectory.appendingPathComponent("agents.json") }
    static var positionURL: URL { applicationSupportDirectory.appendingPathComponent("position.json") }

    /// Fixture lookup is intentionally opt-in. It is used by `--selftest` and
    /// `--demo`, never by a normal launch of the installed app.
    static func fixtureURL(root: URL) -> URL {
        root.appendingPathComponent("examples/desktop-tasks.example.jsonl")
    }
}
