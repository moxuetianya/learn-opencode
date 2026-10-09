# 11. 后台任务主动唤醒：bash 转后台后，对话怎么"自动续上"

> 本课回答：**opencode v2 调用的 bash 后台程序完成后，能主动发起对话吗？**
> 结论：能——**agent 自己发起的后台任务**（`shell` 工具 `background: true`）完成时，会把一条
> synthetic 消息写进持久化收件箱并 **wake 会话**：会话空闲就新起一轮执行，运行中就在下一个
> 安全边界注入。模型因此敢承诺 *"DO NOT poll, you will be resumed automatically"*。
> 对照：**用户自己提交的后台命令**只入队通知、不唤醒。
>
> 承接第 4 课（steer/queue 输入并发）与第 8 课（v2 执行链路）；本课以当前实现
> （`SessionInbox` + `Job` + `SessionExecution`）为准。

## 11.1 两种后台 shell，两种唤醒策略

| 发起者 | 入口 | 完成通知 | 是否唤醒模型 |
|---|---|---|---|
| **agent**（模型调工具） | `shell` 工具 `background: true` | `sessions.synthetic(...)` 默认参数 | **会**（wake） |
| **用户**（TUI/API 提交命令） | `Session.shell` | `synthetic(..., { resume: false })` | **不会**（admit-only） |
| 重启恢复中的 shell 通知 | `restart.ts` `recoverShell` | 同上 `resume: false` | 不会（同理） |

设计动机：agent 发起后台任务是在"等结果继续干活"，完成即新工作到达，应该自动续上；
用户自己跑的命令完成了，不该让模型自己转起来。

## 11.2 建立：`shell` 工具的 background 模式

`packages/core/src/tool/plugin/shell.ts`：

1. `shell.create(...)` 起真实子进程；`background: true` 时 `timeout = input.timeout ?? 0`（不限时）
2. `jobs.start({ id, type: "shell", recovery: { kind: "shell", sessionID, shellID, command }, run })`
   注册成 **Job**——可恢复任务：
   - 有 `recovery` 的 Job 启动时分配 `notificationID`（`packages/core/src/job.ts:364`）
   - 转后台时整个 Background 记录持久化到 KV `job.background/<notificationID>`
     （`job.ts:199-202`）——**跨 server 重启存在**
3. `jobs.background(job.id)` 标记转后台；fork `notifyWhenDone` 观察者；
   工具**立即返回**：

   ```
   Command moved to the background (shell ID: xxx).
   Output is streaming to: <file>
   ```

4. 返回内容附带 `BACKGROUND_INSTRUCTION`（shell.ts:25-26），这是**给模型的协议**：

   > You will be notified automatically when the command finishes... **DO NOT poll**...
   > If you have nothing else to do, end your response; **you will be resumed automatically**
   > when the command finishes.

   前台命令被打断/转后台（`jobs.block` 返回 `backgrounded`）走同一条路（shell.ts:262-266）。

## 11.3 完成时：`notifyWhenDone` → `sessions.synthetic`

观察者 fiber（shell.ts:156-188）：

```
jobs.wait({ id })                       # 等 Job 终态：completed / error / cancelled
  → 收集输出（shell 捕获结果经 Deferred 送达；error 取 info.error；cancelled 取 "Cancelled"）
  → ShellResult.notification({...})     # packages/core/src/shell/result.ts:45
      文本形如:
      <shell id="job-..." state="completed" command="bun run build">
      ...命令输出...
      </shell>
      （非零退出附 "Exited with code N"，超时附 "Timed out before completion"）
  → sessions.synthetic({
        id: info.notificationID,        # 幂等键：重试不产生重复消息
        sessionID,
        description: command,
        ...notification,
      })                                # 注意：没传 resume → 默认唤醒
  → jobs.completeBackground(notificationID)   # 清 KV 记录
```

`Session.synthetic`（`packages/core/src/session/session.ts:273`）做两件事：

```ts
const admittedInput = {
  type: "synthetic",
  payload: { text, description, metadata },
  delivery: input.delivery ?? "steer",   // ← 默认 steer（插队投递）
}
admission.admit({ id, sessionID, item }) // ① 写持久化 session_inbox 行
if (input.resume !== false && !session.revert)
  execution.wake(sessionID)              // ② 主动唤醒（本课的核心）
```

## 11.4 wake 语义：空闲起新执行，运行中合并

`SessionRunCoordinator.wake`（`packages/core/src/session/run-coordinator.ts:136`）：

```
wake(sessionID):
  ├─ 该 Session 有活跃执行 → pendingWake = 合并（scope 取更宽的 "input"）
  │   （当前 drain 结束时 settle() 读到 pendingWake → 起 successor drain）
  └─ 空闲 → start() 新 execution（durable claim 同事务写入，见第 10 课 §10.7）
```

多次 wake **coalesce 成一次**：同一时刻无论多少后台任务完成，会话至多被"门铃"响一次。

## 11.5 投递：synthetic 消息如何进入模型上下文

新执行（或 successor drain）在 `SessionRunner.drain` 里推进（`runner/llm.ts:54`）：

```
advanceToStep 循环:
  nextPromotable(db, sessionID, 边界scope)
    ├─ 有 pending steer → 优先取（任何边界 steer 都赢）
    └─ scope="input"（入口/空闲边界）才轮到一条 queue
  SessionInbox.promote(db, bus, sessionID, scope)   # inbox.ts:496
    ├─ steers 按入队顺序整批提升；遇到控制项（compaction/move）停下不越过
    ├─ publish → bus.publish(session.inbox.delivered, ...)
    │    ★ 同一个事务：消费 session_inbox 行 + 插入可见消息（投影）
    └─ promoted > 0 → 步数配额重置 step = 1
  → 准备上下文 → 发起一次 llm.stream（消息历史里已含完成通知）
```

两种时序：

- **会话空闲**（agent 已结束回答）：wake 直接新起一轮执行——通知作为新的输入被提升，
  模型带着命令输出继续干活。这就是"后台程序完成后主动发起对话"。
- **会话运行中**：wake 合并进当前执行；在每个 step 之间的安全边界
  （`runner/llm.ts:80-109`，scope 收窄为 `"steer"`）通知被提升，同一轮执行的下一次
  `llm.stream` 就能看到它——不打断正在流的调用。

投递语义与第 4 课的 steer/queue 完全一致；synthetic 完成通知走的就是 steer 通道。

## 11.6 可靠性设计

| 关注点 | 机制 | 位置 |
|---|---|---|
| 通知不重复 | `notificationID` 复用为 inbox 条目 ID，admit 幂等 | `job.ts:364`、`session.ts:298` |
| 客户端断开不影响 | 观察者 fork 在 server 的 plugin scope；"server owns completion recording" | `session.ts:184` |
| server 重启不丢 | Background 记录在 KV；启动恢复补发通知（shell 标记 cancelled） | `job.ts:199`、`restart.ts:101` |
| 输出不再可得 | shell 输出文件被清理时回退 "Shell command output is no longer available." | `shell/result.ts:12` |
| 通知会话已删 | `Session.NotFoundError` → 静默吞掉 | `session.ts:217` |

## 11.7 完整时序：agent 发起后台构建

```
模型: shell({ command: "bun run build", background: true })
  ├─ server: shell.create → jobs.start(recovery) → jobs.background
  │          fork notifyWhenDone; 工具立即返回 "moved to the background"
  ├─ 模型: 读到 BACKGROUND_INSTRUCTION → 没有别的可做 → 结束回答（会话空闲）
  │
  ……构建运行中，用户与模型继续聊别的（或什么都不做）……
  │
  构建完成（exit 0）
  ├─ notifyWhenDone: jobs.wait → 组装 <shell ...> 通知
  │   → sessions.synthetic (delivery=steer)
  │      ├─ session_inbox 落行（session.inbox.enqueued）
  │      └─ execution.wake
  ├─ coordinator: 空闲 → start 新 execution（durable claim）
  ├─ runner: promote → session.inbox.delivered（同事务插可见消息）→ step 重置
  ├─ llm.stream: 上下文含完成通知 → 模型检查构建结果、继续任务
  └─ TUI: SSE 事件流实时渲染新一轮输出
```

## 11.8 相关机制：subagent 后台任务

`packages/core/src/tool/plugin/subagent.ts` 与 shell 同构：

- `background: true` → `subagents.background(recovery)`（Job，kind `"subagent"`，
  持久化父子会话 ID）→ 立即返回 *"You will be notified automatically when it finishes"*
- 子会话完成 → `SubagentCompletion.deliver` 向**父会话**注入 synthetic 通知（含子会话结果摘要）
- 重启恢复时（`restart.ts:138`）子会话还能续则续跑，否则向父会话补发结果通知

## 11.9 小结

1. **完成通知 = synthetic steer 消息 + wake**，不是回调、不是轮询——走和用户输入同一条
   持久化收件箱链路。
2. **唤醒策略按发起者区分**：agent 发起的会 wake；用户发起与重启恢复通知 admit-only。
3. **投递时机二分**：空闲起新执行；运行中在安全 step 边界注入（不打断流中的调用）。
4. **一切状态在 SQLite**：inbox 行、Job/KV、可见消息投影同事务落库——崩溃、重启、多客户端
   都不会丢通知或重复通知。
5. `BACKGROUND_INSTRUCTION` 是模型侧协议的一半：工具承诺"会叫你"，提示词约束"别轮询"，
   两者配对才省 token。
