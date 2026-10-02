import SwiftUI

// MARK: - 展开面板布局

/// 展开面板高度估算（不超过 640，超出部分滚动）
enum PanelLayout {
    static let width: CGFloat = 500
    static let maxHeight: CGFloat = 640
    static let minHeight: CGFloat = 120

    static func height(groups: [AgentGroup]) -> CGFloat {
        if groups.isEmpty { return 140 }
        var height: CGFloat = 20 // 上下内边距
        for group in groups {
            // 状态头像放大到 64x64 后，给每行预留对应高度，避免
            // 文字和状态图在面板里互相挤压。
            height += 26 + CGFloat(group.tasks.count) * 82
        }
        height += 34 // 底部 foot
        return min(maxHeight, max(minHeight, height))
    }
}

// MARK: - 展开面板

/// 展开态面板：按 agent 分组展示任务行
struct DetailView: View {

    @ObservedObject var store: TaskStore
    /// 点击「＋ 添加 Agent」入口
    let onAddAgent: () -> Void
    /// 点击任务行：跳转到终端
    let onOpenTask: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if store.groups.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(store.groups) { group in
                            section(group)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
                .background(Color.white.opacity(0.10))

            foot
        }
        .frame(width: PanelLayout.width)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 22 / 255, green: 22 / 255, blue: 24 / 255, opacity: 0.96))
        )
    }

    // MARK: 分组

    private func section(_ group: AgentGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 组头：11px 等宽大写 + 右侧活跃数
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(Color(hex: group.colorHex))
                    .frame(width: 7, height: 7)
                Text(group.displayName.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
                Spacer()
                Text("活跃 \(group.activeCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            ForEach(group.tasks) { task in
                row(task)
            }
        }
    }

    // MARK: 任务行

    private func row(_ task: TaskItem) -> some View {
        Button(action: onOpenTask) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(Color(hex: task.status.dotColorHex))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(task.status == .running
                        ? AgentRegistry.workingCaption(for: task.agentKey)
                         : task.status.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(hex: task.status.dotColorHex).opacity(0.92))
                        .lineLimit(1)
                    Text(task.note.isEmpty ? task.provenance.label : task.note)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.48))
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 6)

                AgentAvatarChip(status: task.status, agentKey: task.agentKey, width: 64, height: 64)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(task.liveDurationText())
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.72))
                    Text(task.status.displayName)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(0.34))
                }
                .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 空态与底部

    private var emptyState: some View {
        VStack(spacing: 8) {
            AgentAvatarChip(status: .queued, width: 46, height: 46)
            Text("暂无任务")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var foot: some View {
        HStack(spacing: 8) {
            Text("tasks.jsonl")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.38))
            Spacer()
            Text("点击行跳转")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.38))
            Text("·")
                .foregroundStyle(Color.white.opacity(0.25))
            Button(action: onAddAgent) {
                Text("＋ 添加 Agent 接口")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.62))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}
