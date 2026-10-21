# 06. 一次对话的全过程：从按下回车到流式渲染

> 本课把"一次对话"拆成可理解的阶段：客户端提交 → 输入准入 → 调度 → 组上下文 →
> 模型调用 → 工具执行 → 步骤结算 → 事件回流。重点是**每个阶段你能扩展什么**。
>
> 本课不追求源码行号；需要精确契约时看 `packages/schema/src/session-*.ts`，
> 需要扩展点时看第 02 课与每节末尾的「扩展点」提示。

---

## 6.0 时序总览

```
[TUI 输入框 submit]
  │  乐观插入本地 pending 行
  ▼
POST /api/session/:id/prompt
  │
  ▼
Session.prompt
  ├─ SessionPrompt.prepare       解析附件/agent/skill，跑 session.prompt hook
  ├─ SessionInbox.admit          写 session_inbox（steer/queue）
  └─ SessionExecution.wake       门铃（可合并）
       │
       ▼
SessionRunCoordinator            同 Session 单 drain
       │
       ▼
SessionRunner.drain
  ├─ advanceToStep               边界：move / compaction / 晋升输入
  ├─ SessionContext.select/load  agent + instructions + tools + model + history
  ├─ SessionModelRequest         LLMRequest + session.context/model.request hook
  ├─ SessionStep.attempt         每个 Attempt 一次 llm.stream
  │    ├─ 事件 → SessionEvent（durable / ephemeral）
  │    ├─ tool-call → 并发工具 fiber
  │    └─ step-finish → usage / snapshot / files
  └─ 继续或结束
       │
       ▼
Bus publish → 投影 + event 行 → SSE → client store → 渲染
```

---

## 6.1 客户端：回车后发生什么

### 6.1.1 组装输入

`tui/src/component/prompt/index.tsx` 的 `submit(delivery)`：

- 取当前 agent、model、variant；
- 新会话先创建 session（或使用 `--session` 指定的 ID）；
- 组装 `text`、`files`、`agents`、`skills`；
- 根据模式分发：

| 模式 | API | 说明 |
|---|---|---|
| 普通 | `data.session.prompt` | 文本 + 附件 + skill/agent 引用 |
| shell | `client.api.session.shell` | 直接提交 shell 命令 |
| 斜杠命令 | `client.api.session.command` | 服务端展开 command 模板 |
| 编辑器选区 | `client.api.session.synthetic` | 作为上下文先准入，`resume: false` |

`delivery` 来自 UI：默认 `steer`，用户可以显式排队（`queue`）。

### 6.1.2 乐观提交

`client/src/solid/data.ts` 的 `session.prompt()`：

1. 立即在 store 插入一条 pending 行（界面马上显示）；
2. 发出 HTTP；
3. 失败 → 回滚 pending 行并恢复输入；
4. 成功 → 等待 `session.inbox.enqueued` / `session.inbox.delivered` 事件替换为真实消息。

这就是"提交不卡 UI"的来源，不是 Web Worker，也不是本地假渲染。

### 6.1.3 为什么输入框在 busy 时仍可用

`tui/src/routes/session/index.tsx` 只在**权限/表单弹窗**时禁用输入。
模型运行状态不参与 `disabled`。Esc 连按两次是独立的中断命令。

**扩展点**：TUI 插件可以注册命令、slot、面板；它运行在客户端，不参与 server hook。

---

## 6.2 服务端准入：只记录，不执行

`Session.prompt`（`core/src/session/session.ts`）：

```
get(sessionID)
messageID = input.id ?? create()
existing = inbox.reconcile({ id, sessionID, type: "user", delivery })
  ├─ 已存在且匹配 → 直接返回（幂等）
  └─ 不存在 → SessionPrompt.prepare(...)
       ├─ Plugin.awaitActivation
       ├─ hooks.trigger("session", "prompt", { prompt, metadata, delivery })
       ├─ materializeAttachment：data: / file: / 目录 / 区间读取
       ├─ 解析 skills：Skill.get + Skill.prepare（正文 + 文件列表）
       └─ 返回 user payload
  → 若有 staged revert → commit
  → inbox.admit(...)               写 session_inbox，发 inbox.enqueued
  → if (resume !== false) execution.wake(sessionID)
```

要点：

- **附件在准入时物化**：文件内容会进入 payload，后续不再依赖客户端；
- **skill 在准入时展开**：用户 `@skill` 引用会变成 `skill_content` 文本；
- **hook 可以改写/拒绝输入**：`session.prompt` 是最早的扩展点；
- **同 ID 重放幂等**：客户端超时重试不会产生两条输入。

`session.prompt` hook 的 event：

```ts
{
  sessionID, messageID,
  prompt: { text, files?, agents?, skills? },
  metadata?, delivery
}
```

你可以在这里追加系统上下文、改 delivery、给输入打标签。

---

## 6.3 调度：门铃与 busy period

`SessionExecution.wake` 委托给 `SessionRunCoordinator`：

- 该 Session 已有执行 → 只置 `pendingWake`（合并）；
- 空闲 → 启动一个 execution fiber；
- execution 的开始会写 durable claim（`session.execution.started` + `SessionStore.claim`）；
- 结束（成功/失败/中断）发布对应终态事件；只有 shutdown 中断保留 claim。

一个 execution 不是"一次模型调用"，而是**一个 busy period**：
它可以在内部连续跑多个 drain / successor，直到没有待处理工作。

**扩展点**：插件不能直接创建 execution；只能通过 `ctx.session.prompt/synthetic/compact`
准入工作，或 `ctx.session.interrupt` 中断。这是有意的隔离。

---

## 6.4 Runner：边界决定一切

`SessionRunner.drain` 的核心是 `advanceToStep()`：

```
每个边界：
  1. Location 是否关闭？
  2. 有 move 控制项？ → 关闭 transport，发布 moved，换 Location 重入
  3. 有 compaction 控制项？ → 执行压缩，发布 started/ended|failed
  4. 有可晋升输入？ → promote → 写可见消息 → step = 1
  5. 没有 → Complete（会话将空闲）
```

晋升范围：

- 首次进入 / 空闲边界：`scope = "input"`，可以晋升一条 queue；
- 正在连续执行：`scope = "steer"`，只晋升 steer，不越过 compaction/move。

`promote` 的原子性：`session.inbox.delivered` 事件在**同一事务**里
删除 inbox 行 + 插入消息投影。因此不会出现"显示了两遍"或"删了没显示"。

### 为什么要把输入放在边界

- 不打断正在流的 `llm.stream`，避免半截输出；
- 一批 steer 只重置一次步数配额；
- compaction/move 必须优先，否则新输入会落进错误的上下文。

**扩展点**：后台任务、skill、重启提示都走 `synthetic`，因此自动获得同样的边界语义。

---

## 6.5 上下文：每次请求重新解析

`SessionContext.select()` 固定四样东西：

1. **Session**（含 agent、model、permissions、location）；
2. **Agent**（`Agent.select`，找不到则 `AgentNotFoundError`）；
3. **Instructions**（有序来源组合）；
4. **Tool.Snapshot**（按 agent+session 权限过滤）。

`SessionContext.load()` 再解析：

5. **Model**（catalog → runtime，含 variant）；
6. **History**（`SessionHistory.entriesForRunner`，带 compaction/instruction epoch 感知）。

### Instructions 的顺序

```
CodeMode catalog
  → MCP instructions
  → references
  → skill guidance
  → AGENTS.md（InstructionDiscovery）
  → built-ins
  → 会话级 instruction entries
```

从最稳定到最易变，目的是让 provider 的 prompt cache 前缀尽量长。

### 工具快照

`Tool.snapshot(permissions)` 返回本次请求的 definitions + execute。
请求开始后即使插件重新注册工具，本请求也不会改变；下一次请求才生效。

**扩展点**：

- 加工具：`ctx.tool.transform(editor => editor.add(...))`；
- 改工具描述/参数：`editor.update(name, tool => ...)`；
- 按权限隐藏整个工具：`options.permission` + 配置 permission 规则；
- 改请求级工具列表/描述：`session.context` hook 里的 `event.tools`。

---

## 6.6 请求组装：hooks 的完整链路

`SessionContext.request.primary(...)` → `SessionModelRequest.prepare("primary", ...)`：

```
1. baseTranscript
     system = [agent.system ?? 默认模板, instruction 基线]
     messages = toLLMMessages(历史投影)

2. session.context hook
     可改 system / messages / tools / options
     可增删工具定义（但不能凭空执行未广告的工具）

3. outputLimit
     根据模型窗口、输入估算、compaction 类型算 maxTokens

4. LLM.request(...)
     headers: session/project/client 标识、affinity、User-Agent
     promptCacheKey: session affinity
     messages: 去除不支持的媒体、限制图片总量
     tools: 过滤后定义

5. session.model.request hook
     可改 baseURL / headers（例如网关、代理）

6. http.request / http.response
     每次实际 HTTP 请求的包装（重试也会经过）

7. WebSocket（可选）
     experimental.ws.handshake / send / receive
```

**扩展点（开发插件最常用）**：

| 你想做 | 用哪个 |
|---|---|
| 注入系统提示 | `session.context` 改 `event.system` |
| 注入历史消息 | `session.context` 改 `event.messages` |
| 改温度/topP/maxTokens | `session.context` 改 `event.options` |
| 改 provider 地址/header | `session.model.request` |
| 观察/改写原始 HTTP | `session.http.request/response` |
| 改工具定义 | `ctx.tool.transform` 或 `session.context` 的 `tools` |
| 重试策略 | `session.retry` |

注意：`session.context` 里新增的"工具"必须来自已有的 `Tool.Snapshot`，
否则执行阶段会因"未广告的工具"被拒绝。正确做法是通过 `tool.transform` 注册。

---

## 6.7 Step：一次逻辑 LLM 调用

`SessionStep.attempt` 的职责：

```
1. 抓开始快照（Snapshot）
2. 创建 LLMEvent publisher（写 SessionEvent）
3. llm.stream(request) 逐事件消费
     ├─ provider-error 且未开始输出且 overflow → 交给 compaction
     ├─ 其它事件 → publisher.publish
     └─ tool-call（非 providerExecuted）→ 启动工具 fiber
4. 中断 → 中断所有工具 fiber，收尾
5. 等待工具结算
6. 计算 usage / snapshot / files
7. 发布 step ended / failed
8. 返回 Outcome
```

### 工具为什么能并行

每个 `tool-call` 都 `Effect.forkScoped` 一个 fiber，交给 `Tool.Snapshot.execute`。
同一个 step 的多个工具**并发执行**，结果按事件顺序流回。
跨 step 是串行的：当前 step 的所有工具结算完，才可能进入下一次 `llm.stream`。

真正的串行点只有：

- 权限询问 / question 弹窗（等待用户）；
- 工具自身内部的依赖（模型需要拆成多个 step）；
- `toolChoice: "none"`（达到步数上限）。

### 工具执行的扩展点

`Tool.Snapshot.execute` 内部：

```
tool.execute.before   可改 input，可失败拒绝
  → 工具 execute
  → tool.execute.after   可改 result/error
  → 内容归一化 / 图片缩放 / 输出截断
```

你的工具应该：

- 用 `Permission.assert` 做自己的授权（工具注册表不做执行授权）；
- 只把预期错误转成 `ToolFailure`，不要 `catchCause`（中断/defect 必须穿透）；
- 用 `context.progress` 回报阶段（TUI 会实时显示）；
- 返回 `{ output, content, metadata }`，让模型和 UI 都有可用信息。

---

## 6.8 事件：从 SQLite 到像素

### 6.8.1 发布

`Bus.publish`：

```
分配 aggregate seq
  → 在同一事务里跑 projector（写 session_message / session_inbox / session 表）
  → 插入 event 行
  → 提交
  → PubSub 扇出（durable + ephemeral）
```

- **durable**：`session.step.*`、`session.tool.*`、`session.inbox.*`、`session.execution.*` 等；
- **ephemeral**：delta（`session.text.delta`、`session.reasoning.delta`、tool progress），
  不落库，只用于实时渲染；重连后靠 durable part + 当前消息补齐。

### 6.8.2 传输

- `GET /api/event`：全局 SSE，客户端默认入口；
- `GET /api/experimental/session/:id/log`：按 `after` 重放 durable 事件；
- WebSocket：仅 PTY。

客户端连接（`client/src/solid/connection.ts`）：

- 第一帧必须是 `server.connected`；
- 10ms 批量 flush；
- 45s 无字节视为 stall（服务端每 15s keepalive）；
- 断线 1s 退避重连。

### 6.8.3 渲染

`client/src/solid/data.ts` 把事件归并到 store：

| 事件 | 本地动作 |
|---|---|
| `session.inbox.enqueued` | 插入 pending 输入 |
| `session.inbox.delivered` | pending → 真实 user 消息 |
| `session.step.started` | 新建 assistant 消息 |
| `session.text.delta` | 追加文本（打字机） |
| `session.reasoning.delta` | 追加 reasoning（可折叠） |
| `session.tool.called/success/failed` | 更新工具状态卡 |
| `session.step.ended` | 写 usage、快照、文件 diff |
| `session.execution.*` | footer 状态 / 结束条件 |

**扩展点**：TUI 插件可以订阅事件、渲染自定义面板；但不要假设事件顺序之外的状态，
一切以 store 的最终投影为准。

---

## 6.9 失败、重试与压缩

### 重试

`SessionRunnerRetry`：

- 2s → 10s 指数退避，最多 10 次，带 jitter；
- 尊重 provider `retryAfterMs`，上限 15 分钟；
- 超时最多 3 次；
- 每次决策都过 `session.retry` hook。

### 不完整流

- 已开始输出后中断 → `Continue`：注入"继续，不要重复"的 synthetic，
  新 assistant 消息接着写；
- 未开始输出且 `retry-full` → `RecoverFull`：重载上下文后整次重试；
- provider 返回未知 finish reason → 视为 `incomplete-stream`。

### 压缩

`SessionCompaction.compact({ reason: "auto" | "overflow" | "manual", context })`：

- `auto`：请求前判断窗口，放得下就跳过；
- `overflow`：provider 拒绝超长，在无可见输出前重建；
- `manual`：`/compact` 收件箱控制项，边界优先；
- 失败会发布 `compaction.failed`，不会静默吞掉。

`session.compaction` hook 可以：

- 改压缩请求的 system/messages/options；
- 直接设置 `result`（`{ summary, providerState?, metadata?, tokens? }`）跳过模型；
- 观察压缩前后状态。

---

## 6.10 完整时间线（浓缩）

```
T1  TUI submit
      data.session.prompt：乐观 pending 行

T2  POST /api/session/:id/prompt
      Session.prompt → prepare → inbox.admit → wake

T3  Coordinator 启动 execution（或合并 pendingWake）
      durable claim + session.execution.started

T4  Runner.advanceToStep
      promote → session.inbox.delivered（同事务插 user 消息）
      step 重置

T5  SessionContext.select/load
      agent / instructions / tools / model / history

T6  SessionModelRequest.prepare
      session.context → LLM.request → session.model.request → http hooks

T7  llm.stream
      reasoning/text/tool-input 流
      每个 tool-call → Tool.Snapshot.execute（并发 fiber）
      tool.execute.before/after

T8  step-finish
      usage、cost、snapshot、files → session.step.ended

T9  还有工具/续写/steer → 下一个 step
      否则 advanceToStep → Complete
      session.execution.succeeded

T10 TUI：SSE → 10ms batch → 消息/工具卡/footer 更新
```

---

## 6.11 开发插件时最该记住的五件事

1. **输入从 `session.prompt` 进**：不要试图直接改历史；准入是唯一入口。
2. **工具从 `tool.transform` 注册**：`session.context` 里改定义只影响"广告什么"，
   执行仍以注册表为准。
3. **请求用 `session.context` 改**：这是最稳定、最常用的扩展点。
4. **不要在工具里吞中断/defect**：只把预期错误转成 `ToolFailure`。
5. **状态以事件为准**：delta 是临时的，durable 事件才是真相。

> **迁移小注**：V1 的 `chat.message`、`chat.params`、`chat.headers`、
> `experimental.chat.messages.transform`、`processor`、`runLoop` 已删除。
> V2 对应 `session.prompt` / `session.context` / `session.model.request` 与
> `SessionStep`。
