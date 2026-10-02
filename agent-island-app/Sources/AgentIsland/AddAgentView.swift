import SwiftUI

/// 设置界面：把用户填写的连接信息转换成 ConnectorSpec。
/// 这里不保存密钥，只保存环境变量名；连接器仍然只读轮询。
struct AddAgentView: View {
    let onSave: (ConnectorSpec) -> String?
    let onCancel: () -> Void

    @State private var id = ""
    @State private var displayName = ""
    @State private var type: ConnectorType = .httpJSON
    @State private var endpoint = ""
    @State private var tokenEnvironment = ""
    @State private var localPath = ""
    @State private var command = ""
    @State private var arguments = ""
    @State private var statusMapText = "working=running, success=done, error=failed"
    @State private var provenanceRaw = TaskProvenance.official.rawValue
    @State private var pollSeconds = "10"
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    identityFields
                    connectionFields
                    mappingFields
                    helpText
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            Divider().background(Color.white.opacity(0.12))
            footer
        }
        .frame(width: 540, height: 610)
        .background(Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255))
        .preferredColorScheme(.dark)
        .onChange(of: type) { _, newType in
            provenanceRaw = newType == .httpJSON
                ? TaskProvenance.official.rawValue
                : TaskProvenance.local.rawValue
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text("添加 Agent 接口")
                    .font(.system(size: 18, weight: .semibold))
                Text("保存后立即开始只读轮询")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(Color.white.opacity(0.035))
    }

    private var identityFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("基本信息")
            field("Agent ID", text: $id, placeholder: "kimi-hosted")
            field("显示名称", text: $displayName, placeholder: "Kimi Hosted Agent")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    label("连接方式")
                    Picker("连接方式", selection: $type) {
                        ForEach(ConnectorType.allCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 5) {
                    label("轮询秒数")
                    TextField("10", text: $pollSeconds)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("连接参数")
            switch type {
            case .httpJSON:
                field("只读 GET 地址", text: $endpoint, placeholder: "https://example.com/api/tasks")
                field("令牌环境变量（可选）", text: $tokenEnvironment, placeholder: "MY_AGENT_TOKEN")
            case .jsonlFile:
                field("JSONL 文件路径", text: $localPath, placeholder: "~/Library/Application Support/MyAgent/tasks.jsonl")
            case .commandJSONL:
                field("适配器命令", text: $command, placeholder: "/absolute/path/to/adapter")
                field("命令参数（空格分隔）", text: $arguments, placeholder: "--fixture /path/to/state.json")
            }
        }
    }

    private var mappingFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("状态与证据")
            field("状态映射（逗号分隔）", text: $statusMapText, placeholder: "working=running, success=done")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    label("来源证据")
                    Picker("来源证据", selection: $provenanceRaw) {
                        Text("官方接口").tag(TaskProvenance.official.rawValue)
                        Text("本地只读").tag(TaskProvenance.local.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                Spacer()
            }
        }
    }

    private var helpText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("安全提示")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.62))
            Text("这里只保存连接配置和环境变量名，不保存 API Key。适配器必须输出 task_id、title、status、started_at、updated_at JSONL；进程消失不会被判定为完成。")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
            }
            HStack {
                Text("同一个 Agent ID 会更新已有配置")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.35))
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存并连接") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func sectionTitle(_ value: String) -> some View {
        Text(value.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.cyan.opacity(0.8))
    }

    private func label(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11))
            .foregroundStyle(Color.white.opacity(0.58))
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            label(title)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedID.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else {
            errorMessage = "Agent ID 不能为空，只能使用字母、数字、-、_、."
            return
        }
        guard !trimmedName.isEmpty else {
            errorMessage = "请填写显示名称。"
            return
        }
        guard let seconds = Double(pollSeconds.trimmingCharacters(in: .whitespacesAndNewlines)), seconds >= 3 else {
            errorMessage = "轮询秒数必须是至少 3 秒的数字。"
            return
        }

        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = localPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .httpJSON:
            guard let url = URL(string: trimmedEndpoint), ["http", "https"].contains(url.scheme?.lowercased()) else {
                errorMessage = "请填写合法的 http 或 https 地址。"
                return
            }
        case .jsonlFile:
            guard !trimmedPath.isEmpty else { errorMessage = "请填写 JSONL 文件路径。"; return }
        case .commandJSONL:
            guard !trimmedCommand.isEmpty else { errorMessage = "请填写适配器命令路径。"; return }
        }

        var mapping: [String: String] = [:]
        for pair in statusMapText.split(separator: ",") {
            let pieces = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard pieces.count == 2, !pieces[0].isEmpty, TaskStatus(rawValue: pieces[1]) != nil else {
                errorMessage = "状态映射格式应为 source=queued/running/blocked/done/failed。"
                return
            }
            mapping[pieces[0]] = pieces[1]
        }

        let spec = ConnectorSpec(
            id: trimmedID,
            displayName: trimmedName,
            type: type,
            url: type == .httpJSON ? trimmedEndpoint : nil,
            path: type == .jsonlFile ? trimmedPath : nil,
            command: type == .commandJSONL ? trimmedCommand : nil,
            arguments: type == .commandJSONL ? arguments.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) : nil,
            tokenEnvironment: type == .httpJSON ? tokenEnvironment.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty : nil,
            headers: nil,
            statusMap: mapping.isEmpty ? nil : mapping,
            provenance: TaskProvenance(rawValue: provenanceRaw) ?? .local,
            pollSeconds: seconds,
            timeoutSeconds: nil,
            maxOutputBytes: nil,
            enabled: true
        )
        if let failure = onSave(spec) {
            errorMessage = failure
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
