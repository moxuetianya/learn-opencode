# 08. Server / Client 架构：职责边界与执行位置

> 本课回答三个问题：
> 1. server 和 client 各负责什么？
> 2. **tool-use 到底是谁执行的**？
> 3. 同一目录开多个客户端，为什么"看起来共享"？
>
> V1 的"老 TUI 内嵌 worker server"已不存在。现在所有客户端（TUI/CLI/Web/Desktop）
> 都是同一个协议上的普通客户端。

---

## 8.1 一张图

```
┌─ Client 进程 ─────────────────────────┐      ┌─ Client 进程 ────────────────────┐
│ @opencode/cli + @opencode/tui         │      │ @opencode/app / desktop          │
│  · 命令、输入、渲染                    │      │  · Solid UI、编辑器集成           │
│  · client store、本地偏好/历史         │      └───────────────┬──────────────────┘
└───────────────┬───────────────────────┘                      │
                │ HTTP JSON + SSE（/api/*）                     │
                ▼                                              ▼
┌─ Server 进程（daemon / standalone / 远端）────────────────────────────────────┐
│ @opencode/server                                                              │
│  · HTTP 路由、认证、CORS、Location 中间件                                      │
│  · Core 服务图：Config、Plugin、Provider、Model、Agent、Tool、Skill、MCP…      │
│  · SessionInbox / SessionExecution / SessionRunner                             │
│  · LLMClient.stream（每个 Physical Attempt 一次）                              │
│  · Tool.Snapshot.execute（bash 是 server 的子进程）                           │
│  · Bus：事件持久化 + 投影 + SSE 扇出                                          │
│  · SQLite：会话、事件、收件箱、Job KV（全局库）                                 │
└───────────────────────────────────────────────────────────────────────────────┘
```

**核心不变式：client 永远不执行工具、不调用模型。**
client 的全部工作 = 组装请求 + 渲染事件 + 本地偏好/历史。

---

## 8.2 包拓扑与依赖方向

```
schema ──▶ protocol ──▶ server
   │            ▲          ▲
   │            │          │
   └──▶ core ───┘──────────┘
          ▲
          ├── client（只依赖 schema / protocol）
          ├── cli / tui / app / desktop
          └── sdk-next（client + core + server，供嵌入）
```

| 包 | 角色 | 关键内容 |
|---|---|---|
| `packages/schema` | 契约 | 事件、消息、Inbox、Config、Tool、Model |
| `packages/protocol` | 线协议 | Effect `HttpApi` 组 |
| `packages/core` | 领域运行时 | SQLite、Bus、Session、Runner、Tool、Plugin |
| `packages/server` | HTTP 绑定 | `createRoutes()`，handler + 中间件 |
| `packages/client` | 客户端运行时 | Promise / Effect / Solid 三套入口 |
| `packages/cli` | 命令与 TUI 宿主 | 命令树、非交互 run、服务连接 |
| `packages/tui` | 终端 UI | Solid + OpenTUI 组件与 store |
| `packages/sdk-next` | 组合包 | 嵌入式使用 |

规则（根 `AGENTS.md`）：**client 不得依赖 core / server**。
这不是风格建议，而是包依赖与生成代码共同保证的边界。

---

## 8.3 tool-use 在哪执行

### 8.3.1 执行链

```
SessionRunner.drain
  → SessionStep.attempt
       ├─ llm.stream(request)
       └─ 对每个本地 tool-call：
            Effect.forkScoped(
              prepared.executeTool({ sessionID, agent, messageID, call })
                → Tool.Snapshot.execute
                     → tool.execute.before hook
                     → tool.execute
                     → tool.execute.after hook
                     → 输出归一化 / 截断
            )
```

- `providerExecuted: true` 的事件（宿主 provider 已代跑的工具，如某些服务端搜索）
  不会在本地执行；
- 所有本地工具都在 **server 进程**；
- `shell` 工具通过 `Shell.Service` spawn 子进程，输出落到 server 的文件，
  返回有界预览 + 完整输出路径；
- 工具执行前会先发布 `session.tool.called` durable 事件，
  崩在中途也能看出"哪些工具正在执行"。

### 8.3.2 client 看到什么

client 只收到：

- `session.tool.input.*`
- `session.tool.called`
- `session.tool.progress`（ephemeral）
- `session.tool.success` / `session.tool.failed`

它不持有工具实现，也不执行权限判断（权限询问由 server 发起，client 只回复）。

### 8.3.3 权限在哪

- `Permission.assert` 在工具叶子内调用，**server 进程**；
- 需要询问时发布 `permission.asked` 事件；
- client 弹窗，`permission.replied` 回到 server；
- server 恢复等待中的工具或抛出拒绝。

因此同一套工具在 TUI、Web、Desktop、CLI 上行为一致。

---

## 8.4 会话执行链路

```
POST /api/session/:id/prompt
  → Session.prompt
       ├─ SessionPrompt.prepare
       ├─ SessionInbox.admit（durable）
       └─ execution.wake
  → SessionExecution（进程级，按 Session ID）
  → SessionRunCoordinator（同 Session 单 drain，跨 Session 并行）
       drain:
         store.get(id)
         → SessionRunner.Service.use(...).provide(instance of session.location)
  → SessionRunner.drain
       ├─ advanceToStep：move/compaction/晋升输入
       ├─ SessionContext.select/load
       ├─ SessionModelRequest.prepare
       ├─ SessionStep.attempt：一次 llm.stream + 工具 fiber
       └─ 继续直到没有工作
```

关键点：

- **执行是 Location 范围**：runner、模型解析、工具、权限、文件系统都从
  `LocationServiceMap.get(session.location)` 借用；
- **协调是进程级**：一个进程内同一 Session 只有一个 drain，集群化之前不跨进程协调；
- **状态全在数据库**：inbox、claim、消息投影、Job KV；进程崩了可以恢复。

---

## 8.5 多客户端为什么共享

### 8.5.1 daemon 模型

默认所有 CLI/TUI 都连接**同一个后台 daemon**：

```bash
opencode service status
# 读取 ~/.local/state/opencode/service.json
# { id, version, url, pid, password }
```

- 读注册文件 + `GET /api/info` 探活；
- 健康且版本匹配 → 复用；
- 版本不匹配 → 按 `mismatch` 策略替换/忽略/报错；
- 不存在/假死 → 由客户端 spawn 一个 contender（第 10 课）。

```
TUI #1 ─┐
TUI #2 ─┼─→ http://127.0.0.1:<port> → 同一 daemon
CLI run ┘                         │
                                   ├─ 同一全局 SQLite（WAL）
                                   └─ 同一事件流
```

### 8.5.2 共享状态 ≠ 共享进程

- 默认是共享进程（daemon）；
- 但不是必须：`--standalone` 或多个独立 server 仍然会"看到彼此的会话"，
  因为数据在同一个全局 SQLite；
- 这正是为什么"打开的 opencode 看不到另一个 opencode 的会话"通常不是进程问题，
  而是 **channel 不同导致库文件不同**（第 09 课）。

### 8.5.3 一个 server 服务多个目录

`LocationMiddleware` 从请求解析目录：

```
?location[directory]=/path
或 header x-opencode-directory: /path
否则 process.cwd()
```

然后 `LocationServiceMap.get(ref)` 取该目录的服务图。
SDK/client 会自动带目录信息。

---

## 8.6 通信协议

### 8.6.1 HTTP

- 所有 API 在 `/api/*`（`packages/protocol/src/api.ts`）；
- 认证：Basic Auth（`opencode` + service password）；
- Schema 解码失败 → 400；
- 路径参数 / 查询参数 / body 都由 Effect Schema 定义。

### 8.6.2 SSE

| 端点 | 用途 |
|---|---|
| `GET /api/event` | 全局事件流，客户端主入口 |
| `GET /api/experimental/session/:id/log` | durable 事件重放（`after` 序号） |

客户端连接要求第一帧是 `server.connected`；服务端每 15s 发 keepalive；
客户端 45s 无字节判定 stall 并重连。

### 8.6.3 WebSocket

只用于 PTY：

- `/api/pty/...`：临时终端；
- `/api/persistent-pty/...`：持久终端。

会话执行**不使用** WebSocket；模型传输可能使用 provider 级 WebSocket，
但那发生在 server 的 `SessionModelTransport` 内，对 client 不可见。

---

## 8.7 Location / Workspace / Project

| 概念 | 定义 | 用途 |
|---|---|---|
| **Project** | 一个仓库/工作区身份 | 数据归属、worktree、项目事件 |
| **Workspace** | 显式 workspace ID（当前多为空） | 预留给远程/集群放置 |
| **Location** | `{ directory, workspaceID? }` | 服务图、runner、工具、权限、FS 的放置单元 |

- 省略 `workspaceID` = 隐式本地放置；
- `LocationServiceMap` 以 Location 为 key 编译整套服务；
- Session 创建时固定 Location；`session.move` 会换 Location 并在新图里重入；
- 同一项目不同子目录 = 不同 Location = 不同配置/工具图。

---

## 8.8 扩展点：server 端还是 client 端

| 你想做 | 放哪 | 用什么 |
|---|---|---|
| 新工具 / 改工具 | server | `ctx.tool.transform` |
| 改模型请求 | server | `session.context` / `session.model.request` |
| 拦截工具执行 | server | `tool.execute.before/after` |
| 自定义 provider/auth | server | `ctx.provider.transform` / `ctx.integration.*` |
| 自定义 HTTP 端点 | server | `ctx.rpc.register` |
| 订阅/持久化自身状态 | server | `ctx.event.subscribe` / `ctx.storage` |
| 新命令、面板、slot | client | `@opencode/plugin/tui` |
| 改主题/keymap | client | `cli.json`（不建议插件写） |

一个经验法则：**只要涉及模型、工具、权限、会话状态，就在 server 插件里做**；
纯展示与交互放 TUI 插件。

---

## 8.9 小结

1. **server 拥有一切有状态执行**：DB、事件、会话编排、模型、工具、权限、PTY。
2. **client 只发请求、收事件、渲染**；不执行工具、不调用模型。
3. **tool-use 在 server**：`SessionStep → Tool.Snapshot.execute`；bash 是 server 子进程。
4. **默认共享 daemon**：service.json 发现 + 探活 + 版本策略；数据在全局 SQLite。
5. **一个 server 多目录**：Location 中间件 + 按目录服务图。
6. **协议只有 HTTP + SSE**；WebSocket 只给 PTY。

> **迁移小注**：旧文档的 `packages/opencode` 大 server、`InstanceStore`、
> `SessionPrompt.prompt`、`EventV2Bridge` 都是 V1；V2 对应
> `packages/server` + `LocationServiceMap` + `Session.prompt` + `Bus`。
