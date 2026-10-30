# 5. Agent 内核：Agent、Tool、Skill、System Prompt 与 LLM 调用

> 本课回答：V2 的"Agent 内核"由哪些服务组成？一次 step 里 Agent 配置、工具快照、
> Skill 指令、System Prompt 和 LLM 请求是怎么拼起来的？
>
> 会话如何被准入、调度、压缩，见第 02/03/04 课；本课聚焦"一次模型调用前后"的组件。
> V1 的 `SessionPrompt.runLoop` / `processor` / `task` 工具已不在源码树，不再讨论。

---

## 5.1 组件总览

```
                       ┌────────────────────────────┐
                       │        SessionRunner       │
                       │  runner/llm.ts + step.ts   │
                       └─────────────┬──────────────┘
                                     │ 每个 step
                                     ▼
        ┌────────────────────────────────────────────────────┐
        │                 SessionContext                      │
        │  select(): Agent / Instructions / Tool.Snapshot    │
        │  load():   Model / 历史投影                         │
        └───────┬─────────────┬───────────────┬──────────────┘
                │             │               │
                ▼             ▼               ▼
          Agent.Service  Skill.Service   Tool.Service
                │             │               │
                └─────────────┴───────┬───────┘
                                      ▼
                          SessionModelRequest.prepare()
                          ├─ session/context hook
                          ├─ session/model.request hook
                          └─ session/http.* 等 hook
                                      │
                                      ▼
                              LLMClient.stream()
                              @opencode/ai/route/client.ts
                                      │
                                      ▼
                               LLMEvent 流
```

### 核心文件

| 文件 | 职责 |
|---|---|
| `packages/core/src/agent.ts` | Agent 注册表（State + transform），默认 agent 选择 |
| `packages/core/src/plugin/agent.ts` | 内置 agent：build / general / explore / compaction / title / summary |
| `packages/core/src/plugin/plan.ts` | plan agent、Plan 模式提醒注入 |
| `packages/core/src/tool.ts` | Location 范围工具注册表、快照、执行、输出归一化 |
| `packages/core/src/tool/plugin/*.ts` | 内置工具（每个都是一个插件） |
| `packages/core/src/skill.ts` | Skill 注册表与加载输出格式 |
| `packages/core/src/skill/instructions.ts` | 把可用 skill 摘要注入 instructions |
| `packages/core/src/config/plugin/skill.ts` | 从目录/URL 发现并热更新 skill |
| `packages/core/src/config/plugin/instruction.ts` | AGENTS.md 发现与热更新 |
| `packages/core/src/instructions/index.ts` | Instructions 代数：读取、diff、渲染 |
| `packages/core/src/session/instructions.ts` | 会话级指令来源 |
| `packages/core/src/session/system-prompt.ts` | 内置 system prompt 模板与工具指导 |
| `packages/core/src/session/model-request.ts` | LLM 请求组装、hook、媒体约束 |
| `packages/core/src/session/runner/model.ts` | 会话模型解析（catalog → runtime） |
| `packages/core/src/model-resolver.ts` | 包/凭证/变体 → `LanguageModel` |
| `packages/ai/src/route/client.ts` | `LLMClient`：stream / generate / compact |
| `packages/ai/src/schema/events.ts` | `LLMEvent` 定义 |

---

## 5.2 Agent

### 5.2.1 数据结构

`@opencode/schema/agent` 的 `Agent.Info`：

```ts
{
  id, name, model?, request: { settings, headers, body },
  system?, description?,
  mode: "subagent" | "primary" | "all",
  hidden: boolean,
  color?, steps?,
  permissions: Permission.Ruleset
}
```

默认权限由 `Agent.Info.default(id)` 给出：全允许，但读取 `*.env` / `*.env.*` 需要询问，
`*.env.example` 允许。

### 5.2.2 注册与选择

`Agent.Service`（`packages/core/src/agent.ts`）是 Location 范围的 State：

- `transform(editor)`：按注册顺序重放，可 `update/remove`；
- `get(id)` / `resolve(id?)` / `select(id?)` / `list()`；
- 默认 agent：配置里的 `default_agent` → 内置 `build` → 第一个可选的 primary。

内置 agent 由 `plugin/agent.ts` 注册：

| Agent | mode | 说明 |
|---|---|---|
| `build` | primary | 默认执行型 agent，允许 question |
| `general` | subagent | 通用多步任务，禁止 question 与继续嵌套 subagent |
| `explore` | subagent | 只读探索：允许 shell（只读约定）、grep、glob、read、webfetch、websearch |
| `plan` | primary | 只读规划；只允许编辑 `~/.opencode/plan/**`，由 `plugin/plan.ts` 注入模式提醒 |
| `compaction` | primary, hidden | 压缩专用 |
| `title` | primary, hidden | 生成标题，拒绝所有工具 |
| `summary` | primary, hidden | 生成摘要，拒绝所有工具 |

配置/项目文件里的 agent 通过 `config/plugin/agent.ts` 合并：
`agent/agents/**/*.md` 与 `mode/modes/*.md` 会被扫描，front-matter 是配置，正文是 `system`；
同名 agent 覆盖内置字段，`disabled: true` 删除。

### 5.2.3 Agent 参与请求的两处

1. `SessionContext.select()`：选择 agent 与它的权限，用于工具快照和 skill 过滤；
2. `SessionModelRequest.baseTranscript()`：`agent.system` 存在时替换默认 system prompt，
   否则使用 `SessionSystemPrompt.make(toolNames)`。

Agent 的 `model` 会参与子代理/标题等辅助选择；primary 请求实际使用 Session 记录的模型
（`Session.model` → `SessionRunnerModel.resolve`）。`request`（headers/body）是配置保留字段，
当前 primary 请求的 headers/body 主要来自 provider/model 设置与 `session.model.request` 等 hook。

---

## 5.3 Tool

### 5.3.1 注册表模型

一个工具就是一条 `Tool.Info`：

```ts
interface Info {
  name: string
  description: string
  input: Schema.Codec | StandardSchema | JsonSchema
  output?: Schema.Codec | StandardSchema | JsonSchema
  options?: {
    namespace?: string       // 对模型暴露为 <namespace>_<tool>
    permission?: string      // 仅用于整工具可见性过滤
    codemode?: boolean       // 默认 true → 进入 CodeMode catalog
  }
  execute(input, context): Effect<Result, Tool.Error>
}
```

关键点：

- **注册顺序有优先级**：同 effective name 后注册者覆盖先注册者；卸载后回退到前一个。
- **快照隔离**：`Tool.snapshot(permissions)` 捕获本次请求可用的 definitions 与 executors；
  运行中的请求不会被后续 `reload` 改变。
- **CodeMode**：默认工具不直接出现在 provider 的 tool list，而是通过 `execute` 工具
  暴露一个可编程 catalog；`codemode: false` 的工具（skill、subagent 等）保持原生暴露。
- **权限可见性 ≠ 执行授权**：快照只过滤"模型看不看得到"；真正执行时工具叶子仍会
  `Permission.assert`。

### 5.3.2 内置工具来源

`packages/core/src/plugin/internal.ts` 的 `pre` 数组按顺序注册：

```
patch → edit / glob / grep / opencode / mcp-resource / question /
read / shell / skill / subagent / webfetch / websearch / write
```

`shell` 是子进程执行入口；`read` 通过 `ReadToolFileSystem` 适配本地/远端；
`mcp-resource` 暴露 MCP resources 工具；`subagent` 见第 12 课。

### 5.3.3 执行链

```
SessionStep.attempt
  └─ 收到 tool-call 事件
       └─ Effect.forkScoped(
            prepare.executeTool({ sessionID, agent, messageID, call })
              └─ Tool.Snapshot.execute
                   ├─ PluginHooks.trigger("tool", "execute.before")  // 可改写 input，可失败拒绝
                   ├─ 找到对应 tool（direct 或 codemode）
                   ├─ execute(tool, input, context)
                   ├─ PluginHooks.trigger("tool", "execute.after")   // 可改写 result / error
                   ├─ normalizeContent + 图片归一化
                   └─ ToolOutput.truncate
          )
```

工具执行上下文只有：

```ts
{ sessionID, agent, messageID, id: CallID, progress }
```

`progress` 会把工具运行中的 metadata 实时写回消息投影（TUI 因此能显示实时标题）。

---

## 5.4 Skill

### 5.4.1 发现与注册

`config/plugin/skill.ts` 汇总来源：

```
每个配置目录（包含 .opencode 目录）下的 skill/ 与 skills/
config.skills[] 里的绝对路径、~/ 路径或 http(s) URL
~/.claude/skills/** 与 ~/.agents/skills/**（兼容目录，ConfigCompatibilityPlugin）
内置：opencode、report
```

支持两种文件布局：

```
skills/<name>/SKILL.md
skills/<name>.md
```

`skill-file.ts` 解析 front-matter（`name`、`description`、`disable-model-invocation`、
`metadata.opencode/autoinvoke`），正文作为 skill content。

### 5.4.2 注入与加载

- **注入**：`skill/instructions.ts` 只把 `id/name/description` 渲染成
  `<available_skills>`；`autoinvoke: false` 或无 description 的 skill 不出现。
- **加载**：模型调用 `skill({ id })`（`tool/plugin/skill.ts`）
  1. `Skill.get(id)`
  2. `Permission.assert({ action: "skill", resources: [id] })`
  3. `Skill.prepare`：读取正文，扫描同目录**前 10 个文件**
  4. 返回 `<skill_content name="...">` + `<skill_files>`
- **用户直接调用**：`Session.skill` 发布 `session.skill.activated` 事件，把
  `<skill_content>` 作为可见消息写入历史，并默认唤醒执行。

Skill 列表变化时，指令来源会生成增量文本（新增/移除给差量，描述变化退回全文重述），
而不是整段重发，保护 prompt cache。注意**正文不在列表里**：正文走工具结果，
已经加载过的那份会留在历史中，改文件只影响下一次加载（详见附录
[`instruction-delta-and-cache.md`](./instruction-delta-and-cache.md)）。

---

## 5.5 System Prompt 与 Instructions

### 5.5.1 Instructions 是"有序来源"，不是一个大字符串

`Instructions`（`packages/core/src/instructions/index.ts`）：

```
Source = { key, read, initial(value), changed(prev, next), removed(prev) }
```

- `read` 返回规范 JSON（或 `unavailable` / `removed`）；
- `diff` 只记录值 hash 的变化；
- `renderInitial` 生成会话基线，`renderUpdate` 生成增量 System 消息。

`SessionContext.select()` 的组合顺序（从最稳定到最易变）：

```
CodeModeInstructions
  → MCP instructions
  → references
  → skill guidance
  → InstructionDiscovery（AGENTS.md）
  → built-ins
  → 会话级 instruction entries
```

这样可以最大化 provider 的 prompt cache 命中率。

> 顺序的运行时含义、增量消息长什么样、改文件/改技能后缓存怎么算，
> 见附录 [`instruction-delta-and-cache.md`](./instruction-delta-and-cache.md)。

### 5.5.2 System prompt 的两段

`SessionModelRequest.baseTranscript()`：

```ts
system = [
  agent.system ?? SessionSystemPrompt.make(toolNames),
  instructionBaseline,
]
```

`SessionSystemPrompt` 的模板是 `session/runner/prompt/system.txt`，
会根据实际工具集注入不同指导（shell / write / edit）。

之后 `SessionModelRequest.prepare()` 还会触发：

- `session.context`：插件可修改 system、messages、tools、options；
- `session.model.request`：可改 baseURL / headers；
- `session.http.request` / `session.http.response`：包住每次 HTTP；
- `session.retry`：可改重试决策；
- WebSocket 传输时还有 `experimental.ws.*`。

---

## 5.6 模型与 LLM 调用

### 5.6.1 解析链

```
Session.model (Model.Ref)
  → SessionRunnerModel.resolve
  → Model.available() 找 catalog 条目
  → ModelResolver.resolveModel
       ├─ withVariant：合并 variant 的 settings/headers/body
       ├─ Provider.Service：provider 定义、认证、包名
       ├─ Integration.Service：连接/凭证
       ├─ Provider.loadPackage：@opencode/ai/providers/* 或 npm 包
       └─ AISDK.model 或原生 provider 包 → LanguageModel
  → Resolved { model, ref, capabilities, cost, limit, compaction, transport }
```

`Resolved.ref` 是**持久化与显示使用的 catalog 身份**；`Resolved.model.id` 是
provider API 的模型 id，两者可能不同（如别名/路由）。

### 5.6.2 请求

`LLM.request({ model, system, messages, tools, toolChoice, generation, providerOptions, http })`
得到规范化 `LLMRequest`，再交给：

```ts
llm.stream(request, options): Stream<LLMEvent, AIError>
```

`StreamOptions` 可带 `http` 中间件和 `webSocket` 绑定。会话 runner 只在
`model.transport === "websocket"` 时使用状态化 WebSocket。

### 5.6.3 LLMEvent

下游只认识统一事件，不关心底层是 AI SDK、原生协议还是 WebSocket：

| 类别 | 事件 |
|---|---|
| 文本 | `text-start` / `text-delta` / `text-end` |
| 推理 | `reasoning-start` / `reasoning-delta` / `reasoning-end` |
| 工具输入 | `tool-input-start` / `-delta` / `-end` / `-error` |
| 工具执行 | `tool-call` / `tool-result` / `tool-error` |
| 步骤 | `step-start` / `step-finish` |
| 结束/错误 | `finish` / `provider-error` |
| 媒体 | `media` |

`runner/publish-llm-event.ts` 把这些事件翻译成 durable/ephemeral 的 `SessionEvent`，
例如 `session.text.started/delta/ended`、`session.tool.called/success/failed`、
`session.step.started/ended/failed`。这是 TUI 和 CLI 看到的一切。

### 5.6.4 重试与失败

`runner/retry.ts`：

- 指数退避 2s → 10s，最多 10 次（带 jitter），总等待约 1 分半；
- 尊重 provider 的 `retryAfterMs`，上限 15 分钟；
- 超时类尝试最多 3 次；
- 每次决策都经过 `session.retry` hook，可强制不重试或改延迟。

`runner/step.ts` 还区分：

| 情况 | 处理 |
|---|---|
| 输出开始前 overflow | 触发 `compaction(reason: "overflow")` 后重建 |
| 输出开始前的传输失败 | 通用重试或 `RecoverFull`（全量上下文重试） |
| 输出开始后流中断 | `Continue`：注入续写提示，保留已产生内容 |
| 权限拒绝 / question 取消 | 工具标记 aborted，按中断语义收尾 |

---

## 5.7 ReAct 在 V2 里是什么样

V2 没有单独的 `runLoop` 函数，ReAct 体现在 `SessionRunner.drain`：

```
while (true) {
  next = advanceToStep()       // 推进输入、处理 compaction/move；没有可推进工作则 Complete
  if (next !== Ready) return
  continuing = runStep(...)    // 一个逻辑 step，返回"模型是否还想继续"
}
```

`continuing` 只影响下一次 `advanceToStep` 的晋升范围（`steer` 还是 `input`）；
真正结束由"没有 pending 输入、且 queue 也不再晋升"决定。

- **一个 step = 一次逻辑 LLM 调用**；
- 模型在 step 内发出多个 tool-call → 每个工具一个 fiber **并发执行**；
- 所有工具结算完、step-finish 落库后，才进入下一个 step；
- 新输入 / 后台通知 / 手动压缩在 step 边界被晋升，不会打断正在流的调用。

终态由 `SessionEvent.Execution.Succeeded / Failed / Interrupted` 标记，
不是函数返回值。

---

## 5.8 开发 Tool 时必须理解的约束

| 约束 | 原因 |
|---|---|
| 工具通过 `tool.transform` 注册，不在请求里临时创建 | 快照隔离；请求只执行自己广告过的工具 |
| `execute` 的上下文只有 session/agent/message/callID/progress | 不把服务泄漏进工具签名；服务在注册时捕获 |
| 权限在工具叶子内断言，不是注册表统一做 | 每个工具知道自己的 resource 粒度；注册表只做可见性过滤 |
| 只把预期错误转成 `Tool.Error` | 中断/defect 必须穿透，否则无法正确收尾 |
| 输出分 `output` / `content` / `metadata` | 分别服务程序、模型、UI |
| 长任务尽快返回 | 阻塞 step 会拖住整个会话；完成通知走 synthetic |

工具执行失败时，模型会看到错误内容并有机会重试；用户拒绝权限则是另一条路径
（`Permission.DeclinedError`，在 `executeTool` 边界恢复为失败）。
不要把两者混成同一种错误文本。

> 外部插件工具若拿不到 `Permission.assert`，应在 `tool.execute.before` 里做显式策略检查，
> 并用 `Tool.Error` 拒绝；不要把"需要用户确认"伪装成普通执行错误。

---

## 5.9 小结

1. **Agent 是配置**：模型、system、权限、步数、请求覆盖；运行行为由 runner 统一实现。
2. **Tool 是注册表 + 快照**：内置工具也是插件；快照隔离保证请求内一致。
3. **Skill 是延迟加载的指令包**：system 里只有摘要，正文通过 `skill` 工具进入历史。
4. **Instructions 是有序来源代数**：支持增量更新与 prompt cache 友好排序。
5. **LLM 调用统一收敛到 `LLMEvent`**：provider 差异被 `@opencode/ai` 吸收。
6. **ReAct = drain 循环**：step 之间串行，step 内工具并行，输入只在安全边界晋升。

> **迁移小注**：旧版 `packages/opencode/src/session/prompt.ts`、`processor.ts`、
> `tool/task.ts` 已删除；如果看到这些路径，说明资料过期。V1 兼容在核心侧只剩
> 配置归一化（`core/src/v1/config/*`）与数据导入（`database/v1-migration*`）；
> CLI 的旧参数桥接（`cli/src/run/v1.ts`）也不属于本课。
