# 8. Server / Client 架构：职责边界、工具在哪执行、多客户端如何共享

> 本课回答三个高频问题：server 和 client 各负责什么？**tool-use 到底是谁执行的**（答案：server 进程，client 只发 prompt 收事件）？同一目录开多个 client 为什么"看起来共享"？承接第 5 课（启动链路）与第 6 课（v1 会话循环），本课补齐 v2 的进程拓扑与执行链路。
>
> **版本对照**：本仓库 `dev` 分支里，老 TUI（`packages/opencode`）每次启动内嵌一个 worker server（走 v1 会话路径）；官方 v2.0.7 release 与新 CLI（`packages/cli`）走 **daemon 模式 + v2 会话路径**。两条链路都会讲。

## 8.0 一张图：进程拓扑

```
┌─ Client 进程 ──────────────────────┐      ┌─ Client 进程 ──────────────────────┐
│ TUI（packages/tui，纯渲染）         │      │ Web App / Desktop 渲染层            │
│  · Solid UI、keymap、输入历史       │      │  · SolidJS UI                      │
│  · 读 tui.json/cli.json（本地偏好）  │      └──────────────┬─────────────────────┘
└────────────┬───────────────────────┘                     │
             │ SDK（packages/sdk v2 client / packages/client）
             │   HTTP JSON  +  SSE 事件流   （x-opencode-directory 头指明目录）
             ▼                                              ▼
┌─ Server 进程（v2 daemon，常驻）────────────────────────────────────────────┐
│ opencode serve --register / opencode service start / Desktop sidecar       │
│  · HTTP 路由（v1 InstanceApi + v2 /api/*）                                  │
│  · Config 加载/合并（第 7 课）        · Provider 注册表、auth              │
│  · SessionV2 / SessionExecution / SessionRunner   ← 会话编排              │
│  · llm.stream（每个 provider turn 恰一次）         ← 模型调用              │
│  · ToolRegistry.settle → bash/edit/read...        ← 工具在这里执行！        │
│  · EventV2（SQLite 事务写 + 投影 + PubSub 扇出）→ SSE                       │
│  · 权限、快照、watcher、LSP、MCP、PTY(WS)                                   │
│  · 全局 SQLite：~/.local/share/opencode/opencode.db（WAL，见第 9 课）       │
└────────────────────────────────────────────────────────────────────────────┘
```

**核心不变式：client 永远不执行工具、不调用模型。** client 的全部工作 = 组装请求 + 渲染 SSE 事件 + 本地偏好/历史。

## 8.1 包拓扑：依赖规则决定了职责

```
schema ──▶ core ──▶ server（v2-only 纯净服务）     protocol ──▶ server
             ▲                                        ▲
             └────────── client ◀─────────────────────┘      sdk-next = client+core+server
                    ▲
              packages/opencode（"大" server：v1 API + Web UI + CLI + 实例路由）
```

| 包 | 角色 | 关键内容 |
|---|---|---|
| `packages/core` | v2 领域运行时 | SQLite 存储、EventV2、SessionV2、SessionExecution/Runner、内置工具、Location 服务 |
| `packages/protocol` | 线协议 | Effect `HttpApi` 组（`src/api.ts:37-64`） |
| `packages/server` | v2-only HTTP 绑定 | `src/routes.ts:26-63` 把 protocol 绑到 core handler |
| `packages/opencode` | 完整应用 | CLI、带 v1 兼容层的大 server（`src/server/server.ts`）、内嵌 host |
| `packages/client` | 生成的 client 运行时 | 从 Protocol/Server HttpApi 生成；**禁止依赖 core/server** |
| `packages/sdk-next` | 组装包 | client + core + server，供嵌入式使用 |
| `packages/tui` / `app` / `desktop` | 界面 | TUI / Web / Electron |

规则（根 AGENTS.md）：*Client 运行时可以依赖 Schema 和 Protocol，但绝不依赖 Core 或 Server*——依赖方向本身就是架构分工的机器校验。

## 8.2 tool-use 是谁执行的：server 进程

### 8.2.1 v2 路径（v2.0.7 / `packages/cli` / sdk-next）

执行链（详细时序见 §8.4）：`SessionRunner.runTurnAttempt`（`packages/core/src/session/runner/llm.ts:173-357`）对流里的每个 `tool-call` 事件调用：

```ts
// llm.ts:241 起（节选）
const providerStream = llm.stream(request).pipe(          // ← 每个 provider turn 恰一次 llm.stream
  Stream.runForEach((event) => Effect.gen(function* () {
    yield* publish(event)                                  // ← 事件先持久化（durable）
    if (event.type !== "tool-call" || event.providerExecuted) return
    yield* Effect.uninterruptibleMask((restore) =>
      restore(toolMaterialization.settle({                 // ← 本地工具结算
        sessionID, agent, assistantMessageID, call: event,
      })).pipe(...).pipe(FiberSet.run(toolFibers))         // ← 并发 fiber，立即执行
    )
  })),
)
```

`settle` 落到 `ToolRegistry.settleWith`（`packages/core/src/tool/registry.ts:50-82`）→ `registration.tool` 的 `settle` → `config.execute`。以 bash 为例（`packages/core/src/tool/bash.ts:122-176`）：

```ts
execute: (input, context) => Effect.gen(function* () {
  yield* permission.assert({ action: "bash", resources: [input.command], ... })  // 权限先断言
  const command = ChildProcess.make(input.command, [], { cwd: target.canonical, ... })
  const result = yield* appProcess.run(command, { combineOutput: true, timeout, ... })
```

**bash/edit/read/glob/grep 全部在 server 进程内执行**（bash 是 server 进程 spawn 的子进程）。`providerExecuted: true` 的事件（宿主 provider 已代跑的工具，如服务端 web search）则跳过本地 settle。

关键安全语义：工具调用**先写库**（`SessionEvent.Tool.Called`，`publish-llm-event.ts:313-335`）再开始副作用——崩溃后能看出"哪些工具在执行中被中断"。

### 8.2.2 v1 路径（老 TUI / v1 API，仍在服务）

第 6 课的 `runLoop` + `processor`：AI SDK `streamText` 的 `tool()` execute 同样跑在 server 进程（实例服务的 `SessionTools.resolve` 包装，`src/session/tools.ts:99-133`）。结论相同：**TUI 进程不执行任何工具**。

## 8.3 v2 会话执行链路（从回车到工具结果）

这是 v2 的心脏，也是 AGENTS.md "V2 Session Core" 约束的落地：

```
POST /api/session/:id/prompt            packages/protocol groups/session.ts
  → SessionV2.prompt                    packages/core/src/session.ts:360-386
      ├─ SessionInput.admit(...)          ①耐久准入：事务内发 PromptAdmitted 事件
      │     └─ projector → session_input 行（promoted_seq = NULL，尚不可见）
      ├─ 幂等：同 messageID 精确重试去重；冲突 → PromptConflictError
      └─ execution.wake(sessionID)        ②仅"建议"唤醒（resume:false = 只准入不执行）
  → SessionExecution (进程级, 按 Session ID 路由)   execution.ts:9-34
  → SessionRunCoordinator                 ③同 Session 去重合并、不同 Session 并行
      drain: store.get(id) → LocationServiceMap.get(session.location)
  → SessionRunner.run                     runner/llm.ts:392-415  ④序列化 runner
      while (还有待推进输入) {
        runTurnAttempt:
          · promoteSteers / promoteNextQueued   ← 收件箱行 → 可见 user message（原子）
          · 重载投影历史 SessionHistory.entriesForRunner
          · 组装 system context + tools（Location 范围）
          · llm.stream(request)                 ← 每 turn 恰一次
          · 流式 publish（text/reasoning/tool-call 增量，全部先落库）
          · 工具并发 settle（§8.2.1）
          等待全部工具 fiber → needsContinuation? → 重载历史 → 下一个 turn
      }
```

**delivery 语义**（`specs/v2/session.md`）：`steer`（默认）在下一个安全 provider-turn 边界插队，当前 drain 继续；`queue` 挂起直到会话即将空闲，一次只推进一条。任何新 user input 的推进都会**重置该 agent 的步数配额**（`llm.ts:195` 附近 `currentStep = 1`）。

与第 6 课 v1 循环的对照：

| 关注点 | v1（runLoop） | v2（SessionRunner） |
|---|---|---|
| 入口 | `POST /session/:id/message` → 同步建 user message | 准入（durable row）+ advisory wake 分离 |
| 中断后 | 依赖运行态标记 | 收件箱/事件全在 SQLite，崩溃可恢复 |
| 输入并发 | run-state 合并 | `session_input` + steer/queue 语义 |
| 模型调用 | `processor` 内 streamText | 每 turn 显式一次 `llm.stream` |
| 工具执行 | AI SDK execute（server 进程） | `ToolRegistry.settle`（server 进程，Location 范围） |

## 8.4 多客户端如何共享：daemon 模型

### 8.4.1 你观察到的现象与机制

"同一目录开多个 TUI/命令，它们共享会话和服务"——在 v2.0.7 里这是因为**所有客户端默认连同一个常驻后台 daemon**：

```bash
$ opencode service status     # 查看后台服务
$ cat ~/.local/state/opencode/service.json
{"id":"6916fb99-...","version":"2.0.7","url":"http://127.0.0.1:49374",
 "pid":1057820,"password":"MNhZ87yVAB-..."}
```

`service.json` 是**注册表**：daemon 启动时原子写入 `{id, version, url, pid}`；后续任何 `opencode` 命令（含 TUI）启动时读它、带 password 探活 `/health`：

- 健康 + 版本一致 → **直接复用**，不起新 server；
- 不健康/版本不符 → 停旧的，`spawn(serve --register)` 拉起新 daemon（detached），轮询直到健康；
- 退出时 finalizer 删注册；`opencode service stop` 认证后才向 pid 发信号（防注册表过期误杀复用 pid 的进程）。

本仓库 dev 分支的对应实现就是 `packages/cli/src/services/daemon.ts`（注册文件叫 `server.json`，密码单独存 `~/.local/state/opencode/password`，`0o600` 跨重启复用；`register()` 每 10s 自检注册归属，被抢占就 SIGTERM 自己，`daemon.ts:164-186`）。v2 CLI 的**每条命令**都被框架注入 `Daemon.Service`（`packages/cli/src/framework/runtime.ts:13-17`）；默认 TUI 命令 `daemon.transport() → runTui(transport)`（`commands/handlers/default.ts:9-11`）——**TUI 用的也是共享 daemon 的 URL**。

```
opencode TUI #1 ─┐
opencode TUI #2 ─┼─ all → http://127.0.0.1:<port>（service.json 发现）→ 同一 daemon
opencode run ... ─┘                                             │
                                                    同一全局 SQLite（WAL）+ 同一事件流
```

### 8.4.2 老 TUI 的内嵌模式（对照）

`packages/opencode` 的老 TUI 没有服务发现：每次启动 spawn 一个 bun Worker 跑完整 server（`cli/cmd/tui.ts:210-249`），fetch 被桥接到 worker 内的 `Server.Default().app.fetch`（假 URL `http://opencode.internal`）。**两个 TUI 各有各的内嵌 server，互不连接**——但它们仍会"看到彼此的会话"，因为所有 v2 数据都在全局 SQLite（第 9 课），WAL + `busy_timeout=5000` 保证多进程安全。这是"共享"的另一层含义：**共享状态 ≠ 共享进程**。

显式连接别人 server 的入口：`opencode attach <url>`（`cli/cmd/attach.ts`）、`opencode run --attach http://localhost:4096`；LAN 发现是可选 mDNS（`--mdns`，`server/mdns.ts`）；Desktop 把 sidecar 当 server；Web app 从配置加 server。

### 8.4.3 一个 TCP server 如何服务多个目录

daemon 只有一个，但每个请求可以指向不同项目目录：v2 中间件读 `x-opencode-directory` / `x-opencode-workspace` 头或 `location[directory]` 查询参数（`packages/server/src/location.ts:29-39`），把请求绑定到对应 **Location 服务包**；v1 实例 API 走 `InstanceStore.load`。SDK 会自动盖目录头（`packages/sdk/js/src/v2/client.ts:63-75`）。

## 8.5 通信协议：HTTP + SSE（+ WS 仅 PTY）

- **RPC**：纯 HTTP JSON（Effect HttpApi）。v2 组在 `/api/*`（`packages/protocol/src/api.ts`），v1 实例组在 `/session`、`/config`、`/provider`…（`packages/opencode/src/server/routes/instance/httpapi/`）。
- **事件**：全部 SSE。三条流：
  - `GET /global/event`——v1 桥形状，按 directory 过滤，TUI 主力（`handlers/event.ts:25-99`，10s 心跳，先发 `server.connected`）；
  - `GET /api/event`——v2 原生流（bounded 256 + 15s 心跳）；
  - `GET /api/session/:sessionID/event`——**先重放后跟踪**（durable 事件按 `after` 序号回放再转实时，`handlers/session.ts:357-364`）——断线重连不丢事件的机制基础。
- **WebSocket** 只有一个用途：PTY 终端流（`PtyConnectApi`，`routes/instance/httpapi/server.ts:150-153`）。

服务端事件链（发布即持久 + 扇出）：

```
业务代码 publish → EventV2.Service.publish
  → 单事务：分配 aggregate seq → 跑全部 projector（写 session_message/session_input/...）
            → 插 event 行（durable journal）
  → 进程内 PubSub 扇出
  → EventV2Bridge（opencode 包）→ GlobalBus → SSE 端点 → client Solid store
```

## 8.6 Location / Workspace / Instance：三个"范围"概念

| 概念 | 定义 | 代码 | 用途 |
|---|---|---|---|
| **Location** | `{ directory, workspaceID?, project }` | `packages/core/src/location.ts:11-17` | v2 放置单元：SessionRunner、模型解析、工具注册表、权限、文件系统都 Location 范围（`LocationServiceMap` 按目录编译整套服务，60 分钟空闲回收，`location-services.ts:42-112`） |
| **Workspace** | 目前只是 ID 品牌 | `packages/core/src/workspace.ts` | 显式 workspace 身份**预留给未来**（远程/集群放置）；省略 = 隐式本地放置 |
| **Instance**（v1） | `{ directory, worktree, project }` | `src/project/instance-context.ts` | 老 API 的每目录服务包；v2 请求经中间件同样落到 per-directory 服务 |

## 8.7 小结

1. **职责**：server 拥有一切有状态的执行（DB、事件、会话编排、`llm.stream`、工具、权限、LSP/MCP/PTY、SSE）；client（TUI/Web/Desktop）只做渲染与输入，外加自己的本地偏好与历史。
2. **tool-use 在 server 进程执行**：v2 是 `SessionRunner → ToolRegistry.settle → 工具 execute`（bash 是 server 的子进程）；v1 是 AI SDK execute，同样在 server。client 只收 `tool-call/tool-result` 事件。
3. **多 client 共享**：v2.0.7 起所有 CLI/TUI 默认连**同一个后台 daemon**（`service.json` 注册表 + password 探活 + 版本不匹配自动重启）；老内嵌 TUI 每个 worker 一个 server，但仍通过**全局 SQLite（WAL）**共享数据。想连别人的 server 用 `opencode attach`。
4. **协议**：HTTP JSON（目录用请求头路由）+ SSE 三条事件流（其中会话流支持重放）；WS 只给 PTY。
5. **v2 会话执行**：准入（`session_input`）与执行（wake → RunCoordinator → Runner）分离；steer/queue 两种投递；每 turn 恰一次 `llm.stream`；工具先落库再执行。
