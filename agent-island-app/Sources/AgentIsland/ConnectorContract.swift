import Foundation

/// 开源连接层的三种通用入口。
/// Agent Island 核心只消费规范化事件，不直接依赖某个厂商的 SDK。
enum ConnectorType: String, Codable, Sendable, Hashable, CaseIterable {
    case httpJSON = "http_json"
    case jsonlFile = "jsonl_file"
    case commandJSONL = "command_jsonl"

    var displayName: String {
        switch self {
        case .httpJSON: return "官方 HTTP API"
        case .jsonlFile: return "本地 JSONL 文件"
        case .commandJSONL: return "命令行适配器"
        }
    }
}

/// `config/agents.json` 中的一个连接声明。
struct ConnectorSpec: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let type: ConnectorType
    let url: String?
    let path: String?
    let command: String?
    let arguments: [String]?
    let tokenEnvironment: String?
    let headers: [String: String]?
    let statusMap: [String: String]?
    let provenance: TaskProvenance?
    let pollSeconds: Double?
    let timeoutSeconds: Double?
    let maxOutputBytes: Int?
    let enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case type, url, path, command, arguments
        case tokenEnvironment = "token_environment"
        case headers
        case statusMap = "status_map"
        case provenance
        case pollSeconds = "poll_seconds"
        case timeoutSeconds = "timeout_seconds"
        case maxOutputBytes = "max_output_bytes"
        case enabled
    }

    var interval: TimeInterval { max(3, pollSeconds ?? 10) }
    var commandTimeout: TimeInterval { min(60, max(1, timeoutSeconds ?? 15)) }
    var commandOutputLimit: Int { min(8 * 1024 * 1024, max(16 * 1024, maxOutputBytes ?? 1 * 1024 * 1024)) }
    var isEnabled: Bool { enabled ?? true }
}

struct ConnectorManifest: Codable, Sendable {
    let schemaVersion: Int
    let connectors: [ConnectorSpec]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case connectors
    }
}

enum ConnectorHealthState: String, Sendable {
    case connected
    case stale
    case error
    case unsupported
}

struct ConnectorHealth: Sendable {
    let connectorID: String
    let state: ConnectorHealthState
    let lastSuccessAt: Date?
    let message: String?
}

struct ConnectorSnapshot: Sendable {
    let tasks: [ObservedTask]
    let health: [ConnectorHealth]
}

/// 适配器输出的最小规范化事件。
/// 厂商 API 的字段映射应在适配器里完成，核心不读取厂商私有字段。
struct ConnectorTaskEvent: Codable, Sendable {
    let taskID: String
    let title: String
    let status: String
    let note: String?
    let startedAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case title, status, note
        case startedAt = "started_at"
        case updatedAt = "updated_at"
    }

    func observed(using spec: ConnectorSpec) -> ObservedTask? {
        guard !taskID.isEmpty else { return nil }
        let rawStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mappedStatus = spec.statusMap?.first(where: { $0.key.lowercased() == rawStatus })?.value.lowercased() ?? rawStatus
        guard let taskStatus = TaskStatus.fromExternal(mappedStatus) else { return nil }

        let updated = ConnectorDate.parse(updatedAt) ?? Date()
        let started = ConnectorDate.parse(startedAt) ?? updated
        let evidence = spec.provenance ?? (spec.type == .httpJSON ? .official : .local)
        let sourceNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ObservedTask(
            id: "connector:\(spec.id):\(taskID)",
            agentKey: spec.id,
            title: title.isEmpty ? taskID : title,
            note: "\(spec.displayName) · \(evidence.label)" + (sourceNote.isEmpty ? "" : " · \(sourceNote)"),
            status: taskStatus,
            startedAt: started,
            updatedAt: updated,
            provenance: evidence
        )
    }
}

enum ConnectorDate {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let number = Double(value) {
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        }
        return DateParser.parse(value)
    }
}

enum ConnectorManifestLoader {
    static func load() -> ConnectorManifest? {
        let candidates: [URL] = [
            environmentURL(),
            applicationSupportURL()
        ].compactMap { $0 }

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(ConnectorManifest.self, from: data),
                  manifest.schemaVersion == 1 else { continue }
            return manifest
        }
        return nil
    }

    /// 从设置界面写入 manifest。若用户通过环境变量指定了 manifest，沿用该路径；
    /// 否则写入应用支持目录，Finder 启动的 .app 也能读取到。
    static func save(_ manifest: ConnectorManifest) throws {
        let url = environmentURL() ?? applicationSupportURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    static var configurationPath: String {
        (environmentURL() ?? applicationSupportURL()).path
    }

    private static func applicationSupportURL() -> URL {
        RuntimePaths.connectorsURL
    }

    private static func environmentURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["AGENT_ISLAND_CONNECTORS"], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }
}

protocol AgentConnector: Sendable {
    var spec: ConnectorSpec { get }
    func poll() async throws -> [ConnectorTaskEvent]
}

enum ConnectorError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidResponse(let message), .timeout(let message): return message
        }
    }
}
