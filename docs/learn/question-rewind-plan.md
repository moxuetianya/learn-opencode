# 附录：question 决策点作为回溯 / 分叉点（含改答案插件方案）

> 本附录回答一类很实际的需求：
>
> - 模型用 question 工具问「A 还是 B」，我答了 A，干了一段之后想**回到那个提问点重来**，行不行？
> - `/fork` 的候选列表里能不能出现 **question 这个点**？
> - API 层面 `fork` / `revert` 支持把任意消息（含 question 所在的 assistant 消息）当边界吗？
> - 分叉时**只改答案、不重新提问**，能不能做到？
>
> 结论先放这里：
>
> 1. **API 层面已支持**：`fork` / `revert` 的边界参数只校验 `SessionMessage.ID` 类型，不限消息类型；
> 2. 卡点在两处——TUI 的 fork 候选列表**只列 user 消息**；且**问答是同一条 assistant 消息的原子内容**（答案 = tool result）；
> 3. 「保留问题、只换答案」**无法用 fork/revert 边界表达**（边界粒度是消息级）；
> 4. 但可以用插件 `session.hook("context")` 做**模型视图重写**：持久历史不动，模型每次看到的都是改后的答案——本附录给完整方案。

---

## 1. question 工具与回溯原语的现状

### 1.1 内置 question 工具

`packages/core/src/tool/plugin/question.ts`，以内部插件 `opencode.tool.question` 注册：

- 通过 `ctx.tool.transform(editor => editor.add({ name: "question", ... }))` 注册；
- 弹表单（`Form.Service`）→ 答案作为 **tool result** 写回该 assistant 消息；
- 结果文本格式（`toModelContent`）：
  `User has answered your questions: "问题"="答案".`

### 1.2 fork / revert 的边界语义

| 能力 | 入口 | 底层 | 边界语义 |
|---|---|---|---|
| 回滚 | `/undo`、`<leader>u`、消息菜单 Revert | `session.revert.stage({ messageID })` | 提交时删除 `seq >= 边界`（**含边界消息**），恢复其后 assistant 步骤的文件 |
| 分叉 | `/fork`、键位 `session.fork`、消息菜单 Fork、CLI `--fork` | `session.fork({ before: messageID })` | 复制 `seq < 边界` 的历史（"through" 仅在省略 `before` 时 = 全量复制） |

关键代码位置：

- `core/src/session.ts:319` `Session.fork`——边界按 ID 查找，**无类型过滤**；
- `core/src/session/revert.ts` `plan()`——按 seq 定位，**无类型过滤**；
- `core/src/session/projector.ts:759-795`——revert 提交时 `seq >= boundary` 的消息与 inbox 全删；
- `core/src/session/projector.ts:139-153`——fork 复制历史（`before` → `lt(seq)`，`through` → `lte(seq)`）。

对 question 场景的实际含义（时间线 `u1 → a1(提问+答案A) → u2 → a2`）：

- `fork({ before: a1 })` → 新会话历史到 `u1` 为止，**整个问答被丢掉**，继续时模型重新提问；
- 想保留问答、只丢弃其后工作 → `before` 传 a1 的**下一条**消息 ID；
- revert 边界 = a1 → 提交后问答及其后全部删除。

### 1.3 两个时序约束

- **question 表单挂起时 session 处于运行态**：`revert.stage/clear/commit` 返回 `Session.BusyError`（必须先回答或取消）；
- **fork 无忙碌检查**，随时可调（`server/src/handlers/session.ts:225-238` 无 BusyError 分支）。

### 1.4 TUI 是唯一卡点

| 卡点 | 位置 | 现状 |
|---|---|---|
| `/fork` 对话框只列 user 消息 | `tui/src/routes/session/dialog-fork.tsx:63` `.filter((message) => message.type === "user")` | question 的 assistant 消息不在候选列表 |
| 消息菜单 Fork 只对 user 消息生效 | `dialog-message.tsx:83` | 同上 |
| 消息菜单 Revert **无类型限制** | `dialog-message.tsx:45` 直接传 `props.messageID` | 今天就能对 question 消息执行 Revert |

---

## 2. API 支持情况

协议定义（`packages/protocol/src/groups/session.ts`）：

```ts
// :313
HttpApiEndpoint.post("session.fork", "/api/session/:sessionID/fork", {
  payload: Schema.Struct({ before: SessionMessage.ID.pipe(Schema.optional) }),
  error: [SessionNotFoundError, MessageNotFoundError, InvalidRequestError],
})

// :535
HttpApiEndpoint.post("session.revert.stage", "/api/session/:sessionID/revert/stage", {
  payload: Schema.Struct({ messageID: SessionMessage.ID, files: Schema.Boolean.pipe(Schema.optional) }),
  error: [MessageNotFoundError, SessionNotFoundError, SessionBusyError, UnknownError],
})
```

调用示例：

```sh
# 1. 定位 question 点：assistant 消息 content[] 里
#    type: "tool" && name: "question" && state.status: "completed"
#    （state.input.questions 是问题，state.metadata.answers 是答案）
opencode api get /api/session/ses_xxx/context

# 2a. 在该点前分叉
opencode api post /api/session/ses_xxx/fork \
  --data '{"before": "msg_question所在消息ID"}'

# 2b. 或把回滚边界 stage 到该消息（session 空闲时）
opencode api post /api/session/ses_xxx/revert/stage \
  --data '{"messageID": "msg_question所在消息ID"}'
```

字段勘误：tool part 的工具名字段是 **`name`**（`schema/src/session-message.ts:162` `AssistantTool`），
判断条件 `part.type === "tool" && part.name === "question"`。

---

## 3. 为什么「分叉时改答案」做不到（以及替代层级）

**fork 改不了答案**的四个原因：

1. 答案物理上内嵌在 assistant 消息里：`AssistantTool` part 的 `state.content`，由持久事件 `session.tool.*` 投影而成，fork 按 `seq` 原样复制消息行；
2. 消息 API 全是只读（`session.message.get/list`、`session.context` 均 GET），不存在 message PATCH/PUT；`session.update` 只改 session 的 title/metadata/permissions；
3. ACP `session/load` 按 sessionId 取回已存会话再回放（`cli/src/acp/service.ts:148` + `ACPReplay.history`），不接受客户端改写的 transcript；
4. 持久事件流 append-only，无公开 API 重写。

三个替代层级：

| 层级 | 做法 | 效果 | 缺点 |
|---|---|---|---|
| ① 重新回答 | `fork({ before: a1 })` 丢掉整个问答 | 模型下轮重新问，你再答 | 模型重新生成的问题可能措辞不同 |
| ② 纠正式 prompt | fork 保留问答后追加「改选 B，按 B 继续」 | 模型看到 A 和纠正并存 | 不是干净重写 |
| ③ **插件视图重写** | `session.hook("context")` 改写模型可见的 tool result | 持久历史不动，**模型每次看到的都是 B** | UI 仍显示 A（见 §5 限制） |

---

## 4. 关键机制依据（方案的地基）

| 机制 | 位置 | 对方案的含义 |
|---|---|---|
| fork 复制消息时**消息行 ID 重造**，消息内容原样复制 | `projector.ts:218`（`forkEventID_seq`）、`:224`（`data: row.data`） | **匹配键必须用 tool call ID（part.id），不能用 messageID**；callID 在 fork 中稳定 |
| 本地工具（question）的 tool-result 在模型消息里是**独立 `role: "tool"` 消息**，不在 assistant 消息内 | `core/src/session/runner/to-llm-message.ts:194,216-227` | 重写要扫**所有 role** 的消息，靠 part.id 关联 call 与 result |
| question 工具结果恒为单条 text | `to-llm-message.ts:130-139` → `result: { type: "text", value }` | 只需替换 `result.value` 字符串 |
| primary 请求走 `session.hook("context")`，**compaction 走 `session.hook("compaction")`** | `core/src/session/model-request.ts:425-426` | 两个 hook 都要挂，否则压缩摘要基于旧答案 |
| 插件域可用：`storage`、`rpc.register`、`session.context`、`session.hook` | `plugin/src/promise/*.ts` | 齐全，无需改 core |
| `.opencode/plugins/` 下自动加载 | docs/plugins | 无需改 `opencode.json` |

---

## 5. question-rewind 插件完整方案

### 5.1 架构与数据流

```
[客户端脚本]                        [插件 question-rewind]              [core]
     │                                    │                              │
     │ 1. session.context({sessionID}) ───┤ (RPC list 也能干这事)        │
     │    找 question 决策点 + 边界        │                              │
     │ 2. POST /session/:id/fork ─────────────────────────────────────→ │ 复制历史到新会话
     │    （before = 问答后那条消息）      │                              │
     │ 3. rewind.set({forkID, callID,     │                              │
     │    answers:["B"]}) ───────────────→│ storage: qr:<sid>:<callID>   │
     │ 4. 在 fork 里发 prompt ─────────────────────────────────────────→ │ 组装请求
     │                                    │← hook("context"/"compaction")│
     │                                    │ 把 tool-result 的 value       │
     │                                    │ 替换为 "User has answered     │
     │                                    │  ...=\"B\"."                  │
     │                                    └────────────────────────────→ │ 模型只见过 B
```

### 5.2 文件结构

```
.opencode/plugins/question-rewind/
├── rpc.ts      # RPC 契约（独立文件，客户端脚本也要 import 它）
└── index.ts    # 插件本体
scripts/question-rewind.ts   # 客户端编排脚本（fork + set + 提示）
```

### 5.3 rpc.ts

```ts
import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

const Point = Schema.Struct({
  callID: Schema.String,
  messageID: Schema.String,
  questions: Schema.Array(Schema.String),
  answers: Schema.Array(Schema.String),
  overridden: Schema.Boolean,
  overrideAnswers: Schema.Array(Schema.String).pipe(Schema.optional),
})

export const Rewind = Rpc.define({
  id: "question.rewind",
  methods: {
    /** 列出会话中的全部 question 决策点及 override 状态 */
    list: {
      input: Schema.Struct({ sessionID: Schema.String }),
      output: Schema.Struct({ points: Schema.Array(Point) }),
    },
    /** 为某个决策点设置/更新答案 override */
    set: {
      input: Schema.Struct({
        sessionID: Schema.String,
        callID: Schema.String,
        /** 第 i 项对应第 i 个问题；多选答案用 ", " 连接 */
        answers: Schema.Array(Schema.String),
      }),
      output: Schema.Struct({ ok: Schema.Boolean }),
      errors: { not_found: Schema.Struct({ callID: Schema.String }) },
    },
    clear: {
      input: Schema.Struct({ sessionID: Schema.String, callID: Schema.String }),
      output: Schema.Struct({ ok: Schema.Boolean }),
    },
  },
  events: {
    changed: { schema: Schema.Struct({ sessionID: Schema.String, callID: Schema.String }) },
  },
})
```

### 5.4 index.ts

```ts
import { Plugin } from "@opencode/plugin"
import { Rewind } from "./rpc.js"

const key = (sessionID: string, callID: string) => `qr:${sessionID}:${callID}`

// 与内置 question 工具的 toModelContent 完全同格式，模型无从分辨
const answerText = (questions: string[], answers: string[]) =>
  `User has answered your questions: ${questions
    .map((q, i) => `"${q}"="${answers[i]?.length ? answers[i] : "Unanswered"}"`)
    .join(", ")}.`

// —— 决策点扫描：读投影历史（插件安装前的旧会话同样有效）——
async function scanPoints(ctx: PluginContext, sessionID: string) {
  const messages = await ctx.session.context({ sessionID })
  const points: Array<{ callID: string; messageID: string; questions: string[]; answers: string[] }> = []
  for (const message of messages) {
    if (message.type !== "assistant") continue
    for (const part of message.content) {
      if (part.type !== "tool" || part.name !== "question") continue
      if (part.state.status !== "completed") continue
      const input = part.state.input as { questions?: Array<{ question: string }> }
      const metadata = part.state.metadata as { answers?: string[][] } | undefined
      points.push({
        callID: part.id,
        messageID: message.id,
        questions: (input.questions ?? []).map((q) => q.question),
        // question 工具把答案写进了 result metadata（core/tool/plugin/question.ts:109）
        answers: (metadata?.answers ?? []).map((a) => a.join(", ")),
      })
    }
  }
  return points
}

export default Plugin.define({
  id: "question-rewind",
  async setup(ctx) {
    // —— RPC 面 ——
    const registration = await ctx.rpc.register(Rewind, {
      list: async ({ sessionID }) => {
        const points = await scanPoints(ctx, sessionID)
        return {
          points: await Promise.all(
            points.map(async (point) => {
              const override = (await ctx.storage.get(key(sessionID, point.callID))) as
                | { answers?: string[] }
                | undefined
              return {
                ...point,
                overridden: override !== undefined,
                ...(override?.answers ? { overrideAnswers: override.answers } : {}),
              }
            }),
          ),
        }
      },
      set: async ({ sessionID, callID, answers }, callCtx) => {
        const points = await scanPoints(ctx, sessionID)
        if (!points.some((point) => point.callID === callID))
          return callCtx.error.not_found({ callID })
        await ctx.storage.set(key(sessionID, callID), { answers })
        await registration.events.emit("changed", { sessionID, callID })
        return { ok: true }
      },
      clear: async ({ sessionID, callID }) => {
        await ctx.storage.remove(key(sessionID, callID))
        await registration.events.emit("changed", { sessionID, callID })
        return { ok: true }
      },
    })

    // —— 视图重写：primary 与 compaction 两条请求路径都要挂 ——
    // （model-request.ts:425-426：primary→"context"，compaction→"compaction"）
    const rewrite = async (event: { sessionID: string; messages: Array<{ content: Array<any> }> }) => {
      const prefix = `qr:${event.sessionID}:`
      const scan = await ctx.storage.scan({ prefix, limit: 100 })
      if (scan.entries.length === 0) return
      const overrides = new Map<string, string[]>(
        scan.entries.map((entry) => [
          entry.key.slice(prefix.length),
          (entry.value as { answers: string[] }).answers,
        ]),
      )
      // 先全量收集 question 调用的 input（tool-call part 在 assistant 消息里，
      // tool-result part 在独立 tool 角色消息里，靠 id 关联——to-llm-message.ts:194,227）
      const questionsById = new Map<string, string[]>()
      for (const message of event.messages)
        for (const part of message.content)
          if (part.type === "tool-call" && part.name === "question")
            questionsById.set(
              part.id,
              ((part.input as { questions?: Array<{ question: string }> }).questions ?? []).map((q) => q.question),
            )
      for (const message of event.messages)
        for (const part of message.content) {
          if (part.type !== "tool-result" || part.name !== "question") continue
          const override = overrides.get(part.id)
          if (!override) continue
          // question 的结果恒为单条 text（to-llm-message.ts:134-135）
          if (part.result.type === "text")
            (part.result as { value: string }).value = answerText(questionsById.get(part.id) ?? [], override)
        }
    }
    await ctx.session.hook("context", rewrite)
    await ctx.session.hook("compaction", rewrite)
  },
})
```

> 注：`scanPoints` 的 `ctx` 参数类型写法示意（`PluginContext`），实现时用 `setup(ctx)` 推断类型内联即可。

### 5.5 客户端编排脚本

```ts
import { OpenCode } from "@opencode/client/effect"
import { Rewind } from "../.opencode/plugins/question-rewind/rpc.js"
import { Effect } from "effect"
import { FetchHttpClient } from "effect/http"

const program = Effect.gen(function* () {
  const client = yield* OpenCode.make({ baseUrl: "http://localhost:4096" })
  const rewind = client.rpc(Rewind)
  const sessionID = "ses_xxx"          // 原会话
  const newAnswer = "B"                // 改后的答案

  // 1. 找决策点：取最后一个 question 点
  const { points } = yield* rewind.list({ sessionID })
  const point = points.at(-1)
  if (!point) return "no question point"
  // 2. fork：边界 = 问答消息的下一条（保留问答、丢弃其后引用旧答案的历史）
  //    若问答是最后一条消息，省略 before（全量复制）
  const context = yield* client.session.context({ sessionID })
  const index = context.findIndex((m) => m.id === point.messageID)
  const boundary = context[index + 1]?.id
  const fork = yield* client.session.fork({ sessionID, ...(boundary ? { before: boundary } : {}) })
  // 3. 对 fork 设置 override（callID 在 fork 复制中保持不变）
  yield* rewind.set({ sessionID: fork.id, callID: point.callID, answers: [newAnswer] })
  // 4. 在 fork 里继续推进
  yield* client.session.prompt({ sessionID: fork.id, /* ... */ })
  return `forked to ${fork.id}, answer rewritten to "${newAnswer}"`
})

await Effect.runPromise(program.pipe(Effect.provide(FetchHttpClient.layer))).then(console.log)
```

手动版（不写脚本）：TUI `/fork`（选问答前的 user 消息）→ 对新会话调 `rewind.set` → 直接继续聊。

### 5.6 验证清单

1. `bun run check`（根目录）确认插件文件过类型检查；
2. `bun run dev:live` 起 TUI + service，问一个会产生 question 的问题并作答；
3. 跑 `scripts/question-rewind.ts`，确认输出 fork ID；`rewind.list` 显示 `overridden: true`；
4. 在 fork 里继续 prompt，观察模型行为按新答案走；打开原会话确认无变化；
5. 触发一次 `/compact`，确认摘要基于新答案（验证 `compaction` hook 生效）。

### 5.7 已知限制

1. **UI 不显示改写**：TUI / 导出 / context API 里仍是原答案。要可视化需再做 TUI 插件订阅 `changed` 事件；
2. **压缩吸收**：问答 tool part 被摘要替代后，可重写的原文不在了，override 自然失效（摘要本身已带新答案，通常无害）；
3. **边界选错会自相矛盾**：若 fork 保留了问答之后引用旧答案 A 的消息，模型会同时看到「答案 B」和「按 A 做的后续」——脚本里已用 `context[index+1]` 规避；
4. **provider prompt cache 失效**：重写改变了消息内容，缓存命中下降，属预期成本；
5. 多选答案在 `set` 里按问题顺序传数组，脚本示例只覆盖单选场景。

### 5.8 如果要「持久化的答案重写」

需要动 core：新增类似 `session.message.patched` 的持久事件 + 投影处理 + message 编辑端点，fork 才能复制改写后的历史。事件溯源的不可变历史是 V2 的设计基线（`04-v2-session-core-map.md`），属架构级改动，量级远大于插件方案。

---

## 6. 相关阅读

- 边界与投影细节：[10-storage-sqlite.md](./10-storage-sqlite.md)（事件溯源）
- 插件加载与 hook：[06-hook-mechanism.md](./06-hook-mechanism.md)、[13-plugin-loading-pipeline.md](./13-plugin-loading-pipeline.md)
- 请求组装链路：[02-conversation-agent-loop.md](./02-conversation-agent-loop.md)
- revert/fork 对指令状态的影响：[instruction-delta-and-cache.md](./instruction-delta-and-cache.md)
