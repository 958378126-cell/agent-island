# Agent Island 开源接入方式

Agent Island 的核心看板不直接依赖每一个 Agent 厂商的 SDK。它只接收一套很小的规范化任务事件，再把事件合并到现有的 `TaskStore` 和 UI：

```text
官方 API / 本地文件 / CLI 适配器
              ↓
     ConnectorTaskEvent
              ↓
          ObservedTask
              ↓
       TaskStore → 胶囊与面板
```

这样开源后，别人不需要修改看板核心代码。只要 Agent 能提供官方任务 API，或者能运行一个只读适配器，就可以通过配置接入。

## 三种连接方式

### 1. 官方 HTTP API（优先）

当 Agent 提供任务或回合查询接口时，配置一个 `http_json` 连接器：

```json
{
  "id": "my-agent",
  "display_name": "My Agent",
  "type": "http_json",
  "url": "https://agent.example.com/api/tasks",
  "token_environment": "MY_AGENT_TOKEN",
  "status_map": {
    "queued": "queued",
    "working": "running",
    "succeeded": "done",
    "error": "failed"
  },
  "provenance": "official",
  "poll_seconds": 10,
  "enabled": true
}
```

看板会发出只读 `GET` 请求。令牌只从环境变量读取，不写进配置文件。接口返回可以是事件数组，也可以是 `{ "tasks": [...] }`：

```json
[
  {
    "task_id": "run-2026-09-23-001",
    "title": "整理会议纪要",
    "status": "working",
    "note": "已处理 12/20 条",
    "started_at": "2026-09-23T09:00:00+08:00",
    "updated_at": "2026-09-23T09:12:30+08:00"
  }
]
```

如果厂商返回的是私有字段（例如 `runId`、`state=processing`），应在一个很薄的适配器里转换成上面的字段；不要把厂商字段塞进看板核心。

### 2. 本地只读 JSONL

没有官方接口，但 Agent 会写本地状态文件时，使用 `jsonl_file`：

```json
{
  "id": "local-agent",
  "display_name": "Local Agent",
  "type": "jsonl_file",
  "path": "~/Library/Application Support/LocalAgent/tasks.jsonl",
  "provenance": "local",
  "enabled": true
}
```

文件每行一个 `ConnectorTaskEvent`。看板只读文件，不接管 Agent 的写入逻辑。文件暂时读失败时，会保留最近一次成功快照 60 秒，避免短暂写入或网络盘抖动造成任务闪退。

### 3. 命令行 JSONL 适配器

如果 Agent 没有 API，也没有稳定的状态文件，可以写一个独立命令，每次运行时把当前任务打印为 JSONL：

```json
{
  "id": "cli-agent",
  "display_name": "CLI Agent",
  "type": "command_jsonl",
  "command": "/absolute/path/to/agent-island-adapter",
  "arguments": [],
  "timeout_seconds": 15,
  "max_output_bytes": 1048576,
  "provenance": "local",
  "enabled": true
}
```

命令必须满足：退出码为 `0`，标准输出每行一个规范化事件，不能把密钥打印到标准输出。适配器失败只影响这个 Agent，不会阻塞其他连接器。

连接器运行时会把单次命令限制在 `timeout_seconds` 内（默认 15 秒，最大 60 秒），并限制标准输出大小
（默认 1 MiB，最大 8 MiB）。超时或输出超限会被记录为该连接器的错误，不会拖住其他连接器的轮询。

## 配置文件位置

复制 [`config/agents.example.json`](config/agents.example.json)，修改后放到：

```text
~/Library/Application Support/AgentIsland/agents.json
```

也可以通过环境变量指定路径：

```bash
export AGENT_ISLAND_CONNECTORS="$PWD/config/agents.json"
```

也可以直接在看板里配置：展开胶囊后点击底部的 **「＋ 添加 Agent 接口」**。表单会根据
`http_json`、`jsonl_file`、`command_jsonl` 显示对应字段；点击「保存并连接」后写入上述
manifest，并立即启动只读轮询。同一个 `id` 会更新原配置。表单不会保存密钥，只保存
`token_environment` 的环境变量名。

配置文件使用 `schema_version: 1`。`id` 必须稳定且唯一；它会成为看板中的 Agent 键名，也是任务 ID 命名空间的一部分。

## 事件契约与可靠性要求

适配器至少要提供：

- `task_id`：稳定的任务或回合 ID，不能用 PID 代替。
- `title`：给人看的任务标题。
- `status`：映射为 `queued`、`running`、`blocked`、`done`、`failed` 之一。
- `updated_at`：最近一次状态更新时间；建议同时提供 `started_at`。

任务从进程列表消失不能直接推断为完成。只有 Agent 的官方终态、状态文件的终态事件或适配器明确报告 `done/failed`，看板才会显示终态并触发通知。官方接口优先级高于本地推断；只有没有官方接口时才使用本地只读或进程级回退。

连接器健康状态与任务状态分开维护：`connected` 表示本轮成功，短暂失败会标记为 `stale` 并保留最近一次快照，
超过 60 秒仍失败才进入 `error` 并清空该连接器的旧任务。这样网络抖动不会被误报成任务完成。

## 开源接入一个新 Agent 的步骤

1. 查 Agent 是否有官方任务/回合查询 API，先使用 `http_json`。
2. 把厂商状态映射到五个标准状态，并保证 ID、开始时间、更新时间稳定。
3. 如果 API 字段不符合契约，单独写一个小适配器，输出 `ConnectorTaskEvent` JSONL。
4. 把连接器加入 `agents.json`，重启 Agent Island，确认面板出现该 Agent 的真实运行任务。
5. 验证一次完整生命周期：启动、持续运行、状态更新、完成/失败、临时断连后恢复。

## Kimi 与千问的具体落法

这两个例子说明了“通用协议 + 厂商适配器”的边界：

- **Kimi Hosted Agents**：官方提供 [`GET /v1/sessions`](https://platform.kimi.com/docs/hosted-agents/session-operations)，可以按 `statuses=running` 列出当前会话。`adapters/kimi-hosted-sessions.py` 只读这个接口并输出统一 JSONL，再通过 `command_jsonl` 接入。
- **千问 / DashScope Responses**：官方[异步响应查询接口](https://help.aliyun.com/en/model-studio/asynchronous-call-api-reference)按 `response_id` 查询 `queued`、`in_progress`、`completed`、`failed` 等状态；[OpenAI 兼容 Responses API](https://help.aliyun.com/en/model-studio/qwen-api-via-openai-responses)也返回同一类响应状态。模型调用接口不会自动列出所有正在运行的桌面任务，所以适配器需要任务启动方保存 response ID；`adapters/qwen-responses.py` 读取 ID 文件后轮询官方查询接口。

因此，接入 Kimi、千问、Claude 或其他 Agent 时，看板核心都走同一套 `ConnectorTaskEvent`。每家只维护自己的认证、分页、字段和状态映射；官方接口能提供任务状态时标为 `official`，只有模型调用接口而没有任务查询接口时，不把一次模型请求冒充成桌面 Agent 任务。

官方资料：Kimi 托管会话的生命周期状态为 `idle/running/terminated`，并支持列出会话；千问异步 Responses 接口按 response ID 返回当前状态。适配器样例的离线 fixture 可以在没有密钥时运行。

## 安全边界

- 连接器默认是只读轮询，不会向 Agent 下发任务或修改状态。
- 令牌用 `token_environment` 从环境变量注入，不要提交到 Git。
- 本地服务优先绑定 `127.0.0.1`；远程 HTTPS 接口应自行处理证书和访问控制。
- 第三方适配器作为独立进程运行时，建议限制文件权限和输出内容。
