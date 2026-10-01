# Agent Island · 可自定义主题的 Agent 看板

Agent Island 是 macOS 顶部的多 Agent 任务看板项目。公开版本只包含通用看板核心、状态契约、连接器示例和可替换主题接口，不内置任何第三方 IP 素材。仓库分为两部分：

- [`agent-island-app/`](agent-island-app/)：Swift 看板核心、状态契约、示例事件、支持矩阵和 CI。
- [`promo/`](promo/)：不含第三方 IP 的静态宣传页、主题模板和交互式状态演示。

## 快速验证

```sh
cd agent-island-app
swift build -c release
swift run -c release agent-island-tests
swift run -c release agent-island-selftest
```

核心包会验证：过期运行快照转为 `unknown / stale`；进程存在不能伪造成功或失败；取消保持独立状态；等待确认、成功和失败提醒按状态转移去重；历史导入不补发提醒。

完整说明见 [`agent-island-app/README.md`](agent-island-app/README.md)、[`TECHNICAL_PLAN_V2.md`](TECHNICAL_PLAN_V2.md) 和 [`agent-island-app/RELEASE_PLAN.md`](agent-island-app/RELEASE_PLAN.md)。

在浏览器打开 [`promo/index.html`](promo/index.html) 查看公开版交互演示。主题模板见 [`promo/THEME_TEMPLATE.md`](promo/THEME_TEMPLATE.md)。当前仓库尚未包含可签名的完整 `.app` 和已通过真实桌面任务验收的全部连接器；宣传页不会把虚构任务当成真实同步结果。
