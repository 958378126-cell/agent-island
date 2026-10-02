import Foundation

struct CodexRolloutState: Sendable {
    let isActive: Bool
    let startedAt: Date?
}

/// Parser for the event envelope written by Codex Desktop and Codex CLI.
/// Keeping this pure makes the detector testable without launching the app.
enum CodexRolloutParser {
    static func state(from text: String) -> CodexRolloutState {
        var isActive = false
        var latestStartedAt: Date?

        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }

            switch type {
            case "task_started", "turn_started":
                isActive = true
                latestStartedAt = eventDate(payload["started_at"] ?? payload["started_at_ms"] ?? object["timestamp"])
            case "task_complete", "task_completed", "turn_complete", "turn_completed", "turn_aborted":
                isActive = false
            default:
                // Progress, token-count and item events preserve the latest
                // start state; they are not terminal signals by themselves.
                continue
            }
        }

        return CodexRolloutState(isActive: isActive, startedAt: isActive ? latestStartedAt : nil)
    }

    private static func eventDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1_000 : raw)
        }
        if let string = value as? String { return DateParser.parse(string) }
        return nil
    }
}
