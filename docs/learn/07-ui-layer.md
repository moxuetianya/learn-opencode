# 7. UI 接入层：CLI、TUI、HTTP Server 与 Client

> 本课回答：V2 的界面层怎么分层？TUI 和 server 是同一进程吗？`opencode run` 走什么链路？
> Web / Desktop 如何复用同一套协议？
>
> V1 的"Bun Worker + 进程内 RPC + 假 URL `http://opencode.internal`"已经不存在；
> 现在 TUI 是一个普通客户端，连接 daemon、standalone server 或远端 URL。

---

## 7.1 一张图

```
┌─ 客户端进程（可多个）──────────────────────────────┐
│  @opencode/cli  ── 命令解析 / 非交互 run / TUI 宿主 │
│      └─ @opencode/tui  Solid + @opentui 渲染        │
│      └─ @opencode/client  协议客户端 + 数据仓库      │
│  @opencode/app（Web） / @opencode/desktop（Electron）│
└──────────────────────────┬──────────────────────────┘
                           │ HTTP JSON + SSE（/api/*）
                           ▼
┌─ Server 进程（daemon / standalone / 远端）──────────┐
│  @opencode/server                                   │
│   · Effect HttpApi 路由 + 认证 + CORS               │
│   · Core 服务图（Database/Bus/Session/Tool/…）      │
│   · Location 按目录懒加载                            │
│   · 事件持久化 + SSE 扇出                            │
└─────────────────────────────────────────────────────┘
```

**核心不变式：客户端不执行工具、不调用模型。**
客户端只做三件事：组装请求、消费事件、保存本地偏好/历史。

---

## 7.2 CLI

### 7.2.1 入口

`packages/cli/src/index.ts`：

1. `ensurePluginRuntime()`
2. 注册所有命令（`commands/commands.ts` 的 `Spec.make` 树）
3. `Runtime.run(Commands, Handlers, { version })`
4. 统一提供 `Global`、`AppProcess`、`Npm`、`EffectFlock`、`Observability`、Node 服务

命令通过 **Effect 的 `unstable/cli`** 定义，不是 yargs。
Handler 按需动态 import（`commands/handlers/*`），保持启动轻量。

### 7.2.2 命令面

| 命令 | 作用 |
|---|---|
| `opencode [directory]` | 默认命令：启动 TUI |
| `opencode run ...` | 非交互执行，流式输出到 stdout |
| `opencode serve` | 起 V2 API + Web 静态资源；`--service` 为托管 daemon，`--stdio` 为嵌入模式 |
| `opencode service ...` | 后台服务 start/restart/status/stop/get/set/unset |
| `opencode api ...` | 按 OpenAPI operation 或 `METHOD path` 调运行中的 server |
| `opencode mini` | 最小交互界面 |
| `opencode acp` | Agent Client Protocol server |
| `opencode auth/mcp/plugin/models/session/stats/pair/reload/upgrade ...` | 管理与诊断 |

`--server <url>` 直连显式 server；`--standalone` 起私享 server；默认走
`Service.ensure` 发现/拉起共享 daemon（第 11 课）。

### 7.2.3 `opencode run` 的链路

`commands/handlers/run.ts` → `run/run.ts` → `run/noninteractive.ts`：

```
ServerConnection.resolve()            得到 endpoint
  → OpenCode.make({ baseUrl, headers })   packages/client/promise
  → resolveSessionTarget()                --continue / --session / --fork
  → client.event.subscribe()              先收到 server.connected 才算连上
  → client.session.prompt({ sessionID, text, files, agent, model, delivery })
  → 消费事件直到 session.execution.succeeded/interrupted/failed
```

非交互模式会：

- 把 `--file` 读成 `data:` URL（限制 10 MiB）；
- 用 `--auto` 自动允许未显式拒绝的权限；
- 遇到 `permission.asked` / `form.created` 自动拒绝/取消，并把原因反馈给模型；
- `--format json` 输出逐行 JSON 事件，否则用 `run/ui.ts` 渲染。

---

## 7.3 TUI

### 7.3.1 技术栈

- 渲染：`@opentui/solid`（SolidJS + 原生终端渲染器），**不是 React/Ink**；
- 入口：`packages/tui/src/app.tsx` 的 `run(input)`；
- 宿主：`packages/cli/src/commands/handlers/default.ts` 调用 `run()`，
  传入 endpoint、`Config`（`cli.json`）、更新器、包管理器等能力。

`run()` 做：

1. 解析 `cli.json`（客户端偏好）
2. `OpenCode.make({ baseUrl, headers })` 建客户端
3. 通过 `file.list` / `location.get` 解析当前 Location
4. 创建 `@opentui/core` renderer（60fps、鼠标、Kitty keyboard）
5. 挂 Provider 树：Log → Exit → App → Paths → Storage → Args → Config →
   Keymap → Toast → Route → Client → Data → Local → Permission → Plugin …
6. 进入初始路由（Home 或 Session）

### 7.3.2 数据层

`packages/tui/src/app.tsx` 的 `DataProvider` 包装
`packages/client/src/solid/data.ts` 的 `createData()`：

```
createData({ api, event, connection, directory })
  ├─ store.session.info/message/pending/permission/form
  ├─ store.location / config / provider / model / agent / skill / command
  ├─ event 归并（session.* / permission.* / form.* / mcp.* / …）
  └─ 乐观提交（prompt / synthetic / command）+ 回滚
```

`prompt()` 的乐观准入：

1. 同步插入一条本地 pending 行（立即可见）；
2. 提交 HTTP；
3. 若失败，回滚该行并恢复输入；若成功，等待 `session.inbox.enqueued` /
   `session.inbox.delivered` 事件把它替换为真实消息。

因此提交不等待网络，界面不会"卡一下"。

### 7.3.3 事件流

`packages/client/src/solid/connection.ts`：

```
api.event.subscribe()                  GET /api/event (SSE)
  → 第一帧必须是 server.connected
  → 事件先入队，默认 10ms 批量 flush（Solid batch）
  → 空闲看门狗 45s（服务端每 15s 发 keepalive）
  → 断线 1s 退避重连；页面前后台切换会主动检查半开连接
```

TUI 的 `context/client.tsx` 把事件分发到 `createGlobalEmitter`，
`context/data.tsx` 与各 Provider 订阅自己关心的事件类型。

### 7.3.4 渲染

- 会话列表与消息在 `packages/session-ui/src/`（message、tools、timeline、pierre diff…）；
- TUI 路由在 `packages/tui/src/routes/session/`；
- `text/reasoning` 的 delta 事件直接追加到本地 part，形成打字机效果；
- `session.execution.*` 驱动 footer 状态（busy/retry/idle）；
- `permission.asked` / `form.created` 渲染为对话框，回复走对应 API。

### 7.3.5 持久终端

终端不是 TUI 本地进程，而是 **server 持有的 persistent PTY**：

| 入口 | 行为 |
|---|---|
| `/terminal`（`session.terminal`） | 无条件新建 PTY 并选中 |
| `terminal.toggle`（`<leader>t`） | 面板可见则隐藏；隐藏则选最后一个，列表为空才新建 |
| `terminal.select`（`<leader>down`） | 打开该 session 的 Terminals 列表 |
| `terminal.close`（`<leader>up`） | 只关面板，不杀 PTY |

- 列表由 server 持有；TUI 在 `server.connected` 时刷新；
- 选中项存在客户端存储 `session-terminal-selection`；
- 新建/删除通过 `experimental.persistentPty.create/list/...`；
- 删除 session 或显式删除 PTY 才会真正结束进程。

核心文件：`tui/src/context/session-terminals.tsx`、
`tui/src/routes/session/composer/terminals-tab.tsx`、
`tui/src/component/session-frame.tsx`。

---

## 7.4 HTTP Server

### 7.4.1 启动

`opencode serve` → `cli/src/server-process.ts`：

```
options（mode = default | service | stdio）
  → 解析 hostname/port/password/CORS/database/models/config
  → import("@opencode/server/process").start(...)
      → packages/server/src/process.ts
          ├─ node:http createServer
          ├─ NodeHttpServer.make
          ├─ createRoutes(options)
          │    ├─ LayerNode 构建 Core 服务图
          │    ├─ HttpApiBuilder.layer(Api)
          │    └─ 中间件：authorization / schema-error / location / session-location / CORS
          ├─ /api/info（启动中就返回 503 + retry-after）
          └─ lifecycle.onListen（服务模式注册 service.json）
```

默认端口：服务模式按 channel（49374 / 49375 / hash），前台默认从 4096 起找空位。
`/api/info` 不需要完整应用就绪，客户端用它探活与判断版本。

### 7.4.2 协议

`packages/protocol/src/api.ts` 组合的 group：

```
server / debug / migration / worktree / generate / persistent-pty / credential
agent / plugin / model / provider / integration / websearch / mcp / project
fs / command / skill / rpc / shell / reference / vcs / config
session / message / permission / form / pty / location / event
```

常用端点：

| 端点 | 用途 |
|---|---|
| `GET /api/info` | 版本、pid、urls、tmp 路径 |
| `POST /api/session` | 创建会话 |
| `GET /api/session/:id` | 会话信息 |
| `POST /api/session/:id/prompt` | 准入一条用户输入 |
| `POST /api/session/:id/interrupt` | 中断当前执行 |
| `GET /api/session/:id/inbox` | 未消费输入 |
| `PATCH /api/session/:id/inbox/:inboxID` | steer/queue 切换 |
| `GET /api/session/:id/message/:messageID` | 单条消息 |
| `GET /api/event` | 全局 SSE |
| `GET /api/experimental/session/:id/log` | durable 事件重放 |
| `WS /api/pty/...`、`/api/persistent-pty/...` | 终端流 |

中间件：

- `authorization`：Basic Auth（`opencode` + service password）；
- `schema-error`：把 Schema 解码失败变成 400；
- `location`：从 `location[directory]` 查询参数或
  `x-opencode-directory` 头解析 Location；
- `session-location`：从 session ID 反查 Location；
- CORS：由 `--cors` / service config 控制。

### 7.4.3 错误与就绪

- 启动中：`/api/info` 返回 503 + `retry-after: 1`；
- 启动失败：503 + `code: service_failed`，提示 `opencode service restart`；
- 版本不匹配：客户端负责决定复用/重启/报错（第 11 课）。

---

## 7.5 Client 包

`packages/client/src/` 有三个入口：

| 入口 | 用途 |
|---|---|
| `promise/` | Promise 风格 `OpenCodeClient`（`opencode run`、CLI 命令） |
| `effect/` | Effect 风格 API + `Service`（发现/ensure/stop） |
| `solid/` | Solid store：`createData()`、`createClientConnection()`、PTY 客户端 |

生成代码来自 Protocol/Server HttpApi；**client 不依赖 core/server**。
`@opencode/sdk-next` 才把三者组合给嵌入式使用。

---

## 7.6 Web / Desktop

- `packages/app`：Vite + Solid Web 应用，复用 `packages/session-ui`；
- `packages/desktop`：Electron 壳，复用 app 与 client；
- 二者都通过同一个 HTTP + SSE 协议连接 server，不共享进程内状态；
- Web 静态资源由 `serve` 的 `WebUi.handler()` 注入（`cli/src/services/web-ui.ts`）。

---

## 7.7 三条数据流

### 7.7.1 TUI 提交

```
prompt/index.tsx submit
  → data.session.prompt()      乐观插入 pending 行
  → client.api.session.prompt() POST /api/session/:id/prompt
  → server Session.prompt       prepare + inbox admit + wake
  → 返回 admitted 记录
  → SSE session.inbox.enqueued / delivered
  → data store 替换 pending 行
```

### 7.7.2 CLI 非交互

```
client.event.subscribe()
  → session.prompt()
  → 逐条消费事件：step.started → text/reasoning/tool → step.ended → execution.succeeded
  → 渲染或 JSON 输出
```

### 7.7.3 Web/外部

```
SDK/Client → HTTP → server handler → Core
Core publish → event 行 + 投影 → PubSub → SSE → client store
```

---

## 7.8 小结

1. **UI 层只有客户端**：CLI、TUI、Web、Desktop 都通过 HTTP + SSE 连接 server。
2. **TUI 是普通客户端**：Solid + OpenTUI，不再有 worker/RPC 桥。
3. **CLI 是 Effect 命令树**：`run` 非交互消费事件，`serve` 起 V2 API。
4. **数据层乐观提交**：提交不等网络，事件到了再对齐。
5. **终端属于 server**：persistent PTY 跨 TUI 重启/切换存活。
6. **协议只有 `/api/*`**：认证、目录、Schema 错误都由中间件统一处理。

> **迁移小注**：旧文档的 `packages/opencode/src/cli/cmd/tui.ts`、
> `cli/tui/worker.ts`、`createWorkerFetch`、React/Ink 等描述均已过时。
