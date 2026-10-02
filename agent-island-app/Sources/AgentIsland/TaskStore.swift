import Foundation
import SwiftUI

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var groups: [AgentGroup] = []
    @Published private(set) var primary: TaskItem?
    @Published private(set) var activeCount: Int = 0
    @Published private(set) var now = Date()
    @Published private(set) var flash: FlashEvent?
    @Published private(set) var flashDeadline: Date?
    @Published private(set) var shakeDeadline: Date?
    @Published private(set) var flashStatus: TaskStatus?
    /// 当前这轮活跃任务刚刚结束后，胶囊短暂保留完成态提示。
    /// 不根据历史终态任务初始化，避免旧项目让看板一直显示“已完成”。
    @Published private(set) var hasFinishedWork = false
    /// 最近一次需要用户处理的任务；由 AppController 显示应用内提醒。
    @Published private(set) var attentionTask: TaskItem?

    let dataPath: String
    private let notifier: Notifier
    private var explicitTasks: [TaskItem] = []
    private var processTasks: [String: TaskItem] = [:]
    private var observedTasks: [String: TaskItem] = [:]
    private var lastStatusByTask: [String: TaskStatus] = [:]
    private var notifiedKeys: Set<String> = []
    private var didLoadBaseline = false
    private var flashSequence = 0
    private var flashClearTask: Swift.Task<Void, Never>?
    private var previousVisibleTaskIDs: Set<String> = []

    init(dataPath: String, notifier: Notifier) {
        self.dataPath = dataPath
        self.notifier = notifier
    }

    var capsuleTasks: [TaskItem] {
        let all = groups.flatMap(\.tasks).filter { !$0.status.isTerminal }
        return all.sorted {
            if $0.status.priority != $1.status.priority { return $0.status.priority > $1.status.priority }
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id < $1.id
        }
    }

    func reload() {
        explicitTasks = TaskParser.loadFile(path: dataPath)
        rebuild(extra: Array(processTasks.values) + Array(observedTasks.values))
    }

    func applyProcessSnapshot(current: [ProcessTask], ended: [ProcessTask]) {
        for item in ended { processTasks.removeValue(forKey: item.id) }
        for item in current {
            processTasks[item.id] = TaskItem(
                id: item.id,
                agentKey: item.agentKey,
                title: item.title,
                note: "仅进程 · PID \(item.pid)",
                status: .running,
                startedAt: item.startedAt,
                updatedAt: Date(),
                provenance: .process
            )
        }
        // 进程消失只代表“看不到进程了”，不能据此推断任务完成，也不发送完成通知。
        rebuild(extra: Array(processTasks.values) + Array(observedTasks.values))
    }

    func applyObservedSnapshot(_ current: [ObservedTask]) {
        observedTasks = Dictionary(uniqueKeysWithValues: current.map { item in
            let note = item.note.isEmpty ? item.provenance.label : "\(item.provenance.label) · \(item.note)"
            return (item.id, TaskItem(
                id: item.id,
                agentKey: item.agentKey,
                title: item.title,
                note: note,
                status: item.status,
                startedAt: item.startedAt,
                updatedAt: item.updatedAt,
                provenance: item.provenance
            ))
        })
        rebuild(extra: Array(processTasks.values) + Array(observedTasks.values))
    }

    func refreshClock() { now = Date() }

    func clearFlash() {
        flash = nil
        flashDeadline = nil
        shakeDeadline = nil
        flashStatus = nil
    }

    /// 关闭当前提醒；任务若仍保持 blocked，不会在每轮轮询中重复弹出。
    func dismissAttention() {
        attentionTask = nil
    }

    private func rebuild(extra: [TaskItem]) {
        // tasks.jsonl 是兼容导入源。没有心跳的 running/blocked 事件不能继续冒充
        // 当前任务，否则历史样例会压过真实适配器；真实会话由 observedTasks 每轮刷新。
        let visibleExplicit = explicitTasks.filter(isFreshImportedTask)
        var seen = Set(visibleExplicit.map(\.id))
        var merged = visibleExplicit
        for item in extra where !seen.contains(item.id) {
            merged.append(item)
            seen.insert(item.id)
        }
        var statusByTask: [String: TaskStatus] = [:]
        for task in merged { statusByTask[task.id] = task.status }
        if didLoadBaseline {
            handleNotificationsIfNeeded(tasks: merged)
        } else {
            for task in merged { notifiedKeys.insert(notificationKey(taskID: task.id, status: task.status)) }
            didLoadBaseline = true
        }

        // blocked 只在进入该状态时提醒一次。轮询不会每 8 秒重复弹窗，
        // 但任务恢复运行后再次阻塞仍会重新提醒。
        if let currentAttention = attentionTask,
           !merged.contains(where: { $0.id == currentAttention.id && $0.status == .blocked }) {
            attentionTask = nil
        }
        let newlyBlocked = merged
            .filter { $0.status == .blocked && lastStatusByTask[$0.id] != .blocked }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
        if let task = newlyBlocked.first {
            attentionTask = task
        }
        lastStatusByTask = statusByTask
        // 看板只展示当前未结束的任务。历史 done/failed 仍参与通知去重，
        // 但不再长期堆在展开面板里污染实时视图。
        let visibleTasks = merged.filter { !$0.status.isTerminal }
        let visibleIDs = Set(visibleTasks.map(\.id))
        if didLoadBaseline,
           !previousVisibleTaskIDs.isEmpty,
           visibleIDs.isEmpty {
            hasFinishedWork = true
        }
        // 只要新一轮任务出现，就恢复普通工作态；下一次结束时再显示完成提示。
        if !visibleIDs.isEmpty { hasFinishedWork = false }
        previousVisibleTaskIDs = visibleIDs
        groups = TaskGrouping.group(visibleTasks)
        primary = TaskGrouping.primary(visibleTasks)
        activeCount = visibleTasks.count
    }

    private func isFreshImportedTask(_ task: TaskItem) -> Bool {
        guard task.provenance == .local, !task.status.isTerminal else { return true }
        return Date().timeIntervalSince(task.updatedAt) <= 15 * 60
    }

    private func notificationKey(taskID: String, status: TaskStatus) -> String {
        "\(taskID)|\(status.rawValue)"
    }

    private func handleNotificationsIfNeeded(tasks: [TaskItem]) {
        for task in tasks where task.status.shouldNotify {
            let key = notificationKey(taskID: task.id, status: task.status)
            guard lastStatusByTask[task.id] != task.status, !notifiedKeys.contains(key) else { continue }
            notifiedKeys.insert(key)
            let agent = AgentRegistry.displayName(for: task.agentKey)
            let body = task.note.isEmpty ? task.title : "\(task.title) · \(task.note)"
            notifier.post(title: "\(agent) · \(task.status.notificationVerb)", body: body, identifier: key, isUrgent: task.status != .blocked)
            if task.status == .done || task.status == .failed { triggerFlash(status: task.status) }
        }
    }

    private func triggerFlash(status: TaskStatus) {
        flashSequence += 1
        flash = FlashEvent(status: status, sequence: flashSequence)
        flashStatus = status
        flashDeadline = Date().addingTimeInterval(3)
        shakeDeadline = status == .failed ? Date().addingTimeInterval(0.62) : nil
        flashClearTask?.cancel()
        let sequence = flashSequence
        flashClearTask = Swift.Task { @MainActor [weak self] in
            try? await Swift.Task.sleep(nanoseconds: 3_100_000_000)
            guard let self, self.flashSequence == sequence else { return }
            self.clearFlash()
        }
    }
}
