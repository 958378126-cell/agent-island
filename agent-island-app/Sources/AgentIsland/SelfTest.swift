import Foundation

/// End-to-end checks for the public desktop build.
/// The checks intentionally cover runtime behavior without requiring private
/// theme assets or a live third-party account.
enum SelfTest {
    final class Report {
        private(set) var failures: [String] = []

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("  ✓ \(label)\(detail.isEmpty ? "" : "  \(detail)")")
            } else {
                print("  ✗ \(label)\(detail.isEmpty ? "" : "  \(detail)")")
                failures.append(label)
            }
        }
    }

    static func run(rootOverride: String? = nil) -> Bool {
        print("Agent Island public build self-test")
        let report = Report()
        guard let root = resolveRoot(rootOverride) else {
            print("  ✗ 找不到 Package.swift，请使用 --root 指定工程目录")
            return false
        }

        let manager = FileManager.default
        func exists(_ relative: String) -> Bool {
            manager.fileExists(atPath: root.appendingPathComponent(relative).path)
        }

        report.check("Package.swift 存在", exists("Package.swift"))
        report.check("完整 App 源码存在", exists("Sources/AgentIsland/main.swift"))
        report.check("中性头像视图存在", exists("Sources/AgentIsland/AvatarView.swift"))
        report.check("Codex 回放解析器存在", exists("Sources/AgentIsland/CodexRolloutParser.swift"))
        report.check("公开 App 不携带主题资源目录",
                     !exists("Sources/AgentIsland/Resources") && !exists("assets"))

        let fixture = RuntimePaths.fixtureURL(root: root)
        if let text = try? String(contentsOf: fixture, encoding: .utf8) {
            let tasks = TaskParser.parse(text: text)
            report.check("示例 JSONL 可解析", !tasks.isEmpty, "\(tasks.count) 个任务")
            report.check("示例任务状态合法", tasks.allSatisfy { TaskStatus.allCases.contains($0.status) })
        } else {
            report.check("示例 JSONL 可读取", false)
        }

        let activeRollout = """
        {"type":"event_msg","payload":{"type":"task_started","started_at":1760000000}}
        {"type":"event_msg","payload":{"type":"item_completed"}}
        """
        let finishedRollout = activeRollout + "\n{" + "\"type\":\"event_msg\",\"payload\":{\"type\":\"task_completed\"}}"
        report.check("Codex task_started 可识别为运行中", CodexRolloutParser.state(from: activeRollout).isActive)
        report.check("Codex task_completed 可结束运行态", !CodexRolloutParser.state(from: finishedRollout).isActive)
        report.check("Codex Desktop app-server 可识别",
                     ProcessProbe.isCodexCommand("/Applications/ChatGPT.app/Resources/codex app-server"))
        report.check("普通 codex 文本不会误报", !ProcessProbe.isCodexCommand("/usr/bin/echo codex"))
        report.check("状态头像不依赖私有图像", TaskStatus.running.avatarSymbolName == "sparkles")

        if report.failures.isEmpty {
            print("自检通过：\(root.path)")
            return true
        }
        print("自检失败：\(report.failures.count) 项")
        return false
    }

    private static func resolveRoot(_ override: String?) -> URL? {
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
        }
        if let env = ProcessInfo.processInfo.environment["AGENT_ISLAND_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath).standardizedFileURL
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var current = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }
}
