# 3. 执行中的新输入：Inbox、steer/queue 与协调器

> 本课回答：模型还在流式输出时，用户又提交了一条输入，会发生什么？
> 输入怎么被"高效"读到？为什么不会丢、不会叠循环、也不会打断正在流的调用？
>
> V1 的 `Runner.ensureRunning` + `join` 已经删除。V2 只有一条链路：
> **准入（admit）→ 门铃（wake）→ 协调器（coordinator）→ runner 边界晋升**。

---

## 3.1 结论先给

- opencode **业务代码里没有 epoll/select/poll 调用**。键盘感知是
  `process.stdin` 的 `"data"` 事件；epoll 是 Bun 运行时在 Linux 下的 I/O 多路复用实现。
- 客户端提交输入**不阻塞**：TUI 先乐观插入本地行，HTTP 发出后立即返回输入循环。
- 服务端把输入写进 durable `session_inbox` 行，然后只按一次"门铃"。
- 同一 Session 同时只有一个执行 fiber（drain）；运行中的 wake 合并成 `pendingWake`。
- `steer` 在下一个安全 step 边界晋升；`queue` 等到会话将要空闲时一次晋升一条。
- 真正打断流只有 `POST /api/session/:id/interrupt`（TUI 里 Esc 连按两次）。

---

## 3.2 进程与线程

```
┌─ 客户端进程 ───────────────────────────┐   ┌─ Server 进程 ──────────────────────┐
│ TUI 渲染 + 键盘 (Bun 事件循环)          │   │ HTTP + Core 服务图                 │
│ client: fetch / SSE / 乐观 store        │──▶│ SessionInbox → Coordinator →       │
│                                         │SSE│ Execution → Runner → llm.stream    │
└─────────────────────────────────────────┘   └────────────────────────────────────┘
```

- 本地默认连**共享 daemon**；`--standalone` 或 `--server` 则换 endpoint（第 11 课）。
- 模型推理与工具执行都在 server 进程；客户端只消费事件。
- 因此即使 server 很忙，TUI 的键盘/渲染仍在自己的进程里。

---

## 3.3 输入感知：事件驱动，不是轮询

```
键盘按键
  → TTY 缓冲
  → Bun 事件循环可读回调（Linux 底层 epoll）
  → process.stdin 触发 "data"
  → @opentui/core CliRenderer 的 stdin 监听
  → StdinParser 解析转义序列（普通键 / 方向键 / 鼠标 / 括号粘贴）
  → KeyEvent / MouseEvent / PasteEvent
  → Solid 组件或 keymap 命令
```

- 有字节才执行；空闲时事件循环挂起，不空转。
- **opencode 源码里没有系统调用级别的多路复用代码**；epoll 属于 Bun。
- 渲染不是逐 token 重绘：客户端把 SSE 事件按 **10ms** 批量 flush
  （`client/src/solid/connection.ts` 的 `flushInterval`），一帧内合并 Solid 更新；
  renderer 目标 60fps。

### 输入框在 busy 时仍可用

`tui/src/routes/session/index.tsx`：

```ts
const disabled = createMemo(() =>
  promptedPermissions().length > 0 || forms().length > 0,
)
```

即只有**权限/表单弹窗**会禁用输入；模型运行中照常输入、照常提交。
提交走 `data.session.prompt()` 的乐观路径，不 await 网络。

打断是独立命令：Esc 连按两次 → `client.api.session.interrupt({ sessionID })`
（`component/prompt/index.tsx` 的 `session.interrupt`）。

---

## 3.4 准入：`Session.prompt` 只落库

`packages/core/src/session/session.ts`：

```
prompt(sessionID, input)
  ├─ get(sessionID)
  ├─ messageID = input.id ?? new
  ├─ existing = SessionInbox.reconcile(...)        // 同 ID 重放 → 幂等
  ├─ SessionPrompt.prepare(...)                    // 解析文件/agent/skill，跑 session.prompt hook
  ├─ 若有 staged revert → commit
  ├─ SessionInbox.admit({ id, sessionID, item })   // 写 session.inbox.enqueued
  └─ if (resume !== false) execution.wake(sessionID)
```

`SessionInbox.admit`（`session/inbox.ts`）：

- 通过 `Bus.publish(SessionEvent.InboxEnqueued)` 拿到聚合 seq；
- 同一事务里投影插入 `session_inbox` 行；
- 立即返回，**不等模型**；
- 同 Session + 同类型的同 ID 重放返回已有条目（首次准入获胜）；
- 跨 Session / 跨类型复用 ID → `LifecycleConflict` → `PromptConflictError`。

`synthetic` 走同一条路：`type: "synthetic"`，用于后台完成通知、重启提示、
skill 内容、Plan 模式提醒等。`resume: false` = 只准入、不响铃。

---

## 3.5 协调器：一个 Session 一个 busy period

`session/run-coordinator.ts`：

```
wake(key, scope)
  ├─ 已有 execution → pendingWake = 合并（scope 取更宽的 "input"）
  └─ 空闲 → start(key, force=false, scope)

run(key)                 // 显式 resume：空闲则起，运行中则等待同一次执行结束
  └─ 返回该 execution 的 exit

interrupt(key)
  ├─ 空闲/正在停止 → false
  ├─ 标记 stopping，清掉此前的 pendingWake
  └─ fork Fiber.interrupt(owner)，立即返回
```

一个 execution 内部是：

```
loop:
  drain(key, force, scope)
  若 stopping 或没有 pendingWake → 结束
  否则取走 pendingWake，yieldNow 后继续 drain
```

- 不同 Session 的 execution 并行；
- 同一 Session 的多次 wake **coalesce**；
- 若 wake 发生在 drain 已经决定结束之后，`settle` 会启动 successor execution；
- `started` / `settled` 钩子负责写 durable claim 与终态事件（第 11 课）。

---

## 3.6 Runner：在安全边界晋升输入

`session/runner/llm.ts` 的 `drain`：

```
advanceToStep():
  while true:
    ├─ Location 关闭 → Reloaded/return
    ├─ 取 pending（进入/空闲边界 scope="input"，step 中 scope="steer"）
    ├─ 遇到 move → 关闭 transport、发布 Moved、返回 Moved
    ├─ 遇到 compaction → 执行压缩、发布 Started/Ended|Failed、continue
    ├─ 没有可晋升输入 → Complete
    ├─ prepareContext + SessionInbox.promote
    │    ├─ 成功晋升 > 0 → step 重置为 1
    │    ├─ 首次无标题会话 → 后台生成 title
    │    └─ 重新加载 SessionContext
    └─ 返回 Ready → runStep
```

### 晋升规则

`SessionInbox.promote(db, bus, sessionID, scope)`：

- 先取所有 pending **steer**；
- 遇到第一个 `compaction` / `move` 控制项就停下，不越过；
- 若第一条就是控制项 → 返回 `undefined`，由 runner 先处理控制项；
- `scope === "steer"` 时**绝不动 queue**；
- `scope === "input"` 且没有 steer 时，只晋升**一条** queue；
- 每次晋升通过 `session.inbox.delivered` 事件在**同一事务**里：
  删除 inbox 行 + 插入可见消息；
- 晋升成功后 `step = 1`，重置该 agent 的步数配额。

### 两种投递

| delivery | 语义 | 适用 |
|---|---|---|
| `steer`（默认） | 下一个 step 边界插队；不打断当前 `llm.stream` | 用户追加、后台完成通知 |
| `queue` | 会话将要空闲时才晋升一条 | 用户明确排队、不希望插队 |

`session_inbox` 只存**未消费**工作；一旦 delivered 就变成消息行。

---

## 3.7 中断

```
TUI Esc×2
  → POST /api/session/:id/interrupt
  → Session.interrupt
  → SessionExecution.interrupt
  → coordinator.interrupt
       ├─ 标记 stopping
       ├─ 清掉 pendingWake（属于被中断的意图）
       └─ Fiber.interrupt(execution fiber)
  → runner/step 收尾：
       ├─ 进行中的工具 fiber 被中断
       ├─ 未结算工具写 Tool.Failed(aborted)
       ├─ assistant 标记 interrupted
       └─ 发布 session.execution.interrupted
```

- 中断是 fire-and-forget：接口立即返回，清理异步完成；
- `options.resume` 可在中断后按剩余的 steer 输入起 successor（默认不 resume）；
- 空闲 Session 的 interrupt 是 no-op；未知 Session 由公共 API 报错。

---

## 3.8 完整时序：运行中追加输入

```
用户按回车
  │
  ├─ TUI data.session.prompt()
  │    ├─ 同步插入本地 pending 行
  │    └─ POST /api/session/:id/prompt（不 await 渲染）
  │
  ├─ Server Session.prompt
  │    ├─ SessionPrompt.prepare（文件/agent/skill/hook）
  │    ├─ SessionInbox.admit → session_inbox 行 + InboxEnqueued
  │    └─ execution.wake
  │         └─ 已有 execution → pendingWake = steer（合并）
  │
  ├─ 当前 step 的 llm.stream 继续，不被打断
  │
  ├─ step 结算（Tool.Success/Failed、Step.Ended）
  │
  ├─ advanceToStep: scope=steer → promote 这条输入
  │    └─ InboxDelivered：删 inbox 行 + 插 user 消息（同事务）
  │
  ├─ 下一次 llm.stream 的历史里已经包含新输入
  │
  └─ TUI：SSE 事件批量 flush → 消息从 pending 变为真实行
```

抢在 `advanceToStep` 决定 Complete 之后到达的输入，会由 coordinator 的
`settle → successor` 接住，不会丢。

---

## 3.9 常见误区

| 误区 | 事实 |
|---|---|
| "opencode 自己用 epoll 读键盘" | 没有；是 Bun 事件循环 + `stdin.on("data")` |
| "新输入会打断当前流" | 不会；只在 step 边界晋升，除非显式 interrupt |
| "wake 等于开始执行" | wake 只是门铃；执行由 coordinator 决定 |
| "queue 会在当前 step 后立刻跑" | 不会；queue 只在会话将要空闲时晋升一条 |
| "inbox 行是历史的一部分" | 不是；它只存未消费工作，delivered 后变成消息 |
| "提交要等 server 返回才显示" | TUI 是乐观插入，失败才回滚 |

---

## 3.10 小结

1. **输入不阻塞**：客户端乐观提交 + SSE 增量渲染。
2. **准入与执行分离**：`session_inbox` 是唯一入口，wake 是 advisory。
3. **一个 Session 一个 drain**：协调器串行化同会话，允许跨会话并行。
4. **边界晋升**：steer 在 step 边界、queue 在空闲边界；控制项优先且不可越过。
5. **中断独立**：只有 `interrupt` 会停止正在流的调用。
6. **不丢、不重、可恢复**：inbox 行、投影、claim 都在 SQLite。

> **迁移小注**：旧资料里的 `session_input`、`promoted_seq`、`Runner.ensureRunning`、
> `RunState` 都是 V1；V2 对应 `session_inbox`、`enqueued_seq`、
> `SessionRunCoordinator` / `SessionExecution`。
