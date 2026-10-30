# 附录：指令变更如何进入会话（Instruction Delta 与 Prompt Cache）

> 本附录回答一类很实际的问题：
>
> - 改了 `AGENTS.md`，**重新打开一个历史会话**，改的规则会生效吗？
> - 生效的话，是不是等于**把 prompt cache 全部打掉了**？
> - 全局 skill 的改动是不是同样的逻辑？改 `description` 和改 `SKILL.md` 正文一样吗？
> - 为什么模型会收到一段 `<system-update> ... diff ...`？
>
> 结论先放这里：
>
> 1. **会生效**，而且是**同一种机制**（AGENTS.md、skill 列表、MCP guidance、日期、环境…全部走同一条管线）；
> 2. **不会打掉缓存**——改动不是"重写 system prompt"，而是在历史末尾**追加一条增量消息**；
> 3. 但**技能的"列表"和"正文"走的是两条路**：列表属于指令源（有增量），正文是工具结果（落进历史，不回溯）。

第 5 课 [5.5](./05-agent-core.md) 讲了 Instructions 的数据结构，本附录讲**运行时语义**：
一次 `prepare` 到底做了什么、状态存在哪、什么时候重算、缓存账怎么算。

---

## 1. 四种注入形态，先分清

模型看到"规则"有四种途径，缓存行为完全不同：

| 形态 | 落到哪 | 例子 | 改动后 |
|---|---|---|---|
| **① 基线（baseline）** | 每请求重发的 system part | AGENTS.md 初始内容、`<available_skills>` | 不变（字节稳定） |
| **② 增量（delta）** | 追加到历史的一条消息 | `<system-update>` 的 diff / 新 skill 公告 | 只追加，前缀不动 |
| **③ 事件型 synthetic** | 追加到历史的消息 | 读文件时发现的嵌套 AGENTS.md | 不回溯 |
| **④ 工具结果** | 历史里的 tool result | `skill` 工具加载的正文、`read` 的内容 | 不回溯，下次重读才更新 |

关键：**①②是同一个开关的两面**。会话建立时把当前值冻结成"基线"，之后每次发现不一致，只发"差量"。

---

## 2. 状态存在哪：会话级的 instruction 账本

`packages/core/src/session/sql.ts` 里两张表：

```
InstructionStateTable   每个 session 一行
  session_id
  epoch_start           本"纪元"起点 seq
  through_seq           已应用到哪个 seq
  initial_values        { key → hash }   基线（每请求重发的那份）
  current_values        { key → hash }   当前最新值

InstructionBlobTable    内容按 hash 去重存
  hash  value(json)
```

要点：

- 存的是 **hash 引用**，不是全文；内容进 blob 表按内容寻址，天然去重；
- `initial_values` 和 `current_values` 分开，才可能"基线不动、只发增量"；
- 内容 hash 用**规范化 JSON**（`canonical()` 排序 key 再 `sha256`），所以键顺序变化不误判。

---

## 3. 一次 `prepare`：整条管线的入口

`SessionRunner.prepareContext`（`session/runner/llm.ts`）在每个"准入边界"（收到用户输入、或 step 间重新取上下文）跑一次：

```ts
const selected = yield* context.select(sessionID)
// A blocked initial instruction baseline must leave admitted input pending.
yield* InstructionState.prepare(db, bus, selected.instructions, sessionID)
```

`prepare` = `observe` + `commit`：

```
observe()
  ├─ Instructions.read(sources)         ← 逐源读"当前值"（读盘/读注册表）
  └─ find(db, sessionID)                ← 取会话账本
       └─ diff(observed, current_values)
            └─ { delta: {key → hash}, blobs }

commit()
  ├─ delta 为空且非首次 → 直接返回（零成本）
  ├─ 非首次 → renderUpdateText()        ← 只渲染变化的那几个 key
  └─ bus.publish(SessionEvent.InstructionsUpdated, { delta, text })
```

`text` 是**发布时就渲染好并冻住**的（schema 注释："The rendered chronological update shown to the model, frozen at emit time"）。
原因很实在：以后重放要能重建同一条消息，而当时那些指令源（尤其是 Location 作用域的）可能早就不在了。

projector 收到事件后 `InstructionState.apply()` 更新 `current_values`。

---

## 4. 渲染层：diff 还是全文？

每个源自己决定"变化后怎么讲"。两种策略：

### 4.1 AGENTS.md：尽量给 unified diff

`instruction-discovery.ts` 的 `renderUpdate`：

```ts
const patch = createPatch(after.path, before.content, after.content, "", "", { context: 3 })
const diff = ["The instructions from ${after.path} changed. Here's the diff:", "```diff", ...].join("\n")
const replacement = `The instructions changed:\n${render([after])}`
return diff.length < replacement.length ? diff : replacement
```

规则很朴素：**diff 比全文短就给 diff，否则给全文**（3 行上下文）。
你现在读到的这段就是它产出的：

```diff
@@ -2,8 +2,7 @@
```

同时处理三种变化：`removed` → "The instructions from X no longer apply."；`added` → 全文；
`changed` → diff / 全文二选一。

### 4.2 Skill 列表：加/删给增量，改描述给全文

`skill/instructions.ts` 的 `update()` 更讲究一点：

| 变化 | 渲染 |
|---|---|
| 只有新增 | "New skills are available in addition to those previously listed:" + 仅新增条目 |
| 只有删除 | "The following skill IDs are no longer available and must not be used: a, b" |
| 任一 **description/name 改变** | 全文重述整张列表（"This list supersedes the previous available skills list."） |
| 空 diff（仅顺序变化等） | 全文重述 |

注意最后那条：`diffByKey` 按 `id` 比较 `name`/`description`，一旦有字段变化就退回全文——
因为"某条描述变了"很难用一句话讲清，模型也可能误以为是另一个技能。

### 4.3 那层 `<system-update>` 壳是哪来的

增量在会话里是一条 `Message.system(text)`（`runner/to-llm-message.ts` 的 `case "system"`）。
但**不是所有 provider 都支持"中途出现的 system 消息"**，于是 `packages/ai/src/protocols/shared.ts` 做降级：

```ts
export const wrapSystemUpdate = (parts) =>
  `<system-update>\n${escapeSystemUpdateText(joinText(parts))}\n</system-update>`
```

注释把意图写得很清楚：**"remains visibly lower-authority user text, preserves the original temporal
position, and XML-escapes content so it cannot close the wrapper."**

也就是三重保证：

1. 降级成 user 角色后，**权限不越级**（指令内容不该借此获得 system 特权）；
2. **时序位置不变**——它就在它该在的那一轮之前，不会被挪到开头；
3. **XML 转义**——内容里写了 `<system-update>` 也关不掉包裹。

这就是你在会话里看到 `<system-update> ... diff ...` 的全部原因：它是**增量消息的降级外壳**，
不是某种"系统重启"。

---

## 5. 重新打开历史会话，到底发生什么

这是本附录的出发点。完整时序：

```
恢复会话 → 用户发第一条新输入
  → prepareContext
      → 逐源读当前磁盘/注册表状态            （此时读到"新"的 AGENTS.md / skill 列表）
      → 与 DB 里 current_values 比对
      → 不同 → 发布 InstructionsUpdated(text=diff)
  → history.entriesForRunner
      → initial = InstructionState.initial()  ← 从 DB 的 initial_values 取，不读盘
      → entries = messageEntries()            ← 含刚追加的那条 update
  → baseTranscript: system = [agent.system, initial] ; messages = entries
```

三个结论：

1. **基线来自 DB，不来自磁盘。** 所以恢复会话时 system prompt 的字节内容与当初完全一致；
2. **磁盘上的变化只体现为一条追加消息**，位置在历史末尾（pending input 之前）；
3. 因此 provider 侧的前缀缓存（system + 已有多轮）**继续命中**，只有新尾部重新计费。

对比一下"反事实设计"：如果每次都从磁盘重建 system prompt，那改一个字符就等于全量重算——
V2 明确避开了这条路，`session/context.ts` 里就写着这个意图：

```ts
// Ordered from most to least shared across sessions so the baseline stays a reusable
// prompt-cache prefix: user-level catalog and guidance, then project instructions, then
// the date and environment, which vary by day and directory.
instructions: Instructions.combine([
  CodeModeInstructions.make(...),  // 最"跨会话共享"
  loaded.mcp,
  loaded.references,
  loaded.skills,
  loaded.discovery,                // AGENTS.md
  loaded.builtins,                 // 日期、环境
  loaded.entries,                  // 会话级 API 注入，最私密
])
```

这个排序不只是"先放稳定的"：源之间的**顺序决定谁在增量里先出现**，越靠前越稳定。
顺带一提，**日期本身也是一个指令源**（`core/date`）。跨天恢复会话时，模型收到的是
"Today's date is now: ..."，而不是基线被重写——同一个机制。

---

## 6. 各指令源的变更检测矩阵

这是最容易踩坑的部分，因为**检测能力并不统一**：

| 源 | key | 变更检测 | 说明 |
|---|---|---|---|
| 全局 `~/.config/opencode/AGENTS.md` | `core/instructions` | **自动** | watcher 订阅该文件，100ms debounce |
| 工作区 → 项目根/家目录的 AGENTS.md | `core/instructions` | **自动** | 启动时枚举祖先目录，逐个 `watcher.subscribe` |
| **工作区之下**的嵌套 AGENTS.md | `core/instructions` → synthetic | **不自动** | 读文件时发现才注入，之后改文件不再感知 |
| `instructions[]` 配置（文件/glob/URL） | 同上 | 自动（新 glob 匹配需配置变更） | ⚠️ 本 checkout（2.0.24）只有 schema + normalize，**未见消费点**；已发布版按文档生效 |
| skill 列表（id/name/description） | `core/skill-guidance` | **自动** | 每次 `load()` 从注册表实时构造 |
| skill **正文** | — | — | 走工具结果，不参与 diff |
| MCP guidance | `core/mcp-guidance` | 自动 | 取决于 MCP 连接与工具集 |
| references | `core/reference-guidance` | 自动 | |
| Code Mode guidance | `core/codemode` | 自动 | 取决于工具目录 |
| 日期 / 环境 | `core/date` / `core/environment` | 自动 | 跨天、换目录时会发增量 |
| 会话级 entries（API `put`） | `api/<key>` | 自动 | 有 `changed`/`removed` 渲染 |

### 6.1 为什么嵌套 AGENTS.md 不自动

看 `config/plugin/instruction.ts`：watcher 订阅的是**构造时算出来的候选集**——

```ts
const candidates = [
  ...(discovery.global ? [globalFile] : []),
  ...(project ? ancestorDirectories(start, stop).map(d => join(d, "AGENTS.md")) : []),
]
```

只有"全局 + 从工作区向上到 root"这条链。工作区**下面**的文件不在里面，它们是在 `read` 工具成功之后
被顺带发现的（`tool/plugin/read.ts`），走另一条路：`SessionInstructions.load()`
发一条 `session.synthetic` 消息，并把已注入的路径记进消息 `metadata.instruction.paths` 作为账本。

所以：

- 嵌套文件**只会注入一次**，改内容不会触发更新；
- 但**如果这条 synthetic 从可见历史里消失**（compaction / revert），账本失效，
  下次读到该区域会**重新注入当前版本**——这是有意的恢复语义；
- 需要立刻生效：**开新会话**（官方文档也是这么说的）。

---

## 7. 缓存账怎么算

把一次请求的 prompt 拆开看：

```
[ agent.system ][ instruction baseline ][ 历史消息 …… ][ 本次增量 update ][ 新输入 ]
  └────────────── 稳定前缀，命中缓存 ──────────────┘ └──── 新增 ────┘
```

| 改动 | 影响 | 代价 |
|---|---|---|
| AGENTS.md 全局/祖先内容 | 追加一条 diff | ≈ diff 长度 |
| skill `description` 改动 | 追加"全文重述列表" | 整个列表长度（比 diff 贵） |
| 新增 / 删除 skill | 追加"仅新增条 / 仅删除 ID" | 很小 |
| skill 正文 | 无（已在历史里） | 0 |
| 嵌套 AGENTS.md | 无（不检测） | 0 |
| 改 `agent.system`（agent 定义、系统提示模板） | **基线变了** | ⚠️ 见下 |

**唯一真正的"基线变化"是 `agent.system` 那一半**：`baseTranscript` 里
`system = [agent.system ?? SessionSystemPrompt.make(toolNames), initial]`。
agent 定义（`.opencode/agent/*.md`）、系统提示模板选择、**工具集合**都参与这段文本的生成，
它们不走 instruction delta。所以切换 agent、增删工具、换模型模板，是会动前缀的。

> 实践中还有一个隐性来源：Code Mode 的 `tools` 定义本身也在请求里。V2 特意"最后一步也保留工具定义"
> （`runner/llm.ts` 注释 "Keep tool definitions on the final Step to preserve the provider's cached prefix"），
> 就是为了不让末尾的 step 破坏缓存。

---

## 8. 四个"基线操作"

除了"检测到变化"，还有几种操作会显式改写账本：

| 操作 | 代码 | 对账本的作用 |
|---|---|---|
| **Compaction 完成** | `projector` → `advanceEpoch` | `initial_values := current_values`，纪元起点前移：压缩后的新基线**已包含**之前所有增量，历史里的 update 消息被退休 |
| **Revert 提交** | `projector` → `reset` | 整行删除；下次 `prepare` 当首次处理，**重建基线**（因为历史被截断了） |
| **Fork** | `Forked` 事件携带 `instructions: Values` + `instructionEntries` | 子会话基线**直接继承父会话当前值**，不会把同样的规则再讲一遍 |
| **Move 到别的目录** | `session/move.ts`（不改账本） | 账本保留；目的地的新 AGENTS.md 以**增量**形式引入 |

Compaction 这一条值得单独记住：压缩时摘要 prompt 明确要求
"Leave out instructions and setup the assistant was given rather than told by the user:
repository conventions, instruction files such as AGENTS.md, and environment details"——
**因为指令会在压缩后以基线形式重新出现**，没必要写进摘要（写了还会随着更新不断堆积）。

---

## 9. 实践结论

给日常使用和写文档/技能的人：

1. **改 AGENTS.md 不用重开会话**，下一轮就生效，缓存几乎无损；
2. **改 skill 正文最便宜**（0 缓存成本），但要**重新加载**才生效——历史里的旧正文不会变；
3. **改 skill `description` 偏贵**（触发全文重述）。这类元数据最好在自然断点改：新会话、或 `/compact` 之后；
4. **改嵌套 AGENTS.md（工作区以下）必须开新会话**，否则模型看不到；
5. **需要"彻底重置"时**：`/compact`（基线前移）或新会话；`revert` 也会导致重建；
6. **不要频繁调 `agent.system` / 工具集**——那是真的动前缀，比改指令贵得多。

反过来说，看到模型收到 `<system-update>` 不必惊讶：那就是差量在正常工作，
**不是**"上下文被重写"，更不是"缓存失效"。

---

## 10. 代码索引

| 关注点 | 位置 |
|---|---|
| 指令代数（read / diff / render） | `packages/core/src/instructions/index.ts` |
| 会话账本（observe / commit / apply / reset / advanceEpoch） | `packages/core/src/session/instruction-state.ts` |
| AGENTS.md 发现与 watcher | `packages/core/src/config/plugin/instruction.ts` |
| AGENTS.md 增量渲染（unified diff） | `packages/core/src/instruction-discovery.ts` |
| skill 列表源与增量渲染 | `packages/core/src/skill/instructions.ts` |
| 嵌套 AGENTS.md 注入（synthetic + 账本） | `packages/core/src/session/instructions.ts`、`tool/plugin/read.ts` |
| 管线触发点 | `packages/core/src/session/runner/llm.ts`（`prepareContext`） |
| 基线 + 历史组装 | `packages/core/src/session/history.ts`（`entriesForRunner`）、`session/model-request.ts`（`baseTranscript`） |
| 源的组合顺序 | `packages/core/src/session/context.ts`（`select`） |
| 账本变更（compaction / revert / fork） | `packages/core/src/session/projector.ts` |
| 事件与冻结文本 | `packages/schema/src/session-event.ts`（`InstructionsUpdated`、`Forked`、`Skill.Activated`） |
| 数据库表 | `packages/core/src/session/sql.ts`（`InstructionStateTable`、`InstructionBlobTable`） |

> `Skill.Activated` 也带 `text`：技能正文**随事件持久化**，
> 所以恢复会话时读到的是"当时加载的那份"，而不是磁盘上的当前版本。
> 这与"正文走工具结果、不回溯"是同一件事的两个侧面。
