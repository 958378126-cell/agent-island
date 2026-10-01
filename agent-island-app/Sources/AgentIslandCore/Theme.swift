import Foundation

/// A theme describes visual assets without coupling the task state engine to a
/// particular character, brand, or illustration set.
public struct ThemeManifest: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let brandName: String?
    public let statusAssets: [String: String]

    public init(id: String, displayName: String, brandName: String? = nil,
                statusAssets: [String: String]) {
        self.id = id
        self.displayName = displayName
        self.brandName = brandName
        self.statusAssets = statusAssets
    }
}

public struct ThemePack: Sendable {
    public let rootURL: URL
    public let manifest: ThemeManifest

    public init(rootURL: URL, manifest: ThemeManifest) {
        self.rootURL = rootURL
        self.manifest = manifest
    }

    public func assetURL(for status: TaskStatus) -> URL? {
        guard let relativePath = manifest.statusAssets[status.rawValue] else {
            return nil
        }
        return rootURL.appendingPathComponent(relativePath)
    }
}
