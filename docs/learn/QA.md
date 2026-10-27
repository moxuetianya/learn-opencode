# OpenCode V2 学习问答（QA）

> 本文件汇总学习过程中提出的问题，只讨论 V2（opencode 2.0.24）。
> 课程正文以讲原理为主；这里用问答形式把容易混淆的概念讲透。
>
> 相关课程：02（一次对话）、03（输入并发）、04（Session Core 地图）、05（Agent 内核）。
>
> **Q1–Q12** 偏会话内核与插件能力；**Q13–Q21** 偏构建、安装布局与多实例定制。
> Q13–Q21 的「实测」输出来自本机安装版 2.0.32，代码定位仍以仓库 2.0.24 为准。

---

## Q1. `steer` 和 `queue` 有什么区别？

两者都是 Session 收件箱（`session_inbox`）的投递模式，区别只在**会话忙的时候**体现。
两者都**不会打断正在流的 `llm.stream`**；真正打断只有 `Session.interrupt`。

| | `steer`（默认） | `queue` |
|---|---|---|
| 什么时候被提交给模型 | 当前 step 结束后的**下一个安全边界** | 会话**将要空闲**时，一次只提交一条 |
| 用途 | 补充上下文、纠正方向、追加要求 | 排下一个任务，不干扰当前工作 |
| 是否插队 | 是 | 否 |
| 多条同时到达 | 一批 pending steer 一起提交 | 一次晋升一条 |
| 空闲时提交 | 立即执行 | **也立即执行** |

### 时序

```
模型正在 step 3（流式输出 + 工具执行）
  │
  ├─ steer："顺便检查一下测试"
  │     → 不进当前流
  │     → 等 step 3 的工具全部结算
  │     → 下一个边界一起提交给模型
  │
  ├─ queue："然后帮我改 README"
  │     → 一直挂着
  │     → 等模型这轮工作结束、会话即将空闲
  │     → 才提交这一条
  │
  └─ Esc×2 → interrupt
        → 唯一会真正打断当前流的方式
```

### 精确规则

- `steer`：在 `advanceToStep()` 的 step 边界晋升；一批 steer 一起晋升，
  并且只重置一次步数配额。
- `queue`：只在 `scope = "input"` 的空闲边界晋升**一条**；晋升后 runner 重新评估，
  再决定是否继续下一条。
- 控制项（compaction/move）优先级更高，新输入不能越过它们。

### TUI 操作

| 操作 | 行为 |
|---|---|
| Enter | 默认 `steer` |
| `<leader>return` | `Queue prompt`，按 `queue` 提交 |
| `<leader>q` | 管理已排队的 prompt（撤销/删除） |

### 已准入但未投递的条目

还可以改投递方式或取消：

- `PATCH /api/session/:id/inbox/:inboxID`：改 `delivery`
- `DELETE /api/session/:id/inbox/:inboxID`：取消

已投递的条目不能再改，会返回冲突。

---

## Q2. 一个 `execution` 是否只能执行一个 Session？自始至终都是同一个会话吗？

**是。一个 execution 从头到尾只属于一个 Session。**

`SessionRunCoordinator` 内部是：

```ts
Map<SessionID, Execution>
```

- 每个 key 是一个 Session；
- 一个 `Execution` 只服务这个 key；
- `drain` 开始时通过 `SessionStore` 和 `session.location` 找服务图，但 Session ID 不变；
- `wake/run/interrupt/awaitIdle` 都按 sessionID 定位。

所以一个 execution **不可能中途切换到另一个会话**。

### 但一个进程可以同时有多个 execution

不同 Session 的 execution 并行：

```
进程
├─ Execution(ses_A)
├─ Execution(ses_B)
└─ Execution(ses_C)
```

同一 Session 在**本进程内**最多只有一个 execution。

### successor 仍是同一个 Session

```
当前 execution fiber:
  drain → drain → drain

wake 在 drain 决定结束之后才到:
  settle() → start() 一个 successor execution
```

- successor 是新的 `Execution` 对象；
- 但不是并发，而是前一个结束后的接续；
- 仍然只服务原来的 sessionID。

### 看起来“换会话”，其实没有

| 情况 | 实际发生 |
|---|---|
| `session.move` | 换 Location / 服务图，**Session ID 不变** |
| compaction | 同一 Session 的历史边界变化，Session 不变 |
| 前台 subagent | 父 Session 等待工具；子 Session 有自己的 execution |
| 后台 subagent | 子 Session 独立执行，完成后向父 Session 投递 synthetic |
| `session.fork` | 创建**新的 Session**，因此是新的 execution |

### 限定：process-local

`SessionExecution` 当前是进程内协调：

- 同一个 server 进程内，一个 Session 只有一个 execution；
- 不提供跨进程锁或集群所有权；
- 托管服务协议假设同一时刻只有一个 managed server 拥有数据库。

---

## Q3. `drain` 是什么？它和 ReAct 循环、step、execution 是什么关系？

`drain` 是 `SessionRunner.drain()` 的一次调用，可以理解为：

> **“把当前 Session 手头能推进的工作，推进到暂时没得做为止。”**

它不是一个 step，也不是一次模型调用。

### 层级关系

```
Execution（一个 busy period，绑定一个 Session）
  └─ drain #1
       ├─ advanceToStep()    // 取输入、处理控制项
       ├─ step 1             // 一次逻辑 LLM 调用 + 工具执行
       ├─ step 2
       └─ ...
  └─ drain #2（execution 内又来了 wake）
       └─ step 3
```

- **一个 drain** 可以包含 0 个或多个 step；
- **一个 step** 对应一次逻辑 LLM 调用；
- **Physical Attempt** 是一次真实 provider 请求，每次恰好一次 `llm.stream`；
- **一个 execution** 是一段 busy period，可以包含多个 drain；
- **successor** 是前一个 execution 结束后的接力，仍是同一个 Session。

### drain 内部做什么

简化后的 `SessionRunner.drain`：

```
drain:
  advanceToStep():
    ├─ 取 pending 输入（steer 或 queue）
    ├─ 遇到 move → 换 Location，返回 Moved
    ├─ 遇到 compaction → 压缩，继续
    ├─ promote 输入 → 变成可见消息
    └─ 返回 Ready

  然后循环：
    runStep(context)          // 一个逻辑 step
    如果还有工作 → advanceToStep() 再来一次
    如果没工作 → Complete
```

### 为什么一个 execution 会有多个 drain

协调器的循环是：

```
loop:
  drain()
  如果 pendingWake 还在 → 再 drain()
  否则结束
```

`pendingWake` 是“门铃”：

- drain 正在跑时，新输入/后台通知到达 → 只置 `pendingWake`；
- 当前 drain 返回后，如果门铃还响着，就在**同一个 execution** 里再调一次 drain。

另外，`move` / `reload` 也会让 execution 重新调用 drain：

```
Moved    → 换 Location 后 drain 同一个 Session
Reloaded → 重新加载服务图后 drain
```

### 那么 drain 是不是一次 ReAct 循环？

接近，但不完全等价：

> `drain` 是 ReAct 循环的**运行边界/驱动器**；循环体是它内部的 `advanceToStep` + `runStep`。

- 只有控制项、没有普通输入时，drain 可能**一次模型都不调**；
- 一次 drain 可以跑多个 step，也就是多轮 ReAct；
- 工具在一个 step 内是并发执行的，不是经典的单线程“思考一步、行动一步”。

---

## Q4. 收件箱是什么？机制是怎样的？

`session_inbox` 是**每个 Session 的耐久待办队列**：

> 所有会影响这个会话继续运行的工作，都先写进收件箱，再由 runner 在安全边界取出来执行。

它不是聊天历史，也不是调度器；它是**准入与执行之间的持久化缓冲区**。

### 数据形状

```ts
session_inbox {
  id            // 同时也是消息 ID
  session_id
  type          // user | synthetic | compaction | move
  payload       // 文本/附件，或控制项参数
  delivery      // steer | queue
  enqueued_seq  // 入队顺序，按 Session 单调递增
  time_created
}
```

关键点：**表里永远只有“尚未消费”的工作**。
一旦投递（delivered），行会被删除，内容转成消息或触发对应动作。

### 一条输入的生命周期

```
Session.prompt / synthetic / compact / move
  │
  ▼
SessionInbox.admit
  ├─ 同 ID、同 Session、同类型重放 → 返回已有条目（幂等）
  ├─ 跨 Session/跨类型复用 ID → LifecycleConflict
  └─ Bus.publish(session.inbox.enqueued)
       └─ 同一事务：
            ├─ 插入 session_inbox 行
            └─ 插入 event 行
  │
  ▼
SessionExecution.wake       // 只是门铃，可合并
  │
  ▼
Runner.advanceToStep        // 安全边界
  ├─ 看 pending 的类型和顺序
  ├─ 普通输入 → promote
  └─ 控制项   → 先处理它
  │
  ▼
SessionInbox.promote
  └─ Bus.publish(session.inbox.delivered)
       └─ 同一事务：
            ├─ 删除 inbox 行
            └─ 插入可见消息（user/synthetic）
               或触发 compaction/move 的投影
```

### 两类条目

#### 普通输入

```ts
type: "user" | "synthetic"
```

最终会变成模型可见的消息：

- `user`：用户 prompt；
- `synthetic`：后台完成通知、重启提示、skill 内容、Plan 模式提醒等。

#### 控制项

```ts
type: "compaction" | "move"
```

它们**不是给模型看的文本**，而是“改变执行状态”的命令：

| 控制项 | 作用 |
|---|---|
| `compaction` | 在边界压缩历史，产生新的 checkpoint |
| `move` | 把 Session 移到新的 Location（目录/worktree），换服务图后继续 |

### 为什么要有收件箱

- **客户端断开不丢输入**：已落库；
- **server 崩溃可恢复**：inbox + claim + 事件都在 SQLite；
- **重复提交幂等**：同 ID 不会产生两条输入；
- **不打断流式输出**：输入只在安全边界晋升；
- **顺序可预测**：控制项、steer、queue 都有明确规则。

---

## Q5. “收件箱控制”是什么？`compaction` / `move` 为什么必须优先？什么场景触发？

“控制项”不是正式 API 名称，指的是 `session_inbox.type` 为
`compaction` 或 `move` 的条目。它们不是普通 prompt，而是执行边界上的命令。

普通输入不能越过控制项。

### 5.1 `compaction`（手动压缩）

触发场景：

- TUI 执行 `/compact`
- API：`POST /api/session/:id/compact`
- 本质上都是 `Session.compact()` → 往收件箱放一个 `type: "compaction"` 的条目

为什么必须优先：

- 压缩会改变“历史边界”；
- 如果先把后面的用户输入晋升成消息，再压缩，这条新消息可能被卷进摘要，失去原文；
- 正确顺序是：**先压缩 → 产生新 checkpoint → 后续输入在新 checkpoint 之后原样进入历史**。

处理过程：

```
暂停晋升
  → 执行压缩
  → 发布 compaction started/ended
  → 继续从新边界晋升输入
```

同一段 pending steers 里，compaction 还会被提到最前面（但不越过 move），
确保 checkpoint 之前的输入先被压缩、之后的输入保持原样。

### 5.2 `move`（会话移动）

触发场景：

- TUI 把会话移动到另一个目录 / worktree
- API：`POST /api/session/:id/move`
- `session.move` 会先验证目标目录、目标 Location 可用，然后把 `type: "move"` 放进收件箱并 wake

为什么必须优先：

- 移动之后，Session 的 `location` 会变；
- runner、模型解析、工具、权限、文件系统都按 Location 取服务图；
- 如果先晋升了“移动后”的输入，它会被旧 Location 的配置/工具处理；
- 所以必须在安全边界：
  1. 关闭当前 transport；
  2. 发布 `session.moved`；
  3. 换到新 Location 重新进入 drain；
  4. 再晋升移动之后的输入。

move 是严格的准入顺序屏障：

```
user A → move → user B
```

A 在旧 Location 处理，B 在新 Location 处理。
move 只换 Location，**不换 Session ID**。

### 5.3 一张图

```
session_inbox（按 enqueued_seq 排序）
  user A
  steer B
  compaction      ← 控制项
  user C
  move            ← 控制项
  user D
```

runner 不会把 C 越过 compaction，也不会把 D 越过 move：

```
先处理 A/B → compaction → 在新边界晋升 C
           → move → 在新 Location 晋升 D
```

### 5.4 auto / overflow compaction 不是控制项

| | 手动 compaction | auto / overflow compaction |
|---|---|---|
| 来源 | `/compact`，进入 `session_inbox` | runner 内部判断 |
| 是否控制项 | 是 | 否 |
| 何时发生 | 边界暂停，先处理控制项 | 请求组装前，或 provider 拒绝超长后 |
| 排序问题 | 需要，不能越过 | 不需要，发生在固定执行点 |

所以“compaction 必须优先”说的是**收件箱控制项**；
自动压缩只是 runner 在一次 step 内部的策略，不参与收件箱排序。

---

## Q6. 是不是所有用户输入都进 inbox？默认是 `steer` 吗？

### 通过 `Session.prompt` 的输入：是

```ts
Session.prompt(...)
  → SessionPrompt.prepare(...)
  → SessionInbox.admit(...)
  → execution.wake(...)
```

包括：

- 普通文本；
- `@file` / 图片附件；
- `@skill` 引用；
- `resume: false` 的输入（只准入、不唤醒，但仍进 inbox）。

即使是 `steer`，也是**先落库再执行**，不是直接塞给模型。

### 但不是所有“用户动作”都是 inbox 的 `user` 条目

| 用户动作 | 路径 |
|---|---|
| 普通 prompt | `Session.prompt` → inbox `user` |
| 编辑器上下文 | `Session.synthetic` → inbox `synthetic` |
| `/compact` | `Session.compact` → inbox `compaction` 控制项 |
| 移动会话到别的目录 | `Session.move` → inbox `move` 控制项 |
| 用户提交 shell 命令 | `Session.shell`，不是 prompt；完成通知才走 synthetic |
| 直接激活 skill | `Session.skill`，发 `session.skill.activated` 事件并写可见消息 |
| slash command | `Session.command`；命令实现可以自己决定是否调用 `ctx.session.prompt` |
| `Session.generate` | 只生成文本，不写历史、不进行 inbox 准入 |
| revert / 切 agent / 切 model | 各自的事件路径 |

精确说法：

> **所有通过 `Session.prompt` 提交的会话输入都进入 inbox；**
> **不是所有用户操作都进入 inbox。**

### 默认 delivery 是 `steer`

| 入口 | 默认 delivery |
|---|---|
| `Session.prompt` | `input.delivery ?? "steer"` |
| `Session.synthetic` | `"steer"` |
| `Session.compact` | `"steer"` |
| `Session.move` | `"steer"` |
| `Session.command` 传给命令的 invocation | `"steer"` |

`steer` 只决定**何时投递**，不决定“是否落库”：

- 空闲时：`steer` 和 `queue` 都会立即开始；
- 忙碌时：`steer` 在下一个 step 边界插队，`queue` 等会话将要空闲；
- 两者都**不会打断当前 `llm.stream`**，只有 `interrupt` 会。

---

## Q7. 一个 Session 同时只能有一个 execution 吗？

在**当前进程内**，是的。

- `SessionExecution` + `SessionRunCoordinator` 以 Session ID 为 key；
- 空闲时 `wake` 启动 execution；
- 运行中再 `wake` 只置 `pendingWake`，不会起第二个；
- `resume` 对运行中的 Session 是 join，不是并发；
- 不同 Session 的 execution 可以并行。

跨进程：

- 当前是 process-local 协调；
- 不提供集群级 fencing；
- 托管服务假设同一时刻只有一个 managed server 拥有数据库。

---

## Q8. `drain`、`step`、`execution`、`physical attempt` 怎么记？

| 概念 | 定义 | 是否绑定 Session |
|---|---|---|
| Execution | 一段 busy period，从第一次 wake 到会话将空闲 | 是，一个 execution 一个 Session |
| Drain | 一次 runner 调用，推进当前手头工作到没得做 | 是，永远同一个 Session |
| Step | 一次逻辑 LLM 调用 | 是，属于某个 drain |
| Physical Attempt | 一次真实 provider 请求，恰一次 `llm.stream` | 是，属于某个 step |
| Turn | 保留词，指从 prompt 提升到会话将空闲的 assistant-turn 单位 | 是 |

记忆顺序：

```
Execution ⊃ Drain ⊃ Step ⊃ Physical Attempt
```

---

## Q9. “store 的最终投影”是什么？

这里的 **store** 指 TUI 客户端的内存状态仓库
（`packages/client/src/solid/data.ts` 的 `createData()`，底层是 Solid store）。

**投影（projection）** 是从“事实来源”推导出来的可读状态：

- 服务端投影：durable 事件 → `session_message` / `session_inbox` / `session_v2` 等表；
- 客户端投影：**初始同步快照 + 实时 SSE 事件 + 本地乐观提交** → Solid store。

所以“store 的最终投影”不是事件流本身，也不是某一条事件的 payload，而是：

> 经过同步、事件归并、乐观提交回滚/确认之后，store 里**当前可用于渲染和读取**的那份状态。

### TUI store 里有什么

```ts
store.session.info        // Session 元数据
store.session.message     // 可见消息列表
store.session.pending     // 未投递的 inbox 条目
store.session.permission  // 权限请求
store.session.form        // 表单
store.project             // 项目
store.location            // 当前 Location
```

TUI 插件通过 `ctx.data` 读取，而不是直接摸内部 store：

```ts
ctx.data.session.get(sessionID)
ctx.data.session.message.list(sessionID)
ctx.data.session.message.get(sessionID, messageID)
ctx.data.session.pending.list(sessionID)
ctx.data.session.permission.list(sessionID)
```

### 为什么说“以最终投影为准”，而不是相信事件顺序

因为客户端状态有多个来源：

1. **初始同步**：`session.get` / `session.messages` / `pending` 等 HTTP 请求；
2. **实时事件**：SSE 的 delta 与 durable 事件；
3. **本地乐观提交**：prompt 先插入本地 pending 行，失败再回滚；
4. **重连**：`server.connected` 后重新拉取状态。

这些来源可能交错：

- 同步响应可能比实时事件旧；
- 同一条事件可能重复到达；
- 乐观行可能先于服务端 echo 出现；
- 断线重连后，delta 会缺失，只能靠投影补齐；
- 同一个 ID 的事件可能先 `started` 后 `retry`，不能假设“started 一定新建消息”。

`createData()` 里有专门的归并逻辑（`activeUpdates`、`pendingUpdates`、`outbox`、
`settle`、`reconcile` 等）处理这些竞态。插件不应该自己再数事件或假设顺序。

### 实际含义

写 TUI 插件时：

- 事件只当作“有变化”的信号；
- 渲染时读 `ctx.data` 的当前投影；
- 需要派生数据时，用 `createMemo` 基于投影计算；
- 不要让插件自己维护一份“权威消息列表”，再和 store 对账；
- 临时 UI 状态用 `ctx.storage.memory`，持久状态用 `ctx.storage.store`。

例子：不要这样做：

```ts
// 错：假设 enqueued 后一定 delivered，自己维护计数
let pending = 0
ctx.data.on("session.inbox.enqueued", () => pending++)
ctx.data.on("session.inbox.delivered", () => pending--)
```

应该这样做：

```ts
// 对：投影是唯一读模型
const pending = () => ctx.data.session.pending.list(sessionID)
```

这样即使事件重复、乱序、重连补拉，界面仍然和最终状态一致。

---

## Q10. TypeScript 里每个 `Object` 都能调用 `.on()` 吗？

**不能。** `.on()` 不是 `Object.prototype` 的方法。

`Object.prototype` 只有 `hasOwnProperty`、`toString`、`valueOf` 这类方法；
普通对象没有 `on`：

```ts
const x = {}
x.on("event", () => {})
// TS: Property 'on' does not exist on type '{}'
// JS: TypeError: x.on is not a function
```

`ctx.data.on(...)` 能调用，是因为 **`ctx.data` 的类型显式声明了 `on`**：

```ts
// packages/plugin/src/tui/context.ts
export interface Data {
  readonly on: <Type extends OpenCodeEvent["type"]>(
    type: Type,
    handler: (event: OpenCodeEventMap[Type]) => void,
  ) => () => void
  // ...
}
```

实现位置：

```ts
// packages/client/src/solid/data.ts
const result = {
  on: config.event.on,
  listen: config.event.listen,
  // ...
}
```

而 `config.event` 来自 TUI 的 `createGlobalEmitter()`（`tui/src/context/client.tsx`）。
所以它不是“所有对象自带”，而是 **`Data` 接口提供的一个事件订阅方法**。

### TypeScript 的判断依据

TypeScript 用结构化类型：只要一个值的类型里有 `on`，就能调用。

```ts
interface Bus {
  on(name: string, handler: () => void): () => void
}

declare const bus: Bus
bus.on("x", () => {}) // 可以，类型里有 on
```

类似但互不相关的 `on`：

| 来源 | 是否有 `on` |
|---|---|
| `ctx.data` | 有，`Data` 接口声明 |
| Node.js `EventEmitter` | 有，类方法 |
| 浏览器 `EventTarget` / DOM | 有 `addEventListener`，部分库再包一层 `on` |
| 普通 `{}` / `Object` | **没有** |
| `Map` / `Set` / `Array` | **没有** |

### 注意返回值

`ctx.data.on()` 返回的是**取消订阅函数**：

```ts
const off = ctx.data.on("session.inbox.delivered", handler)
off() // 取消订阅
```

TUI 插件卸载时应调用它（或把它放进插件自己的 cleanup），避免事件处理器泄漏。

---

## Q11. V2 插件能限制 TUI 的命令（如 `/model`、`/new`、`/fork`）吗？

**不能完整做到。** 当前公开插件 API 没有“过滤命令面板 / 拦截斜杠命令执行”的钩子。

v1 的 `restricted-commands.ts` 是在 TUI 命令层直接隐藏/拦截；v2 的命令系统换成
keymap layer 之后，没有一一对应的公开扩展点。

### 先分清两类命令

| 命令 | 归属 | 例子 |
|---|---|---|
| TUI 本地命令 | 客户端 keymap | `/models`、`/agents`、`/variants`、`/connect`、`/new`、`/fork`、`/sessions`（`/resume`）、`/plugins`、`/mcps`、`/skills` |
| Server 斜杠命令 | Core `Command.Service` | `/init`、`/review`、配置/插件注册的自定义命令 |

你列出的 v1 命令里，大多数现在是 **TUI 本地命令**；`/init`、`/review` 是 server 命令。
`/model`、`/org` 在当前 V2 源码里没有找到同名 slash 入口（`/models` 代替 `/model`）。

### TUI 插件能做什么

`@opencode/plugin/tui` 的 `Keymap` 公开接口：

```ts
layer(factory)        // 注册命令/按键层
dispatch(id)          // 主动派发命令
shortcuts(id)
commands()            // 只读：当前可达命令
pending()
active()
mode
```

它**可以**：

- 注册自己的命令、slash 命令、按键绑定；
- 读取当前可达命令列表；
- 控制自己注册的命令是否 enabled；
- 主动 dispatch 某个命令。

它**不能**：

- 通用地过滤/移除命令面板里的任意命令；
- 过滤 `commands()` 的返回结果；
- 拦截任意命令执行；
- 阻止用户直接输入 `/new`、`/model` 等文本；
- 提供正式的“命令策略”或“只读模式”钩子。

但它**可以尝试同名 shadow（覆盖）**：

`@opentui/keymap` 的 command 是按 layer + priority 解析的，同名命令在
`reachable`/active chain 中取优先级最高（同优先级时后注册者优先）的那一条。
因此插件可以用**相同的 command id** 注册一个更高优先级的层，替换该命令在
命令面板、slash 补全和按键绑定中的执行实现。

这属于“覆盖”，不是“过滤”；它依赖内置命令 ID，属于较脆弱的集成方式，
而且只发生在 TUI 客户端进程内。具体做法和限制见 Q12。

内部 TUI 的 `keymap.intercept` 存在于 `tui/src/context/keymap.tsx`，
但**没有暴露**在插件 `Context` 的 `Keymap` 接口里，所以插件不能靠它拦键。

命令面板构建自 `Keymap.useCommands()`（`component/command-palette.tsx`），
斜杠补全同时合并 keymap 命令和 server 命令
（`component/prompt/autocomplete.tsx`）。它们没有“过滤”钩子，但会按
reachable 链取同名命令的最高优先级条目，所以同名 shadow 可以替换显示与执行。

### Server 插件能做什么

`ctx.command.transform(editor => ...)` 只能 **`add`**：

```ts
// packages/core/src/command.ts
type Editor = { add: (definition: Definition) => void }
```

- 不能 remove/hide；
- 同名 `add` 会覆盖已有定义（当前 Map 行为），所以可以**替换** `/init`、`/review`
  或自定义命令，但这不是公开的“删除”语义；
- 命令注册表是 **Location 范围**，不是按 Session 隔离；
- 可以在 `execute` 里检查 `input.sessionID`，对任务会话直接失败/不执行，
  但命令仍然出现在列表里；
- 它管不到 TUI 本地命令，因为这些命令根本不发到 server。

### 因此，任务会话的确定性应该怎么做

如果目标是防止用户改模型/换 agent/开新会话，推荐按可靠性排序：

1. **不要给用户 TUI 命令面**：任务会话用 `opencode run` / HTTP API / 自定义无头客户端，
   由宿主固定 agent、model、permission。这是最稳的。
2. **自定义 TUI**：在 fork/内部构建里给命令面板和 slash 补全加过滤，
   并在 keymap dispatch 前做 session 级策略检查。需要改 TUI，不是纯插件。
3. **Server 侧策略网关**：在反向代理/自定义 server 层拒绝 `switchAgent`、
   `switchModel`、创建会话、fork、provider connect 等状态变更接口。
   能防 API 调用，但防不住 TUI 本地导航/面板。
4. **纯插件方案只能做“软限制”**：注册自己的命令、提示、面板，
   或覆盖 server 的 `/init`、`/review`；不能真正隐藏或阻止内置 TUI 命令。

### 如果要在上游补这个能力

需要新增一个明确的扩展点，例如：

- TUI `Keymap` 增加 `filter`/`transform`，让插件能隐藏或禁用命令；
- 或在命令 dispatch 前提供 `command.before` 策略 hook（能拿到 command id、sessionID、返回值）；
- 或在 prompt 提交层提供 `slash.before` hook，能拒绝/改写命令；
- 同时区分“可见性”和“执行授权”——只隐藏 UI 不能算强制限制。

目前没有这些公开钩子，所以“v2 插件 API 尚未实现命令限制”这个判断是准确的。

---

## Q12. 用 TUI 插件覆盖这些命令，把它们改成“只能查看”可行吗？

**技术上可行，但要明确它只是 TUI 客户端的“覆盖”，不是强制策略，也不是过滤。**

原理：`@opentui/keymap` 支持同名 command 的跨 layer shadowing。

- 命令按 layer `priority` 排序；同优先级时后注册者优先；
- 命令面板读 `reachable`，同名只保留最高优先级的条目；
- slash 补全读 keymap 的 reachable 命令；
- 按键绑定最终也按 command ID 解析同一条 chain。

所以插件可以用**相同 command ID** 注册一个更高优先级的层，把内置实现替换成只读版本。

### 需要覆盖的命令 ID

| 目标 slash | command ID | 备注 |
|---|---|---|
| `/models` | `model.list` | |
| `/agents` | `agent.list` | |
| `/variants` | `variant.list` | aliases: `thinking`, `effort` |
| `/connect` | `provider.connect` | |
| `/new` | `session.new` | |
| `/fork` | `session.fork` | 只在 session 路由注册 |
| `/sessions`、`/resume` | `session.list` | aliases: `resume`, `continue` |
| `/plugins` | `plugins.list` | 由 TUI feature plugin 注册 |
| `/mcps` | `mcp.list` | |
| `/skills` | `prompt.skills` | |

还有一批**不在 slash 列表里、但同样会改状态**的命令，只读模式也必须覆盖：

```
model.cycle_recent
model.cycle_recent_reverse
model.cycle_favorite
model.cycle_favorite_reverse
agent.cycle
agent.cycle.reverse
variant.cycle
```

否则用户仍可以用快捷键轮换模型/agent/variant。

### 最小骨架

```ts
import { define } from "@opencode/plugin/tui"

export default define({
  id: "task.readonly-commands",
  setup: (ctx) => {
    const isTaskSession = () => {
      const route = ctx.ui.router.current()
      if (route.type !== "session") return false
      return ctx.data.session.get(route.sessionID)?.metadata?.task === true
    }

    ctx.keymap.layer(() => ({
      mode: "global",
      priority: 1000,
      enabled: isTaskSession,
      commands: [
        {
          id: "model.list",
          title: "Models (read-only)",
          palette: true,
          slash: { name: "models" },
          run: () => {
            const models = ctx.data.location.model.list() ?? []
            void ctx.ui.dialog.alert({
              title: "Models (read-only)",
              message: models
                .map((model) => `${model.providerID}/${model.id}`)
                .join("\n"),
            })
          },
        },
        {
          id: "agent.list",
          title: "Agents (read-only)",
          palette: true,
          slash: { name: "agents" },
          run: () => {
            const agents = ctx.data.location.agent.list() ?? []
            void ctx.ui.dialog.alert({
              title: "Agents (read-only)",
              message: agents.map((agent) => agent.id).join("\n"),
            })
          },
        },
        // ...其余命令同样覆盖
      ],
    }))
  },
})
```

关键点：

- `run` **不能返回 `false`**，否则 keymap 会继续尝试下一条（内置）命令；
- `mode: "global"` 让覆盖在任意输入模式下都生效；
- `priority` 设得高于内置层；
- `enabled` 只对任务会话生效，其他会话仍用内置行为；
- slash 的 `name`/`aliases` 要与内置一致，否则补全仍会显示旧入口；
- 命令 ID 是 TUI 内部常量，升级时可能改名，需要回归测试。

### 这个方案的能力边界

能做：

- 替换列表中的 TUI 命令实现；
- 在命令面板/slash 补全里显示只读版本；
- 让对应快捷键执行只读版本；
- 对其他会话保持原行为。

不能做：

- 阻止直接调用 HTTP API（`switchModel`、`switchAgent`、`create`、`fork` 等）；
- 阻止其他客户端（`opencode run`、Web、SDK、另一个 TUI 实例）；
- 覆盖 `/init`、`/review` 这类 **server 命令**（需要 server 插件或网关）；
- 防止用户禁用插件/修改配置；
- 保证未来版本命令 ID 不变。

因此：

> **如果只是 BugHunter 的 TUI 防误触，这个覆盖方案可用。**
> **如果要真正保证流水线确定性，还必须在 server/API 层做授权与拒绝。**

---

**工程与定制（Q13–Q21）**

> 这一组问题偏**构建 / 安装布局 / 多实例定制**，不涉及会话内核。
> 代码位置以仓库 **2.0.24** 为准；标「实测」的输出来自本机安装版 **2.0.32**。
> 两版在这一带的行为基本一致，个别差异（如 `debug.location`）会单独标注。

## Q13. V2 怎么编译？编译后的 main 入口是哪个？

### 编译命令

CLI 的“编译”是 `Bun.build` 打成**单文件可执行二进制**，脚本在 `packages/cli/`：

```bash
cd packages/cli

bun run script/build.ts --single --skip-install   # 只编当前平台（最常用）
bun run script/build.ts                           # 全部 12 个 target
bun run script/build.ts --target=linux-x64 --skip-install
bun run script/build.ts --single --skip-web-ui    # 跳过 web UI 归档，迭代更快
bun run script/build.ts --single --outdir=/path/dist

# 等价写法（package script 透传参数）
bun run build -- --single

# Node SEA 版本（opencode2-node）
bun run script/build-node.ts --single --skip-install
```

几个 flag 的含义：

| flag | 作用 |
|---|---|
| `--single` | 只编当前 os/arch（CI 的 smoke 用这个） |
| `--target=linux-x64` | 指定单个 target，可带 `-musl` / `-baseline` |
| `--skip-install` | 跳过为多平台拉 `@opentui/core` / `@opencode-ai/pty` |
| `--skip-web-ui` | 跳过 app archive 构建 |
| `--outdir=` | 输出目录，默认 `packages/cli/dist`，不能等于包目录 |

注意：脚本依赖 `@opencode/script`，会校验 bun 版本（根 `package.json` 的 `packageManager`，当前 `bun@1.4.2`）。

### 入口分三层

| 层 | 位置 |
|---|---|
| 源码入口（`Bun.build` 的 entrypoints） | `packages/cli/src/index.ts` |
| 命令路由表 | `packages/cli/src/commands/commands.ts` |
| 编译产物 | `packages/cli/dist/cli-<os>-<arch>[-baseline][-musl]/bin/opencode` |

`src/index.ts` 的骨架是 `Runtime.handlers(Commands, …)` + `NodeRuntime.runMain`，真正的 command → handler 映射用动态 import：

```ts
const Handlers = Runtime.handlers(Commands, {
  $: () => import("./commands/handlers/default"),
  run: () => import("./commands/handlers/run"),
  serve: () => import("./commands/handlers/serve"),
  ...
})
```

产物命名值得记住：`build.ts` 里 `const binary = "opencode"`，目录名是 `target.replace(binary, "cli")`，所以是 `dist/cli-linux-x64/bin/opencode`（CI 上传的也是 `packages/cli/dist/cli-*`）。

### 其它入口

- **npm 安装后的启动器**：`packages/cli/bin/opencode.cjs`（bin 名 `opencode` / 旧名 `opencode2`）。它不含业务逻辑，按平台/arch/avx2/musl 找到 `node_modules/@opencode/cli-<platform>-<arch>/bin/opencode`（或 `OPENCODE_BIN_PATH`）再 spawn。
- **Node 版**：`script/build-node.ts` → 先用 vite 打 `dist-node/opencode.mjs`（`vite.node.config.ts` 的 `build.ssr = "src/node/index.ts"`），再用 Node SEA 打成 `dist/cli-node-<os>-<arch>/bin/opencode2-node`。要求本机 Node 26.4.0 的 builder 或自动下载。
- **开发直跑**：仓库根 `bun run dev`（= `bun run --cwd packages/cli src/index.ts`），不产生二进制，`channel=local`。

产物验证：`bun run script/service-smoke.ts`（Node 版加 `--node`）。

> 一键脚本：`script/build-release.sh`；完整步骤、实测记录和排错见
> [`local-release-build.md`](./local-release-build.md)。

---

## Q14. `yield` 和 `yield*` 有什么区别？

### 一句话

- `yield v`：产出一个值。
- `yield* it`：把整个迭代过程**委托**给 `it`，产出它的所有值，并取回它的 `return` 值作为表达式结果。

### 可运行示例（实测输出）

```ts
function* inner() {
  yield 1
  yield 2
  return "inner-return"      // return 不会被产出
}

function* outer() {
  const a = yield 0                 // a = 外部 next(x) 传进来的 x
  const b = yield* inner()          // 产出 1、2；b = "inner-return"
  yield* [7, 8]                     // 也能委托任意 iterable
}
```

```
{"value":0,"done":false}
plain yield got: second
{"value":1,"done":false}
{"value":2,"done":false}
yield* got: inner-return
{"value":7,"done":false}
{"value":8,"done":false}
```

| | `yield v` | `yield* it` |
|---|---|---|
| 产出多少值 | 1 个 | `it` 的全部产出 |
| 表达式结果 | 下一次 `next(x)` 的 `x` | `it` 的 return 值（`done:true` 的 value） |
| `next/throw/return` | 只影响当前生成器 | **转发**给内部迭代器（`outer.return()` 会进入 `inner`） |
| 右边能跟什么 | 任意值 | 任意 iterable |

两个常见坑：

1. 生成器的 `return` 值不会出现在 `[...gen()]` 里，只有 `yield*` 能拿到——漏写 `yield*` 时这个值直接丢。
2. `yield* inner()` 是立即展开，不是“调用一下”。

### Effect 里为什么必须写 `yield*`

`Effect.gen` 的 generator 签名是 `Generator<Eff, AEff, never>`：

```ts
const demo = Effect.gen(function* () {
  const a = yield* Effect.succeed("A")   // a: string   ✅
  const b = yield Effect.succeed("B")    // b: never    ⚠️ 运行时能拿到值，类型是 never
})
```

实测 typecheck（v4 / effect-smol）：

```
error TS2339: Property 'toUpperCase' does not exist on type 'never'.
```

机制：`Effect` 自己实现了 `[Symbol.iterator]()`，返回 `Utils.SingleShotGen`（`packages/effect` 上游的 `Utils.ts`）——第一次 `next()` 产出 effect 本身，第二次 `next(成功值)` 以 `done:true` 返回成功值。所以 `yield*` 的表达式类型就是成功值类型；普通 `yield` 在运行时也会被喂回成功值，但类型是 `never`。

仓库风格约定：不要嵌套 `yield* (yield* Foo.Service).bar()`，先绑定命名变量：

```ts
const service = yield* Foo.Service
const result = yield* service.bar()
```

---

## Q15. `opencode --standalone` 为什么还能看到 service 的 session？

因为 **`--standalone` 只换 server 进程，不换数据**。

`packages/cli/src/services/server-connection.ts:41`：

```ts
if (args.standalone || (yield* ServiceConfig.read()).disabled === true) {
  return { endpoint: yield* Standalone.start() } satisfies Resolved
}
```

`Standalone.start()`（`services/standalone.ts`）spawn 一个一次性 server：

```ts
ChildProcess.make(executable, [...args, "--stdio", "--port", "0"], {
  cwd: startupDirectory,
  env: { OPENCODE_PASSWORD: password },   // 每次随机
  stdin: "pipe",                          // EOF = 放弃所有权 → server 退出
})
```

换掉的只有：连接哪个进程、端口（0 = 随机）、密码、生命周期。**没换**数据目录。

server 的数据库路径由 `databasePath(global.data)` 算（`server-process.ts:107`），只依赖 `Global.data`、`OPENCODE_DB` 和构建时的 `OPENCODE_CHANNEL`——与进程无关。session 是可持久化的 sqlite 行，不是某个进程的内存。

“同一个目录才看得到”是因为**列表查询按 location 过滤**。TUI 请求时自己带上作用域（`packages/tui/src/component/dialog-session-list.tsx`）：

```ts
client.api.session.list({
  ...(allProjects ? {} :
    current.project.id === Project.ID.global
      ? { directory: current.directory }
      : { project: current.project.id,
          subpath: path.relative(current.project.directory, current.directory) }),
  parentID: null,
})
```

server 端只是把条件翻译成 SQL（`core/src/session/store.ts:99`）。project id 由 git remote / root commit 派生，非 git 目录用 `hash("directory:" + dir)`（`core/src/project.ts` 的 `resolve`）。

所以：

> **数据共享，执行不共享。**

- 能看到 = 读到同一份历史；
- 不能接管 = execution claim / `SessionRunCoordinator` 是进程内的，interrupt 对本地未拥有的 session 是 no-op；
- claim 只有在进程真的挂掉后，才由下个启动的 server 做 startup recovery 时认领。

---

## Q16. “不同 channel 的构建”是什么意思？

channel 是**编译期烧进二进制的字符串**，源码里用 `declare const` 声明：

```ts
// packages/cli/script/build.ts:190
define: { OPENCODE_CHANNEL: `'${Script.channel}'`, ... }
```

取值规则（`packages/script/src/index.ts:26`）：

```ts
if (env.OPENCODE_CHANNEL) return env.OPENCODE_CHANNEL
if (env.OPENCODE_BUMP) return "latest"
if (env.OPENCODE_VERSION && !startsWith("0.0.0-")) return "latest"
const branch = git branch --show-current       // 本地构建 → 分支名即 channel
```

| 构建方式 | channel | 版本形态 |
|---|---|---|
| CI 正式发版 | `latest` | `2.0.x` |
| CI 推 `v2`（非发版） | `dev` | `0.0.0-dev-<n>` |
| CI 推 `beta` | `beta` | `0.0.0-beta-<n>` |
| 桌面端 | `prod` | — |
| 本地 `bun run script/build.ts` 在 `v2` 分支 | `v2` | `0.0.0-v2-<时间戳>` |
| 源码直跑（无 define） | `local` | `local` |

channel 决定的东西：

| 用途 | 代码 | 规则 |
|---|---|---|
| 数据库文件名 | `cli/src/database-path.ts` | `latest/dev/beta/next/prod` → `opencode.db`；`local` → `opencode-local.db`；其它 → `opencode-<channel>.db` |
| service 注册文件 | `cli/src/services/service-config.ts:32` | `latest/dev/beta/next` → `service.json`；其它 → `service-<channel>.json` |
| 默认端口 | 同上 `:37` | 白名单 `0xc0de`（49374）；`local` `0xc0df`；其它按 hash 派生 10000–60000 |
| 更新源 | `cli/src/services/updater.ts:260` | `/update/api/<channel>/<artifact>/<distribution>` |
| tunnel 子域 | `cli/src/services/remote-tunnel.ts:11` | `latest` → `opencode`；其它 → `opencode-<channel>` |

两个容易混的点：

1. **白名单内的 channel 仍然共用 db**。严格说只有不在 `latest/dev/beta/next/prod` 里的 channel（如 `v2`、`feature-x`）才分库；`latest` 和 `dev` 两个安装看到的是同一批 session。
2. **channel 不是项目/目录**，它只决定“这个二进制属于哪条通道”。

查看当前二进制用哪个 db：`opencode debug paths --name=db`；预览构建的版本号本身也带 channel（`0.0.0-<channel>-<n>`）。

---

## Q17. 设置了 `OPENCODE_CONFIG_DIR`，`~/.config/opencode` 就失效了吗？

**是（对读取该 env 的进程而言），而且是整体替换，不是叠加。**

`packages/util/src/global.ts:79`：

```ts
const layer = Layer.effect(Service,
  Effect.suspend(() => acquire({ config: process.env.OPENCODE_CONFIG_DIR ?? Path.config })))
```

凡是从“全局配置根”派生的都跟着走：

| 内容 | 位置 |
|---|---|
| `opencode.json` / `opencode.jsonc` | `core/src/config/discovery.ts:27,53` |
| 全局 `AGENTS.md` | `core/src/config/plugin/instruction.ts:38` |
| `agent/`、`command/`、`skill(s)/` | config 的 `Directory` entry |
| `cli.json`（CLI/TUI 自己的配置） | `cli/src/config/config.ts:31` |
| 本地插件扫描 | config `plugin`/`plugins` 目录 + `cli.json` 的相对路径 |
| 遗留 `tui.json` 迁移 | `cli/src/config/migrate.ts:100` |

### 实测

```bash
$ cd /tmp && opencode api --standalone config.get | jq '[.[].path]'
["/home/peter/.config/opencode/opencode.json",
 "/home/peter/.config/opencode/opencode.jsonc",
 "/home/peter/.config/opencode"]

$ OPENCODE_CONFIG_DIR=/tmp/test_config opencode api --standalone config.get | jq '[.[].path]'
["/tmp/test_config/opencode.json",
 "/tmp/test_config"]
```

server 的 watcher 日志也直接反映：

```
watcher subscribe path=/home/peter/.config/opencode type=directory     # 默认
watcher subscribe path=/tmp/test_config type=directory                 # 设置后
```

`opencode debug paths` 里只有 `config` 变，其它不变；目录不存在会自动 `mkdir -p`。我在那个目录跑过命令后，`cli.json` 被自动生成到 `/tmp/test_config`，而 `~/.config/opencode/cli.json` 的 mtime 没变。

### 仍然生效的部分

- `~/.claude`、`~/.agents`：基于 `global.home`（`discovery.ts:28-29`），不受影响；这两个目录下的 `skills/` 也会被当作兼容技能根加载（`config/plugin/compatibility.ts:40`）。
- 项目级配置：cwd 向上的 `opencode.json/.jsonc`、`.opencode/`、`.claude/`、`.agents/`。
- `OPENCODE_CONFIG`（显式文件）、`OPENCODE_CONFIG_CONTENT`、项目配置开关。
- 数据类：`data` / `state` / `db` / `log` 全都不受影响。

### 最大的坑：生效时机

v2 的配置由 **server 进程**加载，CLI 只是客户端。如果后台 service 已经在跑，你在新 shell 里 export 这个变量**不会**改变它：

```bash
$ OPENCODE_CONFIG_DIR=/tmp/test_config opencode debug config | jq '[.[].path]'
["/home/peter/.config/opencode/opencode.json", ...]     # 还是旧的
```

原因：`debug config` 走默认服务连接，而 server 的 `Global` 在启动时就读完了 env（`server-process.ts:37,115`）。让它生效：

```bash
OPENCODE_CONFIG_DIR=/tmp/test_config opencode --standalone     # 私有 server，实测生效
OPENCODE_CONFIG_DIR=/tmp/test_config opencode service restart  # 重启后台服务（会打断会话）
opencode service stop                                          # 或先停
```

另外注意：`opencode debug config` / `debug agents` **没有** `--server` / `--standalone` 标志（实测报 `Unrecognized flag: --standalone`），想验证只能靠重启服务或 `opencode api --standalone config.get`。

---

## Q18. 怎么把 `data` / `cache` / `state` / `db` 也搬走？有对应环境变量吗？

有，但不是 `OPENCODE_*`，而是 **XDG 家族**（`packages/util/src/global-roots.ts`）：

| 目的 | 变量 | 实际路径 |
|---|---|---|
| data（db / log / repos） | `XDG_DATA_HOME` | `$XDG_DATA_HOME/opencode` |
| cache（bin、npm 插件缓存） | `XDG_CACHE_HOME` | `$XDG_CACHE_HOME/opencode` |
| state（service 注册、TUI 状态、locks、pty） | `XDG_STATE_HOME` | `$XDG_STATE_HOME/opencode` |
| config | `XDG_CONFIG_HOME` 或 `OPENCODE_CONFIG_DIR` | 前者加 `/opencode`，后者原样 |
| tmp | `TMPDIR` | `$TMPDIR/opencode` |
| 单独搬 db | `OPENCODE_DB` | 绝对路径 / 相对 data 的文件名 / `:memory:` |
| 关掉 channel 分库 | `OPENCODE_DISABLE_CHANNEL_DB=1` | 强制 `opencode.db` |

db 没有独立目录变量：`db = data 目录 + 文件名`（`cli/src/database-path.ts`）。

### 实测 1：全套 XDG

```bash
$ XDG_DATA_HOME=/tmp/xdg/data XDG_CACHE_HOME=/tmp/xdg/cache \
  XDG_STATE_HOME=/tmp/xdg/state XDG_CONFIG_HOME=/tmp/xdg/config \
  TMPDIR=/tmp/xdg/tmp opencode debug paths

data       /tmp/xdg/data/opencode
cache      /tmp/xdg/cache/opencode
config     /tmp/xdg/config/opencode
state      /tmp/xdg/state/opencode
tmp        /tmp/xdg/tmp/opencode
bin        /tmp/xdg/cache/opencode/bin
log        /tmp/xdg/data/opencode/log
repos      /tmp/xdg/data/opencode/repos
db         /tmp/xdg/data/opencode/opencode.db
```

### 实测 2：`OPENCODE_DB` 三种写法

```bash
$ OPENCODE_DB=/tmp/xdg/custom.db opencode debug paths | grep ^db
db         /tmp/xdg/custom.db                                   # 绝对路径

$ OPENCODE_DB=sessions.db opencode debug paths | grep ^db
db         /home/peter/.local/share/opencode/sessions.db         # 相对 → 落 data 下

$ OPENCODE_DB=:memory: opencode debug paths | grep ^db
db         :memory:
```

server 侧同样生效（db 是 server 拥有的）：

```bash
$ mkdir -p /tmp/xdgprobe
$ OPENCODE_DB=/tmp/xdgprobe/probe.db opencode api --standalone session.list
{"data":[],"cursor":{"previous":null,"next":null}}
$ ls -l /tmp/xdgprobe
-rw------- 1 peter peter 245760 probe.db      # 完整迁移后的库
```

### 让后台 service 也用新路径

`service` 支持给子进程写一份 env（`cli/src/services/service-config.ts:229`）：

```bash
# 每条都会先 stop 当前 service（会打断正在跑的会话！）
opencode service set env XDG_DATA_HOME /home/peter/oc/data
opencode service set env XDG_CACHE_HOME /home/peter/oc/cache
opencode service set env XDG_STATE_HOME /home/peter/oc/state
opencode service set env OPENCODE_DB /home/peter/oc/opencode.db

opencode service get env
opencode service start
opencode service unset env KEY
```

注意它只影响 **server**；CLI/TUI 的 `state`（标签页、prompt 历史）、`cache`、`config` 仍取当前进程 env。想彻底一致就把 export 写进 shell profile。

### 两个注意点

1. 换 `XDG_STATE_HOME` 会同时换掉 service 注册文件。旧服务还在跑会占着端口（默认 `0xc0de`，本机配置成 4096），隔离前先 `service stop`，或用 `service set port` 换端口。
2. `OPENCODE_DB` 只搬数据库；但 v2 的 auth 凭据已经迁进数据库，所以“登录状态”会跟着走。

补充：`Path.home` 读 `OPENCODE_TEST_HOME`（`util/src/global.ts:17`），但 XDG 根目录用的是 `os.homedir()`（`global-roots.ts`），所以它只改 `home`（影响 `~/.claude`、`~/.agents` 与展示），**不会**改 data/cache/state/config。它是测试钩子，不建议日常用。

---

## Q19. 能把路径里的 `opencode` 换成自己的名字吗？插件能做到吗？

### 结论

- **没有环境变量**能改这一层名字。它是编译期常量：
  ```ts
  // packages/util/src/global.ts:12
  const app = "opencode"
  const { data, cache, config, state, tmp } = roots(app)
  ```
  XDG 变量只能换父目录，叶子永远是 `app`。
- **插件不行**。插件 `Context` 只有 `app/location/agent/tool/session/config…` 这些域，没有路径/文件系统域；而且路径在 server 启动时就已定死（目录已建、db 已开），插件是之后才加载的。
- **可行方案 = fork 源码重新编译**。

### 两个例外：db 和 config 已经能完整改名

```bash
export OPENCODE_CONFIG_DIR=/opt/myapp/config      # 完全指定，不带 opencode
export OPENCODE_DB=/opt/myapp/data/state.db       # 完全指定文件
```

`data/cache/state/tmp` 没有等价变量，只能是 `<XDG>/opencode`。

### 最小补丁（路径级）

```diff
--- packages/util/src/global.ts
-const app = "opencode"
+const app = "myapp"

--- packages/cli/src/database-path.ts
-      ? "opencode.db"
-      : `opencode-${OPENCODE_CHANNEL...}.db`)
+      ? "myapp.db"
+      : `myapp-${OPENCODE_CHANNEL...}.db`)

--- packages/util/src/observability/logging.ts
-"opencode.log" / `opencode-${channel}.log`
+"myapp.log" / `myapp-${channel}.log`
```

实测（用仓库真实代码执行，非手写模拟）：

```bash
$ bun -e 'import { roots } from "./packages/util/src/global-roots.ts"; console.log(roots("myapp"))'
{ "data": "/home/peter/.local/share/myapp", "cache": "/home/peter/.cache/myapp",
  "config": "/home/peter/.config/myapp", "state": "/home/peter/.local/state/myapp",
  "tmp": "/home/peter/.tmp/myapp" }

$ bun -e 'import { databasePath } from "./packages/cli/src/database-path.ts"; console.log(databasePath("/tmp/rt/data"))'
/tmp/rt/data/myapp-local.db
```

编译验证：

```bash
cd packages/cli && bun run script/build.ts --single --skip-install
dist/cli-linux-x64/bin/opencode debug paths
```

> 说明：在写这份笔记的机器上没能端到端跑源码/编译（仓库未 `bun install`，且本机 bun 1.3.14 低于要求的 `^1.4.2`），所以上面是单元级实测 + 代码路径确认，端到端需要装好依赖后编译一次。

### 迁移旧数据

```bash
opencode service stop
mv ~/.local/share/opencode ~/.local/share/myapp
mv ~/.local/share/myapp/opencode.db{,-wal,-shm}  # 改成 myapp.db{,-wal,-shm}
mv ~/.cache/opencode ~/.cache/myapp
mv ~/.local/state/opencode ~/.local/state/myapp
mv ~/.config/opencode ~/.config/myapp
```

⚠️ 还有个隐藏 marker：`packages/core/src/project.ts:258` 会读写 `<repo>/.git/opencode`（项目 id 缓存）。**不要**跟着改名：git 仓库的 id 由 remote / root commit 推导，非 git 目录用 `hash("directory:" + path)`，改这个文件只会增加风险。

### 如果要“白标”到 CLI 名和配置文件名

| 目标 | 位置 | 建议 |
|---|---|---|
| 二进制/命令名 | `cli/script/build.ts:16 const binary`、`cli/package.json` 的 `bin`、`bin/opencode.cjs` | 可改 |
| user-agent / artifact | build.ts 的 `OPENCODE_CLI_NAME`、`--user-agent` | 可改 |
| 项目级配置名 | `core/src/config/discovery.ts:11 names`、`.opencode/` 目录 | 可改，但用户已有项目配置要跟着重命名 |
| env 前缀 `OPENCODE_*` | 25+ 处 | 不建议（纯内部） |
| provider id `opencode`、API 路径、share/更新域名 | 多处 | **不要动**，否则 Zen、升级、分享会坏 |

---

## Q20. 只定制插件 + 官方 bin + 自定义 env + 独立 serve，能和用户本地的 opencode 隔离吗？

先纠正命令名：是 **`opencode serve`**（没有 `server` 子命令），`--server` 是客户端连服务端的标志。

### 能做到的部分（实测，安装版 2.0.32）

```bash
OPENCODE_PASSWORD=isolated-pass \
OPENCODE_CONFIG_DIR=/tmp/test_config \
OPENCODE_DB=/tmp/myapp-iso/state.db \
opencode serve --hostname 127.0.0.1 --port 4099
```

```
== 自定义 server 的配置来源 ==
["/tmp/test_config/opencode.json","/tmp/test_config"]
== 自定义 server 的 session 数 ==
0
== 官方 service（4096）的配置来源 ==
["/home/peter/.config/opencode/opencode.json", ...]
== /tmp/myapp-iso ==
state.db  state.db-shm  state.db-wal
```

隔离成功：session/凭据（独立 db）、全局配置与插件（独立 config）、网络入口与进程。

### 做不到完全隔离的部分

| 共享项 | 位置 | 影响 |
|---|---|---|
| 日志 | `~/.local/share/opencode/log/opencode.log` | 两个实例写同一文件（实测同一行 `role=server`） |
| service 注册/密码 | `~/.local/state/opencode/service.json`、`password` | `service stop/restart` 会误伤用户服务 |
| 服务端锁 | `~/.local/state/opencode/locks/` | 跨实例互斥 |
| 持久终端 | `~/.local/state/opencode/pty/` | 共享 pty 根目录 |
| TUI 本地状态 | `~/.local/state/opencode/<channel>/tui/` | 同 channel 会串 |
| 二进制/插件缓存 | `~/.cache/opencode/{bin,npm}/` | 共享 |
| reference 克隆 | `~/.local/share/opencode/repos/` | 共享 |
| 全局技能 | `~/.claude/skills`、`~/.agents/skills` | **始终加载**（`core/src/config/plugin/compatibility.ts:40`），无 env 开关 |
| 项目 id 缓存 | `<repo>/.git/opencode` | 共享，无害 |

TUI 状态这条值得展开：v2 把客户端状态放在 `path.join(state, channel, "tui")`（`packages/tui/src/context/storage.tsx:47`），`channel` 来自 `OPENCODE_TUI_CHANNEL ?? OPENCODE_CHANNEL`（`cli/src/commands/handlers/default.ts:100`）。同一个官方二进制 → `channel=latest` → 和用户共用同一个 TUI 目录，自定义 TUI 会打开用户的标签页，而标签页里的 session id 在你的库里不存在。

### 三档方案

**档位 1：你现在的方案 + 两个变量**

```bash
export OPENCODE_CONFIG_DIR=/opt/myapp/config
export OPENCODE_DB=/opt/myapp/data/state.db
export OPENCODE_TUI_CHANNEL=myapp      # 隔离 TUI 状态和它的 locks
export OPENCODE_PASSWORD=<固定密码>     # serve 与客户端必须一致

opencode serve --hostname 127.0.0.1 --port 4099
opencode --server http://127.0.0.1:4099
opencode run --server http://127.0.0.1:4099 "..."
```

`serve` 前台且没设 `OPENCODE_PASSWORD` 时会随机生成密码并打印 `server password <pw>`（`server-process.ts:83-91`）。

**档位 2：全量 XDG（推荐，零改源码）**

```bash
export XDG_DATA_HOME=/opt/myapp/data
export XDG_CACHE_HOME=/opt/myapp/cache
export XDG_STATE_HOME=/opt/myapp/state
export OPENCODE_CONFIG_DIR=/opt/myapp/config
export OPENCODE_DB=/opt/myapp/data/state.db
```

连 `service` 子命令都只操作 `/opt/myapp/state/opencode/service.json`。代价：叶子目录名仍是 `opencode`。

副作用：换 state 后客户端找不到已注册服务，会**自动再起一个**；默认端口同为 `0xc0de`，先固定端口：

```bash
opencode service set port 4099
```

**档位 3：改源码**（见 Q19）。

### 三个必须知道的坑

1. **不是所有命令都能指向你的 server**
   - `opencode debug config` / `debug agents`：没有 `--server` / `--standalone`，永远连默认服务。
   - `opencode plugin list`：接受 `--server` 但实现里 `ServerConnection.resolve()` 没传参（`cli/src/commands/handlers/plugin/list.ts`），实际仍查默认服务。
   - 其余 `run / session / models / api / auth / mcp / reload / mini / pair / 根 TUI` 都支持。
2. **`opencode service *` 是高危命令**：默认 state 下操作的是与用户服务相同的注册文件。
3. **全局技能一定会被加载**：`~/.claude/skills`、`~/.agents/skills` 不受 config 目录影响。

### 建议用 launcher 固化

```sh
#!/usr/bin/env sh
# /opt/myapp/bin/myapp
: "${MYAPP_PORT:=4099}"
export OPENCODE_CONFIG_DIR=/opt/myapp/config
export OPENCODE_DB=/opt/myapp/data/state.db
export OPENCODE_TUI_CHANNEL=myapp
export OPENCODE_PASSWORD="$(cat /opt/myapp/password 2>/dev/null)"
exec opencode "$@" --server "http://127.0.0.1:${MYAPP_PORT}"
```

忘加 `--server` 落到用户实例，是这套方案最常见的故障。

---

## Q21. 每个 location 都会起一个 server 进程吗？

**不会。一个 server 进程服务所有 location。**

### 请求如何定位 location

`packages/server/src/location.ts:59`：

```ts
export function requestRef(request) {
  const query = new URL(request.url, "http://localhost").searchParams
  const directory =
    query.get("location[directory]") ||
    (request.headers["x-opencode-directory"] ? decode(...) : process.cwd())   // 兜底 = server 自己的 cwd
  return Location.Ref.make({ directory: AbsolutePath.make(directory) })
}
```

### 每个 location 一套“服务图”，但在同一进程内

`packages/core/src/location-services.ts`：

```ts
const inner = yield* LayerMap.make(
  (ref) => Layer.buildWithMemoMap(Instance.layer(ref, { replacements: bindings }), memoMap, scope),
  { idleTimeToLive: Duration.infinity },
)
```

`Instance.layer(ref)` 是那整套 `Config / Agent / Provider / FileSystem / Shell / Pty / Mcp / Tool / SessionStore …`（`core/src/instance.ts` 的 `nodes`）。失败可重试，`reload` 统一 invalidate（`core/src/location-service-map.ts:22`）。

**实测**：一个 `serve` 进程（单 PID、零子进程）同时创建并服务两个目录的 session：

```
{"id":"ses_...","dir":"/tmp/loc-a"}
{"id":"ses_...","dir":"/tmp/loc-b"}
LISTEN 127.0.0.1:4098 users:(("opencode",pid=129644,fd=10))
```

> 版本差异备注：我试图用 `/api/debug/location` 列出缓存条目，在 2.0.32 上返回 `[]`；仓库 2.0.24 写的是 `idleTimeToLive: Duration.infinity`（意图常驻）。两版在这块有差异，或该调试端点只反映当前被借用的图，所以这里不以它作证据。

### 环境变量的真实模型

| 层级 | 存在位置 | 隔离范围 | 跨 location 泄漏 |
|---|---|---|---|
| 进程 env（`process.env`） | server 进程 | 整个 server | **会** |
| `SessionEnvironment` | server 内存 Map（`core/src/session/environment.ts`） | 每个 session | 不会 |
| 配置里的 `${env:...}` | 进程 env | 整个 server | 会 |
| provider 凭据 | location 配置（`provider.*.options`） | 每个 location | 不会 |

session 环境怎么进去：

```ts
// cli/src/session-target.ts:78 —— 建会话时推送
await client.session.environment({ sessionID: session.id, variables: input.environment })

// tui/src/app.tsx:497 —— attach 时再推一次（server 只存内存）
.environment({ sessionID: session.id, variables: terminalEnvironment.variables })
```

`input.environment` 来自 `Env.session()`（`cli/src/env.ts`，`process.env` 去掉两个密码变量）。

**关键条件**：

```ts
// cli/src/commands/handlers/default.ts:142
environment: requestedServer === undefined ? Env.session() : undefined
// cli/src/run/run.ts:102
environment: input.server.service ? Env.session() : undefined
```

只有客户端自己管理/启动 server（managed service 或 `--standalone`）时才推 env；用 `--server` 连别人的 server 时**不会上传**，工具跑在 server 进程自己的环境里。

消费端（`core/src/shell.ts:255-268`）：

```ts
const sessionEnvironment =
  location.workspaceID === undefined && Schema.is(SessionSchema.ID)(sessionID)
    ? yield* environments.get(sessionID)
    : undefined
const invocation = {
  ...,
  env: { ...(sessionEnvironment ?? process.env), TERM: "xterm-256color", OPENCODE_TERMINAL: "1" },
}
```

注意是 **`??` 整体替换**，不是 merge；且仅 `workspaceID === undefined`（本地隐式放置）生效；数据只在内存，server 重启即丢。

### 该选哪条路

- **A. 不同项目要不同行为** → 单进程足够（config/插件/权限/模型按 location 发现）。
- **B. 只是 shell/tool 看到不同 env** → 单进程 + `session.environment`；因为整体替换，必须推**完整** env（否则连 `PATH` 都没了）。
- **C. 必须进程级不同（代理/凭据/全局插件）** → 一 location 一 server。代价：db 共享会有多进程写与 execution claim 冲突风险，各自独立 db 则 session 不共享；还要自己管 service 注册、日志、pty、锁。
- **D. 最省事**：把凭据/代理差异放进 **location 级配置**而不是进程 env。

  ```jsonc
  { "provider": { "myprov": { "options": { "apiKey": "...", "baseURL": "..." } } } }
  ```

最后提醒：`SessionExecution` 明确是进程全局、按 sessionID 协调（仓库根 `AGENTS.md`），`SessionRunCoordinator` 也在进程内，所以“每 location 一进程”不是免费开关。

## 相关源码

| 主题 | 文件 |
|---|---|
| 收件箱 | `packages/core/src/session/inbox.ts` |
| 协调器 | `packages/core/src/session/run-coordinator.ts` |
| 执行路由 / claim | `packages/core/src/session/execution.ts` |
| drain / step 循环 | `packages/core/src/session/runner/llm.ts` |
| 单次 step / 工具 fiber | `packages/core/src/session/runner/step.ts` |
| Session 入口 | `packages/core/src/session/session.ts` |
| 输入准备 | `packages/core/src/session/prompt.ts` |
| move 控制项 | `packages/core/src/session/move.ts` |
| 手动压缩控制项 | `packages/core/src/session/session.ts`（`compact`） |
| 自动/溢出压缩 | `packages/core/src/session/compaction.ts` |
| 客户端投影 | `packages/client/src/solid/data.ts` |
| 客户端事件连接 | `packages/client/src/solid/connection.ts` |
| TUI 数据上下文 | `packages/tui/src/context/data.tsx` |
| TUI keymap / 命令层 | `packages/tui/src/context/keymap.tsx` |
| TUI 命令面板 | `packages/tui/src/component/command-palette.tsx` |
| TUI slash 补全 | `packages/tui/src/component/prompt/autocomplete.tsx` |
| TUI 插件 API | `packages/plugin/src/tui/context.ts` |
| Bun 打包脚本 | `packages/cli/script/build.ts` |
| Node SEA 打包脚本 | `packages/cli/script/build-node.ts` |
| npm 启动器 | `packages/cli/bin/opencode.cjs` |
| channel / version 推导 | `packages/script/src/index.ts` |
| 全局路径（app 名） | `packages/util/src/global.ts`、`packages/util/src/global-roots.ts` |
| 数据库文件名 | `packages/cli/src/database-path.ts` |
| 日志文件名 | `packages/util/src/observability/logging.ts` |
| standalone server | `packages/cli/src/services/standalone.ts` |
| 服务端连接解析 | `packages/cli/src/services/server-connection.ts` |
| service 配置 / env | `packages/cli/src/services/service-config.ts` |
| server 进程启动 | `packages/cli/src/server-process.ts` |
| 配置发现（global/project/claude/agents） | `packages/core/src/config/discovery.ts` |
| 兼容技能根 | `packages/core/src/config/plugin/compatibility.ts` |
| 全局 AGENTS.md | `packages/core/src/config/plugin/instruction.ts` |
| location 解析（header/query） | `packages/server/src/location.ts` |
| location 服务图缓存 | `packages/core/src/location-services.ts`、`packages/core/src/location-service-map.ts` |
| per-location 服务清单 | `packages/core/src/instance.ts` |
| session 环境变量（内存） | `packages/core/src/session/environment.ts` |
| shell env 合成 | `packages/core/src/shell.ts` |
| 客户端推送 session env | `packages/cli/src/session-target.ts`、`packages/tui/src/app.tsx` |
| CLI 进程 env 快照 | `packages/cli/src/env.ts` |
| TUI 本地存储（按 channel） | `packages/tui/src/context/storage.tsx` |

---

*最后更新：2026-11（源码 2.0.24；Q13–Q21 的实测输出使用安装版 2.0.32）*
