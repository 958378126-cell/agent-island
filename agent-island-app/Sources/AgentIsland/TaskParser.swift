import Foundation

/// tasks.jsonl 解析器
///
/// 数据契约（SPEC）：
/// - 每行一个 JSON 事件，追加式写入
/// - 同一 task_id 的最新事件决定当前状态
/// - startedAt 取首个 running 事件的 ts
/// - 时长 = 最新事件 ts − startedAt
/// - 文件不存在 / 为空 → 任务列表为空（面板显示「暂无任务」）
enum TaskParser {

    // MARK: 原始事件

    /// 一行事件的原始结构，字段缺失时给出安全默认值
    private struct RawEvent: Decodable {
        let ts: String
        let agent: String
        let taskId: String
        let title: String
        let status: String
        let note: String?

        enum CodingKeys: String, CodingKey {
            case ts, agent, task_id, taskId, title, status, note
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ""
            agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
            // 同时兼容下划线与驼峰两种 task_id 写法
            taskId = (try? c.decode(String.self, forKey: .task_id))
                ?? (try? c.decode(String.self, forKey: .taskId))
                ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note)
        }
    }

    // MARK: 文本解析

    /// 解析 tasks.jsonl 的文本内容，得到折叠后的任务列表
    /// - 空行、非法 JSON、状态不在枚举内的行会被安全跳过
    static func parse(text: String) -> [TaskItem] {
        // task_id → 事件列表（含时间与行序，便于确定「最新」）
        var buckets: [String: [(date: Date, order: Int, event: RawEvent)]] = [:]
        var order = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            // 状态必须是 SPEC 规定的五种之一，否则整行跳过
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(RawEvent.self, from: data),
                  !event.taskId.isEmpty,
                  TaskStatus.fromExternal(event.status) != nil else {
                // 非法行直接忽略，避免一行坏数据把整个看板搞崩
                continue
            }
            let date = DateParser.parse(event.ts) ?? Date()
            buckets[event.taskId, default: []].append((date, order, event))
            order += 1
        }

        var items: [TaskItem] = []
        items.reserveCapacity(buckets.count)

        for (taskId, events) in buckets {
            // 最新事件 = 时间最大者；时间相同则取文件里靠后的那一行
            let sorted = events.sorted { a, b in
                if a.date != b.date { return a.date < b.date }
                return a.order < b.order
            }
            guard let last = sorted.last else { continue }

            let lastStatus = TaskStatus.fromExternal(last.event.status) ?? .queued
            // startedAt：首个 running 事件；没有 running 事件则退化为首个事件时间
            let startedAt = sorted.first(where: { TaskStatus.fromExternal($0.event.status) == .running })?.date
                ?? sorted[0].date
            // 备注：优先用最新事件的 note，为空时沿用最近一次非空备注，避免进度备注丢失
            let rawNote = sorted.reversed().first(where: { !($0.event.note ?? "").isEmpty })?.event.note ?? ""
            let note = rawNote.isEmpty ? "本地只读" : "本地只读 · \(rawNote)"

            items.append(TaskItem(
                id: taskId,
                agentKey: last.event.agent,
                title: last.event.title.isEmpty ? taskId : last.event.title,
                note: note,
                status: lastStatus,
                startedAt: startedAt,
                updatedAt: last.date,
                provenance: .local
            ))
        }
        return items
    }

    // MARK: 文件解析

    /// 读取文件内容并解析；文件不存在或读取失败时返回空列表
    static func loadFile(path: String) -> [TaskItem] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        return parse(text: text)
    }
}

// MARK: - 时间解析

/// ISO8601 时间解析（兼容带/不带毫秒、带时区偏移的写法）
enum DateParser {
    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // 2026-09-22T21:40:00+08:00
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }

        // 2026-09-22T21:40:00.123+08:00
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }

        // 兜底：空格分隔的本地时间写法
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fallback.date(from: trimmed)
    }
}

// MARK: - 分组与排序

/// 把扁平任务列表按 agent 分组并排序
enum TaskGrouping {
    /// 分组规则：组内按「优先级降序 → 开始时间升序」；组间按「组内最高优先级降序 → 最早开始时间升序」
    static func group(_ tasks: [TaskItem]) -> [AgentGroup] {
        var dict: [String: [TaskItem]] = [:]
        for task in tasks {
            dict[task.agentKey, default: []].append(task)
        }

        var groups: [AgentGroup] = dict.map { key, list in
            let sorted = list.sorted { a, b in
                if a.status.priority != b.status.priority {
                    return a.status.priority > b.status.priority
                }
                return a.startedAt < b.startedAt
            }
            return AgentGroup(
                id: key,
                displayName: AgentRegistry.displayName(for: key),
                colorHex: AgentRegistry.colorHex(for: key),
                tasks: sorted
            )
        }

        groups.sort { a, b in
            let pa = a.topStatus?.priority ?? 0
            let pb = b.topStatus?.priority ?? 0
            if pa != pb { return pa > pb }
            let ea = a.tasks.map(\.startedAt).min() ?? Date.distantFuture
            let eb = b.tasks.map(\.startedAt).min() ?? Date.distantFuture
            return ea < eb
        }
        return groups
    }

    /// 从全部任务里挑出最高优先级的一条（决定胶囊主态）
    static func primary(_ tasks: [TaskItem]) -> TaskItem? {
        tasks.max { a, b in
            if a.status.priority != b.status.priority {
                return a.status.priority < b.status.priority
            }
            return a.updatedAt < b.updatedAt
        }
    }
}
