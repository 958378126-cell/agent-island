import Foundation
import AgentIslandCore

@inline(__always) func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

check(StatusNormalizer.normalize(raw: "completed", evidence: .presenceOnly) == .unknown,
      "presence cannot become succeeded")
check(StatusNormalizer.normalize(raw: "failed", evidence: .presenceOnly) == .unknown,
      "presence cannot become failed")
check(StatusNormalizer.normalize(raw: "cancelled", evidence: .authoritative) == .canceled,
      "cancellation remains cancellation")
let timestamp = Date(timeIntervalSince1970: 100)
let running = TaskEvent(id: "x", title: "x", status: .running,
                       observedAt: timestamp, updatedAt: timestamp,
                       evidence: .derived, sourceHealth: .connected)
let stale = running.withHealth(at: Date(timeIntervalSince1970: 221))
check(stale.status == .unknown && stale.sourceHealth == .stale,
      "stale running snapshot becomes unknown")
var gate = NotificationGate()
let done = TaskEvent(id: "x", title: "x", status: .succeeded,
                     observedAt: timestamp, updatedAt: timestamp,
                     evidence: .authoritative, sourceHealth: .connected)
check(gate.shouldNotify(done), "first terminal event notifies")
check(!gate.shouldNotify(done), "duplicate terminal event is deduped")
check(!gate.shouldNotify(done, isHistoricalImport: true), "historical import is quiet")
var blockedGate = NotificationGate()
let blocked = TaskEvent(id: "b", title: "b", status: .blocked,
                        observedAt: timestamp, updatedAt: timestamp,
                        evidence: .authoritative, sourceHealth: .connected)
let resumed = TaskEvent(id: "b", title: "b", status: .running,
                        observedAt: timestamp, updatedAt: timestamp,
                        evidence: .authoritative, sourceHealth: .connected)
check(blockedGate.shouldNotify(blocked), "first blocked transition notifies")
check(!blockedGate.shouldNotify(blocked), "duplicate blocked state is quiet")
check(!blockedGate.shouldNotify(resumed), "running state is quiet")
check(blockedGate.shouldNotify(blocked), "re-entering blocked notifies")
print("AgentIslandCore regression checks passed")
