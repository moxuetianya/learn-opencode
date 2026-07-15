# OpenCode 核心代码目录导航

本文件帮助快速定位 OpenCode Multi-Agent 系统的核心代码。

---

## 📁 核心目录结构

```
packages/opencode/src/
├── agent/              # Agent 系统
│   ├── agent.ts        # ⭐ Agent 定义与管理（核心）
│   ├── generate.txt    # Agent 生成提示词
│   └── prompt/         # Agent 专用提示词
│       ├── compaction.txt    # 压缩 Agent 提示词
│       ├── explore.txt       # 探索 Agent 提示词
│       ├── summary.txt       # 摘要 Agent 提示词
│       └── title.txt         # 标题 Agent 提示词
│
├── skill/              # Skill 技能系统
│   ├── index.ts        # ⭐ Skill 管理（核心）
│   └── discovery.ts    # Skill 发现机制
│
├── session/            # Session 与会话记忆
│   ├── index.ts        # ⭐ Session 管理（核心）
│   ├── message-v2.ts   # ⭐ 消息结构定义（核心）
│   ├── prompt.ts       # ⭐ Prompt 处理（核心）
│   ├── compaction.ts   # ⭐ 会话压缩（核心）
│   ├── processor.ts    # 消息处理器
│   ├── llm.ts          # LLM 交互
│   ├── system.ts       # ⭐ 系统提示词构造
│   ├── instruction.ts  # 指令管理
│   ├── schema.ts       # 类型定义
│   ├── session.sql.ts  # 数据库表定义
│   └── prompt/         # 系统提示词模板
│       ├── anthropic.txt     # Claude 提示词
│       ├── gemini.txt        # Gemini 提示词
│       ├── gpt.txt           # GPT 提示词
│       ├── default.txt       # 默认提示词
│       ├── plan.txt          # Plan 模式提示词
│       └── build-switch.txt  # Build 切换提示词
│
├── tool/               # 工具系统
│   ├── tool.ts         # ⭐ 工具基础定义（核心）
│   ├── registry.ts     # 工具注册表
│   ├── task.ts         # ⭐ Task 工具（Multi-Agent 核心）
│   ├── skill.ts        # ⭐ Skill 工具
│   ├── bash.ts         # Bash 工具
│   ├── read.ts         # Read 工具
│   ├── edit.ts         # Edit 工具
│   └── *.txt           # 各工具的描述文本
│
├── permission/         # 权限系统
│   └── index.ts        # ⭐ 权限评估
│
├── provider/           # 模型提供商
│   ├── provider.ts     # 提供商管理
│   └── schema.ts       # 模型定义
│
├── effect/             # Effect 框架集成
│   ├── instance-state.ts   # 实例状态管理
│   └── run-service.ts      # 服务运行器
│
├── config/             # 配置系统
│   ├── config.ts       # 配置管理
│   └── markdown.ts     # Markdown 配置解析
│
└── storage/            # 数据存储
    └── db.ts           # 数据库操作
```

---

## 🎯 按主题阅读指南

### 主题 1：Agent 系统

| 优先级 | 文件 | 说明 |
|--------|------|------|
| ⭐⭐⭐ | `agent/agent.ts` | Agent 定义、内置 Agent、权限配置 |
| ⭐⭐ | `agent/prompt/*.txt` | 各 Agent 的系统提示词 |
| ⭐ | `permission/index.ts` | 权限评估机制 |

### 主题 2：Multi-Agent 协作

| 优先级 | 文件 | 说明 |
|--------|------|------|
| ⭐⭐⭐ | `tool/task.ts` | Task 工具，Multi-Agent 核心 |
| ⭐⭐⭐ | `session/index.ts` | 父子 Session 关系 |
| ⭐⭐ | `agent/agent.ts:107-234` | 内置 Agent 配置（特别是 explore、general） |

### 主题 3：Skill 系统

| 优先级 | 文件 | 说明 |
|--------|------|------|
| ⭐⭐⭐ | `skill/index.ts` | Skill 加载和管理 |
| ⭐⭐⭐ | `tool/skill.ts` | Skill 工具实现 |
| ⭐⭐ | `skill/discovery.ts` | Skill 发现机制 |

### 主题 4：Session 与记忆

| 优先级 | 文件 | 说明 |
|--------|------|------|
| ⭐⭐⭐ | `session/index.ts` | Session 生命周期管理 |
| ⭐⭐⭐ | `session/message-v2.ts` | 消息结构定义 |
| ⭐⭐⭐ | `session/compaction.ts` | 会话压缩机制 |
| ⭐⭐ | `session/prompt.ts:189-250` | 标题生成 |

### 主题 5：Prompt 构造

| 优先级 | 文件 | 说明 |
|--------|------|------|
| ⭐⭐⭐ | `session/prompt.ts` | Prompt 构建流程 |
| ⭐⭐⭐ | `session/system.ts` | 系统提示词组装 |
| ⭐⭐ | `session/prompt/*.txt` | 各类提示词模板 |

---

## 📊 核心数据流

### 1. 用户消息处理流程

```
用户输入
    ↓
session/prompt.ts:prompt()
    ↓
resolvePromptParts()      ← 解析 @file 和 Agent 引用
    ↓
insertReminders()         ← 注入 Plan 模式提示词
    ↓
resolveTools()            ← 根据 Agent 权限解析可用工具
    ↓
SessionProcessor.process() ← 调用 LLM
    ↓
返回 Assistant 消息
```

### 2. Multi-Agent 调用流程

```
主 Agent (build)
    ↓
调用 task 工具
    ↓
tool/task.ts:execute()
    ↓
Agent.get(subagent_type)  ← 获取 Agent 配置
    ↓
Session.create({parentID}) ← 创建子会话
    ↓
SessionPrompt.prompt()    ← 启动子 Agent
    ↓
子 Agent 执行（explore/general）
    ↓
返回结果到主 Agent
```

### 3. Session 压缩流程

```
消息数量/Token 超限
    ↓
session/compaction.ts:create()
    ↓
创建压缩消息
    ↓
processCompaction()
    ↓
调用 compaction Agent 生成摘要
    ↓
插入 CompactionPart
    ↓
旧消息标记为 compacted
    ↓
继续对话（带有摘要上下文）
```

---

## 🔍 关键代码片段索引

### Agent 配置（agent/agent.ts）

```typescript
// 行 107-234: 内置 Agent 定义
const agents: Record<string, Info> = {
  build: { ... },
  plan: { ... },
  general: { ... },
  explore: { ... },
  // ...
}

// 行 72-401: Agent Service 定义
export const layer = Layer.effect(...)
```

### Task 工具（tool/task.ts）

```typescript
// 行 28-166: TaskTool 完整实现
export const TaskTool = Tool.define("task", async (ctx) => { ... })
```

### Session 创建（session/index.ts）

```typescript
// 行 495-509: 创建 Session
const create = Effect.fn("Session.create")(...)

// 行 511-546: Fork Session
const fork = Effect.fn("Session.fork")(...)
```

### Prompt 构建（session/prompt.ts）

```typescript
// 行 155-187: 解析 Prompt 变量
const resolvePromptParts = Effect.fn(...)

// 行 252-386: 插入提醒（Plan 模式）
const insertReminders = Effect.fn(...)

// 行 388-500+: 解析工具
const resolveTools = Effect.fn(...)
```

### 会话压缩（session/compaction.ts）

```typescript
// 行 93-139: 修剪旧工具输出
const prune = Effect.fn(...)

// 行 141-347: 处理压缩
const processCompaction = Effect.fn(...)
```

---

## 📚 延伸阅读

### Effect 框架

OpenCode 使用 Effect 框架进行函数式编程：
- `Effect.gen()` - 生成器函数
- `Layer.effect()` - 依赖注入
- `ServiceMap.Service` - 服务定义

### 数据库

使用 Drizzle ORM：
- `session/session.sql.ts` - Session 表
- `storage/db.ts` - 数据库连接

### 配置

- `config/config.ts` - 配置加载
- `config/markdown.ts` - Markdown 配置解析

---

## 💡 阅读建议

### 初学者路径

1. 先读 `agent/agent.ts` 了解 Agent 概念
2. 再读 `tool/task.ts` 理解 Multi-Agent 调用
3. 然后读 `session/index.ts` 了解会话管理
4. 最后读 `session/prompt.ts` 理解 Prompt 构造

### 进阶路径

1. 深入 `session/compaction.ts` 理解记忆压缩
2. 研究 `skill/index.ts` 了解模块化指令
3. 分析 `session/message-v2.ts` 消息结构
4. 探索 `permission/index.ts` 权限系统

### 实践建议

1. 创建自定义 Agent 实验
2. 编写自定义 Skill 测试
3. 观察 Session 压缩行为
4. 分析 Prompt 构造过程

---

*最后更新：2026-04-04*
