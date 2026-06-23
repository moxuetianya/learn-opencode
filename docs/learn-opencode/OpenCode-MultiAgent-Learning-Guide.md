# OpenCode Multi-Agent 核心代码学习指南

> 基于 https://github.com/anomalyco/opencode.git 源码分析
> 重点关注：多 Agent 调用、提示词构造、记忆模块

---

## 目录

1. [第一课：Agent 系统架构](#第一课agent-系统架构)
2. [第二课：Skill 技能系统](#第二课skill-技能系统)
3. [第三课：Session 与会话记忆](#第三课session-与会话记忆)
4. [第四课：Prompt 构造与系统提示词](#第四课prompt-构造与系统提示词)
5. [第五课：Multi-Agent 协作机制](#第五课multi-agent-协作机制)

---

## 第一课：Agent 系统架构

### 1.1 Agent 定义与类型

在 `packages/opencode/src/agent/agent.ts` 中，Agent 被定义为具有不同模式的实体：

```typescript
// Agent 信息结构
export const Info = z.object({
  name: z.string(),
  description: z.string().optional(),
  mode: z.enum(["subagent", "primary", "all"]),  // 三种模式
  native: z.boolean().optional(),    // 是否是内置 Agent
  hidden: z.boolean().optional(),    // 是否隐藏
  topP: z.number().optional(),
  temperature: z.number().optional(),
  color: z.string().optional(),
  permission: Permission.Ruleset,    // 权限规则
  model: z.object({                  // 可选的模型配置
    modelID: ModelID.zod,
    providerID: ProviderID.zod,
  }).optional(),
  prompt: z.string().optional(),     // 系统提示词
  options: z.record(z.string(), z.any()),
  steps: z.number().int().positive().optional(),  // 最大步骤数
})
```

### 1.2 Agent 的三种模式

| 模式 | 说明 | 示例 |
|------|------|------|
| `primary` | 主 Agent，用户直接交互 | `build`, `plan` |
| `subagent` | 子 Agent，被其他 Agent 调用 | `explore`, `general` |
| `all` | 既可主用也可被调用 | 自定义 Agent |

### 1.3 内置 Agent 概览

```typescript
// 核心内置 Agents
const agents: Record<string, Info> = {
  // 主构建 Agent - 默认执行工具
  build: {
    name: "build",
    description: "The default agent. Executes tools based on configured permissions.",
    mode: "primary",
    native: true,
  },
  
  // 规划 Agent - 只读模式
  plan: {
    name: "plan",
    description: "Plan mode. Disallows all edit tools.",
    mode: "primary",
    native: true,
    permission: { /* 禁用 edit 工具 */ }
  },
  
  // 通用子 Agent - 并行任务执行
  general: {
    name: "general",
    description: "General-purpose agent for researching complex questions...",
    mode: "subagent",
    native: true,
  },
  
  // 探索子 Agent - 代码库搜索
  explore: {
    name: "explore",
    description: "Fast agent specialized for exploring codebases...",
    mode: "subagent",
    native: true,
    permission: { /* 只允许搜索类工具 */ }
  },
  
  // 压缩 Agent - 会话压缩
  compaction: {
    name: "compaction",
    mode: "primary",
    hidden: true,  // 隐藏，自动调用
    native: true,
  },
  
  // 标题生成 Agent
  title: {
    name: "title",
    mode: "primary",
    hidden: true,
    temperature: 0.5,
    native: true,
  },
  
  // 摘要 Agent
  summary: {
    name: "summary",
    mode: "primary",
    hidden: true,
    native: true,
  },
}
```

### 1.4 Agent 权限系统

Agent 使用细粒度的权限控制：

```typescript
// 权限规则结构
permission: Permission.Ruleset

// 默认权限配置示例
const defaults = Permission.fromConfig({
  "*": "allow",                    // 默认允许所有
  "doom_loop": "ask",              // doom_loop 需要询问
  "external_directory": {
    "*": "ask",                    // 外部目录默认询问
    "/path/to/safe/*": "allow",    // 特定路径允许
  },
  "question": "deny",              // 禁止 question 工具
  "read": {
    "*": "allow",                  // 默认允许读取
    "*.env": "ask",                // 环境文件询问
    "*.env.*": "ask",
  },
})
```

权限动作有三种：`"allow"`（允许）、`"deny"`（禁止）、`"ask"`（询问用户）。

### 1.5 Agent 生成器

OpenCode 支持动态生成 Agent：

```typescript
export async function generate(input: { 
  description: string
  model?: { providerID: ProviderID; modelID: ModelID }
}) {
  // 使用 LLM 根据描述生成 Agent 配置
  const result = await generateObject({
    model: language,
    schema: z.object({
      identifier: z.string(),      // Agent 标识符
      whenToUse: z.string(),       // 使用场景描述
      systemPrompt: z.string(),    // 系统提示词
    }),
    messages: [
      { role: "system", content: PROMPT_GENERATE },
      { role: "user", content: `Create an agent configuration...` },
    ],
  })
  return result.object
}
```

---

## 第二课：Skill 技能系统

### 2.1 Skill 概念

Skill 是 OpenCode 的模块化指令系统，允许为特定任务封装：
- 详细的工作流程说明
- 领域特定的指导
-  bundled 资源（脚本、模板、参考资料）

### 2.2 Skill 数据结构

```typescript
export const Info = z.object({
  name: z.string(),           // Skill 名称
  description: z.string(),    // 描述
  location: z.string(),       // 文件路径
  content: z.string(),        // SKILL.md 内容
})
```

### 2.3 Skill 发现机制

Skill 从多个来源自动发现：

```typescript
const EXTERNAL_DIRS = [".claude", ".agents"]
const EXTERNAL_SKILL_PATTERN = "skills/**/SKILL.md"
const OPENCODE_SKILL_PATTERN = "{skill,skills}/**/SKILL.md"

// 扫描路径（按优先级）：
// 1. ~/.claude/skills/ 和 ~/.agents/skills/ (全局)
// 2. 项目目录向上查找的 .claude/.agents (项目级)
// 3. 配置中指定的目录
// 4. 远程 URL 拉取的 Skill
```

### 2.4 Skill 文件格式 (SKILL.md)

```markdown
---
name: skill-name
description: 简短描述
---

# Skill 内容

详细的工作流程、指导说明...

## 检查清单

- [ ] 步骤 1
- [ ] 步骤 2
```

### 2.5 Skill 工具

通过 `skill` 工具加载并使用：

```typescript
export const SkillTool = Tool.define("skill", async (ctx) => {
  const list = await Skill.available(ctx?.agent)
  
  return {
    description: "Load a specialized skill...",
    parameters: z.object({
      name: z.string().describe("The name of the skill from available_skills"),
    }),
    async execute(params, ctx) {
      const skill = await Skill.get(params.name)
      if (!skill) throw new Error(`Skill not found`)
      
      // 检查权限
      await ctx.ask({ permission: "skill", patterns: [params.name] })
      
      return {
        title: `Loaded skill: ${skill.name}`,
        output: `<skill_content name="${skill.name}">...`,
        metadata: { name: skill.name, dir: path.dirname(skill.location) },
      }
    },
  }
})
```

### 2.6 Skill 过滤

Agent 可以限制可用的 Skill：

```typescript
const available = async (agent?: Agent.Info) => {
  const list = await Skill.all()
  if (!agent) return list
  // 根据 Agent 权限过滤
  return list.filter(skill => 
    Permission.evaluate("skill", skill.name, agent.permission).action !== "deny"
  )
}
```

---

## 第三课：Session 与会话记忆

### 3.1 Session 结构

Session 是 OpenCode 的会话容器，存储对话历史和元数据：

```typescript
export const Info = z.object({
  id: SessionID.zod,
  slug: z.string(),           // URL 友好的短标识
  projectID: ProjectID.zod,
  workspaceID: WorkspaceID.zod.optional(),
  directory: z.string(),      // 工作目录
  parentID: SessionID.zod.optional(),  // 父会话（用于子 Agent）
  title: z.string(),
  version: z.string(),        // OpenCode 版本
  summary: z.object({         // 变更摘要
    additions: z.number(),
    deletions: z.number(),
    files: z.number(),
    diffs: Snapshot.FileDiff.array().optional(),
  }).optional(),
  time: z.object({
    created: z.number(),
    updated: z.number(),
    compacting: z.number().optional(),
    archived: z.number().optional(),
  }),
  permission: Permission.Ruleset.optional(),
  revert: z.object({          // 回退点
    messageID: MessageID.zod,
    partID: PartID.zod.optional(),
    snapshot: z.string().optional(),
    diff: z.string().optional(),
  }).optional(),
})
```

### 3.2 Message 结构 (V2)

OpenCode 使用分层的消息结构：

```typescript
// 消息基本信息
export const Info = z.object({
  id: z.string(),
  sessionID: z.string(),
  role: z.enum(["user", "assistant"]),
  time: z.object({ created: z.number() }),
})

// 消息部分 (Part) 类型
export type Part = 
  | TextPart      // 文本内容
  | ToolPart      // 工具调用
  | FilePart      // 文件附件
  | SnapshotPart  // 代码快照
  | PatchPart     // 代码补丁
  | SubtaskPart   // 子任务
  | CompactionPart // 压缩标记
  | ReasoningPart  // 推理内容

// Assistant 消息详情
export const Assistant = Base.extend({
  role: z.literal("assistant"),
  parentID: z.string(),        // 回复的用户消息 ID
  agent: z.string(),           // 使用的 Agent
  variant: z.string().optional(),
  modelID: ModelID.zod,
  providerID: ProviderID.zod,
  mode: z.enum(["plan", "compaction", "normal"]).optional(),
  summary: z.boolean().optional(),  // 是否是摘要消息
  cost: z.number(),
  tokens: z.object({
    input: z.number(),
    output: z.number(),
    reasoning: z.number(),
    cache: { read: z.number(), write: z.number() },
  }),
  error: z.object({...}).optional(),
  finish: z.enum(["stop", "error", "interrupted", "overflow"]).optional(),
})

// User 消息详情
export const User = Base.extend({
  role: z.literal("user"),
  agent: z.string(),           // 指定的 Agent
  model: z.object({ providerID: ProviderID, modelID: ModelID }),
  tools: z.string().array(),   // 可用工具
  system: z.string().array(),  // 系统提示词片段
  variant: z.string().optional(),
  format: OutputFormat.optional(),  // 输出格式要求
})
```

### 3.3 会话压缩 (Compaction)

当会话过长时，自动压缩历史：

```typescript
export namespace SessionCompaction {
  const PRUNE_MINIMUM = 20_000   // 最小修剪 token 数
  const PRUNE_PROTECT = 40_000   // 保护最近 token 数

  // 修剪工具输出
  const prune = Effect.fn("SessionCompaction.prune")(function* (input) {
    // 从后往前遍历，保留最近 PRUNE_PROTECT tokens
    // 标记旧工具输出为已压缩
    for (const part of toPrune) {
      part.state.time.compacted = Date.now()
      yield* session.updatePart(part)
    }
  })

  // 生成压缩摘要
  const processCompaction = Effect.fn("SessionCompaction.process")(function* (input) {
    const agent = yield* agents.get("compaction")
    const result = yield* processor.process({
      agent,
      messages: compactedMessages,
      system: [],
      tools: {},  // 无工具，纯文本生成
    })
    // 生成包含目标、指令、发现、已完成工作、相关文件的摘要
  })
}
```

### 3.4 上下文溢出处理

```typescript
export const ContextOverflowError = NamedError.create(
  "ContextOverflowError",
  z.object({ message: z.string(), responseBody: z.string().optional() })
)

// 溢出检测
function isOverflow({ cfg, tokens, model }) {
  const limit = model.contextWindow
  const threshold = cfg.compaction?.threshold ?? 0.8
  return tokens.input + tokens.output > limit * threshold
}
```

### 3.5 会话 Fork

支持创建会话分支：

```typescript
const fork = Effect.fn("Session.fork")(function* (input) {
  const original = yield* get(input.sessionID)
  const title = getForkedTitle(original.title)  // "Title (fork #1)"
  const session = yield* createNext({ title })
  
  // 复制指定消息之前的所有消息
  const msgs = yield* messages({ sessionID: input.sessionID })
  for (const msg of msgs) {
    if (input.messageID && msg.info.id >= input.messageID) break
    // 克隆消息到新会话
    yield* cloneMessage(msg, session.id)
  }
  return session
})
```

---

## 第四课：Prompt 构造与系统提示词

### 4.1 系统提示词架构

OpenCode 使用分层系统提示词：

```typescript
// 1. 提供商特定提示词
function provider(model: Provider.Model) {
  if (model.api.id.includes("claude")) return [PROMPT_ANTHROPIC]
  if (model.api.id.includes("gpt")) return [PROMPT_GPT]
  if (model.api.id.includes("gemini")) return [PROMPT_GEMINI]
  return [PROMPT_DEFAULT]
}

// 2. 环境信息
async function environment(model: Provider.Model) {
  return [
    `You are powered by the model named ${model.api.id}`,
    `<env>`,
    `  Working directory: ${Instance.directory}`,
    `  Workspace root folder: ${Instance.worktree}`,
    `  Platform: ${process.platform}`,
    `  Today's date: ${new Date().toDateString()}`,
    `</env>`,
  ]
}

// 3. Skill 信息
async function skills(agent: Agent.Info) {
  const list = await Skill.available(agent)
  return [
    "Skills provide specialized instructions...",
    Skill.fmt(list, { verbose: true }),
  ]
}
```

### 4.2 提示词模板文件

位于 `packages/opencode/src/session/prompt/`：

| 文件 | 用途 |
|------|------|
| `anthropic.txt` | Claude 模型特定提示词 |
| `gpt.txt` | GPT 模型特定提示词 |
| `gemini.txt` | Gemini 模型特定提示词 |
| `default.txt` | 默认提示词 |
| `plan.txt` | Plan 模式额外提示词 |
| `build-switch.txt` | 从 Plan 切换到 Build 时的提示词 |

### 4.3 Agent 特定提示词

每个 Agent 可以有自己的系统提示词：

```typescript
const agents: Record<string, Info> = {
  explore: {
    name: "explore",
    prompt: PROMPT_EXPLORE,  // 来自 explore.txt
    // ...
  },
  compaction: {
    name: "compaction",
    prompt: PROMPT_COMPACTION,  // 压缩专用提示词
    // ...
  },
}
```

### 4.4 Prompt 变量解析

支持在 Prompt 中引用文件和 Agent：

```typescript
const resolvePromptParts = Effect.fn("SessionPrompt.resolvePromptParts")(function* (template: string) {
  const parts: PromptInput["parts"] = [{ type: "text", text: template }]
  
  // 提取 @file 引用
  const files = ConfigMarkdown.files(template)
  for (const match of files) {
    const name = match[1]
    // 检查是否是 Agent 名称
    const found = yield* agents.get(name)
    if (found) {
      parts.push({ type: "agent", name: found.name })
    } else {
      // 否则作为文件处理
      parts.push({
        type: "file",
        url: pathToFileURL(filepath).href,
        filename: name,
        mime: stat.type === "Directory" ? "application/x-directory" : "text/plain",
      })
    }
  }
  return parts
})
```

### 4.5 动态提示词注入

Plan 模式下的工作流提示词：

```typescript
const insertReminders = Effect.fn("SessionPrompt.insertReminders")(function* (input) {
  // Plan 模式激活时注入
  if (input.agent.name === "plan") {
    userMessage.parts.push({
      type: "text",
      text: PROMPT_PLAN,  // 包含 5 阶段工作流
      synthetic: true,     // 标记为系统生成
    })
  }
  
  // 从 Plan 切换到 Build 时注入
  if (wasPlan && input.agent.name === "build") {
    userMessage.parts.push({
      type: "text",
      text: BUILD_SWITCH,
      synthetic: true,
    })
  }
})
```

### 4.6 Plan 模式 5 阶段工作流

```
Phase 1: Initial Understanding
- 使用 explore Agent 并行探索代码库（最多3个）
- 理解用户需求和相关代码

Phase 2: Design
- 启动 general Agent 设计实现方案
- 考虑不同方案的权衡

Phase 3: Review
- 审查 Agent 返回的计划
- 确保符合用户意图

Phase 4: Final Plan
- 将最终计划写入 plan 文件
- 包含关键文件路径和验证步骤

Phase 5: Call plan_exit tool
- 调用 plan_exit 工具请求用户批准
```

---

## 第五课：Multi-Agent 协作机制

### 5.1 Task 工具（Agent 调用核心）

Task 工具是实现 Multi-Agent 协作的核心机制：

```typescript
export const TaskTool = Tool.define("task", async (ctx) => {
  const parameters = z.object({
    description: z.string().describe("A short (3-5 words) description"),
    prompt: z.string().describe("The task for the agent to perform"),
    subagent_type: z.string().describe("The type of specialized agent"),
    task_id: z.string().optional(),  // 用于恢复任务
    command: z.string().optional(),
  })

  return {
    description: DESCRIPTION,
    parameters,
    async execute(params, ctx) {
      // 1. 获取 Agent 配置
      const agent = await Agent.get(params.subagent_type)
      
      // 2. 创建子会话
      const session = await Session.create({
        parentID: ctx.sessionID,  // 关联父会话
        title: params.description + ` (@${agent.name} subagent)`,
        permission: [
          // 子 Agent 默认禁用 task 和 todowrite
          { permission: "task", pattern: "*", action: "deny" },
          { permission: "todowrite", pattern: "*", action: "deny" },
        ],
      })
      
      // 3. 启动子 Agent 会话
      const result = await SessionPrompt.prompt({
        sessionID: session.id,
        agent: agent.name,
        model: agent.model ?? parentModel,
        tools: {
          task: hasTaskPermission,      // 根据权限控制
          todowrite: hasTodoWritePermission,
        },
        parts: promptParts,
      })
      
      return {
        output: `task_id: ${session.id}\n<task_result>${text}</task_result>`,
        metadata: { sessionId: session.id, model },
      }
    },
  }
})
```

### 5.2 父子会话关系

```
父会话 (build Agent)
    ├── 子会话 1 (explore Agent) - task_id: session-001
    ├── 子会话 2 (explore Agent) - task_id: session-002
    └── 子会话 3 (general Agent) - task_id: session-003
```

通过 `parentID` 建立层级关系，子会话可以访问父会话的上下文。

### 5.3 并行 Agent 调用

在 Plan 模式下，可以同时启动多个 Agent：

```typescript
// 单次用户消息中并行调用多个 explore Agent
[
  { 
    tool: "task",
    params: { 
      subagent_type: "explore",
      description: "Explore API endpoints",
      prompt: "Search for all API endpoint definitions..."
    }
  },
  { 
    tool: "task",
    params: { 
      subagent_type: "explore",
      description: "Explore data models",
      prompt: "Find all data model definitions..."
    }
  },
  { 
    tool: "task",
    params: { 
      subagent_type: "explore",
      description: "Explore tests",
      prompt: "Find relevant test files..."
    }
  },
]
```

### 5.4 Agent 发现与过滤

Task 工具动态发现可用的子 Agent：

```typescript
const agents = await Agent.list().then(x => 
  x.filter(a => a.mode !== "primary")  // 只显示非主 Agent
)

// 根据调用者权限过滤
const accessibleAgents = caller
  ? agents.filter(a => 
      Permission.evaluate("task", a.name, caller.permission).action !== "deny"
    )
  : agents
```

### 5.5 Agent 递归限制

通过权限控制防止无限递归：

```typescript
// 子 Agent 默认禁用 task 工具
const session = await Session.create({
  permission: [
    { permission: "task", pattern: "*", action: "deny" },
  ],
})

// 但可通过配置允许特定 Agent 调用 task
if (hasTaskPermission) {
  // 在 SessionPrompt.prompt 中启用 task 工具
  tools: { task: true }
}
```

### 5.6 Agent 间通信

通过返回结果传递信息：

```typescript
// 子 Agent 返回结果
return {
  output: [
    `task_id: ${session.id} (for resuming)`,
    "",
    "<task_result>",
    text,  // 执行结果
    "</task_result>",
  ].join("\n"),
}

// 父 Agent 可以通过 task_id 恢复子 Agent 会话
const resumed = await Session.get(SessionID.make(params.task_id))
```

### 5.7 工作流最佳实践

根据 Plan 模式提示词，Multi-Agent 工作流最佳实践：

1. **探索阶段**：使用 1-3 个 explore Agent 并行探索
   - 1 个 Agent：任务孤立、已知文件路径、小改动
   - 多个 Agent：范围不确定、涉及多区域、需要理解现有模式

2. **设计阶段**：使用 1 个 general Agent
   - 提供探索阶段的完整背景
   - 描述需求和约束
   - 请求详细实现计划

3. **审查阶段**：主 Agent 审查结果
   - 读取关键文件深入理解
   - 确保计划符合用户意图

4. **执行阶段**：切换到 build Agent
   - 按照计划执行
   - 必要时再次调用子 Agent

---

## 附录：核心文件速查

### Agent 相关
- `packages/opencode/src/agent/agent.ts` - Agent 定义与管理
- `packages/opencode/src/agent/prompt/*.txt` - Agent 系统提示词

### Skill 相关
- `packages/opencode/src/skill/index.ts` - Skill 系统
- `packages/opencode/src/skill/discovery.ts` - Skill 发现
- `packages/opencode/src/tool/skill.ts` - Skill 工具

### Session/记忆相关
- `packages/opencode/src/session/index.ts` - Session 管理
- `packages/opencode/src/session/message-v2.ts` - 消息结构
- `packages/opencode/src/session/prompt.ts` - Prompt 处理
- `packages/opencode/src/session/compaction.ts` - 会话压缩
- `packages/opencode/src/session/system.ts` - 系统提示词

### Tool 相关
- `packages/opencode/src/tool/tool.ts` - 工具基础定义
- `packages/opencode/src/tool/task.ts` - Task 工具（Multi-Agent 核心）
- `packages/opencode/src/tool/registry.ts` - 工具注册表

### Prompt 相关
- `packages/opencode/src/session/prompt/*.txt` - 各类系统提示词模板

---

## 学习路径建议

1. **第 1-2 天**：理解 Agent 架构，阅读 `agent.ts` 和内置 Agent 定义
2. **第 3-4 天**：掌握 Skill 系统，尝试创建自定义 Skill
3. **第 5-6 天**：深入 Session 和记忆机制，理解消息结构和压缩
4. **第 7-8 天**：学习 Prompt 构造，阅读各提供商提示词模板
5. **第 9-10 天**：实践 Multi-Agent 协作，理解 Task 工具工作原理

---

*文档生成时间：2026-04-04*
*基于 OpenCode Commit: 最新 dev 分支*
