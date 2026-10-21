# 附录 B：插件与工具开发示例

> 这是**上手用的最小示例集**，不是 API 全集。
> 原则：先看第 06 课理解 Transform/Hook，再从这里抄骨架。
>
> 所有示例针对 V2（opencode 2.0.24）。旧版 `Hooks` 接口的示例不要再用。

---

## B.1 一个最小的 Server 插件

文件：`~/.config/opencode/plugin/hello.ts`（或项目 `.opencode/plugin/hello.ts`）

```ts
import { define } from "@opencode/plugin/effect/plugin"
import { Effect } from "effect"

export default define({
  id: "example.hello",
  effect: Effect.fn(function* (ctx) {
    yield* ctx.tool.transform((editor) =>
      editor.add({
        name: "hello",
        description: "Return a greeting. Use when the user asks for a hello.",
        input: { type: "object", properties: { name: { type: "string" } } },
        execute: (input) =>
          Effect.succeed({
            output: `Hello, ${(input as { name?: string }).name ?? "world"}!`,
          }),
      }),
    )
  }),
})
```

启用：

```
# 推荐：放在目录发现位置，自动加载
~/.config/opencode/plugin/hello.ts
<project>/.opencode/plugin/hello.ts
```

如果要用配置显式声明，必须指向**目录**：

```jsonc
// ~/.config/opencode/opencode.jsonc
{
  "plugins": ["/home/me/.config/opencode/plugin"]
}
```

**要点**

- `id` 必须稳定；重复 ID 只有第一个生效。
- `effect` 的 scope 关闭时，transform 自动卸载。
- 工具的 `input` 可以是 Effect Schema、Standard Schema 或 JSON Schema。
- 返回 `{ output }` 最省事；需要附件/富内容时用 `content`。

---

## B.2 带结构化输出、metadata 和进度

```ts
import { define } from "@opencode/plugin/effect/plugin"
import { Effect, Schema } from "effect"

const Input = Schema.Struct({
  path: Schema.String.annotate({ description: "Workspace-relative file path" }),
})

const Output = Schema.Struct({
  lines: Schema.Number,
  bytes: Schema.Number,
})

export default define({
  id: "example.file-stats",
  effect: Effect.fn(function* (ctx) {
    yield* ctx.tool.transform((editor) =>
      editor.add({
        name: "file_stats",
        description: "Report line and byte counts for a file.",
        input: Input,
        output: Output,
        execute: (input, context) =>
          Effect.gen(function* () {
            yield* context.progress({ title: `Reading ${input.path}` })
            // 这里应通过 Core 的文件 API 读取；示例只演示形状。
            const text = ""
            yield* context.progress({ title: `Counted ${input.path}` })
            return {
              output: { lines: text.split("\n").length, bytes: text.length },
              metadata: { path: input.path },
              content: `file_stats: ${input.path}`,
            }
          }),
      }),
    )
  }),
})
```

**要点**

- `output` 是给程序/结构化消费的；`content` 是给模型看的。
- `context.progress` 写入 metadata，TUI 实时显示；不要高频刷爆。
- 真实文件访问请用插件可用的文件 API，不要直接 `node:fs`。

---

## B.3 用 `session.context` 注入系统提示

```ts
import { SystemPart } from "@opencode/ai"
import { Effect } from "effect"

export default define({
  id: "example.context",
  effect: Effect.fn(function* (ctx) {
    yield* ctx.session.hook("context", (event) => {
      event.system.push(
        SystemPart.make(
          "Project convention: all new public functions must have a JSDoc comment.",
        ),
      )
      return Effect.void
    })
  }),
})
```

**要点**

- `event.system` 是 `SystemPart[]`，可以直接 push 字符串构造的内容；
- 这段文本会在**每次 primary 请求**出现，适合短规则；
- 长文档应做成 skill 或 AGENTS.md，而不是每轮重复。

---

## B.4 改模型参数 / header

```ts
export default define({
  id: "example.params",
  effect: Effect.fn(function* (ctx) {
    yield* ctx.session.hook("context", (event) => {
      event.options.temperature = 0.2
      event.options.maxTokens = 8_000
      return Effect.void
    })

    yield* ctx.session.hook("model.request", (event) => {
      event.headers["x-team"] = "platform"
      return Effect.void
    })
  }),
})
```

**要点**

- `event.options` 同时包含 generation 参数与 provider options；
- 不确定的键会作为 provider option 透传，谨慎使用；
- 需要网关/代理时，`model.request` 可改 `baseURL`。

---

## B.5 拦截工具执行

```ts
import { Tool } from "@opencode/schema/tool"
import { Effect } from "effect"

export default define({
  id: "example.guard",
  effect: Effect.fn(function* (ctx) {
    yield* ctx.tool.hook("execute.before", (event) => {
      if (event.tool !== "shell") return Effect.void
      const command = String((event.input as { command?: unknown }).command ?? "")
      if (/\brm\s+-rf\b/.test(command)) {
        return Effect.fail(new Tool.Error({ message: "Refusing recursive delete." }))
      }
      return Effect.void
    })
  }),
})
```

**要点**

- `execute.before` 可以改 `event.input`，也可以失败拒绝；
- 唯一失败类型是 `Tool.Error`；其它错误会成为 defect；
- 这是外部插件做策略检查的推荐位置；
- 内置工具还会在叶子内调用 `Permission.assert`，外部插件工具应自行做必要检查。

---

## B.6 插件自己的持久状态

```ts
export default define({
  id: "example.counter",
  effect: Effect.fn(function* (ctx) {
    yield* ctx.tool.transform((editor) =>
      editor.add({
        name: "count_call",
        description: "Increment and return a per-plugin call counter.",
        input: { type: "object", properties: {} },
        execute: () =>
          Effect.gen(function* () {
            const current = (yield* ctx.storage.get("calls")) as number | undefined
            const next = (current ?? 0) + 1
            yield* ctx.storage.set("calls", next)
            return { output: String(next) }
          }),
      }),
    )
  }),
})
```

**要点**

- `ctx.storage` 按插件 ID 隔离，存在 SQLite `kv` 表；
- 值必须是 JSON；
- 不要直接打开 `opencode.db`，也不要写 `model.json` 等界面状态。

---

## B.7 订阅事件

```ts
import { Effect, Stream } from "effect"

export default define({
  id: "example.events",
  effect: Effect.fn(function* (ctx) {
    yield* ctx.event.subscribe().pipe(
      Stream.filter((event) => event.type === "session.execution.succeeded"),
      Stream.runForEach((event) =>
        Effect.logInfo("session finished", { sessionID: event.data.sessionID }),
      ),
      Effect.forkScoped({ startImmediately: true }),
    )
  }),
})
```

**要点**

- `ctx.event.subscribe()` 只给 server 事件（含 `rpc.*`）；
- 长任务要 `forkScoped`，插件卸载时自动中断；
- 不要用事件做唯一状态源；需要完整历史时用 session API。

---

## B.8 注册一个 slash command

```ts
import { define } from "@opencode/plugin/effect/plugin"
import { Effect } from "effect"

export default define({
  id: "example.command",
  effect: Effect.fn(function* (ctx) {
    yield* ctx.command.transform((editor) =>
      editor.add({
        name: "standup",
        description: "Summarize recent work in standup format.",
        execute: (input) =>
          ctx.session
            .prompt({
              sessionID: input.sessionID,
              text: "Summarize the recent changes in standup format.",
              delivery: input.delivery,
            })
            .pipe(Effect.asVoid),
      }),
    )
  }),
})
```

**要点**

- `CommandDefinition.execute` 拿到 `{ sessionID, prompt, delivery }`；
- 可以在这里改写 prompt、加文件、选择 delivery；
- 不要直接调用模型；走 `ctx.session.prompt` 才能享受准入/调度/恢复。

---

## B.9 Skill 目录

```
.opencode/skills/release-check/
├── SKILL.md
├── checklist.md
└── scripts/check.sh
```

`SKILL.md`：

```markdown
---
name: release-check
description: Run the release checklist before tagging a version.
metadata:
  opencode/autoinvoke: true
---

# Release Check

## Steps
1. Run `scripts/check.sh`.
2. Verify `package.json` version matches the tag.
3. Confirm the changelog has an entry for this version.

Read `checklist.md` for the detailed checks.
```

**要点**

- 模型在 system prompt 里只看到 `id/name/description`；
- 调用 `skill` 工具后，正文 + 同目录前 10 个文件会作为 `<skill_content>` 进入历史；
- `autoinvoke: false` 的 skill 不会出现在自动可用列表，但用户可以直接调用；
- skill 是"按需加载的指令"，不是可执行代码。

---

## B.10 自定义 Agent（markdown）

文件：`.opencode/agent/reviewer.md`

```markdown
---
description: Review code changes for correctness and style
mode: subagent
model: anthropic/claude-sonnet-4-5
steps: 20
permissions:
  - action: "*"
    resource: "*"
    effect: deny
  - action: read
    resource: "*"
    effect: allow
  - action: grep
    resource: "*"
    effect: allow
  - action: glob
    resource: "*"
    effect: allow
---

You are a code reviewer. Read the relevant files, identify correctness and
maintainability issues, and report findings with file paths. Do not edit files.
```

**要点**

- front-matter 是配置，正文是 `system`；
- `mode: subagent` 才能被 `subagent` 工具调用；
- `permissions` 有序，最后匹配者生效；
- 也可以用 `agents` 配置对象内联定义。

---

## B.11 调用运行中的 server（外部脚本）

```ts
import { OpenCode } from "@opencode/client/promise"

// endpoint 的获取方式见第 11 课；这里假设已有 url + password
const client = OpenCode.make({
  baseUrl: "http://127.0.0.1:49374",
  headers: {
    authorization: "Basic " + Buffer.from("opencode:" + password).toString("base64"),
  },
})

// 订阅事件（SSE）
for await (const event of client.event.subscribe()) {
  if (event.type === "server.connected") {
    await client.session.prompt({
      sessionID,
      text: "Explain the repository layout.",
      delivery: "steer",
    })
  }
  if (event.type === "session.execution.succeeded") break
}
```

**要点**

- 先订阅再提交，避免错过早期事件；
- `session.prompt` 返回的是准入结果，不是最终回答；
- 最终结果从事件/消息里取；
- 生产代码应处理 `permission.asked` / `form.created`。

---

## B.12 配置片段

```jsonc
{
  "$schema": "https://opencode.ai/config.json",

  "model": { "providerID": "anthropic", "model": "claude-sonnet-4-5" },

  "permissions": [
    { "action": "*", "resource": "*", "effect": "allow" },
    { "action": "read", "resource": "*.env", "effect": "ask" },
    { "action": "shell", "resource": "git push *", "effect": "deny" }
  ],

  "plugins": [
    "opencode-my-plugin",
    { "package": "opencode-my-plugin", "options": { "level": 2 } }
  ],

  "compaction": { "auto": true, "keep": { "tokens": 20_000 } },

  "skills": ["~/shared-skills"],
  "references": {
    "design-system": { "path": "../design-system" }
  },

  "experimental": { "subagent_depth": 2 }
}
```

**要点**

- 字段名以 `packages/schema/src/config.ts` 为准；
- 旧键会被归一化，但新代码请直接写 V2 键；
- 不确定时用 `opencode debug config` 看最终解析结果。

---

## B.13 调试清单

| 问题 | 检查 |
|---|---|
| 插件没加载 | `opencode plugin list`；看 `Plugin.Info.state` 是否 failed；日志搜 `plugin` |
| 工具没出现 | 是否被 `permissions` 整工具 deny；是否 `codemode` 导致只出现在 `execute` catalog |
| hook 没触发 | domain/name 是否写对；`providerID` 过滤是否把事件筛掉 |
| 请求没变 | 用 `session.context` 还是 `session.model.request`？前者改 system/messages/options |
| 配置没生效 | `opencode debug config` 看最后一份文档 |
| TUI 没刷新 | 客户端是否收到 `server.connected`；SSE 是否断线重连 |
| 服务异常 | `opencode service status`；`opencode api get /api/info` |

---

## B.14 参考顺序

1. 第 06 课：Transform / Hook 的区别与顺序。
2. 第 05 课：Tool/Skill/Agent 的数据结构。
3. 第 02 课：`session.context` 在请求组装的哪一步。
4. 本文件：抄骨架 → 跑起来 → 看日志。
5. `code-navigation.md`：需要深入时再按目录查。

> **版本提醒**：V2 的插件 API 仍在演进。以 `packages/plugin/src/effect/*`
> 的类型定义为准；本文件的示例只保证结构与调用方式正确，具体可选字段可能增加。
