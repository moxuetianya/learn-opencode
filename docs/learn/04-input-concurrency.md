# 4. 执行中的新输入：会话并发与输入感知机制

## 4.1 场景与要回答的问题

使用 TUI 时最常见的交互：**模型还在流式输出（上一个问题正在执行），用户又按回车提交了新输入**。
opencode 既不会丢掉新输入，也不会让界面卡住。本章梳理两条主线：

1. **输入感知**：键盘输入是如何被"高效"读到的？是 epoll 吗？
2. **会话并发**：新输入到达时，正在执行的循环/流怎么处理它（接着干、排队、还是打断）？

结论先放在前面：

- opencode **业务代码里没有任何 epoll/select/poll 调用**。"高效感知"的最后一公里是 **Bun 运行时在 Linux 上用 epoll 做 I/O 多路复用**（键盘 stdin、网络 socket、子进程、定时器都挂在同一事件循环上）；opencode 自己只做"事件驱动"的注册与分发。
- 新输入的处理分两条服务端链路：**v1（legacy `SessionPrompt`，当前 HTTP 端点默认）用 Runner 的 join**，**v2（`SessionV2`）用"落盘 + 协调器 wake"**，二者都不依赖 UI 线程。

## 4.2 进程架构：输入与执行分离到两个线程

`opencode` 编译为 Bun 原生二进制（`packages/opencode/script/build.ts:168` 的 `Bun.build` + `compile`）。TUI 模式运行时拆成两个线程：

```
┌─ 主线程：TUI ──────────────────┐   ┌─ Worker 线程：Server ───────────────┐
│                                │   │                                    │
│  渲染（@opentui + Solid.js）     │   │  HTTP 应用（Effect HttpApiBuilder） │
│  读键盘（process.stdin）         │   │  v1: SessionPrompt.loop()          │
│  SDK client（fetch 代理）       │RPC│  v2: SessionV2 / SessionExecution   │
│  createWorkerFetch()           │◀─▶│  rpc.fetch / rpc 方法                │
│  createEventSource()           │   │  GlobalBus → global.event 推送       │
└────────────────────────────────┘   └─────────────────────────────────────┘
```

- 启动：`packages/opencode/src/cli/cmd/tui.ts:210` 里 `new Worker(target())` 起 server worker，再 `run({ url: "http://opencode.internal", ... })` 跑 TUI。
- 默认模式**没有 OS socket**：`packages/opencode/src/cli/tui/worker.ts:30` 的 `rpc.fetch` 直接调 `Server.Default().app.fetch(request)`，TUI 侧用 `createWorkerFetch`/`createEventSource`（`tui.ts:24-50`）把 fetch/SSE 模拟成进程内 RPC。
- 只有 `--port`/`--hostname` 才走真实网络：`packages/opencode/src/server/server.ts:200` 的 `node:http.createServer`。

好处：即使模型推理 / 工具执行再阻塞 worker 线程，主线程的**渲染和输入依旧流畅**（RPC 是异步消息）。

## 4.3 输入感知：事件驱动，不是轮询

### 4.3.1 键盘到事件的两段式

```
键盘按键 → 内核 TTY 缓冲
        → Bun 事件循环就绪回调（Linux 底层 = epoll）
        → process.stdin 触发 "data" 事件
        → @opentui/core 的 CliRenderer.stdinListener
        → StdinParser 解析转义序列（普通键 / 方向键 / 鼠标 / 括号粘贴）
        → 派发 KeyEvent / MouseEvent / PasteEvent
        → 路由到 Solid.js 组件或 keymap 命令
```

- 感知层在 `@opentui/core`：`CliRenderer` 构造时 `this.stdin.on("data", handler)`，handler 把字节 `push` 进 `StdinParser`（`ByteQueue` + 转义序列状态机），解析出结构化事件。
- 这是**事件驱动**：有字节才执行，没有输入时事件循环挂起，不空转、不轮询。
- **epoll 的真实位置**：opencode 跑在 Bun 的事件循环上，Bun 在 Linux 下用 epoll 做 I/O 多路复用。所以严格说是"**Bun 用 epoll**"，opencode 源码里没有系统调用级别的代码。

### 4.3.2 渲染的批处理与帧输出

即使 `llm.stream` 每秒吐成百上千个 token 事件，界面也不会逐字符重绘：

- **16ms 批量 flush**：`packages/tui/src/context/sdk.tsx:68-80` 的 `handleEvent` 把事件先入队，若距上次 flush 不足 16ms 就等定时器一起 `batch()` 提交，一次触发所有 store 更新 → 每帧最多一次重渲染。
- **帧渲染 + diff**：renderer 按 `targetFps: 60` 出帧，只向终端写差异。
- **SSE 重连退避**：`sdk.tsx:112-114`，断线按指数退避（1s → 30s）重连，事件流不丢。

### 4.3.3 输入框在 busy 时保持可用

`packages/tui/src/routes/session/index.tsx:236`：`disabled` 只在**权限/提问弹窗**时置真；模型 busy 时输入框照常可输入、可提交。提交走 `packages/tui/src/component/prompt/index.tsx:1093` 的 `sdk.client.session.prompt(...)`，且是 **fire-and-forget**（`.catch()` 不 await），所以提交后渲染循环立即恢复响应。

打断是另一条独立路径：`prompt/index.tsx:407-418` 按 Esc（5 秒内连按两次）→ `store.interrupt >= 2` → `sdk.client.session.abort({ sessionID })` → 服务端中断当前 run。

## 4.4 服务端 v1：Runner 的 join（当前默认）

HTTP 端点 `POST /session/:id/prompt` 默认走 legacy `SessionPrompt`。

调用链与并发语义：

```
SessionHttpApi.prompt (handlers/session.ts:295)
  └─ SessionPrompt.prompt (session/prompt.ts:1052)
       ├─ revert.cleanup(session)
       ├─ createUserMessage(input)          # ① 先持久化 user 消息
       └─ loop({ sessionID })               # ② 请求执行
            └─ RunState.ensureRunning       # (run-state.ts:88)
                 └─ Runner.ensureRunning    # (effect/runner.ts:115)
```

`Runner.ensureRunning` 的状态机（`Idle / Running / Shell / ShellThenRun`）：

| 当前状态 | 新 prompt 的行为 |
|---------|-----------------|
| `Idle` | 启动一个新 run fiber（`startRun`） |
| `Running` | **join**：`awaitDone(st.run.done)`，不另起循环，等现有循环结束 |
| `Shell` | 先挂起为 `ShellThenRun`，shell 结束再启动 run |
| `ShellThenRun` | join |

关键点：**普通 prompt 永远不会拒绝**。正在跑的 `runLoop`（`prompt.ts:1081`）每轮迭代都从 DB 重新读消息（`MessageV2.latest`），所以新 user 消息会在**下一个迭代边界**（当前 provider turn / 工具结果结算完）被看见，循环继续而不是退出——即"接着干"。

- 副作用：`session.prompt` 这个 HTTP 请求会一直挂着，直到整轮循环彻底结算才返回；TUI 不 await 它，所以无感知。
- 只有 `shell` / `revert` 等需要互斥的操作才用 `assertNotBusy` / `mapBusy` 拒绝，返回 `SessionBusyError`（409）。

## 4.5 服务端 v2：落盘 + 协调器 wake（新核心）

v2 把"输入准入"与"模型执行"彻底分离。核心文件在 `packages/core/src/session/`。

### 4.5.1 准入（admit）即返回

`V2Session.prompt`（`packages/core/src/session.ts:360`）：

```
prompt(input)
  ├─ result.get(sessionID)              # 会话必须存在
  ├─ resolvePrompt(input.prompt)
  ├─ SessionInput.admit(db, events, …)  # ① 持久化一行 session_input（delivery: steer|queue）
  ├─ 校验 admitted 与请求等价，否则 PromptConflictError
  └─ execution.wake(sessionID)          # ② 触发一次"协调"（resume !== false 时）
```

`SessionInput.admit`（`packages/core/src/session/input.ts:41`）通过 `SessionEvent.PromptAdmitted` 事件拿到聚合序列号后**立即返回** admitted 记录，不等执行。同 ID 重放返回已 admit 的记录（幂等）。

### 4.5.2 协调器：wake 合并 + successor drain

`SessionExecution` 是进程级、按 Session ID 的服务；本地实现 `packages/core/src/session/execution/local.ts` 把它接到 `SessionRunCoordinator`（`run-coordinator.ts`）。

- `wake`（`run-coordinator.ts:81`）：若该 Session 正在执行，只置 `pendingWake = true`——**多次唤醒 coalesce 成一次**；若空闲，直接起一个 drain。
- `settle`（`run-coordinator.ts:51-65`）：当前 drain 结束后，若 `pendingWake` 且未被 stop，用 `successor = true` 起**下一个 drain**（`Effect.yieldNow` 之后立刻开始），实现"接着跑"。
- 每个 Session 同时只有**一个** drain，不同 Session 可并行。

### 4.5.3 drain 内：安全边界提升输入

`SessionRunner.run`（`packages/core/src/session/runner/llm.ts:383`）：

```
run(sessionID, force)
  ├─ hasPending("steer") ? promotion="steer" : hasPending("queue") ? "queue" : undefined
  ├─ while shouldRun:
  │    ├─ while needsContinuation:                    # 一个 provider turn
  │    │    └─ runTurn(sessionID, promotion, step)    # 每次只调一次 llm.stream()
  │    │        ├─ promotion 时：promoteSteers / promoteNextQueued（在 cutoff 内提升）
  │    │        ├─ 重载投影历史 SessionHistory.entriesForRunner
  │    │        └─ 结算工具、持久化事件
  │    │    └─ needsContinuation ||= hasPending("steer")
  │    └─ shouldRun = hasPending("queue")              # 会话将空闲时提升一个 queue
```

投递语义（对应 `delivery` 字段）：

- **`steer`（默认）**：在**下一个安全 provider-turn 边界**提升全部 pending steers；一批 steers 只重置一次步数上限。**不会打断正在流的 `llm.stream`**，只是下个 turn 把新消息纳入投影历史。
- **`queue`**：保持 pending，直到会话即将空闲时才提升**一个**，随后重新评估是否继续，再决定是否提升下一个。

要真正打断流，只能走 `V2Session.interrupt` → `execution.interrupt`（`run-coordinator.ts:94`）：中断当前 drain 的 fiber；空闲或缺失时是 no-op（幂等）。

## 4.6 一次完整时序：模型运行中用户提交新输入

```
用户按回车
  │
  ├─ TUI: sdk.client.session.prompt({...})  (fire-and-forget)
  │        └─ createWorkerFetch → RPC fetch → worker 线程
  │
  ├─ Server:
  │   v1:  createUserMessage() 落库
  │        loop() → Runner.ensureRunning → join 现有 run
  │        正在跑的 runLoop 下轮迭代看到新 user 消息 → 继续，不退出
  │
  │   v2:  SessionInput.admit() 落库（delivery=steer）
  │        execution.wake() → coordinator.pendingWake=true（合并）
  │        当前 turn 结算 → successor drain → 提升 steers → 下个 turn 生效
  │
  └─ TUI 渲染：SSE/global.event 批量(≤16ms) → batch() → 一帧重绘
```

用户想打断（Esc ×2）：
```
TUI: sdk.client.session.abort({ sessionID })
  ├─ v1: RunState.cancel → Runner.cancel → Fiber.interrupt → onInterrupt（标记 assistant 消息 aborted）
  └─ v2: V2Session.interrupt → execution.interrupt → 中断当前 drain fiber
```

## 4.7 常见误区：epoll

- **opencode 没有直接调用 epoll**。仓库里搜不到 `epoll/select/poll/io_uring` 的调用。
- 键盘感知 = `process.stdin` 的 `"data"` 事件，是**事件驱动**，不是轮询。
- epoll 是 **Bun 运行时**在 Linux 下的实现细节：Bun 的事件循环（stdin、socket、timer 共用一个 loop）用 epoll 做 I/O 多路复用；macOS 则是 kqueue。
- 默认本地模式 TUI↔server 是进程内 RPC，**根本不经过 OS socket**，连 epoll 都不涉及；只有 `--port` 模式走真实 `node:http`（同样是 Bun 的 loop 托管）。

## 4.8 设计要点小结

| 关注点 | 机制 | 位置 |
|--------|------|------|
| 输入不阻塞渲染 | 单线程事件循环，非阻塞 `stdin.on("data")` | `@opentui/core` CliRenderer |
| token 洪泛不重绘 | 16ms 批量 flush + `batch()` + 60fps 帧渲染 | `packages/tui/src/context/sdk.tsx` |
| 执行不拖累 UI | server 放 Worker 线程，RPC 异步 | `cli/tui/worker.ts` |
| 新输入不丢 | v1 先落 user 消息再 join；v2 先落 `session_input` 再 wake | `session/prompt.ts` / `core/session/input.ts` |
| 新输入不叠循环 | v1 `Runner` 状态机 join；v2 协调器单 drain + `pendingWake` 合并 | `effect/runner.ts` / `core/session/run-coordinator.ts` |
| 打断唯一入口 | Esc×2 → `session.abort` → fiber interrupt | `prompt/index.tsx` |
