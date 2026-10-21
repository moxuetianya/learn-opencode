# 1. 启动链路：从 `opencode` 命令到 TUI 就绪

> 本课梳理：命令入口 → 解析 endpoint（共享 daemon / standalone / 显式 URL）→
> 启动 server（如需要）→ 按 Location 懒加载 Core 服务 → TUI 初始化 → 首批数据同步。
>
> 后台服务的发现、竞争、重启恢复细节见第 11 课；配置来源细节见第 08 课。
> V1 的"每次启动 spawn 一个 Worker 跑内嵌 server"已不存在。

---

## 1.0 总览

```
opencode [directory]                    packages/cli/src/index.ts
  │  Effect CLI 解析 → default handler
  ▼
ServerConnection.resolve()              cli/src/services/server-connection.ts
  ├─ --server <url>        → 直连并探活 /api/info
  ├─ --standalone / disabled → Standalone.start()（私享进程）
  └─ 默认                   → Service.ensure()（共享 daemon，必要时拉起）
  │  endpoint = { url, auth }
  ▼
run({ server, config, args, ... })      packages/tui/src/app.tsx
  ├─ Config.resolve(cli.json)
  ├─ OpenCode.make(endpoint)            packages/client
  ├─ file.list / location.get           确定当前 Location
  ├─ create renderer + Provider 树
  └─ DataProvider 开始同步
  │
  ▼
GET /api/...                            packages/server
  └─ LocationMiddleware
       └─ LocationServiceMap.get(ref)   core/src/location-services.ts
            └─ Instance.layer(ref)      按目录编译整套 Location 服务
                 ├─ Config / Plugin     最先启动
                 ├─ Agent / Provider / Model / Tool / Skill / MCP …
                 └─ SessionRunner / Compaction / Context
```

关键设计：**配置、插件与工具注册表不是 server 进程启动时加载，而是按 Location 懒加载**。
同一个 daemon 可以同时服务多个目录，每个目录一套独立服务图。

---

## 1.1 命令入口

`packages/cli/src/index.ts`：

1. `ensurePluginRuntime()`：注册插件运行时模块解析；
2. `Runtime.handlers(Commands, {...})`：每个命令按需 import handler；
3. `Runtime.run(Commands, Handlers, { version })`；
4. Effect 层提供 `Config`、`Updater`、`Global`、`AppProcess`、`Npm`、
   `EffectFlock`、`Observability`、Node 服务。

命令定义在 `commands/commands.ts`，默认命令 `$0 [directory]` 就是 TUI。
`--continue` / `--session` / `--prompt` / `--model` / `--agent` / `--auto` 等
都是 root 参数，TUI 和 `run` 共享。

`packages/opencode` 现在只有旧的构建产物，没有源码入口；
源码入口只有 `packages/cli/src/index.ts`。

---

## 1.2 解析 endpoint

`ServerConnection.resolve()`（`cli/src/services/server-connection.ts`）：

| 条件 | 行为 |
|---|---|
| `--server <url>` | 构造 `{url, auth}`，`GET /api/info` 探活；版本不同只警告 |
| `--standalone` 或 service config `disabled: true` | `Standalone.start()`：起一个私享 server 进程 |
| 默认 | `Service.ensure(options)`：发现共享 daemon，必要时 spawn |

- `--server` 与 `--standalone` 互斥；
- 共享模式读取注册文件、Basic Auth、版本检查，返回 `endpoint`；
- `mismatch: "replace" | "ignore" | "error"` 控制版本不一致时的行为；
- 返回的 `service` 还带 `reconnect` / `restart`，TUI 在服务替换后可重连。

`Standalone.start()` 会启动当前二进制：

```
selfCommand() serve --stdio --port 0
  → stdout 输出 { url } / "server password ..."
  → 客户端解析 endpoint
```

`--server` 模式的密码来自 `OPENCODE_PASSWORD`（Basic Auth 用户名为 `opencode`）。

---

## 1.3 TUI 初始化

`packages/cli/src/commands/handlers/default.ts`：

1. `process.chdir(directory)`
2. `ServerConnection.resolve(...)`
3. 处理 `--session`：如果 ID 已存在则续用，不存在则作为"首个 prompt 创建"的 ID
4. 启动后台更新检查（10 分钟一次）
5. `run({ app, server, args, config, updater, packages, environment, log, ... })`

`packages/tui/src/app.tsx` 的 `run()`：

1. `Config.resolve(input.config.get())`：读取 `cli.json`（主题、keymap、mouse…）；
2. `OpenCode.make({ baseUrl, headers })`；
3. `api.file.list({ location: { directory: cwd } })` → 拿 `location`；
   失败则退回 `api.location.get()`；
4. 发现本地 TUI 插件目录；
5. 接管 terminal handoff（如果是 daemon 重启后的 TUI 复用手册，见第 11 课）；
6. 创建 `@opentui/core` renderer：
   - `targetFps: 60`
   - `useMouse` 来自 `cli.json`
   - `exitOnCtrlC: false`（Ctrl-C 交给应用处理）
7. 挂 Provider 树：

```
Log → Exit → Epilogue → TuiApp → ErrorBoundary
  → Paths → Storage → Lifecycle → TerminalEnvironment → Startup
  → Clipboard → Args → Config → Keymap → Toast → Route
  → Client → Data → Local → Permission → Plugin → …
```

8. 进入初始路由：Home 或 Session（`--continue` / `--session` / `--prompt`）。

`DataProvider`（`tui/src/context/data.tsx`）创建 `createData()`，立即开始：

- `session.active` / session 列表；
- location config、provider、model、agent、skill、command；
- 打开 `GET /api/event` SSE。

---

## 1.4 Server 启动

### 1.4.1 `opencode serve`

`cli/src/commands/handlers/serve.ts` → `cli/src/server-process.ts`：

```
mode = default | service | stdio
  ├─ service 模式：chdir(home)，读 service config，固定/默认端口，写注册文件
  ├─ stdio 模式：不写注册文件，stdin 关闭即退出（嵌入方使用）
  └─ default：前台，随机密码，端口默认从 4096 找空位
```

步骤：

1. 读取 PTY handoff（`OPENCODE_PTY_HANDOFF`，消费后删除）；
2. 计算 hostname/port/password；
3. 若配置了固定端口，先 `Service.incumbent` 检查是否已有兼容服务在位；
4. `import("@opencode/server/process").start(...)`；
5. 监听成功后：
   - service 模式：持久化密码（若未配置）→ `ServiceRegistration.register`
   - 打印 `server listening on ...`；stdout 模式输出 JSON
6. service 模式等待 `server.shutdown`；stdio 等 stdin 关闭；前台保持运行。

### 1.4.2 HTTP 层

`packages/server/src/process.ts`：

```
listen(hostname, port)
  → node:http createServer
  → NodeHttpServer.make
  → dispatch(password, status, application, ...)
       ├─ 未就绪时 /api/info 返回 503 + retry-after
       ├─ 其它请求先验 Basic Auth
       └─ 就绪后交给 HttpRouter
  → serve(app, compression, CORS, error logger)
  → boot:
       Layer.build(createRoutes(options))
         ├─ LayerNode: Database / Bus / Session / Job / Project / PTY / …
         ├─ HttpApiBuilder.layer(Api)
         ├─ handlers + 中间件
         └─ V1Migration.layer（旧库导入）
       → 安装 SessionRestart：恢复带 claim 的会话
       → status.ready
```

`/api/info` 在启动阶段也回答，因此客户端可以在服务尚未 ready 时区分
"正在启动"（503 starting）与"启动失败"（503 failed）。

---

## 1.5 Location 懒加载

### 1.5.1 一个 daemon，多套服务图

`server/src/location.ts` 的 `LocationMiddleware`：

```
requestRef(request):
  directory = query.location[directory]
           ?? header["x-opencode-directory"]
           ?? process.cwd()
  ref = Location.Ref({ directory })
  effect.pipe(Effect.provide(locations.get(ref)))
```

`LocationServiceMap`（`core/src/location-services.ts`）是一个 `LayerMap`：

- key = `canonical(Location.Ref)`（目录规范化 + workspaceID）；
- value = `Instance.layer(ref)` 编译出的整套 Location 服务；
- **构建成功后长期保留**（`idleTimeToLive: infinity`），显式 invalidate 或进程退出才关闭；
- 构建失败会 invalidate，下一次请求可重试；
- invalidate 时先解除路由，再关闭权限/表单/RPC、发布 `location.shutdown`；
  正在运行的 step 仍持有借来的服务图，在边界处交接。

### 1.5.2 Location 图里有什么

`core/src/instance.ts` 的 `nodes` 顺序就是启动顺序（依赖关系已由 LayerNode 解析）：

```
Location / LocationLifecycle
Config → Agent → Command → Reference → Rpc → WebSearch → Integration
Provider → Model → ModelResolver → AISDK
Plugin → PluginHooks → InstancePlugins → PluginSupervisor
WorktreeStrategies → FileSystemSearch → FileSystem → ShellSelect → Pty → Shell
Skill → InstructionBuiltIns → InstructionDiscovery
FileAccess → FileMutation → Formatter → Mcp → Permission
Tool → ToolOutput → Image → SkillInstructions → ReferenceInstructions
InstructionEntry → Form → Generate → ReadToolFileSystem → McpTool
SessionInstructions → SessionRunnerModel → SessionCompaction → SessionTitle
SessionContext → Snapshot → SessionRunnerLLM → Vcs → LocationWatcher
```

所以：

- 配置最先构建，插件在 Provider/Model 解析之后、工具/skill 首次使用之前激活；
- `PluginSupervisor` 激活插件，工具/agent/skill/provider 的 transform 在这时重放；
- `SessionRunnerLLM` 是 Location 范围服务，但由进程级的 `SessionExecution` 在 drain 时选用。

---

## 1.6 配置与插件在启动中的位置

- **Config**：`Config.Service` 在 Location 图里构建，读取 `opencode.json(c)` 与 `.opencode` 目录；
  具体来源与优先级见第 08 课。
- **Plugin**：`PluginSupervisor` 在 Config 之后启动，按 `pre → SDK/实例/外部 → post`
  激活；`Plugin.awaitActivation` 是会话准入与模型请求的等待点。
- **TUI 偏好**：完全在客户端，`cli.json`（`~/.config/opencode/cli.json`），
  不经过 server。

---

## 1.7 首屏同步

TUI 的 `createData()` 首次同步大致分两批：

**阻塞可见 UI 的批**：

```
session.active / session list
location config
provider / model / agent / skill / command
```

**非阻塞批**：

```
session.message（当前会话）
permission / form 列表
mcp / vcs / integration 状态
```

首屏路由：

- 无 session → Home
- `--continue` → 最近会话
- `--session` → 指定会话
- `--prompt` → 新会话并在挂载后提交

`server.connected` 是 SSE 的第一帧；客户端必须收到它才认为连接成功。
重连后客户端会重新拉取当前状态，并依靠 resume/事件补洞。

---

## 1.8 一次启动的时间线

```
opencode
  ├─ Effect CLI 解析参数
  ├─ ServerConnection.resolve
  │    ├─ 读 service.json → probe /api/info
  │    ├─ 健康且版本匹配 → 复用
  │    └─ 否则 → spawn "opencode serve --service" → 轮询直到 ready
  ├─ TUI run()
  │    ├─ 读 cli.json
  │    ├─ 建 client + renderer + Provider 树
  │    └─ 打开 /api/event
  │
  ├─ Server 进程
  │    ├─ listen + dispatch（/api/info 可先回答）
  │    ├─ createRoutes → 构建全局服务图
  │    ├─ status.ready
  │    └─ SessionRestart.resumeSuspendedSessions
  │
  └─ 第一个 Location 请求
       └─ Instance.layer(ref)
            ├─ Config + PluginSupervisor
            ├─ Agent / Provider / Model / Tool / Skill / MCP
            └─ SessionContext / SessionRunner / Compaction
```

---

## 1.9 小结

1. **TUI 是客户端**：启动时解析 endpoint，连不上就按策略发现/拉起 daemon。
2. **Server 有两层启动**：进程级 HTTP/Core 图，Location 级按目录服务图。
3. **配置与插件在 Location 启动时加载**，不是进程启动时。
4. **`/api/info` 先于 ready**：客户端能区分 starting / failed / incompatible。
5. **重启恢复在 server 就绪后自动执行**（第 11 课）。
6. **TUI 偏好完全在客户端**：`cli.json`，server 不感知。

> **迁移小注**：`packages/opencode/src/cli/cmd/tui.ts`、`cli/tui/worker.ts`、
> `TuiThreadCommand`、`InstanceBootstrap`、`server.instance.disposed` 都是 V1；
> V2 对应 `packages/cli` 命令树、`ServerConnection`、`LocationServiceMap`。
