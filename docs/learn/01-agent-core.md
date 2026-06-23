# 1. Agent 内核：ReAct 循环、Tool-Use、LLM 调用与 Skill 注入

## 1.1 架构概览

Agent 内核是整个 opencode 的"大脑"，负责接收用户输入、调用大模型、执行工具、返回结果。核心是一个 **ReAct (Reasoning + Acting) 循环**。

```
用户输入 → Prompt → 解析Agent → 构建System Prompt → 构建Tools → LLM调用
                                                              ↓
                                                         解析Event流
                                                              ↓
                                               ┌─ text → 写入消息
                                               ├─ tool-call → 执行工具
                                               ├─ step-finish → 结算tokens
                                               └─ error → 重试/停止
                                                              ↓
                                              continue? → 回到循环开头
                                              stop → 结束
```

### 核心文件

| 文件 | 职责 |
|------|------|
| `packages/opencode/src/session/prompt.ts` | **主循环入口**：`runLoop()` 函数（第1134行）是整个 Agent 循环的核心 |
| `packages/opencode/src/session/processor.ts` | **LLM 事件流处理器**：接收原始 LLM 事件，翻译为持久化的 session 消息 |
| `packages/opencode/src/session/llm.ts` | **LLM 调用服务**：模型解析、运行时选择（AI SDK / Native）、流式调用 |
| `packages/opencode/src/session/tools.ts` | **工具解析**：为 LLM 调用构建 `Record<string, Tool>` |
| `packages/opencode/src/tool/registry.ts` | **工具注册表**：内置工具 + 插件工具发现、过滤 |
| `packages/opencode/src/tool/tool.ts` | **工具类型定义**：`Def`、`Context`、`ExecuteResult` 接口 |
| `packages/opencode/src/skill/index.ts` | **Skill 服务**：从磁盘发现和加载 skill 文件 |
| `packages/opencode/src/session/system.ts` | **System Prompt 构建**：环境信息、skill 列表注入到 system prompt |
| `packages/opencode/src/agent/agent.ts` | **Agent 定义与管理**：内置 agent 类型（build/plan/general/explore 等） |

---

## 1.2 ReAct 循环详解

### 1.2.1 循环入口：`SessionPrompt.runLoop()`

位置：`packages/opencode/src/session/prompt.ts:1134`

```ts
const runLoop = Effect.fn("SessionPrompt.run")(function* (sessionID: SessionID) {
  let step = 0
  const session = yield* sessions.get(sessionID)

  while (true) {
    yield* status.set(sessionID, { type: "busy" })

    // 1. 获取当前所有消息（含 compaction 过滤）
    let msgs = yield* MessageV2.filterCompactedEffect(sessionID)

    // 2. 找到最新的 user/assistant/finished 消息
    const { user: lastUser, assistant: lastAssistant, finished: lastFinished, tasks } = MessageV2.latest(msgs)

    // 3. 检查终止条件：assistant 已 finish 且无待处理的 tool-calls
    if (lastAssistant?.finish && !["tool-calls"].includes(lastAssistant.finish) && !hasToolCalls) {
      break
    }

    step++

    // 4. 解析模型
    const model = yield* getModel(lastUser.model.providerID, lastUser.model.modelID, sessionID)

    // 5. 检查待处理任务：subtask（子代理）或 compaction（上下文压缩）
    const task = tasks.pop()
    if (task?.type === "subtask") { yield* handleSubtask(...); continue }
    if (task?.type === "compaction") { yield* compaction.process(...); continue }

    // 6. 上下文溢出检测 → 自动触发 compaction
    if (lastFinished && yield* compaction.isOverflow(...)) {
      yield* compaction.create({ ..., auto: true })
      continue
    }

    // 7. 解析 Agent 配置
    const agent = yield* agents.get(lastUser.agent)

    // 8. 创建空的 Assistant 消息（待填充）
    yield* sessions.updateMessage(assistantMsg)

    // 9. 创建 processor handle（管理此次 LLM 调用的生命周期）
    const handle = yield* processor.create({ assistantMessage, sessionID, model })

    // 10. 解析工具
    const tools = yield* SessionTools.resolve({ agent, session, model, processor: handle, ... })

    // 11. 构建 system prompt、环境信息、skill 列表
    const [skills, env, instructions, modelMsgs] = yield* Effect.all([
      sys.skills(agent),
      sys.environment(model),
      instruction.system(),
      MessageV2.toModelMessagesEffect(msgs, model),
    ])
    const system = [...env, ...instructions, ...(skills ? [skills] : [])]

    // 12. 调用 LLM 流式请求
    const result = yield* handle.process({
      user: lastUser,
      agent,
      system,
      messages: modelMsgs,
      tools,
      model,
    })

    // 13. 评估结果
    if (result === "stop") break
    if (result === "compact") { yield* compaction.create(...) }
    // continue → 回到循环开头
  }
})
```

### 1.2.2 循环状态机

```
                    ┌──────────┐
                    │  idle    │  初始状态
                    └────┬─────┘
                         │ prompt() / loop() 被调用
                         ▼
                    ┌──────────┐
             ┌─────▶│  busy    │  step++
             │      └────┬─────┘
             │           │
             │           ├── subtask detected ──▶ handleSubtask() ──▶ continue
             │           │
             │           ├── compaction needed ──▶ compaction.process() ──▶ continue/stop
             │           │
             │           ├── overflow detected ──▶ compaction.create(auto=true) ──▶ continue
             │           │
             │           └── normal ──────────▶ LLM.call() ──▶ processor.process()
             │                                              │
             │                    ┌─────────────────────────┤
             │                    ▼                         ▼
             │              "continue"                  "stop" / "compact"
             │                    │                         │
             └────────────────────┘                         ▼
                                                     ┌──────────┐
                                                     │  idle    │ 循环结束
                                                     └──────────┘
```

### 1.2.3 终止条件

循环在以下情况终止：
1. 最新的 Assistant 消息 `finish` 不为 `"tool-calls"` 且没有待处理的工具调用
2. `processor.process()` 返回 `"stop"`（被权限拒绝、发生错误、或模型正常结束）
3. 达到 Agent 配置的最大步数限制（`maxSteps`）
4. 生成结构化输出（JSON Schema 模式）
5. 内容过滤（content-filter）错误

---

## 1.3 LLM 调用层

### 1.3.1 LLM 服务入口

`packages/opencode/src/session/llm.ts` — `LLM.Service.stream()`

```
LLM.StreamInput {
  user, sessionID, model, agent, system[], messages[], tools{}, retries?, toolChoice?
}
        ↓
LLM.run() {
  1. 获取语言模型（provider.getLanguage）
  2. 获取配置、Provider 信息、认证信息
  3. 请求预处理（LLMRequestPrep.prepare）：构建 system prompt、注入 chat.headers/params 钩子
  4. 运行时选择门：
     ├─ experimentalNativeLlm=true & 支持 → LLMNativeRuntime.stream()
     └─ 默认 → AI SDK streamText()
  5. 返回统一的 LLMEvent Stream
}
```

### 1.3.2 双运行时架构

```
                         LLM.Service (../llm.ts)
                               │
                  native gate  ├─ yes → native-runtime.ts
                               │           │
                               │           └─ native-request.ts → LLMClient → LLMEvent Stream
                               │
                               └─ no  → AI SDK (streamText)
                                           │
                                           └─ ai-sdk.ts → fullStream → LLMEvent Stream
```

两种运行时最终都产生统一的 `LLMEvent` 流，下游处理器不关心用哪个运行时。

**AI SDK 路径**（默认）：
- 使用 `streamText()` 从 `ai` 包
- 通过 `wrapLanguageModel` 中间件进行 Provider 特定的消息转换
- `ai-sdk.ts` 将 `fullStream` 事件转换为 `LLMEvent`

**Native Runtime 路径**（可选）：
- 环境变量 `OPENCODE_EXPERIMENTAL_NATIVE_LLM=true` 启用
- 使用 `@opencode-ai/llm` 包的原生 LLM Client
- 目前支持 OpenAI、Anthropic 等

### 1.3.3 Provider 模型解析

`packages/opencode/src/provider/provider.ts`：
- 根据 `providerID/modelID` 查找模型配置
- 处理定价、API Key、能力检测
- `ProviderTransform` 提供 schema 和 provider options 的转换

---

## 1.4 Tool-Use 机制

### 1.4.1 工具定义接口

`packages/opencode/src/tool/tool.ts`：

```ts
interface Def<Parameters, Metadata> {
  id: string              // 工具唯一ID（如 "bash", "read", "task"）
  description: string     // LLM 可读的描述
  parameters: Schema      // Effect Schema 参数定义
  jsonSchema?: JSONSchema7 // LLM function calling 用的 JSON Schema
  execute(args, ctx): Effect<ExecuteResult>  // 执行函数
}

interface Context {
  sessionID: SessionID
  messageID: MessageID
  agent: string
  abort: AbortSignal
  callID?: string
  messages: SessionV1.WithParts[]
  metadata(input): Effect<void>  // 更新工具状态元数据
  ask(input): Effect<void>       // 权限请求
}
```

### 1.4.2 工具注册表

`packages/opencode/src/tool/registry.ts`：

三层来源：
1. **内置工具**（hardcoded）：bash(shell)、read、write、edit、glob、grep、task、webfetch、websearch、todo、skill、question、lsp、plan、apply_patch、invalid
2. **磁盘工具**：扫描配置目录下的 `{tool,tools}/*.{js,ts}` 文件
3. **插件工具**：通过 `plugin.tool` 钩子注册

工具过滤逻辑：
- `websearch`：仅 opencode provider 或特定 flag 启用
- `apply_patch` vs `edit`+`write`：GPT 模型用 patch，其他用 edit/write
- `question`：仅 TUI/CLI/Desktop 客户端
- `lsp`：`experimentalLspTool` flag
- `plan`：`experimentalPlanMode` flag

### 1.4.3 工具解析与执行流程

`packages/opencode/src/session/tools.ts` — `SessionTools.resolve()`

```ts
for (const item of registry.tools({ modelID, providerID, agent })) {
  tools[item.id] = tool({
    description: item.description,
    inputSchema: jsonSchema(transformed),
    execute(args, options) {
      return run.promise(Effect.gen(function* () {
        // 1. 触发 tool.execute.before 钩子
        yield* plugin.trigger("tool.execute.before", { tool, sessionID, callID }, { args })

        // 2. 执行工具
        const result = yield* item.execute(args, ctx)

        // 3. 触发 tool.execute.after 钩子
        yield* plugin.trigger("tool.execute.after", { tool, sessionID, callID, args }, output)

        return output
      }))
    },
  })
}
```

工具执行上下文（`ctx`）提供：
- `metadata()` — 更新工具运行状态（如 title）
- `ask()` — 触发权限询问（检查 `tool.execute.before` 和 agent/session 权限规则）
- `abort` — 取消信号
- `messages` — 当前会话历史

### 1.4.4 子代理 Task 工具

`packages/opencode/src/tool/task.ts`：
- `task` 工具创建一个子 session，调用另一个 agent（如 `explore`）执行任务
- 支持 `background: true` 异步模式
- 支持 `task_id` 恢复之前的子任务
- `command` 参数用于 slash command 触发

执行流程：
1. 创建子 Session
2. 调用子 Agent 的 `general` 模式（非 primary）
3. 应用子代理权限规则
4. 等待完成或后台运行

### 1.4.5 Processor 事件处理

`packages/opencode/src/session/processor.ts` — `SessionProcessor.process()`

处理 LLM 事件流中的各种事件类型：

| 事件类型 | 处理逻辑 |
|---------|---------|
| `reasoning-start/delta/end` | 管理推理过程文本（如 Claude 的 thinking） |
| `text-start/delta/end` | 普通文本流，写入 TextPart |
| `tool-input-start/delta/end` | 工具调用参数接收（流式） |
| `tool-call` | 工具调用完成，触发执行 |
| `tool-result` | 工具执行结果 |
| `tool-error` | 工具执行错误 |
| `provider-error` | Provider 级别错误 |
| `step-start/finish` | 步骤边界，结算 token 和 cost |
| `start/finish` | 流开始/结束 |

**死循环检测（Doom Loop Detection）**：
当连续 3 次对同一工具用相同参数调用时，触发权限询问。

**重试机制**：
使用 `SessionRetry.policy()` 进行指数退避重试，处理可恢复的 Provider 错误。

---

## 1.5 Skill 注入机制

### 1.5.1 Skill 发现与加载

`packages/opencode/src/skill/index.ts`：

**Skill 来源（按优先级）**：
1. **内置 skill**：`customize-opencode`（配置 opencode 自身的 skill）
2. **全局 skills**：`~/.claude/skills/**/SKILL.md` 和 `~/.agents/skills/**/SKILL.md`
3. **项目 skills**：从工作目录向上查找 `.claude/skills/` 和 `.agents/skills/`
4. **配置目录 skills**：`.opencode/{skill,skills}/**/SKILL.md`
5. **配置路径 skills**：`config.skills.paths` 指定的路径
6. **远程 skills**：`config.skills.urls` 指定的 URL（通过 `Discovery.pull()` 下载）

**Skill 文件格式**（SKILL.md）：
```yaml
---
name: skill-name
description: Skill 描述（用于触发匹配）
---
# 具体指令内容...
```

### 1.5.2 Skill 注入到 System Prompt

`packages/opencode/src/session/system.ts` — `SystemPrompt.skills()`：

1. 检查 agent 是否有 `skill` 权限被禁用
2. 调用 `skill.available(agent)` 获取可用 skill 列表（按权限过滤）
3. 格式化为 XML 格式注入 system prompt：

```xml
<available_skills>
  <skill>
    <name>skill-name</name>
    <description>skill description</description>
    <location>file:///path/to/SKILL.md</location>
  </skill>
</available_skills>
```

### 1.5.3 Skill Tool 运行时加载

`packages/opencode/src/tool/skill.ts`：

当模型调用 `skill` 工具时：
1. 根据 name 查找并验证 skill 存在
2. 要求权限确认
3. 读取 SKILL.md 内容
4. 列出 skill 目录下的相关文件（通过 ripgrep）
5. 返回完整的 skill 内容给模型

```
模型调用 skill(name="effect")
        ↓
skill tool execute()
        ↓
读取 SKILL.md + 列出目录文件
        ↓
返回 <skill_content name="effect">...</skill_content>
```

### 1.5.4 System Prompt 完整构成

`SystemPrompt` 由以下部分组成（按顺序）：

```
1. 模型能力描述："You are powered by the model named claude-sonnet-4-20250514..."
2. 环境信息：<env> working directory, git status, platform, date </env>
3. 项目引用：<available_references> ... </available_references>
4. Agent 指令：来自 agent 配置的 prompt 文本
5. Skill 列表：<available_skills> ... </available_skills>
6. 自定义指令：来自 .opencode/instructions.md 等
```

Provider 特定的 system prompt 模板位于 `packages/opencode/src/session/prompt/`：
- `anthropic.txt`、`gpt.txt`、`gemini.txt`、`codex.txt` 等 — 针对不同提供商的提示优化

---

## 1.6 Agent 类型

`packages/opencode/src/agent/agent.ts`：

| Agent | 用途 | 模式 |
|-------|------|------|
| `general` | 默认通用 agent | primary |
| `build` | 代码构建 agent | primary |
| `plan` | 规划模式 agent | primary |
| `explore` | 代码探索子代理 | subagent |
| `compaction` | 上下文压缩 | subagent |
| `title` | 自动生成会话标题 | subagent |
| `summary` | 对话摘要 | subagent |

Agent 配置包含：
- `model`：使用的模型
- `mode`：`primary`（用户直接交互）/ `subagent`（工具调用）/ `all`
- `steps`：最大步数
- `permission`：权限规则
- `hidden`：是否隐藏
- `prompt`：自定义 prompt 模板

---

## 1.7 Processor 内部状态管理

`packages/opencode/src/session/processor.ts` 中的 `ProcessorContext`：

```ts
interface ProcessorContext {
  assistantMessage: SessionV1.Assistant  // 当前 assistant 消息
  toolcalls: Record<string, ToolCall>    // 活跃的工具调用
  shouldBreak: boolean                   // 权限拒绝时是否停止
  snapshot: string                       // 文件快照（用于 patch）
  blocked: boolean                       // 是否被权限阻塞
  needsCompaction: boolean               // 是否需要压缩
  currentText: TextPart                  // 当前流式文本
  reasoningMap: Record<string, ReasoningPart>  // 活动推理
}
```

`Handle.process()` 返回三种结果：
- `"continue"` — 继续 ReAct 循环
- `"stop"` — 停止（权限拒绝、错误）
- `"compact"` — 触发上下文压缩
