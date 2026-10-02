import Foundation

/// 从 Agent 的官方可观察状态或本机只读状态中提取“仍在运行”的任务。
///
/// 当前阶段的策略是：
/// - Codex：读取桌面/CLI 共用的 rollout 文件，文件正在写入且没有 task_complete 事件时视为活动回合。
/// - WorkBuddy：读取本地会话 JSONL，只有最近仍在写入的会话才进入看板。
/// - AutoClaw：读取本地 session JSONL；trajectory 出现 session.ended 后不再显示。
/// - 任何来源都不会因为“进程还在”就伪造一个 running 任务。
final class LiveActivityProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "agent-island.live-activity-probe", qos: .utility)
    private let onSnapshot: @MainActor @Sendable ([ObservedTask]) -> Void
    private var timer: DispatchSourceTimer?
    private var stopped = false
    // Rollout files can pause while a model/tool is working without writing a
    // line. Keep the window generous; terminal status still comes from events.
    private let activityWindow: TimeInterval = 180
    private var lastWorkBuddyTasks: [ObservedTask] = []
    private var lastWorkBuddyDatabaseReadAt: Date?

    init(onSnapshot: @escaping @MainActor @Sendable ([ObservedTask]) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.scanAndPublish()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 8, repeating: 8, leeway: .seconds(1))
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
        let tasks = codexTasks() + workBuddyTasks() + autoClawTasks() + doubaoTasks()
        Task { @MainActor [onSnapshot] in onSnapshot(tasks) }
    }

    // MARK: Codex

    private func codexTasks() -> [ObservedTask] {
        let root = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        return recentFiles(root: root, suffix: ".jsonl").compactMap { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) <= activityWindow else { return nil }

            let tail = readTail(url, maxBytes: 96 * 1024)
            let activity = CodexRolloutParser.state(from: tail)
            guard activity.isActive else { return nil }

            let metadata = readCodexMetadata(url)
            let sessionID = metadata.id ?? stableID(from: url)
            let cwdName = metadata.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap(nonEmpty)
                ?? "当前工作区"
            // 长生命周期的 Codex session 会复用同一个 JSONL。优先取本轮
            // task_started；找不到时也不要回退到数周前的 session_meta 时间。
            let startedAt = activity.startedAt ?? modified.addingTimeInterval(-30)
            return ObservedTask(
                id: "codex:\(sessionID)",
                agentKey: "codex",
                title: cwdName,
                note: "本地回放仍在写入 · 回合 \(sessionID.prefix(8))",
                status: .running,
                startedAt: startedAt,
                updatedAt: modified,
                provenance: .local
            )
        }
    }

    private func readCodexMetadata(_ url: URL) -> CodexMetadata {
        let prefix = readPrefix(url, maxBytes: 128 * 1024)
        var result = CodexMetadata()
        for line in prefix.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any] {
                result.id = payload["session_id"] as? String ?? payload["id"] as? String
                result.cwd = payload["cwd"] as? String
            }
            if object["type"] as? String == "event_msg",
               let payload = object["payload"] as? [String: Any],
               payload["type"] as? String == "task_started",
               let seconds = payload["started_at"] as? NSNumber {
                result.startedAt = Date(timeIntervalSince1970: seconds.doubleValue)
            }
            if result.id != nil && result.cwd != nil && result.startedAt != nil { break }
        }
        return result
    }

    // MARK: WorkBuddy

    private func workBuddyTasks() -> [ObservedTask] {
        let databaseResult = workBuddyDatabaseTasks()
        let databaseTasks: [ObservedTask]
        if databaseResult.readSucceeded {
            databaseTasks = databaseResult.tasks
            lastWorkBuddyTasks = databaseTasks
            lastWorkBuddyDatabaseReadAt = Date()
        } else if let lastRead = lastWorkBuddyDatabaseReadAt,
                  Date().timeIntervalSince(lastRead) < 60,
                  !lastWorkBuddyTasks.isEmpty {
            // 数据库短暂加锁、WorkBuddy 正在升级或 sqlite 读取失败时，保留最后一次
            // 已确认的状态，避免看板每 8 秒闪烁消失。
            databaseTasks = lastWorkBuddyTasks
        } else {
            databaseTasks = []
        }
        let databaseIDs = Set(databaseTasks.map(\.id))
        // DB 是当前 WorkBuddy 版本的稳定会话状态源；JSONL 只作为旧版本/数据库不可读时的回退。
        // 两者同时存在时按稳定 session ID 去重。
        return databaseTasks + workBuddyFileTasks().filter { !databaseIDs.contains($0.id) }
    }

    /// WorkBuddy 本地数据库中的 sessions 表包含稳定会话 ID、标题、状态和最后活动时间。
    /// 这比“文件最近被写过”可靠：任务等待模型/工具时，即使 JSONL 暂停写入，状态仍会保留。
    private func workBuddyDatabaseTasks() -> (tasks: [ObservedTask], readSucceeded: Bool) {
        let candidates = [
            home.appendingPathComponent(".workbuddy/workbuddy.db"),
            home.appendingPathComponent(".workbuddy/app/workbuddy.db")
        ]
        guard let database = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return ([], false) }

        // 输出模式用 runSQLite 的 `-list` 选项，不要把 `.mode` 这类 dot 命令写进脚本：
        // sqlite3 CLI 只接受「库文件 + 单条 SQL」一个参数，脚本含换行或 dot 命令时
        // 参数会被拆开，进程以退出码 1 结束，读取会被静默判为失败。
        let query = """
        SELECT json_group_array(json_object(
                 'id', id,
                 'cwd', cwd,
                 'title', COALESCE(NULLIF(custom_title, ''), NULLIF(title, ''), ''),
                 'status', status,
                 'created_at', created_at,
                 'updated_at', updated_at,
                 'last_activity_at', last_activity_at
               ))
        FROM (
          SELECT id, cwd, custom_title, title, status, created_at, updated_at, last_activity_at
          FROM sessions
          WHERE deleted_at IS NULL
            AND lower(status) IN ('creating', 'pending', 'queued', 'planning', 'working', 'running', 'waiting', 'waiting_user', 'awaiting_input', 'input_required', 'awaiting_confirmation', 'waiting_confirmation', 'waiting_for_confirmation', 'needs_confirmation', 'needs_approval', 'approval_required', 'permission_required', 'blocked', 'idle')
          ORDER BY COALESCE(last_activity_at, updated_at) DESC
        );
        """
        guard let output = runSQLite(database: database, query: query),
              let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return ([], false) }

        let tasks: [ObservedTask] = rows.compactMap { row in
            guard let sessionID = row["id"] as? String, !sessionID.isEmpty else { return nil }
            let cwd = row["cwd"] as? String ?? ""
            let rawTitle = row["title"] as? String ?? ""
            let title = rawTitle.isEmpty ? (URL(fileURLWithPath: cwd).lastPathComponent.nonEmpty ?? "当前项目") : rawTitle
            let rawStatus = (row["status"] as? String ?? "working").lowercased()
            let taskStatus = TaskStatus.fromWorkBuddy(rawStatus) ?? .running
            let updatedAt = dateFromDatabase(row["last_activity_at"] ?? row["updated_at"]) ?? Date()
            let startedAt = dateFromDatabase(row["created_at"]) ?? updatedAt
            return ObservedTask(
                id: "workbuddy:\(sessionID)",
                agentKey: "workbuddy",
                title: title,
                note: "WorkBuddy DB · \(taskStatus == .blocked ? "等待确认" : rawStatus) · 最后活动 \(DurationText.string(from: max(0, Date().timeIntervalSince(updatedAt))))前",
                status: taskStatus,
                startedAt: startedAt,
                updatedAt: updatedAt,
                provenance: .local
            )
        }
        return (tasks, true)
    }

    private func workBuddyFileTasks() -> [ObservedTask] {
        let root = home.appendingPathComponent(".workbuddy/projects", isDirectory: true)
        return recentFiles(root: root, suffix: ".jsonl").compactMap { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) <= activityWindow else { return nil }

            let tail = readTail(url, maxBytes: 64 * 1024)
            guard !workBuddyTailIsTerminal(tail) else { return nil }
            let taskStatus = workBuddyTailStatus(tail)
            let parts = url.pathComponents
            let project = parts.drop(while: { $0 != "projects" }).dropFirst().first ?? "当前项目"
            let sessionID = url.deletingPathExtension().lastPathComponent
            return ObservedTask(
                id: "workbuddy:\(sessionID)",
                agentKey: "workbuddy",
                title: "WorkBuddy · \(prettyPathComponent(project))",
                note: taskStatus == .blocked ? "会话正在等待确认 · \(sessionID.prefix(8))" : "会话 JSONL 仍在写入 · \(sessionID.prefix(8))",
                status: taskStatus,
                startedAt: modified.addingTimeInterval(-30),
                updatedAt: modified,
                provenance: .local
            )
        }
    }

    private func runSQLite(database: URL, query: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        // `-list` 等价于脚本里的 `.mode list`，但作为命令行选项传入不会引入第二个
        // 非选项参数，因此多行 SQL 也能正常执行。
        process.arguments = ["-list", database.path, query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }

    private func dateFromDatabase(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
    }

    private func workBuddyTailIsTerminal(_ text: String) -> Bool {
        guard let lastLine = text.split(whereSeparator: \.isNewline).last,
              let data = String(lastLine).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if object["status"] as? String == "completed" { return true }
        if let message = object["message"] as? [String: Any], message["status"] as? String == "completed" { return true }
        return false
    }

    /// 旧版 WorkBuddy 没有可读数据库时，从最后一条 JSONL 事件尽量识别等待确认。
    /// 无法确认时保持 running，不凭“文件停止写入”猜测阻塞。
    private func workBuddyTailStatus(_ text: String) -> TaskStatus {
        guard let lastLine = text.split(whereSeparator: \.isNewline).last,
              let data = String(lastLine).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .running }
        let candidates: [String] = [
            object["status"] as? String,
            (object["message"] as? [String: Any])?["status"] as? String,
            object["type"] as? String,
            (object["event"] as? [String: Any])?["type"] as? String
        ].compactMap { $0 }
        return candidates.compactMap(TaskStatus.fromExternal).first ?? .running
    }

    // MARK: AutoClaw

    // MARK: 豆包桌面版

    /// 豆包桌面端目前没有提供给本地看板的任务状态 API。这里使用它自己的聊天
    /// IndexedDB / Local Storage 写入作为只读“正在回答”信号：聊天内容持续落盘时
    /// 认为豆包正在输出；仅打开窗口但没有新写入时不显示，避免把闲置的桌面端误报成任务。
    ///
    /// 这是本地活动推断，不会读取或展示对话正文，也不会向豆包发送任何请求。
    private func doubaoTasks() -> [ObservedTask] {
        let supportRoot = home.appendingPathComponent(
            "Library/Containers/com.bot.neotix.doubao/Data/Library/Application Support/Doubao",
            isDirectory: true
        )
        let roots = [
            // 只看聊天 IndexedDB；Local Storage / Session Storage 会被桌面端
            // 的后台心跳、窗口状态和遥测更新，不能作为“正在回答”的信号。
            supportRoot.appendingPathComponent("Default/IndexedDB/chrome_doubao-chat_0.indexeddb.leveldb", isDirectory: true)
        ]
        guard let modified = latestDoubaoActivity(in: roots) else { return [] }
        let age = Date().timeIntervalSince(modified)
        // 给文件系统时间戳留一点容差；窗口足够短，不会把刚才已经结束的回答长期留在胶囊里。
        guard age >= -1, age <= 18 else { return [] }

        return [ObservedTask(
            id: "doubao:desktop-chat",
            agentKey: "doubao",
            title: "豆包桌面版",
            note: "桌面端正在回答 · 本地活动推断 · (DurationText.string(from: max(0, age)))前更新",
            status: .running,
            startedAt: modified.addingTimeInterval(-min(8, max(0, age))),
            updatedAt: modified,
            provenance: .local
        )]
    }

    private func latestDoubaoActivity(in roots: [URL]) -> Date? {
        let fileManager = FileManager.default
        var latest: Date?
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard ["log", "ldb"].contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate else { continue }
                if latest == nil || modified > latest! { latest = modified }
            }
        }
        return latest
    }

    private func autoClawTasks() -> [ObservedTask] {
        let databaseTasks = autoClawDatabaseTasks()
        let logTasks = autoClawLogTasks()
        let root = home.appendingPathComponent(".openclaw-autoclaw/agents", isDirectory: true)
        let fileTasks: [ObservedTask] = recentFiles(root: root, suffix: ".jsonl").compactMap { (url: URL) -> ObservedTask? in
            guard !url.lastPathComponent.hasSuffix(".trajectory.jsonl"),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date else { return nil }

            // AutoClaw 会复用同一个 session JSONL 追加多轮任务；对应的
            // `.trajectory.jsonl` 可能仍保留上一轮的 session.ended。当前
            // `.jsonl.lock` 才是这一轮是否仍在执行的直接证据。
            let hasActiveLock = autoClawSessionLockIsActive(for: url)
            guard hasActiveLock || Date().timeIntervalSince(modified) <= activityWindow else { return nil }

            let trajectoryPath = url.path.replacingOccurrences(of: ".jsonl", with: ".trajectory.jsonl")
            let trajectory = URL(fileURLWithPath: trajectoryPath)
            // 只有没有活动锁时，才用同一时段写入的 trajectory 终态过滤。
            // 旧 trajectory 的结束标记不能覆盖当前仍持锁的会话。
            let trajectoryIsCurrent = ((try? FileManager.default.attributesOfItem(atPath: trajectory.path)[.modificationDate] as? Date) ?? nil)
                .map { $0 >= modified.addingTimeInterval(-5) } ?? false
            if !hasActiveLock, trajectoryIsCurrent,
               FileManager.default.fileExists(atPath: trajectory.path),
               readTail(trajectory, maxBytes: 16 * 1024).contains("\"type\":\"session.ended\"") {
                return nil
            }

            let components = url.pathComponents
            guard let agentsIndex = components.firstIndex(of: "agents"), components.count > agentsIndex + 2 else { return nil }
            let agentID = components[agentsIndex + 1]
            let sessionID = url.deletingPathExtension().lastPathComponent
            return ObservedTask(
                id: "autoclaw:\(agentID):\(sessionID)",
                agentKey: "autoclaw",
                title: autoClawTaskTitle(from: url, fallback: "会话 \(agentID)"),
                note: "本地会话仍在写入 · \(sessionID.prefix(8))",
                status: .running,
                startedAt: modified.addingTimeInterval(-30),
                updatedAt: modified,
                provenance: .local
            )
        }

        // gateway/SQLite 是 AutoClaw 自己的运行状态源；只要存在官方活动记录，
        // 文件回退可能代表旧 session，避免把它和当前 run 重复显示。
        let fallbackFiles = (databaseTasks.isEmpty && logTasks.isEmpty) ? fileTasks : []
        return databaseTasks + logTasks + fallbackFiles
    }

    /// AutoClaw 的官方本地状态库记录了任务生命周期。任务刚启动、session JSONL
    /// 尚未刷新时，这里仍能给看板提供真实的 task_id/status，而不是猜测进程状态。
    private func autoClawDatabaseTasks() -> [ObservedTask] {
        let database = home.appendingPathComponent(".openclaw-autoclaw/state/openclaw.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }

        // 同 WorkBuddy：输出模式交给 runSQLite 的 `-list`，脚本里不写 dot 命令。
        let query = """
        SELECT json_group_array(json_object(
                 'task_id', task_id,
                 'agent_id', COALESCE(agent_id, ''),
                 'run_id', COALESCE(run_id, ''),
                 'label', COALESCE(label, ''),
                 'task', task,
                 'status', status,
                 'created_at', created_at,
                 'started_at', started_at,
                 'last_event_at', last_event_at
               ))
        FROM task_runs
        WHERE lower(status) NOT IN ('succeeded', 'completed', 'done', 'failed', 'error', 'cancelled', 'canceled', 'stopped')
          AND COALESCE(last_event_at, started_at, created_at) >= (strftime('%s', 'now') - 7200) * 1000;
        """
        guard let output = runSQLite(database: database, query: query),
              let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return rows.compactMap { row in
            guard let taskID = row["task_id"] as? String, !taskID.isEmpty else { return nil }
            let agentID = (row["agent_id"] as? String).flatMap(nonEmpty) ?? "main"
            let status = (row["status"] as? String).flatMap(nonEmpty) ?? "running"
            let taskStatus = TaskStatus.fromExternal(status) ?? .running
            let updatedAt = dateFromDatabase(row["last_event_at"] ?? row["started_at"] ?? row["created_at"]) ?? Date()
            let startedAt = dateFromDatabase(row["started_at"] ?? row["created_at"]) ?? updatedAt
            let label = (row["label"] as? String).flatMap(compactTaskTitle)
                ?? (row["task"] as? String).flatMap(compactTaskTitle)
                ?? "AutoClaw · \(agentID)"
            return ObservedTask(
                id: "autoclaw:task:\(taskID)",
                agentKey: "autoclaw:\(agentID)",
                title: label,
                note: "AutoClaw 状态库 · \(taskStatus == .blocked ? "等待确认" : status)",
                status: taskStatus,
                startedAt: startedAt,
                updatedAt: updatedAt,
                provenance: .local
            )
        }
    }

    /// gateway 日志里的 acknowledged/stream/done 事件覆盖“任务已经启动但 JSONL
    /// 尚未写入”的窗口。只保留有启动确认、且尚未收到终态事件的 run。
    private func autoClawLogTasks() -> [ObservedTask] {
        let log = home.appendingPathComponent(".openclaw-autoclaw/logs/autoclaw-dev.log")
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }

        struct RunState {
            let runID: String
            let sessionKey: String
            var agentID: String
            var startedAt: Date
            var lastEventAt: Date
            var timeout: TimeInterval
            var status: TaskStatus = .running
            var terminal = false
        }

        var runs: [String: RunState] = [:]
        let now = Date()
        for line in readTail(log, maxBytes: 512 * 1024).split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = (object["ts"] as? String).flatMap(DateParser.parse),
                  let message = object["message"] as? String,
                  let payload = object["data"] as? [String: Any] else { continue }

            let runID = (payload["runId"] as? String) ?? (payload["traceId"] as? String)
            let sessionKey = payload["sessionKey"] as? String
            if message == "agent.send.acknowledged",
               let runID, let sessionKey,
               (payload["status"] as? String) == "started" {
                let agentID = autoClawAgentID(from: sessionKey)
                runs[runID] = RunState(
                    runID: runID,
                    sessionKey: sessionKey,
                    agentID: agentID,
                    startedAt: timestamp,
                    lastEventAt: timestamp,
                    timeout: 7_200,
                    terminal: false
                )
                continue
            }

            guard message == "agent.stream.event", let runID else { continue }
            let initialState = runs[runID] ?? {
                // 日志尾部可能从一次较早的 acknowledged 开始；只要尾部仍有
                // 非终态 stream 事件，就把它当作当前运行恢复出来。
                guard let sessionKey else { return nil }
                let agentID = (payload["agentId"] as? String) ?? autoClawAgentID(from: sessionKey)
                return RunState(
                    runID: runID,
                    sessionKey: sessionKey,
                    agentID: agentID,
                    startedAt: timestamp.addingTimeInterval(-30),
                    lastEventAt: timestamp,
                    timeout: 7_200,
                    terminal: false
                )
            }()
            guard var state = initialState else { continue }
            state.lastEventAt = timestamp
            if let rawEventStatus = (payload["status"] as? String) ?? (payload["type"] as? String),
               let eventStatus = TaskStatus.fromExternal(rawEventStatus) {
                state.status = eventStatus
            }
            if let type = payload["type"] as? String,
               ["done", "error", "failed", "aborted", "stopped", "cancelled", "canceled"].contains(type.lowercased()) {
                state.terminal = true
            }
            runs[runID] = state
        }

        return runs.values.compactMap { run in
            guard !run.terminal,
                  now.timeIntervalSince(run.startedAt) <= run.timeout,
                  now.timeIntervalSince(run.lastEventAt) <= run.timeout else { return nil }
            return ObservedTask(
                id: "autoclaw:run:\(run.runID)",
                agentKey: "autoclaw:\(run.agentID)",
                title: "AutoClaw · \(run.agentID) 运行中",
                note: run.status == .blocked ? "gateway stream · 等待确认 · \(run.runID.prefix(8))" : "gateway stream · \(run.runID.prefix(8))",
                status: run.status,
                startedAt: run.startedAt,
                updatedAt: run.lastEventAt,
                provenance: .local
            )
        }
    }

    private func autoClawAgentID(from sessionKey: String) -> String {
        let parts = sessionKey.split(separator: ":")
        return parts.count > 1 ? String(parts[1]) : "main"
    }

    /// 从 AutoClaw session JSONL 的最后一条用户消息提取真实任务标题。
    /// AutoClaw 的系统提醒很多，优先读取其稳定的用户请求标记，避免把
    /// 系统提示或工具输出显示到看板里。
    private func autoClawTaskTitle(from url: URL, fallback: String) -> String {
        let startMarker = "<<<AUTOCLAW_USER_AUTHORED_REQUEST_START>>>"
        let endMarker = "<<<AUTOCLAW_USER_AUTHORED_REQUEST_END>>>"
        let lines = readTail(url, maxBytes: 128 * 1024).split(whereSeparator: \.isNewline).reversed()

        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "message",
                  let message = object["message"] as? [String: Any],
                  message["role"] as? String == "user",
                  let content = message["content"] else { continue }

            let raw = autoClawMessageText(content)
            guard !raw.isEmpty else { continue }
            if let start = raw.range(of: startMarker),
               let end = raw.range(of: endMarker, range: start.upperBound..<raw.endIndex) {
                let request = String(raw[start.upperBound..<end.lowerBound])
                if let title = compactTaskTitle(request) { return title }
            }
            if let title = compactTaskTitle(raw) { return title }
        }
        return fallback
    }

    private func autoClawMessageText(_ content: Any) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block in
            if let text = block["text"] as? String { return text }
            if let text = block["content"] as? String { return text }
            return nil
        }.joined(separator: "\n")
    }

    private func compactTaskTitle(_ text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "<system-reminder>", with: "")
            .replacingOccurrences(of: "</system-reminder>", with: "")
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(48))
    }

    /// AutoClaw 写入 session 时会创建同名 `.jsonl.lock`，并记录本轮最大持有时长。
    /// 不直接依赖锁文件 mtime，避免文件系统没有刷新 mtime 时误判；锁过期后
    /// 仍回退到普通 activityWindow 规则。
    private func autoClawSessionLockIsActive(for session: URL) -> Bool {
        let lock = URL(fileURLWithPath: session.path + ".lock")
        guard let data = try? Data(contentsOf: lock),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let createdRaw = object["createdAt"] as? String,
              let createdAt = DateParser.parse(createdRaw) else { return false }
        let maxHoldMs = (object["maxHoldMs"] as? NSNumber)?.doubleValue ?? 420_000
        let age = Date().timeIntervalSince(createdAt)
        return age >= -5 && age <= maxHoldMs / 1_000
    }

    // MARK: 文件工具

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private func recentFiles(root: URL, suffix: String) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              // The Codex root is itself hidden (`~/.codex`). Do not skip hidden
              // descendants, otherwise a future hidden session directory can be
              // silently omitted from detection.
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: []) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == String(suffix.dropFirst()) else { return nil }
            return url
        }
    }

    private func readPrefix(_ url: URL, maxBytes: Int) -> String { readBytes(url, offset: 0, count: maxBytes) }

    private func readTail(_ url: URL, maxBytes: Int) -> String {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue else { return "" }
        return readBytes(url, offset: max(0, size - maxBytes), count: maxBytes)
    }

    private func readBytes(_ url: URL, offset: Int, count: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return String(data: try handle.read(upToCount: count) ?? Data(), encoding: .utf8) ?? ""
        } catch { return "" }
    }

    private func stableID(from url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.split(separator: "-").suffix(5).joined(separator: "-")
    }

    private func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }

    private func prettyPathComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "Users-sandy-", with: "").replacingOccurrences(of: "-", with: " ")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct ObservedTask: Identifiable, Sendable {
    let id: String
    let agentKey: String
    let title: String
    let note: String
    let status: TaskStatus
    let startedAt: Date
    let updatedAt: Date
    let provenance: TaskProvenance
}

private struct CodexMetadata {
    var id: String?
    var cwd: String?
    var startedAt: Date?
}
