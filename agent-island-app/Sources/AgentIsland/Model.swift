import Foundation
import SwiftUI

// MARK: - 任务状态

/// 任务状态：与 tasks.jsonl 中 status 字段一一对应
/// 同时承担「状态头像 / 光点颜色 / 优先级 / 是否通知」的唯一映射源（胶囊与面板同源）
enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case blocked
    case done
    case failed

    /// 把不同 Agent 的状态名统一到看板状态。
    /// 等待用户确认、授权或输入属于“需要用户处理”的阻塞态；看板只提醒，
    /// 不替用户执行确认动作。
    static func fromExternal(_ raw: String) -> TaskStatus? {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch value {
        case "queued", "pending", "creating", "planning":
            return .queued
        case "running", "working", "executing", "in_progress", "streaming":
            return .running
        case "waiting", "waiting_user", "awaiting_input", "input_required",
             "awaiting_confirmation", "waiting_confirmation", "waiting_for_confirmation", "needs_confirmation",
             "needs_approval", "approval_required", "permission_required", "paused",
             "blocked", "stalled":
            return .blocked
        case "done", "completed", "succeeded", "success", "terminated":
            return .done
        case "failed", "failure", "error", "cancelled", "canceled", "aborted", "stopped":
            return .failed
        default:
            return TaskStatus(rawValue: value)
        }
    }

    /// WorkBuddy 的 `pending` 在桌面任务列表里表示“待确认”，不是普通排队。
    /// 单独处理，避免影响其它 Agent 对 pending 的语义。
    static func fromWorkBuddy(_ raw: String) -> TaskStatus? {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if value == "pending" { return .blocked }
        return fromExternal(value)
    }

    /// 中文展示名
    var displayName: String {
        switch self {
        case .queued:  return "排队中"
        case .running: return "运行中"
        case .blocked: return "阻塞"
        case .done:    return "已完成"
        case .failed:  return "失败"
        }
    }

    /// 优先级权重，数值越大越优先
    /// SPEC 规定顺序：failed > blocked > running > queued > done
    var priority: Int {
        switch self {
        case .failed:  return 5
        case .blocked: return 4
        case .running: return 3
        case .queued:  return 2
        case .done:    return 1
        }
    }

    /// 状态光点颜色（十六进制，取自 SPEC 映射表）
    var dotColorHex: String {
        switch self {
        case .queued:  return "#a78bfa"
        case .running: return "#22d3ee"
        case .blocked: return "#fbbf24"
        case .done:    return "#4ade80"
        case .failed:  return "#f87171"
        }
    }

    /// 对应中性 SF Symbol；主题素材不参与状态机。
    var avatarSymbolName: String {
        switch self {
        case .queued:  return "clock.arrow.circlepath"
        case .done:    return "checkmark.circle.fill"
        case .running: return "sparkles"
        case .blocked: return "exclamationmark.triangle.fill"
        case .failed:  return "xmark.octagon.fill"
        }
    }

    /// 是否为终态（不再产生后续状态变化）
    var isTerminal: Bool { self == .done || self == .failed }

    /// 是否需要发系统通知（blocked 属低优先级，且只发一次）
    var shouldNotify: Bool { self == .done || self == .failed || self == .blocked }

    /// 通知标题里用的动词
    var notificationVerb: String {
        switch self {
        case .done:   return "任务完成"
        case .failed: return "任务失败"
        default:      return "任务阻塞"
        }
    }
}

/// 任务来源证据等级。它让看板可以把“真实回合”“本地状态回退”和“仅进程存在”分开。
enum TaskProvenance: String, Codable, Sendable, Hashable {
    /// Agent 自己提供了稳定任务/回合 ID 和状态信号。
    case official
    /// 没有可用官方接口时，从本机只读会话或日志推断出的活动。
    case local
    /// 只能确认进程存在，不能确认任务状态。
    case process

    var label: String {
        switch self {
        case .official: return "官方接口"
        case .local: return "本地只读"
        case .process: return "仅进程"
        }
    }
}

// MARK: - 任务条目

/// 折叠后的任务当前状态（同一 task_id 多条事件合并成一条）
struct TaskItem: Identifiable, Sendable, Hashable {
    /// 任务唯一标识（task_id）
    let id: String
    /// agent 键名（如 autoclaw）
    let agentKey: String
    /// 任务标题
    let title: String
    /// 进度备注
    let note: String
    /// 当前状态
    let status: TaskStatus
    /// 起始时间：首个 running 事件的 ts（无 running 事件时退化为首个事件 ts）
    let startedAt: Date
    /// 最近一次事件的时间
    let updatedAt: Date
    /// 任务状态的证据来源。tasks.jsonl 及旧数据默认为本地只读。
    let provenance: TaskProvenance

    /// 时长（秒）：按 SPEC 定义 = 最新事件 ts − startedAt（终态任务用这个值，是定格时间）
    var duration: TimeInterval { max(0, updatedAt.timeIntervalSince(startedAt)) }

    /// 时长文案（按 SPEC 公式）
    var durationText: String { DurationText.string(from: duration) }

    /// 面板里显示的时长：终态任务定格在 updatedAt − startedAt；
    /// 进行中任务按当前时间实时增长（SPEC 定义的是定格公式，这里对非终态做实时化，
    /// 否则「面板每 5 秒刷新时长」没有意义）
    func liveDuration(now: Date = Date()) -> TimeInterval {
        let end = status.isTerminal ? updatedAt : max(updatedAt, now)
        return max(0, end.timeIntervalSince(startedAt))
    }

    /// 面板时长文案（实时）
    func liveDurationText(now: Date = Date()) -> String {
        DurationText.string(from: liveDuration(now: now))
    }
}

/// 按 agent 分组后的看板数据
struct AgentGroup: Identifiable, Sendable {
    /// 组标识即 agent 键名
    let id: String
    /// 展示名（内置注册表或键名本身）
    let displayName: String
    /// 组颜色（十六进制）
    let colorHex: String
    /// 组内任务（已按优先级与开始时间排序）
    var tasks: [TaskItem]

    /// 组内活跃任务数（非终态任务）
    var activeCount: Int { tasks.filter { !$0.status.isTerminal }.count }

    /// 组内最高优先级状态（决定组头小圆点颜色）
    var topStatus: TaskStatus? {
        tasks.max(by: { $0.status.priority < $1.status.priority })?.status
    }
}

// MARK: - 事件高亮

/// 新事件到达时的胶囊高亮（描边亮状态色 3 秒）
struct FlashEvent: Sendable, Equatable {
    /// 触发高亮的状态（done 绿 / failed 红）
    let status: TaskStatus
    /// 自增序号，用于驱动 SwiftUI 的 onChange 去重
    let sequence: Int
}

// MARK: - 时长格式化

/// 把秒数格式化成中文时长文案
enum DurationText {
    static func string(from interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hour = total / 3600
        let minute = (total % 3600) / 60
        let second = total % 60
        if hour > 0 { return "\(hour)小时\(minute)分\(second)秒" }
        if minute > 0 { return "\(minute)分\(second)秒" }
        return "\(second)秒"
    }
}

// MARK: - 颜色扩展

extension Color {
    /// 从 #RRGGBB（或 RRGGBB）十六进制字符串构造颜色，解析失败返回灰色兜底
    init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self = .gray
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}

extension NSColor {
    /// AppKit 侧的十六进制颜色（用于 NSView / 面板背景等）
    static func fromHex(_ hex: String) -> NSColor {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            return .gray
        }
        return NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
