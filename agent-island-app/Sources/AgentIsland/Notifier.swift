import Foundation
import UserNotifications
import AppKit

/// 系统通知封装
/// SPEC 要求：done / failed 走 UNUserNotificationCenter；blocked 低优先级仅一次；**一律不发声**
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    /// 是否已获得通知授权
    private(set) var isAuthorized = false

    /// 通知是否可用
    ///
    /// 关键坑：SPM 裸可执行文件没有 Info.plist，也就没有 bundleIdentifier，
    /// 这时 `UNUserNotificationCenter.current()` 会直接抛
    /// `NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil`，进程当场崩。
    /// 因此只有在真正打包成 .app（或用 Scripts/make-app.sh 产出）时才启用通知，
    /// 未打包时降级为「只做胶囊高亮/抖动，不发通知」，保证启动不崩。
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    override init() {
        super.init()
    }

    /// 首次运行请求通知权限（系统授权弹窗，属正常行为）
    func requestAuthorization() {
        guard isAvailable else {
            print("[AgentIsland] 未打包为 .app（无 bundleIdentifier），跳过通知授权；")
            print("[AgentIsland] 需要通知请执行 Scripts/make-app.sh 生成 dist/AgentIsland.app 后运行。")
            return
        }
        let center = UNUserNotificationCenter.current()
        // 让自己成为通知中心代理，才能收到「点击通知」回调
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge]) { [weak self] granted, error in
            if let error {
                print("[AgentIsland] 通知授权失败：\(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self?.isAuthorized = granted
            }
        }
    }

    /// 发送一条静默通知
    /// - Parameters:
    ///   - title: 通知标题，格式「{Agent名} · 任务完成/失败」
    ///   - body: 通知正文 = 任务名 + 备注
    ///   - identifier: 去重标识（task_id + 状态）
    ///   - isUrgent: done/failed 为紧急；blocked 为低优先级
    func post(title: String, body: String, identifier: String, isUrgent: Bool) {
        // 未打包为 .app 时静默降级（只在首次提示一次，不刷屏）
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // 用户明确关掉音效：这里显式置空，且授权选项里不带 .sound
        content.sound = nil
        content.interruptionLevel = isUrgent ? .active : .passive

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[AgentIsland] 通知投递失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前台时也要展示横幅（否则通知会被系统吞掉）
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    /// 点击通知：P1 先激活终端窗口，不做精确跳转
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        TerminalLauncher.open()
        completionHandler()
    }
}
