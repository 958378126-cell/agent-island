# Agent Island 主题模板

公开仓库只提供主题接口和中性默认主题，不包含任何第三方角色、图片、名称或 Logo。

## 主题目录

```text
my-theme/
├── theme.json
└── assets/
    ├── status-queued.png
    ├── status-running.png
    ├── status-blocked.png
    ├── status-succeeded.png
    └── status-failed.png
```

## `theme.json`

```json
{
  "id": "my-theme",
  "displayName": "我的主题",
  "brandName": "我的 Agent 看板",
  "statusAssets": {
    "queued": "assets/status-queued.png",
    "running": "assets/status-running.png",
    "blocked": "assets/status-blocked.png",
    "succeeded": "assets/status-succeeded.png",
    "failed": "assets/status-failed.png"
  }
}
```

导入主题前，请确认自己拥有图片、角色名称、Logo 和相关文案的使用及再分发权利。主题文件的许可证由主题作者自行提供，不能由 Agent Island 的代码许可证代为授权。
