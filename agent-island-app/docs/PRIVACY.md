# 隐私说明（开发预览）

Agent Island 的设计目标是本机优先、只读观察。默认数据目录为 `~/Library/Application Support/AgentIsland/`；仓库中的 `examples/` 只放虚构事件。环境变量 `AGENT_ISLAND_TASKS` 仅用于测试或受控 wrapper 覆盖路径，不应指向包含真实凭证的文件。

连接器应只读取完成任务状态所需的字段：稳定任务 ID、标题、状态、更新时间、来源健康和证据等级。官方 token 通过环境变量或系统安全存储提供，不写入日志、fixture、截图或诊断报告。带 token 的远程请求只允许 HTTPS 或明确的本机回环地址。

删除本地数据时，退出应用后删除上述 Application Support 目录即可；连接器自己的会话数据仍由对应 Agent 管理。当前仓库不上传任务内容，也没有遥测服务。未来加入网络连接器时，必须在设置页逐源显示目标主机、权限和最近同步时间。
