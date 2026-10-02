import Foundation

enum LaunchOptions {
    static var isSmoke: Bool { CommandLine.arguments.contains("--smoke") }
    static var isSoak: Bool { CommandLine.arguments.contains("--soak") }
    static var isDemo: Bool { CommandLine.arguments.contains("--demo") }
    static var smokeSeconds: TimeInterval {
        guard let i = CommandLine.arguments.firstIndex(of: "--smoke"), i + 1 < CommandLine.arguments.count, let v = Double(CommandLine.arguments[i + 1]) else { return 3 }
        return max(1, v)
    }
    static var soakSeconds: TimeInterval {
        guard let i = CommandLine.arguments.firstIndex(of: "--soak"), i + 1 < CommandLine.arguments.count, let v = Double(CommandLine.arguments[i + 1]) else { return 1800 }
        return max(5, v)
    }
    static func rootOverride(from arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "--root"), i + 1 < arguments.count else { return nil }
        let value = arguments[i + 1]
        return value.isEmpty ? nil : value
    }
    static func printUsage() {
        print("""
        Agent Island —— macOS 顶部悬浮胶囊，多 Agent 任务看板

        用法:
          AgentIsland                   启动悬浮胶囊 App
          AgentIsland --selftest        自检并退出
          AgentIsland --smoke [秒数]    冒烟启动并自动退出（默认 3 秒）
          AgentIsland --soak [秒数]     多任务/高亮长跑压测（默认 1800 秒）
          AgentIsland --demo             显式加载仓库内演示事件（不会用于真实运行）
          AgentIsland --help            显示本帮助
        """)
    }
}
