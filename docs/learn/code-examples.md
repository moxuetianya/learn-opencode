# OpenCode 核心概念代码示例

本文件提供 OpenCode Multi-Agent 系统的核心概念代码示例，帮助理解实际实现。

---

## 1. Agent 定义示例

### 1.1 基础 Agent 配置

```typescript
// packages/opencode/src/agent/agent.ts

// 定义一个自定义 Agent
const myCustomAgent: Agent.Info = {
  name: "code-reviewer",
  description: "Specialized agent for reviewing code changes",
  mode: "subagent",  // 作为子 Agent 被调用
  native: false,     // 用户自定义
  temperature: 0.3,  // 较低温度，更确定性
  permission: Permission.merge(
    defaults,
    Permission.fromConfig({
      "read": { "*": "allow" },           // 允许读取所有文件
      "edit": { "*": "deny" },            // 禁止编辑
      "bash": { "test/*": "allow" },      // 允许运行测试
      "task": "deny",                     // 禁止再调用其他 Agent
    })
  ),
  options: {},
}
```

### 1.2 Agent 权限评估

```typescript
// 检查 Agent 是否有权限使用某个工具
const canUseTool = Permission.evaluate(
  "read",                          // 工具名
  "src/main.ts",                   // 操作对象
  agent.permission                 // Agent 的权限规则
)

if (canUseTool.action === "deny") {
  throw new Error("Agent not allowed to read this file")
}
```

---

## 2. Skill 创建示例

### 2.1 创建自定义 Skill

创建文件 `~/.claude/skills/my-skill/SKILL.md`：

```markdown
---
name: typescript-refactor
description: Guidelines for refactoring TypeScript code with best practices
---

# TypeScript 重构 Skill

## 使用场景

当需要对 TypeScript 代码进行重构时使用此 skill。

## 重构原则

1. **类型安全优先**
   - 避免使用 `any` 类型
   - 使用严格模式
   
2. **函数式编程**
   - 优先使用 `const` 而非 `let`
   - 使用纯函数

## 检查清单

- [ ] 所有函数都有返回类型注解
- [ ] 没有 `any` 类型
- [ ] 通过 TypeScript 编译检查
- [ ] 运行测试确保功能正确
```

### 2.2 Skill 加载代码

```typescript
// 在 Agent 中使用 Skill
const skillTool = {
  tool: "skill",
  params: {
    name: "typescript-refactor"
  }
}

// Skill 内容将被注入到对话上下文中
// 输出示例：
// <skill_content name="typescript-refactor">
// # TypeScript 重构 Skill
// ...
// </skill_content>
```

---

## 3. Session 操作示例

### 3.1 创建会话

```typescript
// 创建父会话
const parentSession = await Session.create({
  title: "My Project Task",
  directory: "/path/to/project",
})

// 创建子会话（用于子 Agent）
const childSession = await Session.create({
  parentID: parentSession.id,  // 关联父会话
  title: "Explore codebase (@explore subagent)",
  permission: [
    { permission: "task", pattern: "*", action: "deny" },  // 禁止递归
  ],
})
```

### 3.2 添加消息

```typescript
// 添加用户消息
const userMessage = await Session.updateMessage({
  id: MessageID.ascending(),
  sessionID: session.id,
  role: "user",
  time: { created: Date.now() },
  agent: "build",
  model: { providerID: "anthropic", modelID: "claude-4-5-sonnet" },
  tools: ["read", "edit", "bash"],
  system: [],
})

// 添加文本部分
await Session.updatePart({
  id: PartID.ascending(),
  messageID: userMessage.id,
  sessionID: session.id,
  type: "text",
  text: "请帮我重构这个函数",
})

// 添加文件附件
await Session.updatePart({
  id: PartID.ascending(),
  messageID: userMessage.id,
  sessionID: session.id,
  type: "file",
  url: "file:///path/to/file.ts",
  filename: "file.ts",
  mime: "text/plain",
})
```

### 3.3 消息历史获取

```typescript
// 获取完整对话历史
const messages = await Session.messages({ sessionID })

// 输出结构示例：
[
  {
    info: { id: "msg-1", role: "user", ... },
    parts: [
      { type: "text", text: "请帮我..." },
      { type: "file", filename: "example.ts", ... }
    ]
  },
  {
    info: { id: "msg-2", role: "assistant", agent: "build", ... },
    parts: [
      { type: "text", text: "我来帮您..." },
      { type: "tool", tool: "read", state: { status: "completed", output: "..." } }
    ]
  }
]
```

---

## 4. Prompt 构造示例

### 4.1 构建完整 Prompt

```typescript
async function buildPrompt(agent: Agent.Info, session: Session.Info) {
  const parts: string[] = []
  
  // 1. 提供商特定提示词
  parts.push(...SystemPrompt.provider(model))
  
  // 2. Agent 特定提示词
  if (agent.prompt) {
    parts.push(agent.prompt)
  }
  
  // 3. 环境信息
  parts.push(...await SystemPrompt.environment(model))
  
  // 4. Skill 信息
  parts.push(...await SystemPrompt.skills(agent))
  
  // 5. 工具说明
  parts.push(...await ToolRegistry.describe(agent))
  
  return parts.join("\n\n")
}
```

### 4.2 工具描述格式

```typescript
// 工具描述示例
const toolDescription = `
## Bash

Execute a bash command in the working directory.

Parameters:
- command: string - The bash command to execute
- timeout?: number - Optional timeout in milliseconds

Usage:
<bash>
  <command>ls -la</command>
</bash>
`
```

---

## 5. Multi-Agent 协作示例

### 5.1 并行探索代码库

```typescript
// 主 Agent (build) 同时启动多个 explore Agent
const exploreTasks = [
  {
    description: "Find API endpoints",
    prompt: `Search for all API endpoint definitions in the codebase.
Focus on:
1. Route definitions
2. Handler functions
3. Middleware usage`,
  },
  {
    description: "Find data models",
    prompt: `Find all data model definitions.
Look for:
1. Database schemas
2. TypeScript interfaces
3. Validation schemas`,
  },
  {
    description: "Find auth logic",
    prompt: `Find authentication and authorization logic.
Search for:
1. Auth middleware
2. Permission checks
3. User models`,
  },
]

// 并行执行
const results = await Promise.all(
  exploreTasks.map(task => 
    TaskTool.execute({
      description: task.description,
      prompt: task.prompt,
      subagent_type: "explore",
    }, context)
  )
)

// 汇总结果
const combinedContext = results.map(r => r.output).join("\n\n")
```

### 5.2 分层任务分解

```typescript
// 第一阶段：探索
const exploreResult = await TaskTool.execute({
  description: "Explore codebase structure",
  prompt: "Explore the overall codebase structure and identify key modules",
  subagent_type: "explore",
}, context)

// 第二阶段：设计（基于探索结果）
const designResult = await TaskTool.execute({
  description: "Design implementation",
  prompt: `Based on the codebase exploration:
${exploreResult.output}

Design an implementation for the new feature. Consider:
1. Where to add new code
2. How to integrate with existing code
3. What tests to write`,
  subagent_type: "general",
}, context)

// 第三阶段：执行（主 Agent 执行）
// 使用 designResult 中的计划执行代码修改
```

### 5.3 任务恢复机制

```typescript
// 首次启动任务
const firstResult = await TaskTool.execute({
  description: "Long running task",
  prompt: "Process all files in the data directory...",
  subagent_type: "general",
}, context)

// 获取 task_id
const taskId = extractTaskId(firstResult.output)  // "task_id: session-abc123"

// 后续恢复任务
const resumedResult = await TaskTool.execute({
  description: "Continue long running task",
  prompt: "Continue processing from where we left off...",
  subagent_type: "general",
  task_id: "session-abc123",  // 恢复现有会话
}, context)
```

---

## 6. 完整工作流示例

### 6.1 Plan 模式工作流

```typescript
// 1. 用户请求进入 Plan 模式
// Agent 切换到 "plan" Agent

// 2. 启动并行探索
const exploreResults = await Promise.all([
  TaskTool.execute({
    description: "Explore routing",
    prompt: "Find routing configuration and patterns",
    subagent_type: "explore",
  }, context),
  TaskTool.execute({
    description: "Explore models",
    prompt: "Find data models and schemas",
    subagent_type: "explore",
  },
])

// 3. 启动设计 Agent
const designResult = await TaskTool.execute({
  description: "Design feature",
  prompt: `Based on exploration results, design the feature implementation...`,
  subagent_type: "general",
}, context)

// 4. 生成计划文件
await WriteTool.execute({
  file_path: ".opencode/plans/feature-implementation.md",
  content: generatePlan(designResult),
}, context)

// 5. 调用 plan_exit 工具
await PlanExitTool.execute({}, context)
```

### 6.2 会话压缩流程

```typescript
// 当会话接近上下文限制时
const tokens = calculateTokens(messages)
const limit = model.contextWindow

if (tokens > limit * 0.8) {
  // 1. 创建压缩消息
  await SessionCompaction.create({
    sessionID,
    agent: "compaction",
    model: { providerID, modelID },
    auto: true,
  })
  
  // 2. 生成摘要
  const result = await SessionCompaction.process({
    sessionID,
    parentID: lastUserMessageId,
    messages,
    auto: true,
  })
  
  // 3. 如果成功，摘要会作为特殊消息插入
  // 旧消息被标记为 compacted，不再计入上下文
}
```

---

## 7. 类型定义速查

### 7.1 核心类型

```typescript
// Agent 类型
type AgentMode = "subagent" | "primary" | "all"
type PermissionAction = "allow" | "deny" | "ask"

// 消息类型
type MessageRole = "user" | "assistant"
type PartType = 
  | "text" 
  | "tool" 
  | "file" 
  | "snapshot" 
  | "patch" 
  | "subtask" 
  | "compaction"
  | "reasoning"

// 工具状态
type ToolStatus = "pending" | "in_progress" | "completed" | "error"
```

### 7.2 常用函数签名

```typescript
// Agent
Agent.get(name: string): Promise<Agent.Info>
Agent.list(): Promise<Agent.Info[]>
Agent.generate(input: { description: string }): Promise<AgentConfig>

// Session
Session.create(input?: { parentID?, title?, permission? }): Promise<Session.Info>
Session.get(id: SessionID): Promise<Session.Info>
Session.messages(input: { sessionID, limit? }): Promise<MessageV2.WithParts[]>

// Skill
Skill.get(name: string): Promise<Skill.Info | undefined>
Skill.available(agent?: Agent.Info): Promise<Skill.Info[]>

// Task Tool
TaskTool.execute(params: {
  description: string
  prompt: string
  subagent_type: string
  task_id?: string
}): Promise<{ output: string, metadata: {...} }>
```

---

## 8. 调试技巧

### 8.1 查看会话结构

```typescript
// 打印会话消息树
function printMessageTree(messages: MessageV2.WithParts[]) {
  for (const msg of messages) {
    console.log(`${msg.info.role} (${msg.info.id}):`)
    for (const part of msg.parts) {
      console.log(`  [${part.type}] ${summarize(part)}`)
    }
  }
}
```

### 8.2 权限调试

```typescript
// 检查权限决策过程
function debugPermission(tool: string, pattern: string, rules: Permission.Ruleset) {
  const result = Permission.evaluate(tool, pattern, rules)
  console.log(`${tool}:${pattern} => ${result.action}`)
  console.log(`  Matched rule:`, result.rule)
}
```

---

## 9. 最佳实践总结

### 9.1 Agent 设计

1. **单一职责**：每个 Agent 专注于特定任务类型
2. **权限最小化**：只授予必要的工具权限
3. **清晰的描述**：description 要明确说明使用场景

### 9.2 Multi-Agent 协作

1. **并行探索**：对未知代码库使用多个 explore Agent
2. **串行依赖**：设计 → 执行 → 验证
3. **结果汇总**：明确如何将子 Agent 结果传递给主 Agent

### 9.3 Prompt 工程

1. **分层构造**：提供商 → Agent → Skill → 环境
2. **明确指令**：避免模糊描述
3. **格式规范**：使用结构化格式（如 XML 标签）

---

*本示例文件配合学习指南使用*
