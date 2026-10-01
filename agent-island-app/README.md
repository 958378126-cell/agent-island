# Agent Island

Agent Island 是一个 macOS 顶部任务看板的开源核心与产品预览。当前仓库公开的是可复现的状态归一化核心、提醒去重规则、示例事件、主题接口和不含第三方 IP 的静态宣传页；完整的桌面胶囊 UI 与各厂商连接器仍在接入阶段，不能把宣传页中的演示任务当成真实同步结果。

## 现在可以验证什么

在 macOS 13 或更高版本运行：

```sh
swift build -c release
swift run -c release agent-island-tests
swift run -c release agent-island-selftest
```

核心包会验证三条发布底线：只有明确终态证据才能报告完成/失败；过期的运行快照会降为“状态待确认”并标记来源失联；等待确认、完成和失败通知对同一任务状态只发一次，历史导入不补发通知。

示例事件见 [`examples/tasks.example.jsonl`](examples/tasks.example.jsonl)。它们是虚构数据，不能代表任何已接通的 Agent。

## 支持范围

当前支持矩阵和每个来源的证据等级见 [`docs/SUPPORT_MATRIX.md`](docs/SUPPORT_MATRIX.md)。默认策略是只读：不替用户批准操作，不从“进程存在”推断任务完成，也不会把断连显示成“暂无任务”。

隐私边界、数据位置和删除方法见 [`docs/PRIVACY.md`](docs/PRIVACY.md)。公开发布前请阅读 [`ASSETS_LICENSE.md`](ASSETS_LICENSE.md)：代码许可证不自动覆盖用户自行导入的主题素材。

## 宣传页与演示

在本地打开 [`../promo/index.html`](../promo/index.html) 可查看不含第三方 IP 的交互式状态演示。页面中的任务、时间和来源均为虚构 fixture；它展示的是信息架构和状态文案，不是已连接的真实产品录屏。主题模板见 [`../promo/THEME_TEMPLATE.md`](../promo/THEME_TEMPLATE.md)。

## 现阶段限制

仓库尚未包含可签名的 `.app` 或已验证覆盖全部桌面 Agent 的连接器。要发布二进制，需要另行完成干净用户账户安装、升级、卸载、通知权限、多显示器和网络断开验收；素材授权完成后才能公开分发宣传页图片。
