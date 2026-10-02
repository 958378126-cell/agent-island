import Foundation

/// Agent 注册表：内置 Agent 的展示名、配色与中性状态文案。
/// 这里不绑定任何第三方角色或图像；用户可以在自己的主题层替换视觉元素。
enum AgentRegistry {

    /// 内置 agent 键 → 展示名
    static let knownAgents: [String: String] = [
        "autoclaw":  "AutoClaw",
        "codex":     "Codex",
        "workbuddy": "WorkBuddy",
        "doubao":    "豆包",
        "grokbot":   "Grokbot"
    ]

    /// 8 色循环调色板（SPEC 给定）
    private static let palette: [String] = [
        "#0ea5b7", "#8b8bf4", "#e0885a", "#9aa4b2",
        "#e0c65a", "#7fb069", "#c586c0", "#d17a7a"
    ]

    /// 展示名：内置 agent 用注册名，未知 agent 回退为键名
    static func displayName(for key: String) -> String {
        knownAgents[key] ?? key
    }

    /// 颜色（十六进制）：内置 agent 按注册顺序稳定取色；
    /// 未知 agent 用键名做稳定哈希后取模，保证同一键名每次运行颜色一致
    static func colorHex(for key: String) -> String {
        let orderedKeys = knownAgents.keys.sorted()
        if let index = orderedKeys.firstIndex(of: key) {
            return palette[index % palette.count]
        }
        var hash = 0
        for byte in key.utf8 {
            hash = (hash &* 31 &+ Int(byte)) & 0x7FFF_FFFF
        }
        return palette[abs(hash) % palette.count]
    }

    /// 运行中显示的中性文案；主题素材不参与状态判断。
    static func workingCaption(for key: String) -> String {
        switch key.split(separator: ":").first.map(String.init)?.lowercased() ?? key.lowercased() {
        case "codex": return "正在处理"
        case "workbuddy": return "正在协作"
        case "autoclaw": return "正在执行"
        case "doubao": return "正在回答"
        default: return "正在工作"
        }
    }
}
