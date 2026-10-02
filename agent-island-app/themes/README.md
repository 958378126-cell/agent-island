# 私有主题

公开 App 不内置任何角色或第三方 IP 素材。你可以在本机创建：

```text
~/Library/Application Support/AgentIsland/theme/
├── theme.json
├── queued.png
├── running.png
├── blocked.png
├── done.png
└── failed.png
```

`theme.json` 示例：

```json
{
  "display_name": "My Private Theme",
  "status_assets": {
    "queued": "queued.png",
    "running": "running.png",
    "blocked": "blocked.png",
    "done": "done.png",
    "failed": "failed.png"
  }
}
```

也可以通过环境变量指定一个主题目录或 `theme.json` 文件：

```sh
export AGENT_ISLAND_THEME="$HOME/私人主题/theme.json"
```

主题图片只在本机读取，不会被打包进公开 App，也不应提交到 GitHub。请自行确认图片、角色名称和 Logo 的授权范围。
