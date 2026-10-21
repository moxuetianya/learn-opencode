# 6. Plugin 与 Hook：V2 扩展机制

> 本课回答：V2 的插件长什么样？有哪些扩展点？Hook 与 Transform 的区别是什么？
> 多个插件按什么顺序生效？外部插件如何加载和热更新？
>
> 旧版 `packages/plugin/src/index.ts` 的 `Hooks` 巨型接口、`Plugin.trigger()` 已重构为
> **按 domain 分组的 Effect API**；本课只讲现行结构。

---

## 6.1 两层插件模型

V2 把"扩展"拆成两种能力，它们都在插件的 Effect scope 内注册，scope 关闭即自动清理：

| 能力 | 形态 | 用途 |
|---|---|---|
| **Transform** | `(editor) => void` | 注册/修改长时间存在的注册表（agent、tool、skill、provider、model…） |
| **Hook** | `(event) => Effect<void>` | 在某个时刻观察/改写一次事件（会话请求、工具调用、权限评估…） |

```
Plugin (Effect)
  ├─ ctx.agent.transform(...)      改 Agent 注册表
  ├─ ctx.tool.transform(...)       加工具
  ├─ ctx.session.hook("context")   改一次模型请求
  ├─ ctx.tool.hook("execute.before")
  └─ ctx.event.subscribe()         订阅全局事件流
```

### 核心文件

| 文件 | 职责 |
|---|---|
| `packages/plugin/src/effect/plugin.ts` | `Context`、`Plugin`、`define()` |
| `packages/plugin/src/effect/registration.ts` | `Hooks` / `Transform` / `Registration` 类型 |
| `packages/core/src/plugin/hooks.ts` | `PluginHooks` 运行时：注册、`trigger`、`has` |
| `packages/core/src/plugin.ts` | 插件激活注册表：代际、失败回退、scope |
| `packages/core/src/plugin/supervisor.ts` | 内置 + SDK + 实例 + 外部插件的编排 |
| `packages/core/src/plugin/module.ts` | 外部插件解析、安装、导入 |
| `packages/core/src/plugin/internal.ts` | `pre` / `post` 内置插件清单 |
| `packages/core/src/plugin/service.ts` | `Plugin.Service` 接口（`activate` / `hold` / `awaitActivation`） |

---

## 6.2 Hook domain 一览

`PluginHooks` 的 domain 和事件来自 `packages/plugin/src/effect/*`：

### Session（`effect/session.ts`）

| Hook | 时机 | 可修改 |
|---|---|---|
| `prompt` | 用户输入被准入前 | prompt 文本/文件/agents/skills、metadata、delivery |
| `context` | 每次 primary 请求组装后 | system、messages、tools、options |
| `compaction` | 压缩请求组装后 | 同上；可设置 `result` 跳过模型 |
| `generate` | `Session.generate` | 同上 |
| `title` | 标题请求 | 同上；可设置 `result` |
| `model.request` | LLMRequest 完成后 | `baseURL`、`headers` |
| `http.request` / `http.response` | 每次 HTTP | 请求/响应对象 |
| `experimental.ws.handshake/send/receive` | WebSocket 传输 | URL/headers/frame |
| `retry` | 每次重试决策 | `decision: { retry, delay }` |

### Tool（`effect/tool.ts`）

| Hook | 失败通道 | 说明 |
|---|---|---|
| `execute.before` | `Tool.Error` | 可改 `input`；抛错即拒绝该次调用 |
| `execute.after` | 无 | 可改 `result` 或 `error`（`status: completed/error`） |

### Permission（`effect/permission.ts`）

| Hook | 说明 |
|---|---|
| `evaluate` | 单个权限规则评估时调用；可改 `effect`（allow/deny/ask）与 `message` |

### Shell（`effect/shell.ts`）

| Hook | 说明 |
|---|---|
| `create.before` | 子进程创建前；可改 command、cwd、timeout、shell、env |

### AISDK（`effect/aisdk.ts`）

| Hook | 说明 |
|---|---|
| `sdk` | 拿到 provider SDK 实例后，可替换 `sdk` |
| `language` | 构造 `LanguageModelV3` 后，可替换 `language` |

### 其它 domain

`agent` / `command` / `mcp` / `model` / `provider` / `reference` / `skill` /
`websearch` / `worktree` / `vcs` 主要是 **Transform + API**，个别带 hook。
`event` 只有 `subscribe()`，没有可消化的 hook。

---

## 6.3 `PluginHooks.trigger` 的执行语义

`packages/core/src/plugin/hooks.ts`：

```ts
trigger(domain, name, event)
  for (entry of callbacks[`${domain}.${name}`] ?? []) {
    if (entry.options?.providerID && entry.options.providerID !== event.model?.providerID) continue
    yield* entry.callback(event)
  }
  return event
```

规则：

1. **同一事件的所有回调串行执行**，顺序 = 注册顺序；
2. **事件对象是原地修改的**（`event.messages.splice(...)`、`event.decision.retry = false`）；
3. 只有声明了失败通道的 hook 可以失败（目前主要是 `tool.execute.before`）；
4. `providerID` 选项只对带 `model` 的事件生效（session/model 请求、aisdk）；
5. `has(domain, name, providerID?)` 可用于避免无谓的请求包装。

`trigger` 返回同一个事件对象，调用方继续使用它。

---

## 6.4 Transform 的生效方式

Transform 不是"立即改当前对象"，而是**登记到 State 的变换列表里，按注册顺序重放**：

```
State.create({ initial, editor })
  transform(callback) → 登记 callback
  reload()            → 清空草稿，按顺序重放所有 callback
  transform 注册/释放 → 触发 reload
```

这带来几个重要性质：

- 后注册的 transform 覆盖先注册的（同名字段）；
- 卸载一个插件会重建注册表，被它覆盖的早期定义重新出现；
- `reload()` 不改变优先级，只重新计算当前状态；
- 每个模型请求捕获自己的 `Tool.Snapshot`，运行中 reload 不影响已开始的请求。

`Agent` / `Skill` / `Tool` / `Provider` / `Model` / `MCP` 等都是这个模式。

---

## 6.5 插件加载与排序

### 6.5.1 顺序

`plugin/supervisor.ts` 的 `activate()`：

```
pre  = 内置 pre 插件
     + SdkPlugins.all()
     + InstancePlugins.all()
     + 配置声明的外部插件（resolve 后）
post = 内置 post 插件
```

最终激活顺序：

```
pre（内置 pre → SDK/实例 → 外部包） → post（内置 post）
```

- 外部插件在 `resolve()` 中按配置声明顺序加载；能立即加载的先激活，缺失依赖的包
  在 `npm install` 完成后再跑第二轮。
- 实例插件排在 SDK 之后，因此实例的显式选择覆盖全局默认。
- 重复 ID：保留 boot 顺序中的第一个，后面的作为 failed 上报。

### 6.5.2 `pre` 里有什么

`plugin/internal.ts` 的 `pre` 是"运行时基础设施与工具"：

```
工具输入修复、worktree/mcp 配置、MCP CodeMode 默认值、well-known、VCS(git/hg)、
Agent 内置定义、Plan 模式、Command、Skill、models.dev、Provider 插件、WebSearch 插件、
编辑工具（patch/edit/glob/grep/opencode/mcp-resource/question/read/shell/skill/subagent/
webfetch/websearch/write）…
```

### 6.5.3 `post` 里有什么

`post` 是"读取用户配置并改写注册表"的插件：

```
ConfigInstruction、ConfigReference、ConfigAgent、Browser、
ConfigCommand、ConfigCompaction、ConfigFormatter、ConfigImage、
ConfigLocationWatcher、ConfigShell、ConfigSnapshot、ConfigToolOutput、
ConfigCompatibility、ConfigSkill、ConfigProvider、ConfigWebSearch、ConfigPolicy
```

顺序很关键：例如 `ConfigAgent` 必须在 `Agent` 内置定义之后运行，
才能覆盖 `build/plan/...` 并加入用户 agent。

### 6.5.4 失败与热更新

`Plugin.Service.activate()`：

- 每次激活是一代（generation）；只重新加载发生变化的插件；
- 新插件 setup 失败 → 记录 failed，**保留上一个可用版本**；
- 插件 transform 失败 → 之后被禁用，并刷新受影响的服务状态；
- 配置、插件文件、managed policy、SDK 插件变化都会触发重新激活（100ms debounce）。

`Plugin.awaitActivation` 是会话准入与 runner 的等待点：确保插件就绪后再准备输入/模型请求。

---

## 6.6 外部插件

### 6.6.1 声明

```jsonc
// opencode.jsonc
{
  "plugins": [
    "opencode-my-plugin",                              // npm 包
    { "package": "opencode-my-plugin", "options": { "level": 2 } },
    "/abs/path/to/plugin-dir"                          // 本地目录（配置项必须是目录）
  ]
}
```

项目内还可以直接放文件，由目录发现加载：

```
.opencode/plugin/*.ts
.opencode/plugins/*.ts
```

（`PluginSourceDirectory.discover` 读取 `plugin` / `plugins` 目录；
配置里显式写路径时只接受目录，不接受单个 `.ts` 文件。）

### 6.6.2 模块契约

`plugin/module.ts` 接受默认导出：

```ts
// Effect 版
export default {
  id: "my-plugin",
  effect: (ctx) => Effect.gen(function* () {
    yield* ctx.tool.transform((editor) => editor.add({ ... }))
  }),
}
```

或 Promise 版：

```ts
export default {
  id: "my-plugin",
  setup: async (ctx) => { ... },
}
```

加载流程：

```
解析 target（绝对路径视为本地，否则 npm）
  → npm resolve / add（可跳过安装）
  → Host.resolve 找到 entrypoints.server
  → 动态 import
  → Schema 校验 default.id + effect/setup
  → 包装成 Generation { id, revision, source, effect }
```

`engines`/兼容性、managed policy（`integration.use`）在加载前检查；
失败会记录在 `Plugin.Info.state = failed`，不会拖垮整个进程。

### 6.6.3 插件上下文

`Context`（`packages/plugin/src/effect/plugin.ts`）包含：

```ts
{
  app, location, options,
  agent, aisdk, command, event,
  experimental: { terminal },
  integration, mcp, model, generate, permission, plugin,
  provider, reference, rpc, session, shell, skill,
  storage, tool, vcs, websearch, worktree
}
```

每个 domain 同时提供：
- 对 Effect API client 的调用（例如 `ctx.session.prompt(...)`）；
- 本 domain 的 `transform` / `reload`；
- 需要的事件 hook。

`storage` 是按插件 ID 隔离的 KV；`rpc` 可以注册自定义 HTTP 端点。

---

## 6.7 两个最小示例

### 6.7.1 注册一个只读工具

```ts
import { define } from "@opencode/plugin/effect/plugin"
import { Effect, Schema } from "effect"

export default define({
  id: "example.word-count",
  effect: Effect.fn(function* (ctx) {
    yield* ctx.tool.transform((editor) =>
      editor.add({
        name: "word_count",
        description: "Count words in the provided text.",
        input: Schema.Struct({ text: Schema.String }),
        execute: (input) =>
          Effect.succeed({ output: String(input.text.trim().split(/\s+/).filter(Boolean).length) }),
      }),
    )
  }),
})
```

> 需要访问文件时，外部插件应使用 `ctx` 暴露的 API（或工具/会话 API）；
> Core 内部插件可以直接使用 Location 范围的 `FSUtil.Service`。两者都不要直接
> `node:fs` 绕过 Location 约束。

### 6.7.2 给模型请求加 header

```ts
export default define({
  id: "example.header",
  effect: Effect.fn(function* (ctx) {
    yield* ctx.session.hook("model.request", (event) => {
      event.headers["x-example"] = "1"
      return Effect.void
    })
  }),
})
```

### 6.7.3 拦截工具参数

```ts
import { Tool } from "@opencode/schema/tool"
import { Effect } from "effect"

export default define({
  id: "example.guard",
  effect: Effect.fn(function* (ctx) {
    yield* ctx.tool.hook("execute.before", (event) => {
      if (event.tool !== "shell") return Effect.void
      // 只允许只读命令
      if (!/^(ls|rg|git status)\b/.test(String((event.input as { command?: unknown }).command))) {
        return Effect.fail(new Tool.Error({ message: "read-only shell only" }))
      }
      return Effect.void
    })
  }),
})
```

> `execute.before` 的唯一失败类型是 `Tool.Error`；抛其它错误会变成 defect。
> 用户拒绝权限（`Permission.DeclinedError`）不在这里处理，它由工具叶子抛出并在
> `SessionModelRequest.executeTool` 边界恢复为失败。

---

## 6.8 权限 Hook 与内置策略

`Permission.evaluate(action, resource, ...rulesets)`：

```
从后往前找最后一条同时匹配 action 与 resource 的规则
  → 没有匹配则 ask
```

规则来源按顺序叠加（后者覆盖前者）：

```
Agent.Info.permissions（包含配置里的全局 permissions）
  → 会话 permissions（Session.setPermissions）
  → 保存的 "always" 授权（PermissionSaved）
```

`permission.evaluate` hook 可以在最终决策前改写 `effect` 或 `message`，
但不会替代 `Permission.assert` 的"询问 → 等待用户回复"流程。
权限请求以 `permission.asked` 事件推送给客户端，客户端回复
`permission.replied`（once / always / reject）。

---

## 6.9 TUI 插件

TUI 也有一套独立插件接口（`@opencode/plugin/tui`）：

```ts
import { define } from "@opencode/plugin/tui"

export default define({
  id: "my-tui-plugin",
  setup: (ctx) => {
    // 注册命令、slot、面板、route…
    return () => { /* cleanup */ }
  },
})
```

它运行在客户端进程，不参与 server 的 `PluginHooks`；两者可以同名但互不影响。
具体可用 API 见 `packages/plugin/src/tui/context.ts` 与
`packages/tui/src/plugin/*`。

---

## 6.10 小结

1. **Transform 建表，Hook 改事件**：前者是有序重放的注册表，后者是串行的事件回调。
2. **顺序即语义**：内置 pre → SDK/实例/外部 → 内置 post；后注册覆盖先注册。
3. **失败可回退**：插件 setup 失败保留上一版；transform 失败会被禁用并刷新状态。
4. **外部插件是普通模块**：默认导出 `{ id, effect|setup }`，支持 npm 与本地目录。
5. **所有注册都受 scope 管理**：插件卸载 = 关闭 scope = 自动 dispose。
6. **TUI 插件是另一套接口**：不要和 server 插件混用。

> **迁移小注**：旧文档里的 `Hooks` 接口、`chat.message`、`chat.params`、
> `tool.definition`、`experimental.*` hook 名称属于 V1；V2 对应的是
> `session.prompt/context`、`session.model.request`、`tool.execute.before/after` 等。
