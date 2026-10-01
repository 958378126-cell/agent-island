import Foundation
import AgentIslandCore

let now = Date()
let event = TaskEvent(id: "demo-1", title: "示例任务", status: .running,
                      observedAt: now.addingTimeInterval(-10), updatedAt: now,
                      evidence: .derived, sourceHealth: .connected)
let stale = event.withHealth(at: now.addingTimeInterval(121))
precondition(stale.status == .unknown && stale.sourceHealth == .stale)
precondition(StatusNormalizer.normalize(raw: "done", evidence: .presenceOnly) == .unknown)
var gate = NotificationGate()
let blocked = TaskEvent(id: "demo-1", title: event.title, status: .blocked,
                        observedAt: now, updatedAt: now, evidence: .authoritative, sourceHealth: .connected)
precondition(gate.shouldNotify(blocked))
precondition(!gate.shouldNotify(blocked))
print("AgentIslandCore selftest passed: stale snapshots, weak evidence, and notification dedupe")
