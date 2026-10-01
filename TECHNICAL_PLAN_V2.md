# Agent Island 技术方案 V2：真实桌面任务接入

状态：第一阶段纵向样板已落地；本文件继续作为后续真实接入与验收基线。

## 1. 目标与边界

看板应展示这台 Mac 上 AutoClaw、Codex 桌面版、Codex CLI、WorkBuddy 桌面版正在执行的**真实任务**，并在有可靠终态事件时提醒。用户应能从每条任务看到来源、最近同步时间，并尽可能跳回原任务。无真实来源时显示空态或“未接通”，不得用演示数据填充。

保留已确定的产品形态：顶部居中悬浮胶囊、点击展开分组面板、可替换主题插画、静音系统通知。视觉体验在真实数据链路成立之后验收。

“任务”须区分会话、一次运行/回合、子任务。第一版默认以**可独立进入运行或终态、具有稳定原生 ID 的运行/回合**为看板任务；同一会话的多个回合不合并成一个永远运行的条目。若某产品只暴露会话，则须标明“会话级”，不得宣称已获取任务级状态。

## 2. 已核对的现状

| 证据 | 当前结论 | 对方案的影响 |
|---|---|---|
| `HANDOFF.md`、`SPEC.md` 与 `data/tasks.jsonl` | 文件中有 Codex、WorkBuddy 等样例/验收事件；交接明确承认 WorkBuddy 未接入。 | 样例只能用于 UI 测试，正式模式不得当作实时任务。 |
| `TaskStore.swift`、`TaskParser.swift` | App 主要折叠 JSONL 事件，缺少事件来源、原生任务 ID、同步健康度和过期规则。旧 `running` 事件可无限期保持运行。 | 必须引入来源证明与失联状态。 |
| `ProcessProbe.swift`、`TaskStore.swift` | 当前源码已有 `ps` 进程探测，比交接文档更新；PID/命令行被推成任务，进程消失会触发完成高亮。 | `ps` 只能证明进程存在，不能证明任务、标题、成功或失败；不能用于完成通知。 |
| `codex-wrapper.sh` | 仅覆盖经此脚本启动的 Codex CLI；退出码可表示该启动命令的结果。 | 保留为 CLI 可控启动的接入方式，但不能代表 Codex 桌面版所有任务。 |
| 本机只读盘点 | AutoClaw 与 WorkBuddy 桌面 App 已安装；WorkBuddy 有本地运行数据目录。 | 有本机验证条件，但尚未证明其中有稳定任务接口。 |

交接材料中的“唯一事实源是 `tasks.jsonl`”“`ps` 消失自动记 done”“点击行激活终端”等属于旧方案或旧工单指令，不作为 V2 的实现命令。它们与用户当前要求的真实桌面任务和准确结果不一致。交接对稳定性故障的描述保留为待复现风险，不能把动画循环认定为已经证实的唯一根因。

## 3. 核心架构

```text
各 Agent 的已验证接口 / 事件 / 只读状态
        ↓
每厂商一个 Adapter（独立失败、可关闭、只读优先）
        ↓ 规范化事件 + 来源证据 + 原生 ID
Reconciler（去重、状态机、断线与过期、顺序）
        ↓
本机持久化事件库（SQLite/WAL）+ 公开 JSONL 导入/导出契约
        ↓
TaskStore 快照 → SwiftUI/AppKit 看板与通知
```

看板不直接抓取各客户端 UI，也不把进程列表当任务数据库。Adapter 负责读取原生信号，不负责猜测终态；Reconciler 才负责生成统一视图。一个 Adapter 失效不得卡住其他 Adapter 或主线程。采集器与 UI 之间采用异步消息/快照；实现时优先把采集移到独立 helper 进程，避免日志解析或厂商接口挂起拖死悬浮窗。

`tasks.jsonl` 继续作为开源自定义 Agent 的**输入契约**与可导出审计格式，不再声称只要文件里有一行就代表厂商桌面任务已接通。内置 Adapter 也可输出同一规范化事件结构，但正式任务库以 Reconciler 的持久化结果为准。演示事件只在显式 Demo 模式加载，并带“演示”标识。

### 统一事件最小字段

`schema_version`、`source`、`source_instance`、`native_task_id`、`native_parent_id?`、`event_id`、`observed_at`、`occurred_at?`、`title?`、`status`、`status_evidence`、`source_health`、`deep_link?`。唯一键为 `source + source_instance + native_task_id`；事件须可幂等重放。标题和备注属敏感内容，默认只留展示所需的最小字段，日志中脱敏。

统一状态：`queued / running / waiting / blocked / succeeded / failed / canceled / unknown`。适配器对原生状态做显式映射，未知值保留原值供诊断，不擅自归类为完成。`status_evidence` 标注 `authoritative`（原生任务事件/API）、`derived`（从可验证回合记录推导）、`presence_only`（仅进程或窗口存在）；只有具有可靠终态证据的 `succeeded / failed` 能触发完成/失败通知。

断线、权限失效、数据长时间不更新时，状态转为 `unknown/stale`，保留“最后一次确认在运行”的时间。不能把“进程消失”“文件不见”“轮询失败”写成 `succeeded`。若同一任务由两条通道上报，按原生 ID 关联并展示更高可信度来源，避免双报；无法证明同一性时不按标题去重。

## 4. 各 Agent 接入路径与验证门槛

| 对象 | 首选路径 | 备选路径 | 必须先证明 |
|---|---|---|---|
| Codex 桌面版 | 验证官方 App Server 的只读 `thread/list`、`thread/read`、运行状态事件是否**能覆盖当前桌面版实例**；若可以，做本机只读桥接。 | 经用户允许后验证本地持久化会话记录的稳定结构；只读采集。 | 同一真实任务的原生 ID、运行中、完成/失败与跳转；单独起一个 App Server 实例能否看到桌面版活跃状态不能预设。 |
| Codex CLI | 对受控启动使用官方 `codex exec --json` 事件流和退出状态，关联 thread/turn ID。 | 对既有会话评估官方 App Server/结构化记录；能力不足时明确“仅支持受控启动”。 | 直接在终端启动与经 wrapper 启动的覆盖范围分别验收。 |
| AutoClaw | 调查本机客户端/其 OpenClaw 运行时是否有稳定会话与任务事件或只读查询入口。 | 官方扩展点或受控任务上报；不得靠 App 存活推断任务运行。 | 并行 2–3 个真实任务的 ID、开始、等待、终态、重启恢复。 |
| WorkBuddy 桌面版 | 先核对官方开放接口与用户当前桌面任务是否属于同一任务域。官方本地助理接口可查在线/消息历史，云端任务接口有任务状态；两者不可直接等同于全部桌面任务。 | 在允许范围内只读验证本地数据库、日志或受支持的 IPC/扩展点，并做版本兼容门槛。 | 一条从桌面版发起的真实任务能否被查询、状态是否同步、原生 ID 是否稳定；若做不到，明确显示“未接通”。 |
| 自定义 Agent | 发布版本化 JSONL/本地 socket 适配契约与校验工具。 | 明确标识手工上报。 | 自定义事件的生产者确实能产生开始、终态和心跳。 |

`ps` 只用于“应用/进程在线”的诊断标签。不得生成默认任务、补 `done` 或发送成功通知。任何本地端口、日志、数据库都先做只读可行性验证；不调用未公开的写接口，不从进程命令行、日志或查询结果复制令牌到方案、测试夹具或诊断日志。

参考依据：[Codex App Server 文档](https://developers.openai.com/codex/app-server)列出 `thread/list`、`thread/read`、`thread/status/changed` 和 `turn/completed`；[Codex 非交互模式文档](https://learn.chatgpt.com/docs/non-interactive-mode)介绍结构化输出；[WorkBuddy 官方 Open API](https://open.workbuddy.cn/docs/openapi)区分本地助理消息与云端任务。文档只证明接口存在，**没有证明它们已覆盖这台机器上的对应桌面任务**。

## 5. 用户可见规则

- 每条任务显示 Agent、标题、真实状态、来源类型、最近同步时间、原生任务定位能力。
- 接入健康单独显示：已连接、权限待处理、同步中断、接口不支持；不能用“暂无任务”掩盖“接入失败”。
- 点击任务只在 Adapter 给出并验证可用的深链/窗口定位方式时跳转；否则打开该 Agent 并提示无法精确定位。
- 同一个任务的重复终态事件只通知一次；首次导入历史不补发旧通知。来源失联只提示同步异常，不提示任务完成。
- 暂停/等待用户输入是独立状态，不能并入“失败”或“正在运行”。

## 6. 稳定性、隐私与交付

采集异步、限时、可取消；文件和数据库读取有大小/频率上限，增量游标与断线回退；Adapter 故障隔离。UI 静止时不保留 60 fps 刷新；计时只更新可见区域。位置钳制、多屏/分辨率变化、点击和退出需要真机验证。

最小权限、本机处理、按 Agent 授权；凭证只使用操作系统安全存储或官方授权流程。诊断日志默认记录事件计数、耗时、错误码、脱敏 ID，不记录任务全文、命令行、token、cookie。若某接入只能依赖不稳定的私有存储，应作为可选实验适配器，升级失效时明确降级。

交付形态仍可保持 Swift 6 + SwiftUI/AppKit；当前故障没有足够证据要求整体换到 Electron/Tauri。是否拆 helper、如何签名和开机启动，应在首个真实接入纵向样板通过后固定。正式迁移时，新库与旧 `tasks.jsonl` 隔离，旧样例不自动进入正式列表。

## 7. 分阶段开工与硬门槛

| 阶段 | 产物 | 通过标准 |
|---|---|---|
| 0. 只读可行性审计 | 三个桌面 Agent 的接口证据表、真实任务样本（脱敏）、权限清单、可行/受限/不可行结论。 | 每个目标至少做一次真实任务的开始→运行→终态观察；取不到的明确阻塞，不写伪适配器。 |
| 1. 一条真实纵向链路 | 先接最有把握的一种 Agent：采集→规范化→持久化→胶囊→通知→跳转。 | 双并行任务 ID 不串、成功/失败不误报、重启后恢复、历史不误通知。 |
| 2. 其余适配器与自定义契约 | 每 Agent 独立 Adapter、诊断页、契约校验。 | 每个接入单独完成真机对照；未达标的功能标为受限或关闭。 |
| 3. UI 与长跑 | 多行胶囊、面板、动画、通知、位置与故障恢复。 | 连续 30 分钟最小压测后再做 2 小时真实场景长跑；期间可点开/退出，空闲 CPU 目标 <2%，无主线程长阻塞。 |
| 4. 打包与发布 | 签名/权限说明、安装升级、回滚、版本兼容矩阵。 | 全新安装、升级、断网、Agent 升级、权限撤销均有可解释结果。 |

事件延迟目标：推送源 3 秒内，轮询源 10 秒内（按实际接口能力修订）。最重要的质量门槛是**零虚假的“已完成/成功”提醒**；单纯“能展示一条 running”不算接通。每阶段须保存脱敏证据、可复现步骤和失败记录，不用 README 勾选或样例 JSONL 代替真机验收。

## 8. 开工前需要用户决定

1. 第一版范围：是否要求 AutoClaw、Codex 桌面版、WorkBuddy 桌面版**三者都真接通**才算首版完成，还是允许先以一个 Agent 的真实链路交付内部试用，同时把未接通的来源明确标灰？
2. Codex 范围：桌面版任务与终端 `codex` 任务是否都必须覆盖？这决定是否需要两套采集路径。
3. 对 WorkBuddy/AutoClaw 若没有公开任务级接口：是否接受“只读本地日志/数据库适配，升级可能失效”，还是只接受官方稳定接口并暂时显示未接通？
4. 验证权限：开工时是否允许对这三个 App 做**只读本机侦查**、启动几个短的真实测试任务、读取必要的本地状态（脱敏记录）；任何授权、安装 helper、改设置另行列清单？
5. 任务粒度与隐私：胶囊默认显示真实任务标题，还是只显示 Agent/状态，展开面板后再看标题？

在这些问题明确前可先完成只读可行性审计；不会把尚未验证的桌面接口写成“已接通”。

## 9. 2026-09-23 第一阶段落地记录

用户已确定：按阶段推进；Codex 桌面版与 CLI 都覆盖；WorkBuddy/AutoClaw 官方接口优先、无可用官方任务级接口时允许本地只读回退；第一阶段以“看板显示当前电脑上正在跑的真实任务”为验收目标。

已落地到 `agent-island-app` 的最小纵向链路：

1. 新增异步 `LiveActivityProbe`，按来源读取活动快照，不阻塞悬浮 UI。
2. Codex 同时扫描桌面/CLI 共用的 rollout 文件，使用稳定 session ID；最近仍在写入且尾部没有 `task_complete`/终止事件才标记为 running。
3. WorkBuddy 优先读取本地 `~/.workbuddy/workbuddy.db` 的 `sessions` 表（稳定会话 ID、标题、状态和最后活动时间）；数据库读取失败时才回退到本机会话 JSONL。数据库短暂加锁或读取失败时保留最后一次已确认状态，避免任务在看板上闪退。当前审计时没有符合条件的 WorkBuddy 任务。
4. AutoClaw 扫描本地 session JSONL，并结合 trajectory 的 `session.ended` 做终态排除。当前审计时没有符合条件的 AutoClaw 任务。
5. `TaskItem` 增加 `TaskProvenance`（官方接口 / 本地只读 / 仅进程）；进程消失不再生成 done 高亮或完成通知。
6. 历史 `tasks.jsonl` 中超过 15 分钟没有心跳的 running/blocked 事件不再进入当前活跃列表，避免样例事件伪装成实时任务；终态历史仍保留在展开面板并标注本地只读来源。

本阶段的限制仍明确保留：独立启动的 Codex App Server 能读取持久化线程，但不能证明它能看到当前桌面实例的 live runtime；WorkBuddy 官方 Open API 需要授权且任务域与桌面会话覆盖范围尚未证明。因此当前显示的 Codex 活动属于本地只读回退证据，不宣称官方实时桥已完成。

## 10. 2026-09-23 第二阶段开工：开放连接层

为支持开源后的第三方 Agent，核心新增一套不依赖厂商 SDK 的连接契约：

1. `ConnectorTaskEvent` 规定最小字段：稳定 `task_id`、标题、标准状态、开始时间、更新时间和备注。
2. `ConnectorSpec` + `agents.json` 负责声明连接方式；通过 `AGENT_ISLAND_CONNECTORS` 或应用支持目录加载，凭证只从环境变量注入。
3. 内置三种连接器：官方优先的 `http_json`、本地只读 `jsonl_file`、独立命令输出 JSONL 的 `command_jsonl`。
4. `ConnectorPollCoordinator` 将每个连接器隔离轮询；短暂失败保留最近一次成功快照，成功返回空数组才确认没有活动任务；同一任务多条事件按更新时间折叠。
5. 现有 Codex、WorkBuddy、AutoClaw 本机探针仍保留，作为内置适配器；第三方 Agent 不需要修改看板核心，只需提供标准 HTTP 响应或一个薄适配器。

开源接入契约、示例配置和安全边界见 `agent-island-app/CONNECTORS.md` 与 `config/agents.example.json`。本阶段的验收重点是：别人能用配置接入一个新 Agent，并在面板看到稳定 ID、真实运行状态和来源证据；若厂商字段不同，必须在适配器边界映射，不能在 UI 中猜测终态。

### Kimi / 千问的官方接口核对（2026-09-24）

- Kimi API 同时提供模型调用格式和托管智能体会话 API。托管智能体的 `GET /v1/sessions` 可以按 `statuses=running` 列出会话，并返回稳定会话 ID、标题、创建/更新时间和 `idle/running/terminated` 状态；适合做官方只读 Adapter。
- 千问 / DashScope 的模型调用接口与异步 Responses 接口分开。Responses 查询通过 `response_id` 获取 `queued/in_progress/completed/failed` 等状态，但接口本身不负责枚举用户电脑上的所有桌面任务；需要任务启动方把 response ID 交给适配器。
- 已增加 `adapters/kimi-hosted-sessions.py`、`adapters/qwen-responses.py` 和 `config/vendor-adapters.example.json`。两者都只输出统一 `ConnectorTaskEvent`，不创建、修改或取消远端任务；没有 response ID 时不会假造千问任务。

## 11. 2026-09-28 架构边界落地

在继续扩展真实 Agent 适配器前，先完成运行数据与采集器的隔离：

1. 新增 `RuntimePaths`，真实运行数据、连接器 manifest 和胶囊位置统一放在
   `~/Library/Application Support/AgentIsland/`；源码 checkout 不再作为默认写入目录。
2. 新增 `examples/tasks.example.jsonl`，只有显式 `--demo` 才加载，避免演示事件混入真实任务列表。
   `AGENT_ISLAND_TASKS` 仍可用于测试、兼容导入和受控 wrapper。
3. `command_jsonl` 适配器改为异步、可取消的进程 runner：默认 15 秒超时，最大 60 秒；标准输出默认
   1 MiB，最大 8 MiB；超时、非零退出和超量输出只影响当前连接器。
4. 连接器快照增加独立健康状态：`connected`、`stale`、`error`。短暂失败保留最近一次成功快照，持续
   60 秒失败才清空旧任务，不把断连误报为 `done`。
5. `codex-wrapper.sh` 默认写入用户级运行目录，并支持通过 `AGENT_ISLAND_TASKS` 指向临时 JSONL；
   `.gitignore` 也阻止运行数据、日志和本机配置进入公开仓库。

这一步是采集与运行边界的基础设施，不等同于 AutoClaw、Codex 桌面版或 WorkBuddy 已完成官方任务级接入。
下一阶段仍按第 4、7 节的真实任务证据门槛推进，并补齐统一的 `waiting/canceled/unknown` 状态与可见的
连接器健康面板。
