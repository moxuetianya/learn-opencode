# OpenCode V2 学习问答（QA）

> 本文件汇总学习过程中提出的问题，只讨论 V2（opencode 2.0.24）。
> 课程正文以讲原理为主；这里用问答形式把容易混淆的概念讲透。
>
> 相关课程：02（一次对话）、03（输入并发）、04（Session Core 地图）、05（Agent 内核）。

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

---

*最后更新：2026-10（opencode 2.0.24）*
