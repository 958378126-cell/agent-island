import Foundation
import AppKit

/// 胶囊位置持久化
/// SPEC：位置存 ~/Library/Application Support/AgentIsland/position.json
enum PositionStore {

    /// 落盘结构：记录胶囊窗口左下角原点（Cocoa 坐标系）
    private struct Payload: Codable {
        var x: Double
        var y: Double
    }

    /// 应用支持目录，不存在时自动创建
    private static var directory: URL { RuntimePaths.applicationSupportDirectory }

    static var fileURL: URL {
        directory.appendingPathComponent("position.json")
    }

    /// 读取上次保存的位置；没有记录或数据非法时返回 nil（调用方回退到默认居中位置）
    static func load() -> CGPoint? {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let point = CGPoint(x: payload.x, y: payload.y)
        // 坐标必须是有限值，避免脏数据把窗口扔到屏幕外
        guard point.x.isFinite, point.y.isFinite else { return nil }
        // 钳制到任意已连接屏幕的可视范围内：防止外接屏拔掉 / 分辨率变化后胶囊消失
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return point }
        let visibleUnion = screens.reduce(NSRect.zero) { $0.union($1.visibleFrame) }
        guard visibleUnion.intersects(NSRect(origin: point, size: CGSize(width: 10, height: 10))) else {
            return nil // 位置完全落在屏幕外 → 回退默认居中
        }
        return point
    }

    /// 保存当前位置（拖动结束后调用）
    static func save(_ point: CGPoint) {
        let payload = Payload(x: Double(point.x), y: Double(point.y))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 数据文件路径选择
enum TaskFilePath {
    /// 优先级：显式环境变量 > 显式 Demo fixture > Application Support。
    /// 正常启动绝不扫描源码 checkout，避免把开发机样例或真实任务带入安装版。
    static func resolve(root: URL? = nil, demo: Bool = false) -> String {
        if let override = ProcessInfo.processInfo.environment["AGENT_ISLAND_TASKS"],
           !override.isEmpty {
            return override
        }
        if demo, let root {
            return RuntimePaths.fixtureURL(root: root).path
        }
        return RuntimePaths.tasksURL.path
    }
}

/// 终端激活工具（点击任务行 / 点击通知时使用）
enum TerminalLauncher {
    /// P1 只做「激活终端 App」，不做精确窗口跳转
    static func open() {
        let run: @Sendable () -> Void = {
            let candidates = [
                "/System/Applications/Utilities/Terminal.app",
                "/Applications/Utilities/Terminal.app"
            ]
            for path in candidates where FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                return
            }
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }
}

/// 从提醒里尽量打开对应 Agent。若本机没有可识别的桌面 App，则回退到终端，
/// 保证“打开处理”按钮仍然有可用出口；不修改 Agent 状态，也不自动确认。
enum AgentLauncher {

    /// 每个 Agent 的桌面 App 标识。**优先按 bundle id 匹配**：它稳定、不随系统
    /// 语言变，也不会误命中同名的辅助进程（例如「自动填充 (WorkBuddy)」这类 XPC）。
    /// App 名只在拿不到 bundle id 时兜底。
    private struct Target {
        let bundleIdentifier: String?
        let appNames: [String]
    }

    private static let targets: [String: Target] = [
        "workbuddy": Target(bundleIdentifier: "com.workbuddy.workbuddy", appNames: ["WorkBuddy"]),
        "autoclaw": Target(bundleIdentifier: "com.zhipuai.autoclaw", appNames: ["AutoClaw", "QClaw"]),
        "doubao": Target(bundleIdentifier: "com.bot.neotix.doubao", appNames: ["Doubao", "豆包"]),
        "codex": Target(bundleIdentifier: nil, appNames: ["Codex"])
    ]

    static func open(for agentKey: String) {
        let key = agentKey.split(separator: ":").first.map(String.init)?.lowercased() ?? agentKey.lowercased()
        guard let target = targets[key] else {
            TerminalLauncher.open()
            return
        }

        if let running = runningApplication(for: target) {
            bringToFront(running)
            return
        }

        if let url = installedURL(for: target) {
            launchAndActivate(url)
            return
        }

        TerminalLauncher.open()
    }

    /// 交给系统的 `open` 启动并激活。
    ///
    /// 它走 LaunchServices，等价于用户在 Dock / 访达里点开这个 App，因此在
    /// Agent Island 自己不是前台的环境下也能保证 App 被提到最前 ——
    /// 这是实测下来最稳的一条路（`NSWorkspace.openApplication(activates: true)`
    /// 在非前台环境下不一定会激活已运行的实例）。
    private static func launchAndActivate(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path]
        try? process.run()
    }

    // MARK: - 定位

    private static func runningApplication(for target: Target) -> NSRunningApplication? {
        // 只考虑能上屏的 App，避开同名后台辅助进程。
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
        if let bundleID = target.bundleIdentifier,
           let app = running.first(where: { $0.bundleIdentifier == bundleID }) {
            return app
        }
        guard !target.appNames.isEmpty else { return nil }
        return running.first { app in
            guard let name = app.localizedName else { return false }
            return target.appNames.contains { name.caseInsensitiveCompare($0) == .orderedSame }
        }
    }

    private static func installedURL(for target: Target) -> URL? {
        if let bundleID = target.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = target.appNames.flatMap {
            ["/Applications/\($0).app", "\(home)/Applications/\($0).app"]
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - 置前

    /// 把已在运行的 App 提到最前，包括被最小化或隐藏的窗口。
    ///
    /// 只调 `activate(options: [])` 是原来「点了按钮窗口不上来」的原因：它只是让
    /// App 激活，不会把被最小化/藏在后面的窗口抬上来；而悬浮面板是
    /// `.nonactivatingPanel`，点它不会激活 Agent Island 本身，在 macOS 14+ 的
    /// 协作式激活策略下一个非前台 App 的 activate 请求还可能被直接忽略。
    private static func bringToFront(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }

        // 第一步：把激活权拿到自己手里，再转交给目标。
        if #available(macOS 14.0, *) {
            NSApp.activate()
            app.activate(from: .current, options: [.activateAllWindows])
        } else {
            NSApp.activate(ignoringOtherApps: true)
            app.activate(options: [.activateAllWindows])
        }

        // 第二步：再走一次系统的 open。`activate` 只保证 App 成为最前台，并不保证
        // 它的窗口被抬上来 —— 窗口被最小化、或停在别的桌面时，就会出现「App 已经
        // 激活但窗口没上来」。open 会给目标发 reopen 事件，是真正把主窗口叫回来的
        // 那一步；交给 LaunchServices 也和用户在 Dock / 访达里点开等价。
        //
        // 注意这里**不能**加「已经是最前台就跳过」的判断：症状恰恰是已经最前台、
        // 但窗口不在，跳过就正好把唯一有效的补救动作漏掉了。
        guard let url = app.bundleURL ?? app.executableURL else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            launchAndActivate(url)
        }
    }
}
