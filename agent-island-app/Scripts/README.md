# Scripts

构建和打包脚本放在这里。`make-app.sh` 会把 release 可执行文件包装成未签名的 `.app`；签名、公证和发布渠道仍需单独配置。

```sh
swift build -c release
./Scripts/make-app.sh
open ./dist/AgentIsland.app
```
