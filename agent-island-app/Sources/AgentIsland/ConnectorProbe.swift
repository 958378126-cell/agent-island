import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct ConnectorEnvelope: Decodable {
    let tasks: [ConnectorTaskEvent]
}

private final class HTTPJSONConnector: AgentConnector, @unchecked Sendable {
    let spec: ConnectorSpec

    init(spec: ConnectorSpec) { self.spec = spec }

    func poll() async throws -> [ConnectorTaskEvent] {
        guard let rawURL = spec.url, let url = URL(string: rawURL) else {
            throw ConnectorError.invalidConfiguration("\(spec.id): http_json 缺少合法 url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(15, max(3, spec.interval))
        for (key, value) in spec.headers ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
        if let envName = spec.tokenEnvironment,
           let token = ProcessInfo.processInfo.environment[envName], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ConnectorError.invalidResponse("\(spec.id): HTTP \(http.statusCode)")
        }
        if let events = try? JSONDecoder().decode([ConnectorTaskEvent].self, from: data) { return events }
        if let envelope = try? JSONDecoder().decode(ConnectorEnvelope.self, from: data) { return envelope.tasks }
        throw ConnectorError.invalidResponse("\(spec.id): 响应不是任务事件数组或 {tasks:[]}")
    }
}

private final class JSONLFileConnector: AgentConnector, @unchecked Sendable {
    let spec: ConnectorSpec

    init(spec: ConnectorSpec) { self.spec = spec }

    func poll() async throws -> [ConnectorTaskEvent] {
        guard let rawPath = spec.path else {
            throw ConnectorError.invalidConfiguration("\(spec.id): jsonl_file 缺少 path")
        }
        let path = (rawPath as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ConnectorError.invalidResponse("\(spec.id): 无法读取 \(path)")
        }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ConnectorTaskEvent.self, from: data)
        }
    }
}

private final class CommandJSONLConnector: AgentConnector, @unchecked Sendable {
    let spec: ConnectorSpec

    init(spec: ConnectorSpec) { self.spec = spec }

    func poll() async throws -> [ConnectorTaskEvent] {
        guard let rawCommand = spec.command, !rawCommand.isEmpty else {
            throw ConnectorError.invalidConfiguration("\(spec.id): command_jsonl 缺少 command")
        }
        let command = (rawCommand as NSString).expandingTildeInPath
        let data = try await ConnectorProcessRunner.run(
            executable: URL(fileURLWithPath: command),
            arguments: spec.arguments ?? [],
            timeout: spec.commandTimeout,
            outputLimit: spec.commandOutputLimit,
            connectorID: spec.id
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ConnectorTaskEvent.self, from: lineData)
        }
    }
}

/// Runs third-party adapters away from the main actor with a hard deadline and
/// bounded stdout. A hung or noisy adapter must not freeze the floating UI.
private enum ConnectorProcessRunner {
    private enum RaceResult { case exited(Int32), timedOut }
    private struct ReadResult: Sendable {
        let data: Data
        let truncated: Bool
    }

    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int,
        connectorID: String
    ) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() }
        catch { throw ConnectorError.invalidConfiguration("\(connectorID): 无法启动适配器：\(error.localizedDescription)") }

        let outputTask = Task.detached(priority: .utility) {
            Self.readLimited(output.fileHandleForReading, limit: outputLimit)
        }
        let errorTask = Task.detached(priority: .utility) {
            Self.readLimited(errors.fileHandleForReading, limit: 64 * 1024)
        }
        let waitTask = Task.detached(priority: .utility) {
            process.waitUntilExit()
            return process.terminationStatus
        }

        let race: RaceResult = await withTaskGroup(of: RaceResult.self) { group in
            group.addTask { .exited(await waitTask.value) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        switch race {
        case .exited(let status):
            let outputResult = await outputTask.value
            _ = await errorTask.value
            guard status == 0 else {
                throw ConnectorError.invalidResponse("\(connectorID): command exit \(status)")
            }
            guard !outputResult.truncated else {
                throw ConnectorError.invalidResponse("\(connectorID): 标准输出超过 \(outputLimit) bytes 上限")
            }
            return outputResult.data
        case .timedOut:
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = await waitTask.value
            _ = await errorTask.value
            _ = await outputTask.value
            throw ConnectorError.timeout("\(connectorID): 适配器超过 \(Int(timeout)) 秒未退出")
        }
    }

    private static func readLimited(_ handle: FileHandle, limit: Int) -> ReadResult {
        var result = Data()
        var truncated = false
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            let remaining = max(0, limit - result.count)
            if chunk.count > remaining { truncated = true }
            if remaining > 0 { result.append(chunk.prefix(remaining)) }
        }
        return ReadResult(data: result, truncated: truncated)
    }
}

private enum ConnectorFactory {
    static func make(_ spec: ConnectorSpec) -> AgentConnector? {
        switch spec.type {
        case .httpJSON: return HTTPJSONConnector(spec: spec)
        case .jsonlFile: return JSONLFileConnector(spec: spec)
        case .commandJSONL: return CommandJSONLConnector(spec: spec)
        }
    }
}

/// 配置型连接器的轮询协调器。单个 Agent 失败不会清空其他 Agent，也不会阻塞主线程。
private actor ConnectorPollCoordinator {
    private let connectors: [AgentConnector]
    private var cached: [String: [ObservedTask]] = [:]
    private var lastSuccess: [String: Date] = [:]
    private var firstFailure: [String: Date] = [:]
    private var nextPollAt: [String: Date] = [:]
    private var health: [String: ConnectorHealth] = [:]
    private let staleGrace: TimeInterval = 60

    init(specs: [ConnectorSpec]) {
        self.connectors = specs.filter(\.isEnabled).compactMap(ConnectorFactory.make)
    }

    var isEmpty: Bool { connectors.isEmpty }

    func poll() async -> ConnectorSnapshot {
        for connector in connectors {
            let now = Date()
            if let next = nextPollAt[connector.spec.id], next > now { continue }
            defer { nextPollAt[connector.spec.id] = Date().addingTimeInterval(connector.spec.interval) }
            do {
                let events = try await connector.poll()
                // 一个适配器可能同时输出事件流和当前快照；按稳定 task_id 折叠，
                // 避免同一任务重复出现在看板，或触发 Dictionary(uniqueKeysWithValues:) 崩溃。
                var latestByID: [String: ObservedTask] = [:]
                for task in events.compactMap({ $0.observed(using: connector.spec) }) {
                    guard let old = latestByID[task.id] else {
                        latestByID[task.id] = task
                        continue
                    }
                    if task.updatedAt >= old.updatedAt {
                        latestByID[task.id] = task
                    }
                }
                let tasks = Array(latestByID.values)
                cached[connector.spec.id] = tasks
                lastSuccess[connector.spec.id] = Date()
                firstFailure[connector.spec.id] = nil
                health[connector.spec.id] = ConnectorHealth(
                    connectorID: connector.spec.id,
                    state: .connected,
                    lastSuccessAt: lastSuccess[connector.spec.id],
                    message: nil
                )
            } catch {
                // 连接失败时保留短暂快照，避免网络抖动让任务从胶囊里闪退。
                let failureStarted = firstFailure[connector.spec.id] ?? now
                firstFailure[connector.spec.id] = failureStarted
                let lastConfirmed = lastSuccess[connector.spec.id] ?? failureStarted
                if now.timeIntervalSince(lastConfirmed) > staleGrace {
                    cached[connector.spec.id] = []
                    health[connector.spec.id] = ConnectorHealth(
                        connectorID: connector.spec.id,
                        state: .error,
                        lastSuccessAt: lastSuccess[connector.spec.id],
                        message: error.localizedDescription
                    )
                } else {
                    health[connector.spec.id] = ConnectorHealth(
                        connectorID: connector.spec.id,
                        state: .stale,
                        lastSuccessAt: lastSuccess[connector.spec.id],
                        message: error.localizedDescription
                    )
                }
            }
        }
        return ConnectorSnapshot(
            tasks: cached.values.flatMap { $0 },
            health: health.values.sorted { $0.connectorID < $1.connectorID }
        )
    }
}

final class ConfiguredConnectorProbe: @unchecked Sendable {
    private let coordinator: ConnectorPollCoordinator
    private let pollInterval: TimeInterval
    private let onSnapshot: @MainActor @Sendable (ConnectorSnapshot) -> Void
    private var loop: Task<Void, Never>?

    init?(manifest: ConnectorManifest, onSnapshot: @escaping @MainActor @Sendable (ConnectorSnapshot) -> Void) {
        let enabledSpecs = manifest.connectors.filter(\.isEnabled)
        let coordinator = ConnectorPollCoordinator(specs: enabledSpecs)
        self.coordinator = coordinator
        self.pollInterval = enabledSpecs.map(\.interval).min() ?? 10
        self.onSnapshot = onSnapshot
        // 空清单不启动常驻任务。
        if enabledSpecs.isEmpty { return nil }
    }

    func start() {
        loop = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let snapshot = await self.coordinator.poll()
                await MainActor.run { self.onSnapshot(snapshot) }
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }
}
