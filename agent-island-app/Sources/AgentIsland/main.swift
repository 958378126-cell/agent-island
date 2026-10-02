import AppKit
import Foundation

// MARK: - 命令行入口
//
// Agent Island 有三种运行方式：
//   1) 无参数运行        → 启动顶部居中悬浮胶囊 App（NSApplication，accessory 模式，无 Dock 图标）
//   2) --selftest        → 跑内置自检（工程资产 + Demo fixture 校验），打印报告后退出
//   3) --smoke [秒数]    → 冒烟启动：真实建 UI、读数据、挂监听，N 秒后自动退出（用于自动化验证不崩）

let cliArguments = Array(CommandLine.arguments.dropFirst())

if cliArguments.contains("--help") || cliArguments.contains("-h") {
    LaunchOptions.printUsage()
    exit(0)
}

if cliArguments.contains("--selftest") || cliArguments.contains("--self-test") {
    let rootOverride = LaunchOptions.rootOverride(from: cliArguments)
    let passed = SelfTest.run(rootOverride: rootOverride)
    exit(passed ? 0 : 1)
}

// 全局持有 AppController：NSApplication.delegate 是 weak，必须有强引用兜住
nonisolated(unsafe) var appController: AppController?

@MainActor func bootstrapApplication() {
    let app = NSApplication.shared
    let controller = AppController()
    appController = controller
    app.delegate = controller
    // 纯悬浮胶囊：不进 Dock、不显示菜单栏
    app.setActivationPolicy(.accessory)
}

bootstrapApplication()
NSApplication.shared.run()
