import AppKit
import SwiftUI

enum CapsuleMetrics {
    static let height: CGFloat = 52
    static let minWidth: CGFloat = 190
    static let maxWidth: CGFloat = 460
    static let rowHeight: CGFloat = 40
    static let horizontalInset: CGFloat = 16
    /// 行内固定元素的尺寸，用来把胶囊宽度算准（与 row(_:now:) 里的实际取值一致）。
    static let avatarChipWidth: CGFloat = 40
    static let terminalAvatarChipWidth: CGFloat = 56
    static let statusDotWidth: CGFloat = 8
    static let rowSpacing: CGFloat = 8
    /// Spacer(minLength:) 的最小值。
    static let spacerMinWidth: CGFloat = 2
    /// 右侧状态语 + 时长的宽度上限。
    static let maxTrailingWidth: CGFloat = 118

    /// 行内不可伸缩部分：左右内边距 + 状态头像 + 5 段间距 + Spacer 最小值 + 状态圆点。
    private static var chromeWidth: CGFloat {
        horizontalInset * 2 + avatarChipWidth + statusDotWidth + rowSpacing * 5 + spacerMinWidth
    }

    static func title(for item: TaskItem?) -> String {
        guard let item else { return "暂无任务" }
        return "\(AgentRegistry.displayName(for: item.agentKey)) · \(item.status.displayName) · \(item.title)"
    }

    /// 行尾的状态语：运行中显示 Agent 专属的中性状态语，其余状态显示状态名。
    static func trailingCaption(for item: TaskItem) -> String {
        item.status == .running ? AgentRegistry.workingCaption(for: item.agentKey) : item.status.displayName
    }

    private static func measuredWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight)]
        return ceil(NSAttributedString(string: text, attributes: attributes).size().width)
    }

    private static func measuredMonoWidth(_ text: String, size: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)]
        return ceil(NSAttributedString(string: text, attributes: attributes).size().width)
    }

    /// 单行真实需要的宽度。
    ///
    /// 长标题由 maxWidth 封顶、超出部分交给标题自己截断；关键是给 Agent 名、
    /// 右侧状态语和时长留出**固定**宽度 —— 它们一旦被压缩，Text 会逐字换行，
    /// 在 40pt 高的行里变成一列竖排碎字（英文名“被挡住”就是这个原因）。
    static func requiredWidth(for item: TaskItem) -> CGFloat {
        let name = measuredWidth(AgentRegistry.displayName(for: item.agentKey), size: 10.5, weight: .semibold)
        let title = measuredWidth(item.title, size: 11.5, weight: .medium)
        let trailing = min(
            maxTrailingWidth,
            max(measuredWidth(trailingCaption(for: item), size: 8.5, weight: .medium),
                measuredMonoWidth(item.liveDurationText(), size: 9.5))
        )
        return chromeWidth + name + title + trailing
    }

    static func width(for items: [TaskItem], extraCount: Int) -> CGFloat {
        let needed: CGFloat
        if items.isEmpty {
            // 空态与完成提示共用同一个胶囊宽度。
            let idle = horizontalInset * 2 + measuredWidth("暂无任务", size: 12.5, weight: .medium)
            let allDone = horizontalInset * 2 + terminalAvatarChipWidth + 10
                + max(
                    measuredWidth("人 活干完了", size: 12.5, weight: .medium),
                    measuredWidth("状态已完成", size: 12.5, weight: .medium)
                ) + 10 + 9
            needed = max(idle, allDone)
        } else {
            var widest = items.map(requiredWidth(for:)).max() ?? minWidth
            if extraCount > 0 {
                // 「还有 N 个任务…」左侧有 36pt 缩进，只占一段文字。
                let extra = horizontalInset * 2 + 36
                    + measuredWidth("还有 \(extraCount) 个任务…", size: 11, weight: .medium)
                widest = max(widest, extra)
            }
            needed = widest
        }
        return min(maxWidth, max(minWidth, ceil(needed)))
    }

    static func height(rowCount: Int) -> CGFloat {
        rowCount <= 0 ? height : max(height, 16 + CGFloat(rowCount) * rowHeight)
    }

    static func cornerRadius(rowCount: Int) -> CGFloat {
        // 单行仍然保持胶囊感；多行改用更方的圆角，四个角都能包住文字。
        rowCount <= 1 ? 26 : 22
    }
}

struct CapsuleView: View {
    @ObservedObject var store: TaskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [TaskItem] { Array(store.capsuleTasks.prefix(3)) }
    private var extraCount: Int { max(0, store.capsuleTasks.count - rows.count) }
    private var rowCount: Int { rows.isEmpty ? 0 : rows.count + (extraCount > 0 ? 1 : 0) }
    private var isAllTerminal: Bool { store.capsuleTasks.isEmpty && store.hasFinishedWork }
    private var status: TaskStatus { store.primary?.status ?? .queued }

    var body: some View {
        TimelineView(.animation(minimumInterval: motionInterval, paused: reduceMotion || !needsTimeline)) { context in
            capsule(at: context.date)
        }
    }

    private var needsTimeline: Bool {
        guard !reduceMotion else { return false }
        if store.flashDeadline != nil || store.shakeDeadline != nil { return true }
        return !rows.isEmpty && rows.contains { $0.status == .running || $0.status == .blocked || $0.status == .failed }
    }

    private var motionInterval: TimeInterval {
        if store.flashDeadline != nil || store.shakeDeadline != nil { return 1.0 / 20.0 }
        if rows.contains(where: { $0.status == .failed }) { return 1.0 / 20.0 }
        if rows.contains(where: { $0.status == .running }) { return 1.0 / 15.0 }
        return 1.0
    }

    private func capsule(at now: Date) -> some View {
        let flashRemain = store.flashDeadline.map { $0.timeIntervalSince(now) } ?? 0
        let glow = CGFloat(max(0, min(1, flashRemain / 3.0)))
        let shakeRemain = store.shakeDeadline.map { $0.timeIntervalSince(now) } ?? 0
        let shakeX: CGFloat = shakeRemain > 0 ? CGFloat(sin(shakeRemain * 38)) * 6 * CGFloat(shakeRemain / 0.62) : 0
        let glowColor = Color(hex: (store.flashStatus ?? status).dotColorHex)
        let shape = RoundedRectangle(cornerRadius: CapsuleMetrics.cornerRadius(rowCount: rowCount), style: .continuous)

        return Group {
            if isAllTerminal {
                HStack(spacing: 10) {
                    AgentAvatarChip(status: .done, width: 56, height: 46)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("人 活干完了")
                        Text("状态已完成")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    Circle().fill(Color(hex: TaskStatus.done.dotColorHex)).frame(width: 9, height: 9)
                        .shadow(color: Color(hex: TaskStatus.done.dotColorHex).opacity(0.9), radius: 5)
                }
            } else if rows.isEmpty {
                Text("暂无任务").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { item in row(item, now: now) }
                    if extraCount > 0 {
                        Text("还有 \(extraCount) 个任务…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .lineLimit(1)
                            .frame(height: CapsuleMetrics.rowHeight)
                            .padding(.leading, 36)
                    }
                }
            }
        }
        .padding(.horizontal, CapsuleMetrics.horizontalInset)
        .padding(.vertical, rows.isEmpty ? 3 : 8)
        .frame(height: CapsuleMetrics.height(rowCount: rowCount))
        .frame(maxWidth: .infinity)
        .background(shape.fill(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255, opacity: 0.92)))
        .overlay(shape.stroke(glowColor.opacity(glow), lineWidth: 1.6))
        .offset(x: reduceMotion ? 0 : shakeX)
    }

    private func row(_ item: TaskItem, now: Date) -> some View {
        HStack(spacing: CapsuleMetrics.rowSpacing) {
            AgentAvatarChip(status: item.status, agentKey: item.agentKey, width: CapsuleMetrics.avatarChipWidth, height: 34)
            // Agent 名、行尾状态语和时长都必须单行完整显示。它们一旦被压缩，Text 会
            // 逐字换行，在 40pt 高的行里变成一列竖排碎字（英文名“被挡住”就是这个原因）。
            // 这里给它们比标题更高的布局优先级：HStack 会先把理想宽度分给它们，
            // 剩下的才轮到标题，压缩与截断全部由标题承担。胶囊总宽由
            // CapsuleMetrics.width 算准，正常情况下三者都能完整显示；
            // 万一测算有偏差，它们也只会省略号截断，不会溢出被裁掉。
            Text(AgentRegistry.displayName(for: item.agentKey))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(1)
                .layoutPriority(2)
            Text(item.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: CapsuleMetrics.spacerMinWidth)
            VStack(alignment: .trailing, spacing: 0) {
                Text(CapsuleMetrics.trailingCaption(for: item))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .lineLimit(1)
                Text(item.liveDurationText(now: now))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .lineLimit(1)
            }
            .frame(maxWidth: CapsuleMetrics.maxTrailingWidth, alignment: .trailing)
            .layoutPriority(2)
            Circle()
                .fill(Color(hex: item.status.dotColorHex))
                .frame(width: CapsuleMetrics.statusDotWidth, height: CapsuleMetrics.statusDotWidth)
                .shadow(color: Color(hex: item.status.dotColorHex).opacity(0.85), radius: 4)
        }
        .frame(height: CapsuleMetrics.rowHeight)
    }
}
