# Agent Island Desktop App

这是 Agent Island 的公开 macOS 桌面实现。它不携带任何第三方 IP 素材，默认状态头像使用 SF Symbols；任务监控、连接器和主题层彼此分离，用户可以在私有主题中替换头像。

## 构建与运行

要求 macOS 15+、Swift 6：

```sh
swift build -c release
./.build/release/AgentIsland --selftest --root .
./.build/release/AgentIsland --smoke 3 --demo
./Scripts/make-app.sh
open ./dist/AgentIsland.app
```

普通启动不读取源码目录中的样例，而是读取：

```text
~/Library/Application Support/AgentIsland/tasks.jsonl
~/Library/Application Support/AgentIsland/agents.json
~/Library/Application Support/AgentIsland/position.json
```

`--demo` 显式加载 [`examples/desktop-tasks.example.jsonl`](examples/desktop-tasks.example.jsonl)。它只用于演示，不代表真实 Agent 已接通。

## 已实现功能

- 顶部悬浮胶囊和可展开任务面板
- 任务文件监听、状态归一化、通知去重和位置记忆
- Codex Desktop / CLI 的本地 rollout 只读识别
- `codex app-server` 进程回退识别
- HTTP JSON、JSONL 文件、命令 JSONL 三种连接器
- 中性 SF Symbol 状态头像和减弱动态效果支持
- `--selftest`、`--smoke` 和 Core 回归测试

## Codex 数据边界

App 只读扫描 `~/.codex/sessions/**/*.jsonl`，根据 `event_msg` 中的启动/终止事件判断当前回合是否活跃；不会读取提示词正文，不会向 Codex 发请求，也不会替用户批准操作。会话目录不可读、Codex 输出格式变化或系统权限不足时，任务可能不会显示。

## 自定义连接器

先阅读 [`CONNECTORS.md`](CONNECTORS.md)，再复制 [`config/agents.example.json`](config/agents.example.json) 到：

```text
~/Library/Application Support/AgentIsland/agents.json
```

也可以点击展开面板底部的「＋ 添加 Agent 接口」。连接器默认只读，令牌通过环境变量注入，不写入配置文件。

## 私有主题

主题图片不放进仓库。把 `theme.json` 和自有 PNG 放到
`~/Library/Application Support/AgentIsland/theme/`，或设置 `AGENT_ISLAND_THEME` 指向主题目录/manifest；格式见 [`themes/README.md`](themes/README.md)。

## 主题授权

公开构建不包含第三方角色、熊图、Logo 或名称素材。代码许可证不覆盖用户自行导入的主题。请将私有素材放在仓库外，并在自己的主题包中保存授权凭证和许可证说明。

## 已知限制

- 当前只提供未签名的本地 `.app` 打包脚本，不提供公证安装包。
- Codex、WorkBuddy、AutoClaw 等本地路径属于只读适配，客户端升级后需要重新验证。
- 公开版不会把进程存在当成任务完成，也不会把没有终态证据的任务标记为成功。
