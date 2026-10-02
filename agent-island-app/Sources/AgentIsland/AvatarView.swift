import SwiftUI

/// Neutral, asset-free avatar used by the public build.
///
/// The state engine deliberately knows nothing about a character or brand. Users
/// can replace this view in a private theme layer without changing monitoring,
/// task parsing, or connector code.
struct AvatarView: View {
    let status: TaskStatus
    let agentKey: String?

    init(status: TaskStatus, agentKey: String? = nil) {
        self.status = status
        self.agentKey = agentKey
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            avatar
        } else {
            TimelineView(.animation(minimumInterval: status == .running ? 1.0 / 15.0 : 1.0,
                                    paused: false)) { context in
                avatar
                    .scaleEffect(pulse(at: context.date))
                    .rotationEffect(.degrees(status == .running ? sin(context.date.timeIntervalSinceReferenceDate * 12) * 3 : 0))
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let image = ThemeLoader.image(for: status) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(3)
        } else {
            Image(systemName: status.avatarSymbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: status.dotColorHex))
        }
    }

    private func pulse(at date: Date) -> CGFloat {
        guard status == .done || status == .queued else { return 1 }
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2)
        return 1 + CGFloat((1 - cos(phase / 3.2 * 2 * .pi)) * 0.015)
    }
}

/// Neutral status chip. It contains no bundled image or third-party artwork.
struct AgentAvatarChip: View {
    let status: TaskStatus
    let agentKey: String?
    let width: CGFloat
    let height: CGFloat

    init(status: TaskStatus, agentKey: String? = nil, width: CGFloat, height: CGFloat) {
        self.status = status
        self.agentKey = agentKey
        self.width = width
        self.height = height
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.10))
            AvatarView(status: status, agentKey: agentKey)
        }
        .frame(width: width, height: height)
    }
}
