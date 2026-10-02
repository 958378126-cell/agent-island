# 官方 Agent 适配器样例

这些脚本是 Agent Island 统一连接协议的薄适配器。它们只读取官方接口，然后输出 `ConnectorTaskEvent` JSONL；看板核心仍只处理统一事件。

## Kimi Hosted Agents

Kimi 托管智能体提供 `GET /v1/sessions`，可以按 `statuses=running` 查询当前运行会话。运行：

```bash
export KIMI_API_KEY="$MOONSHOT_API_KEY"
./adapters/kimi-hosted-sessions.py
```

配置：

```json
{
  "id": "kimi-hosted",
  "display_name": "Kimi Hosted Agent",
  "type": "command_jsonl",
  "command": "/absolute/path/to/agent-island-app/adapters/kimi-hosted-sessions.py",
  "provenance": "official",
  "poll_seconds": 10,
  "enabled": true
}
```

脚本使用只读查询，不创建、修改或终止会话。Kimi 文档中的 `running` 会话状态直接映射为看板的 `running`。

## Qwen / DashScope Responses

千问异步 Agent Response 查询接口按 `response_id` 读取状态。它没有一个等价的“列出本机所有桌面任务”接口，因此适配器需要由任务启动方把 response ID 写入 `QWEN_RESPONSE_IDS_FILE`：

```bash
export DASHSCOPE_API_KEY="你的百炼 API Key"
export QWEN_APP_ID="你的 Agent App ID"
export QWEN_RESPONSE_IDS_FILE="$HOME/Library/Application Support/AgentIsland/qwen-response-ids.txt"
./adapters/qwen-responses.py
```

每行写一个 response ID。适配器读取 `queued/in_progress/completed/failed`；`cancelled/incomplete` 暂时写入 stderr 并跳过，避免把取消误报为失败。后续增加看板的一等“已取消”状态后再补齐。

## 离线测试

两个脚本都支持 fixture，不需要 API Key：

```bash
./adapters/kimi-hosted-sessions.py --fixture /path/to/kimi-sessions.json
./adapters/qwen-responses.py --fixture /path/to/qwen-response.json
```
