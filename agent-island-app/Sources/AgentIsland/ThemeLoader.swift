import AppKit

/// Loads an optional user-owned theme outside the repository.
///
/// The public build ships with no artwork. A user can point
/// `AGENT_ISLAND_THEME` at a theme directory, or place one at
/// `~/Library/Application Support/AgentIsland/theme/`.
enum ThemeLoader {
    private struct Manifest: Decodable {
        let displayName: String?
        let statusAssets: [String: String]

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case statusAssets = "status_assets"
        }
    }

    nonisolated(unsafe) private static var cachedManifest: (directory: URL, manifest: Manifest)?
    nonisolated(unsafe) private static var cachedImages: [URL: NSImage] = [:]

    static func image(for status: TaskStatus) -> NSImage? {
        guard let manifest = loadManifest(),
              let relativePath = manifest.manifest.statusAssets[status.rawValue] else { return nil }
        let url = manifest.directory.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(manifest.directory.standardizedFileURL.path + "/") else { return nil }
        if let cached = cachedImages[url] { return cached }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        cachedImages[url] = image
        return image
    }

    private static func loadManifest() -> (directory: URL, manifest: Manifest)? {
        if let cachedManifest { return cachedManifest }
        let fileManager = FileManager.default
        let configured = ProcessInfo.processInfo.environment["AGENT_ISLAND_THEME"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let defaultDirectory = RuntimePaths.applicationSupportDirectory.appendingPathComponent("theme", isDirectory: true)
        let candidate = configured ?? defaultDirectory
        let manifestURL = candidate.pathExtension.lowercased() == "json"
            ? candidate
            : candidate.appendingPathComponent("theme.json")
        guard fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        let directory = manifestURL.deletingLastPathComponent().standardizedFileURL
        let result = (directory: directory, manifest: manifest)
        cachedManifest = result
        return result
    }
}
