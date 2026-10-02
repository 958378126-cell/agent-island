# Agent Island

一个无第三方 IP 素材的 macOS Agent 任务胶囊。公开仓库包含可运行的桌面 App、任务状态核心、只读连接器和可替换主题接口；默认头像使用系统 SF Symbols，用户可以在自己的私有主题层替换成有授权的素材。

## 快速运行

要求：macOS 15+、Swift 6。

```sh
cd agent-island-app
swift build -c release
./.build/release/AgentIsland --selftest --root .
./.build/release/AgentIsland --smoke 3 --demo
./Scripts/make-app.sh
open ./dist/AgentIsland.app
```

正常启动后，App 使用以下本地文件：

- `~/Library/Application Support/AgentIsland/tasks.jsonl`
- `~/Library/Application Support/AgentIsland/agents.json`
- `~/Library/Application Support/AgentIsland/position.json`

`--demo` 只加载仓库内的虚构演示事件，不会用于普通启动。

## Codex 监控

App 以只读方式观察 `~/.codex/sessions/**/*.jsonl`，识别 `task_started` / `turn_started` 到终态事件之间的活动回合；同时兼容 Codex Desktop 的 `codex app-server` 进程回退识别。它不会读取或发送提示词，也不会修改 Codex 会话。

冒烟测试会验证当前构建可以发现活动 Codex 回放文件，但不同 Codex 版本、权限设置和会话格式仍可能影响可见性。

## 接入其他 Agent

看板通过三种只读连接方式接入自定义 Agent：HTTP JSON、JSONL 文件、命令 JSONL。协议和示例见 [`agent-island-app/CONNECTORS.md`](agent-island-app/CONNECTORS.md)，配置模板见 [`agent-island-app/config/`](agent-island-app/config/)。

## 主题与授权边界

公开仓库不包含任何第三方角色、熊图、Logo 或名称素材。代码许可证不自动授权用户导入的图片和主题；请把私有素材放在仓库外或被 `.gitignore` 忽略的目录中，并单独确认授权范围。

完整主题目录格式见 [`agent-island-app/themes/README.md`](agent-island-app/themes/README.md)。公开 App 默认使用 SF Symbols，也支持从用户本机主题目录加载自有图片。

宣传页位于 [`promo/`](promo/)，公开版不含第三方 IP。带私有素材的宣传材料只能保留在本机私有目录，不要提交到 GitHub。

## 当前边界

公开 App 已有完整胶囊、展开面板、任务文件监听、Codex 本地回放识别、连接器配置和中性头像，但尚未提供签名/公证的发布包，也没有承诺覆盖所有厂商 Agent 的内部状态。真实接入必须按来源逐项验收。

## 测试

```sh
cd agent-island-app
swift build -c release
./.build/release/agent-island-tests
./.build/release/agent-island-selftest
./.build/release/AgentIsland --selftest --root .
```
