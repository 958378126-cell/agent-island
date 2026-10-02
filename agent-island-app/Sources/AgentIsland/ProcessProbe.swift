import Foundation

struct ProcessTask: Identifiable, Sendable {
    let id: String
    let pid: Int32
    let agentKey: String
    let title: String
    let command: String
    let startedAt: Date
}

final class ProcessProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "agent-island.process-probe", qos: .utility)
    private let onSnapshot: @MainActor @Sendable ([ProcessTask], [ProcessTask]) -> Void
    private var timer: DispatchSourceTimer?
    private var known: [String: ProcessTask] = [:]
    private var stopped = false

    init(onSnapshot: @escaping @MainActor @Sendable ([ProcessTask], [ProcessTask]) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.scanAndPublish()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.scanAndPublish() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func scanAndPublish() {
        guard !stopped else { return }
        let current = scan()
        let currentMap = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let ended = known.values.filter { currentMap[$0.id] == nil }
        known = currentMap
        Task { @MainActor [onSnapshot] in
            onSnapshot(current, ended)
        }
    }

    private func scan() -> [ProcessTask] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,etime=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run(); process.waitUntilExit() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(whereSeparator: \.isNewline).compactMap(parse)
    }

    private func parse(_ line: Substring) -> ProcessTask? {
        let text = line.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let pid = Int32(parts[0]) else { return nil }
        let elapsed = String(parts[1])
        let command = String(parts[2])
        let lower = command.lowercased()
        guard !lower.contains("grep"), !lower.contains("codex-wrapper.sh") else { return nil }
        // Codex Desktop runs a long-lived `codex app-server` process. Older
        // builds only matched `codex exec`, which made the desktop app invisible
        // even while a rollout file was actively changing.
        let isCodex = Self.isCodexCommand(lower)
        let isClaude = lower.contains("claude")
        guard isCodex || isClaude else { return nil }
        let agent = isCodex ? "codex" : "claude"
        let title = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? agent
        return ProcessTask(id: "process-\(pid)", pid: pid, agentKey: agent, title: title, command: command, startedAt: Date().addingTimeInterval(-Self.seconds(elapsed)))
    }

    static func isCodexCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        guard lower.contains("codex") else { return false }
        return lower.contains("exec") ||
            lower.contains("proto") ||
            lower.contains("codex-code-mode") ||
            lower.contains("app-server") ||
            lower.contains("app_server") ||
            lower.contains("appserver")
    }

    private static func seconds(_ text: String) -> TimeInterval {
        let pieces = text.split(separator: ":").map { Int($0) ?? 0 }
        if pieces.count == 3 { return TimeInterval(pieces[0] * 3600 + pieces[1] * 60 + pieces[2]) }
        if pieces.count == 2 { return TimeInterval(pieces[0] * 60 + pieces[1]) }
        if let day = text.split(separator: "-").first, let d = Int(day) { return TimeInterval(d * 86400) }
        return 0
    }
}
