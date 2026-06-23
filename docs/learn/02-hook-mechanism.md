# 2. Hook 机制（Plugin SDK）

## 2.1 架构概览

opencode 的 Hook 系统基于插件（Plugin）架构，允许外部代码在关键生命周期节点插入自定义逻辑。Hook 通过 `(input, output) => Promise<void>` 的模式实现双向数据传递。

```
┌──────────────────────────────────────────────────────────────────┐
│                        opencode 内核                             │
│                                                                  │
│  ┌─────────┐   ┌───────────┐   ┌──────────┐   ┌───────────┐   │
│  │ Prompt  │   │ Processor │   │ Tools    │   │ Agent     │   │
│  │  Loop   │   │           │   │          │   │           │   │
│  └────┬────┘   └─────┬─────┘   └────┬─────┘   └─────┬─────┘   │
│       │              │              │               │          │
│       └──────────────┼──────────────┼───────────────┘          │
│                      │              │                           │
│               Plugin.trigger(name, input, output)               │
│                      │                                          │
└──────────────────────┼──────────────────────────────────────────┘
                       │
              ┌────────┴────────┐
              │   Plugin 层      │
              │  for hook in     │
              │   hooks:         │
              │   hook[name]?    │
              │   (input, output)│
              └─────────────────┘
```

### 核心文件

| 文件 | 职责 |
|------|------|
| `packages/plugin/src/index.ts` | **Hook 类型定义**：`Hooks` 接口，定义所有可用的 hook 签名 |
| `packages/plugin/src/tool.ts` | **插件工具类型**：`ToolDefinition` 接口 |
| `packages/opencode/src/plugin/index.ts` | **Plugin 服务**：加载内部/外部插件，`trigger()` 执行 hook |
| `packages/opencode/src/plugin/loader.ts` | **插件加载器**：npm 安装、版本解析 |
| `packages/opencode/src/plugin/shared.ts` | **插件工具函数**：spec 解析、ID 解析 |

---

## 2.2 Hook 类型一览

`packages/plugin/src/index.ts` 中的 `Hooks` 接口定义了以下 hook：

### 2.2.1 生命周期 Hooks

```ts
interface Hooks {
  // 插件卸载时调用
  dispose?: () => Promise<void>

  // 所有事件广播（session、message、tool 等事件的通配订阅）
  event?: (input: { event: Event }) => Promise<void>

  // 插件加载后收到当前配置
  config?: (input: Config) => Promise<void>
}
```

### 2.2.2 Tool 相关 Hooks

```ts
  // 提供自定义工具
  tool?: { [key: string]: ToolDefinition }

  // 工具执行前（可修改或拒绝参数）
  "tool.execute.before"?: (
    input: { tool: string; sessionID: string; callID: string },
    output: { args: any },
  ) => Promise<void>

  // 工具执行后（可查看/修改结果）
  "tool.execute.after"?: (
    input: { tool: string; sessionID: string; callID: string; args: any },
    output: { title: string; output: string; metadata: any },
  ) => Promise<void>

  // 修改工具定义（描述和参数）发送给 LLM
  "tool.definition"?: (
    input: { toolID: string },
    output: { description: string; parameters: any },
  ) => Promise<void>
```

### 2.2.3 Chat 相关 Hooks

```ts
  // 收到新消息时
  "chat.message"?: (
    input: { sessionID: string; agent?: string; model?: {...}; messageID?: string },
    output: { message: UserMessage; parts: Part[] },
  ) => Promise<void>

  // 修改发送给 LLM 的参数（temperature、topP 等）
  "chat.params"?: (
    input: { sessionID: string; agent: string; model: Model; provider: ProviderContext; message: UserMessage },
    output: { temperature: number; topP: number; topK: number; maxOutputTokens: number; options: Record<string, any> },
  ) => Promise<void>

  // 修改 HTTP 请求头
  "chat.headers"?: (
    input: { sessionID: string; agent: string; model: Model; provider: ProviderContext; message: UserMessage },
    output: { headers: Record<string, string> },
  ) => Promise<void>
```

### 2.2.4 权限相关 Hooks

```ts
  // 权限询问拦截
  "permission.ask"?: (
    input: Permission,
    output: { status: "ask" | "deny" | "allow" },
  ) => Promise<void>
```

### 2.2.5 Shell 与 Command Hooks

```ts
  // 修改 Shell 环境变量
  "shell.env"?: (
    input: { cwd: string; sessionID?: string; callID?: string },
    output: { env: Record<string, string> },
  ) => Promise<void>

  // 命令执行前
  "command.execute.before"?: (
    input: { command: string; sessionID: string; arguments: string },
    output: { parts: Part[] },
  ) => Promise<void>
```

### 2.2.6 Auth / Provider Hooks

```ts
  // OAuth / API 认证
  auth?: AuthHook

  // Provider 模型注入
  provider?: ProviderHook
```

### 2.2.7 实验性 Hooks

```ts
  // 消息发送给 LLM 前批量转换
  "experimental.chat.messages.transform"?: (
    input: {},
    output: { messages: { info: Message; parts: Part[] }[] },
  ) => Promise<void>

  // System prompt 变换
  "experimental.chat.system.transform"?: (
    input: { sessionID?: string; model: Model },
    output: { system: string[] },
  ) => Promise<void>

  // 小模型推荐
  "experimental.provider.small_model"?: (
    input: { provider: ProviderV2 },
    output: { model?: ModelV2 },
  ) => Promise<void>

  // Compaction 自定义 prompt
  "experimental.session.compacting"?: (
    input: { sessionID: string },
    output: { context: string[]; prompt?: string },
  ) => Promise<void>

  // Compaction 后自动继续控制
  "experimental.compaction.autocontinue"?: (
    input: { sessionID: string; agent: string; model: Model; ... },
    output: { enabled: boolean },
  ) => Promise<void>

  // 文本完成后处理
  "experimental.text.complete"?: (
    input: { sessionID: string; messageID: string; partID: string },
    output: { text: string },
  ) => Promise<void>
```

---

## 2.3 Hook 触发机制

### 2.3.1 Plugin.trigger()

`packages/opencode/src/plugin/index.ts:280`：

```ts
const trigger = Effect.fn("Plugin.trigger")(function* (
  name: TriggerName,
  input: Input,
  output: Output,
) {
  const state = yield* InstanceState.get(state)
  // 遍历所有已注册的 hook，如果 hook 有对应的 name 函数就调用
  for (const hook of state.hooks) {
    const fn = hook[name]
    if (!fn) continue
    yield* Effect.promise(async () => fn(input, output))
  }
  return output  // 返回可能被修改的 output
})
```

核心模式：
- **input** 是只读上下文信息
- **output** 是可被修改的对象，hook 可以直接修改其属性
- 所有匹配的 hook **串行**执行
- 返回可能被修改后的 output

### 2.3.2 Hook 触发位置

| 触发位置 | Hook 列表 |
|----------|----------|
| `session/prompt.ts` 主循环 | `command.execute.before`、`experimental.chat.messages.transform`、`experimental.chat.system.transform` |
| `session/prompt.ts` subtask | `tool.execute.before`、`tool.execute.after` |
| `session/tools.ts` 工具解析 | `tool.execute.before`、`tool.execute.after` |
| `session/processor.ts` 事件处理 | `experimental.text.complete` |
| `session/llm.ts` LLM 调用 | `chat.params`、`chat.headers` |
| `tool/registry.ts` 工具过滤 | `tool.definition` |
| `agent/agent.ts` Agent 构建 | `experimental.chat.system.transform` |
| `shell.ts` Shell 执行 | `shell.env` |

### 2.3.3 TriggerName 类型约束

只允许 `(input, output) => Promise<void>` 签名的 hook 通过 `trigger()` 调用：

```ts
type TriggerName = {
  [K in keyof Hooks]-?: NonNullable<Hooks[K]> extends (input: any, output: any) => Promise<void> ? K : never
}[keyof Hooks]
```

这排除了 `dispose()`、`event()`、`config()`、`auth`、`provider`、`tool` 等不同签名的 hook。

---

## 2.4 插件加载流程

### 2.4.1 初始化

`packages/opencode/src/plugin/index.ts` — `Plugin.state()` (InstanceState)：

```
1. 创建 SDK Client（用于插件内部调用 opencode API）
2. 加载内置插件（internalPlugins）：
   ├─ CodexAuthPlugin（OpenAI Codex OAuth）
   ├─ CopilotAuthPlugin（GitHub Copilot）
   ├─ GitlabAuthPlugin
   ├─ PoeAuthPlugin
   ├─ CloudflareWorkersAuthPlugin
   ├─ CloudflareAIGatewayAuthPlugin
   ├─ AzureAuthPlugin
   ├─ DigitalOceanAuthPlugin
   ├─ SnowflakeCortexAuthPlugin
   └─ XaiAuthPlugin
3. 加载外部插件：
   ├─ 解析 config.plugin_origins（spec → npm 包）
   ├─ PluginLoader.loadExternal() 安装和加载
   └─ 调用 applyPlugin() 实例化
4. 触发所有 hook 的 config() 调用
5. 订阅全局事件流 → 触发所有 hook 的 event()
```

### 2.4.2 外部插件加载

`PluginLoader.loadExternal()`:
1. 解析插件 specifier（`npm:package@version` 格式）
2. 安装 npm 依赖
3. 动态 import 模块
4. 检测兼容性
5. 调用插件工厂函数 `plugin(input) => Hooks`

### 2.4.3 插件输入（PluginInput）

```ts
interface PluginInput {
  client: OpencodeClient       // SDK client
  project: Project             // 当前项目信息
  directory: string            // 工作目录
  worktree: string             // 工作树根目录
  experimental_workspace: {
    register(type, adapter)    // 注册 workspace 适配器
  }
  serverUrl: URL               // 服务器 URL
  $: BunShell                  // Bun shell
}
```

---

## 2.5 内置 Auth 插件详解

以 Copilot 为例（`packages/opencode/src/plugin/github-copilot/copilot.ts`）：

Auth hook 结构：
```ts
interface AuthHook {
  provider: string
  loader?: (auth, provider) => Promise<Record<string, any>>
  methods: Array<{
    type: "oauth" | "api"
    label: string
    prompts?: Array<...> // 收集用户输入
    authorize(inputs?) => Promise<AuthResult> // 执行认证
  }>
}
```

支持的认证方式：
- **OAuth**：自动回调或 code 模式
- **API Key**：用户输入 API key

每个 auth 插件负责：
1. 提供登录界面（CLI 或 TUI 中的 prompts）
2. 执行 OAuth 流程
3. 存储认证凭据
4. 返回 token 供 LLM 调用使用

---

## 2.6 Provider Hook

```ts
interface ProviderHook {
  id: string
  models?: (provider: ProviderV2, ctx: { auth?: Auth }) => Promise<Record<string, ModelV2>>
}
```

Provider hook 允许插件动态注入模型列表。例如 Copilot 插件通过此 hook 提供 Copilot 专有模型。

---

## 2.7 插件工具（Plugin-Provided Tools）

插件可通过 `tool` hook 提供自定义工具：

```ts
interface ToolDefinition {
  description: string
  args?: Record<string, z.ZodType>
  execute(args: any, ctx: PluginToolContext): Promise<string | ToolResult>
}
```

在 `tool/registry.ts` 中：
1. 扫描配置目录下的 `{tool,tools}/*.js|ts` 文件
2. 从插件 hooks 中提取 `tool` 定义
3. 包装为统一 `Tool.Def` 格式
4. 内部使用 `EffectBridge` 桥接 Promise API 和 Effect API
