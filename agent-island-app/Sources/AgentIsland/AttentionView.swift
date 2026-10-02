import AppKit
import SwiftUI

/// 任务需要用户二次确认时的应用内提醒。
///
/// 这里只负责说明“哪个任务在等确认”并把用户带回对应 Agent，
/// 不在看板里自动批准任何命令、权限或文件修改。
struct AttentionView: View {

    let task: TaskItem
    let onOpenAgent: () -> Void
    let onDismiss: () -> Void

    private var agentName: String { AgentRegistry.displayName(for: task.agentKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                AgentAvatarChip(status: .blocked, width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("需要你确认")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("\(agentName) 有一个任务正在等待继续")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.66))
                }

                Spacer(minLength: 4)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(task.note.isEmpty ? "请打开 Agent 查看确认内容" : task.note)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.52))
                    .lineLimit(2)
            }
            .padding(.leading, 58)

            HStack(spacing: 8) {
                Spacer()
                Button("稍后处理", action: onDismiss)
                    .buttonStyle(AttentionSecondaryButtonStyle())
                Button("打开 \(agentName)", action: onOpenAgent)
                    .buttonStyle(AttentionPrimaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 410)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 25 / 255, green: 25 / 255, blue: 28 / 255, opacity: 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(hex: TaskStatus.blocked.dotColorHex).opacity(0.78), lineWidth: 1.2)
        )
        .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
    }
}

private struct AttentionPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.86))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(hex: TaskStatus.blocked.dotColorHex).opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(Capsule())
    }
}

private struct AttentionSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.55 : 0.78))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.05))
            .clipShape(Capsule())
    }
}
