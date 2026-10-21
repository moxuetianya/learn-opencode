# OpenCode V2 架构总览：五条主线

> 这是 `docs/learn` 的入口课，只讨论当前 V2 实现（opencode 2.0.24）。
> 详细展开见编号课程；本课负责把 V2 的整体形状先立起来。
>
> V1（`SessionPrompt.runLoop`、`session_input`、内嵌 worker TUI）已经不在源码树里，
> 只剩少量配置/数据/入口兼容代码，本课不再展开。

---

## 目录

1. [包与分层](#一包与分层)
2. [会话执行模型](#二会话执行模型)
3. [工具、插件与扩展点](#三工具插件与扩展点)
4. [上下文、压缩与记忆](#四上下文压缩与记忆)
5. [多代理与后台任务](#五多代理与后台任务)
6. [学习路径](#六学习路径)

---

## 一、包与分层

```
@opencode/schema      契约：Session 事件、消息、Inbox、Config、Tool、Model…
        ▲
        ├── @opencode/protocol     HttpApi 组：/api/session、/api/event…
        │            ▲
        │            └── @opencode/server    把协议绑定到 Core handler
        │
        └── @opencode/core        运行时：Database、Bus、Session、Runner、Tool、Plugin…
                     ▲
        ┌────────────┼─────────────┬──────────────┐
     @opencode/cli  @opencode/tui  @opencode/client  @opencode/app / desktop
```

- **Schema 只放可序列化契约**，不放服务与副作用。
- **Protocol 只放 HTTP 形状**，不知道 Core 的服务标识。
- **Server 负责组装**：`createRoutes()` 用 `LayerNode` 把 Core 服务图 + handler + 中间件接起来。
- **Core 是全部有状态执行**：SQLite、事件总线、Session 编排、模型调用、工具执行。
- **CLI/TUI/Web/Desktop 都是客户端**：只发请求、收事件、渲染。

对应文件：

| 层 | 入口 |
|---|---|
| Schema | `packages/schema/src/index.ts`、`session-event.ts`、`session-inbox.ts` |
| Protocol | `packages/protocol/src/api.ts`、`groups/session.ts`、`groups/event.ts` |
| Server | `packages/server/src/routes.ts`、`handlers/*.ts`、`process.ts` |
| Core | `packages/core/src/session.ts`、`session/`、`tool.ts`、`plugin.ts` |
| CLI | `packages/cli/src/index.ts`、`commands/commands.ts`、`commands/handlers/default.ts` |
| TUI | `packages/tui/src/app.tsx`、`context/*`、`packages/session-ui/src/*` |
| Client | `packages/client/src/solid/data.ts`、`solid/connection.ts` |

---

## 二、会话执行模型

V2 的核心思想只有一句：**先把工作耐久地记下来，再决定什么时候执行**。

```
用户输入
  │
  ▼
Session.prompt                 packages/core/src/session/session.ts
  ├─ SessionPrompt.prepare     解析文本/文件/agent/skill，跑 session.prompt hook
  ├─ SessionInbox.admit        写一行 session_inbox（delivery = steer | queue）
  └─ SessionExecution.wake     门铃：只是"有活了"，不是开始执行
        │
        ▼
SessionRunCoordinator          packages/core/src/session/run-coordinator.ts
  ├─ 同一 Session 只允许一个 drain（busy period）
  ├─ 运行中再 wake → pendingWake 合并
  └─ 空闲 → 启动 execution fiber
        │
        ▼
SessionRunner.drain            packages/core/src/session/runner/llm.ts
  loop:
    ├─ advanceToStep           边界检查 + 晋升输入 + 处理 compaction/move
    ├─ context.select/load     解析 agent、instructions、工具快照、模型、历史
    ├─ SessionModelRequest     组装 LLMRequest，跑 session/model.request 等 hook
    ├─ SessionStep.attempt     每个 Physical Attempt 恰一次 llm.stream
    │    ├─ 流事件 → SessionEvent（durable/ephemeral）
    │    ├─ tool-call → 每个工具一个 fiber 并发执行
    │    └─ step-finish → 用量、快照、文件 diff
    └─ needsContinuation? → 下一个 step
```

四个关键词：

| 词 | 含义 | 位置 |
|---|---|---|
| **Admit** | 只落库，不执行 | `session/inbox.ts` |
| **Wake** | advisory 门铃，可合并 | `session/run-coordinator.ts` |
| **Drain** | 一次 busy period 的执行 fiber | `session/execution.ts` |
| **Step** | 一次逻辑 LLM 调用 | `session/runner/step.ts` |

`steer`（默认）在下一个安全 step 边界插队；`queue` 等到会话将要空闲时一次晋升一条。
真正打断流只能 `Session.interrupt`。细节见第 03 课。

---

## 三、工具、插件与扩展点

### 3.1 Tool 是一个 Location 范围的注册表

```ts
// packages/core/src/tool.ts
interface Snapshot {
  definitions: readonly ToolDefinition[]
  execute(input: {
    sessionID
    agent
    messageID
    call: ToolCall
    progress?
  }): Effect<NormalizedResult, Tool.Error>
}
```

内置工具不是硬编码列表，而是一批**内置插件**，在 `plugin/internal.ts` 的 `pre` 数组里
通过 `ctx.tool.transform(editor => editor.add(...))` 注册：

`shell`、`read`、`write`、`edit`、`patch`、`glob`、`grep`、`skill`、`subagent`、
`webfetch`、`websearch`、`question`、`mcp-resource`、`opencode` 等。

每个请求只捕获当时的工具快照；注册/卸载/重载影响之后的请求，不影响进行中的请求。
工具执行上下文只有 `sessionID / agent / messageID / callID / progress`，
权限由工具叶子自己通过 `Permission.assert` 断言。

### 3.2 Skill 是按需加载的指令包

- 发现：`packages/core/src/config/plugin/skill.ts`
- 解析：`config/plugin/skill-file.ts`（`SKILL.md` 或目录名 `.md`）
- 注册：`Skill.Service`，内置 `opencode` / `report` 两个 skill
- 注入：`skill/instructions.ts` 只把 `id/name/description` 放进 system prompt；
  模型调用 `skill` 工具后才把正文与文件列表作为 `<skill_content>` 返回

### 3.3 Plugin 有两种能力

1. **Hook**：`PluginHooks.trigger(domain, name, event)`，事件对象可被原地修改；
2. **Transform**：`ctx.agent.transform` / `ctx.tool.transform` / `ctx.skill.transform` /
   `ctx.provider.transform` / `ctx.model.transform` 等，按注册顺序重放。

加载顺序：内置 `pre` → SDK/实例插件 → 内置 `post` → 配置声明的外部插件
（顺序与覆盖规则见第 06 课）。

---

## 四、上下文、压缩与记忆

### 4.1 历史不是“聊天数组”，而是事件投影

- **真相源**：`event` 表（durable 事件日志，按 aggregate + seq 排序）
- **读模型**：`session_message`（可见消息）、`session_inbox`（未消费工作）
- 发布一个 durable 事件时，**投影与事件行在同一事务**提交，然后才 PubSub 扇出。

因此：客户端断线可重放、进程崩溃可恢复、投影可重建。细节见第 10 课。

### 4.2 每次请求重新组装上下文

`SessionContext.select()` 解析：

```
agent（Agent.Service）
instructions（Instructions.combine 的有序来源）
  ├─ CodeMode catalog
  ├─ MCP instructions
  ├─ references
  ├─ skill guidance
  ├─ AGENTS.md 发现（InstructionDiscovery）
  ├─ built-ins
  └─ 会话级 instruction entries（增量更新）
tools（Tool.Service.snapshot，按权限过滤）
```

顺序刻意从“跨会话最稳定”到“最容易变化”，让前缀更容易命中 provider 的 prompt cache。

### 4.3 压缩是 Session 的职责

`packages/core/src/session/compaction.ts` 处理三种触发：

| reason | 触发 | 行为 |
|---|---|---|
| `auto` | 上下文接近窗口上限 | 放得下/关闭自动则跳过 |
| `overflow` | provider 刚拒绝超长 | 在产生可见输出前重建 |
| `manual` | `/compact` 收件箱控制项 | 边界优先 |

它选择 summary 或 provider 原生 checkpoint，负责请求收缩、重试、中断、用量与
checkpoint 持久化；provider 细节封装在 `@opencode/ai` 的 `LLMClient.compact`。

---

## 五、多代理与后台任务

### 5.1 子代理 = 子 Session

`subagent` 工具（`tool/plugin/subagent.ts`）：

- 校验父子关系与 `experimental.subagent_depth`
- `sessions.create({ parentID })` 创建子会话
- 前台：`sessions.prompt` + `sessions.wait`，把最终 assistant 文本作为工具结果
- 后台：`background: true` 注册 Job，立即返回
  *"You will be notified automatically when it finishes"*
- 完成后通过 `SubagentCompletion.deliver` 向父会话注入 synthetic 消息并 wake

### 5.2 后台 shell 同一套机制

`shell` 工具 `background: true` → `Job.start` → `jobs.background` → 完成时
`Session.synthetic`（默认 steer）+ `execution.wake`。细节见第 12 课。

### 5.3 重启后继续

执行开始时写入 write-ahead claim（`session.time_suspended`），终态释放；
shutdown/崩溃保留 claim。托管 server 启动时 `SessionRestart.resumeSuspendedSessions`
扫描 claim、注入 "Continuing after restart"、带预算地续跑。细节见第 11 课。

---

## 六、学习路径

| 天数 | 内容 | 对应课程 |
|---|---|---|
| 第 1 天 | 启动链路 + 第一次对话 | 01、02 |
| 第 2 天 | 并发与收件箱、Session Core 不变式 | 03、04 |
| 第 3 天 | Agent / Tool / Skill / System Prompt | 05 |
| 第 4 天 | Plugin 与 Hook | 06 |
| 第 5 天 | 配置、存储、服务生命周期 | 08、10、11 |
| 第 6 天 | UI、Server/Client、后台任务 | 07、09、12 |

> **如果你的目标是开发插件/工具**：先读 06（扩展模型）→ 05（数据结构）→ 02（hook 时机），
> 然后直接用 `code-examples.md` 里的骨架。其余课程按需回查即可。

读源码的推荐顺序：

```
session/inbox.ts
  → session/run-coordinator.ts
  → session/execution.ts
  → session/runner/llm.ts
  → session/runner/step.ts
  → session/context.ts
  → session/model-request.ts
  → tool.ts + tool/plugin/*
  → plugin/hooks.ts + plugin/supervisor.ts
```

遇到不确定的行为，先看 `packages/schema/src/session-event.ts`：
事件类型就是系统对外承诺的全部事实。
