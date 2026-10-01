import Foundation

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case queued, running, blocked, succeeded, failed, canceled, unknown
}

public enum SourceHealth: String, Codable, Sendable {
    case connected, stale, permissionRequired = "permission_required", unsupported, error
}

public enum Evidence: String, Codable, Sendable {
    case authoritative, derived, presenceOnly = "presence_only"
}

public struct TaskEvent: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: TaskStatus
    public let observedAt: Date
    public let updatedAt: Date
    public let evidence: Evidence
    public let sourceHealth: SourceHealth

    public init(id: String, title: String, status: TaskStatus, observedAt: Date,
                updatedAt: Date, evidence: Evidence, sourceHealth: SourceHealth) {
        self.id = id; self.title = title; self.status = status
        self.observedAt = observedAt; self.updatedAt = updatedAt
        self.evidence = evidence; self.sourceHealth = sourceHealth
    }

    /// A stale snapshot is no longer allowed to claim that work is running.
    public func withHealth(at now: Date, staleAfter: TimeInterval = 120) -> TaskEvent {
        guard now.timeIntervalSince(updatedAt) > staleAfter,
              status == .queued || status == .running else { return self }
        return TaskEvent(id: id, title: title, status: .unknown,
                         observedAt: observedAt, updatedAt: updatedAt,
                         evidence: evidence, sourceHealth: .stale)
    }
}

public enum StatusNormalizer {
    /// Only explicit terminal evidence can produce a terminal status.
    public static func normalize(raw: String, evidence: Evidence) -> TaskStatus {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "queued", "pending", "waiting_to_start": return .queued
        case "running", "working", "in_progress": return .running
        case "blocked", "needs_input", "awaiting_approval": return .blocked
        case "succeeded", "success", "completed", "done":
            return evidence == .presenceOnly ? .unknown : .succeeded
        case "failed", "error":
            return evidence == .presenceOnly ? .unknown : .failed
        case "canceled", "cancelled", "aborted", "stopped": return .canceled
        default: return .unknown
        }
    }
}

public struct NotificationKey: Hashable, Sendable {
    public let taskID: String
    public let status: TaskStatus
    public init(taskID: String, status: TaskStatus) { self.taskID = taskID; self.status = status }
}

public struct NotificationGate: Sendable {
    private var deliveredTerminal = Set<NotificationKey>()
    private var lastStatus = [String: TaskStatus]()
    public init() {}

    /// Returns true when a task enters blocked, or reaches a terminal state for the first time.
    /// Historical imports update no notification state and never notify.
    public mutating func shouldNotify(_ event: TaskEvent, isHistoricalImport: Bool = false) -> Bool {
        guard !isHistoricalImport else { return false }
        let previous = lastStatus.updateValue(event.status, forKey: event.id)
        if event.status == .blocked { return previous != .blocked }
        guard event.status == .succeeded || event.status == .failed else { return false }
        return deliveredTerminal.insert(NotificationKey(taskID: event.id, status: event.status)).inserted
    }
}
