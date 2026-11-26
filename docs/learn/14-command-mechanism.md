# 14. 命令机制：斜杠命令的注册、扩展与执行

> 本课回答一组连环追问：**输入框里敲 `/init`、`/review`、`/commit` 时，到底是谁在响应？
> 扩展命令（`.opencode/command/*.md`）的核心逻辑在哪里？它和内置命令有区别吗？**
> 答案分三层：一张不问出身的注册表（`Command.Service`）、三条装填管线
> （内置 txt / MCP prompt / 用户 md 文件）、两个执行世界（TUI/App 本地命令 vs server 命令）。
>
> 承接 06（Transform/Hook 扩展模型——命令注册表正是 Transform 的典型用户）、
> 13（插件怎么被装上——`Plugin.awaitActivation` 在这里登场）、
> 08（配置来源——md 命令文件的目录就是配置目录）、
> 02 / 03（`session.prompt` 之后的准入与执行链）。

---

## 14.0 全景图：三类命令，两个世界

```
输入框 "/foo bar"
   │
   ├─ ① 客户端本地命令（keymap command，自带 slash 名）
   │     TUI: tui/context/keymap.tsx、tui/routes/session/index.tsx、tui/app.tsx（/new /models /undo /fork …）
   │     App: app/session/commands/use-session-commands.tsx（/new /undo /compact /export /mcp …）
   │     → slash.command.run(input)      纯客户端执行，完全不经过 Command.Service
   │
   └─ ② server 斜杠命令（名字命中 location.command.list）
         HTTP session.command              server/src/handlers/session.ts
           → SessionCommand.execute        core/src/session/command.ts
             Plugin.awaitActivation        （等冷启动的插件把命令注册完）
             instances.provide(session)    （取会话所属 location 的那份 Command.Service）
           → Command.Service.execute       core/src/command.ts（查表 + 调用）
               │
               ├─ 装填管线 A：core/src/plugin/command.ts
               │    init / review           编译进包的 txt 模板
               │    <server>:<prompt>       MCP prompts（运行时拉取）
               │
               └─ 装填管线 B：core/src/config/plugin/command.ts
                    .opencode|~/.config/opencode/{command,commands}/**/*.md
                    （模板求值 + agent/model 覆盖 + subagent 派生）
               │
               └─ 三条管线殊途同归：ctx.session.prompt(...) → inbox → SessionExecution（第 02/03 课）
```

一句话总纲：**注册表只有一张表、一条 `execute` 通道；"内置"与"扩展"的差别只发生在
装填阶段（定义从哪来、模板有哪些能力），不发生在执行阶段。**
真正"另一套"的是 ①客户端本地命令：它操作 UI 与客户端状态，注册在 keymap/command 系统
里，与 `Command.Service` 无关。

---

## 14.1 注册表本体：`core/src/command.ts`

整个命令机制的"内核"不到 100 行，核心是三个类型 + 一个 State：

```ts
// packages/core/src/command.ts
export interface Invocation {
  readonly sessionID: Session.ID
  readonly prompt: PromptInput.Prompt        // { text, files, agents, skills }
  readonly delivery: SessionInbox.Delivery  // "steer" | "queue" | ...
}

export interface Definition {
  readonly name: string
  readonly description?: string
  readonly execute: (input: Invocation) => Effect.Effect<void, unknown>
}

export interface Interface extends State.Transformable<Editor> {
  readonly get: (name: string) => Effect.Effect<Info | undefined>
  readonly list: () => Effect.Effect<Info[]>
  readonly execute: (input: { name, invocation }) => Effect.Effect<void, NotFoundError | ExecutionError>
}
```

`execute` 的全部逻辑就是查表、调用、包错误：

```ts
execute: Effect.fn("Command.execute")(function* (input) {
  const definition = state.get().get(input.name)
  if (!definition) return yield* new NotFoundError({ command: input.name, ... })
  return yield* definition.execute(input.invocation).pipe(
    Effect.tapError((error) => Effect.logError("command execution failed", ...)),
    Effect.mapError((error) => new ExecutionError({ command: input.name, message: errorMessage(error) })),
  )
})
```

两个值得记住的设计：

| 设计 | 含义 |
|---|---|
| `State.create<Map<string, Definition>>` | 注册表是 06 课讲的 Transform 状态：`transform(editor)` 注册一个编辑回调；`reload()` 只是"标记脏"，下一次 `get()` 从空 Map **重放所有已注册 transform** 重建。插件 scope 关闭 = 自动摘除它的注册。 |
| `makeLocationNode`（`Command.node`） | 命令表是 **location 级**的：每个项目目录一份，互不串门。`/foo` 在 A 项目可用不代表 B 项目可用。 |

`notify` 会在每次注册/重载后广播 `command.updated`（`event-logger.ts` 持久化该事件，
客户端靠它刷新 `location.command.list` 缓存——所以改命令文件后补全列表会自己变）。

---

## 14.2 扩展命令的装填管线：`core/src/config/plugin/command.ts`

这就是"扩展 command 命令的核心逻辑"所在，插件 id `opencode.config.command`。

### 来源：config entries（第 08 课的产物）

```ts
const loadEntry = (entry) => {
  if (entry.type === "document")  return [{ commands: entry.info.commands }]   // opencode.json 的 commands 键
  if (entry.type !== "directory") return []
  const commands = yield* loadDirectory(fs, entry.path)                        // 扫 md 文件
  return [{ commands: Object.fromEntries(...) }]
}
```

- **document 条目**：`opencode.json` / `opencode.jsonc` 的 `commands` 字段（`config/normalize.ts`
  还会把旧版 `command` 键归一化进来）。
- **directory 条目**：每个配置目录本身。目录从哪来见第 08 课：
  全局 `~/.config/opencode`、`~/.claude`、`~/.agents`，加上从当前目录**逐级向上**的
  `.opencode` / `.claude` / `.agents`。

### 扫描与解码

```ts
fs.scan("{command,commands}/**/*.md", { cwd: directory, absolute: true, dot: true, symlink: true })
```

每个文件走 `decode()`：`ConfigMarkdown.parseOption` 拆 frontmatter 与正文（正文 trim 后即
`template`），再用 `ConfigCommand.Info`（`schema/src/config/command.ts`）校验：

| 字段 | 类型 | 作用 |
|---|---|---|
| `template` | string（必填） | 命令正文，支持占位符与 shell 插值（14.3） |
| `description` | string? | 补全列表里的一行说明 |
| `agent` | string? | 执行前切换会话 agent |
| `model` | `{ providerID, model, variant? }` | 执行前切换模型 |
| `subagent` | boolean? | 派生子代理会话执行 |
| `subtask` | boolean? | **弃用别名**，等价 `subagent` |

**命名规则**：文件相对路径去掉 `command|commands/` 前缀和 `.md` 后缀。
所以 `command/git/commit.md` → 命令名 `git/commit`（子目录天然当命名空间用）。

### 热重载：一条防抖触发链

```
config.changes()（文件 watch，isCommandSource 过滤只放行 command/commands 下的事件）
ctx.event 的 "config.updated"
        │  两路都 PubSub.publish 到同一个 sliding(1) PubSub（合并触发、天然串行化）
        ▼
Stream.debounce("100 millis")
        ▼
reload = load() → 写 loaded.documents → ctx.command.reload()
        ▼
State 标脏 → 下次 get() 重放全部 transform → notify → command.updated 广播
```

两个工程细节值得抄：

- `PubSub.sliding(1)`：N 个文件同时变动只留一个"还有更新"的信号，reload 天然合并；
- `isCommandSource` 只按**目录前缀**判断（`<root>/{command,commands}` 下）而不看文件后缀——
  目录级事件（重命名）不带具体文件路径。

### 注册位置决定覆盖权：`plugin/internal.ts`

内置 `CommandPlugin` 在 `pre` 清单、`ConfigCommandPlugin` 在 `post` 清单，
都在各自的 `ctx.command.transform` 里 `editor.add({ name, ... })`，而 editor 的 `add`
就是 `map.set(name, definition)`——**后写的赢**。所以：

> 自定义命令与内置命令同名（比如自己写一个 `init.md`）时，**自定义版本覆盖内置版本**。

---

## 14.3 执行语义：`execute` 闭包里发生什么

md 命令注册进表里的 `execute` 是一段 Effect 闭包，按顺序做四件事。

### ① 解析 agent / model 覆盖

`agent` 字段经 `ctx.agent.get` 解析成完整 Agent 信息；`model` 字段优先级高于
command agent 自带的 model。

### ② 模板求值：`evaluateTemplate`

| 写法 | 语义 |
|---|---|
| `$1` `$2` … `$N` | 按位置替换命令参数；**最后出现的那个占位符吃掉全部剩余参数**（`Math.max` 找位置，`args.slice(argIndex).join(" ")`） |
| `$ARGUMENTS` | 用户原始输入整段替换 |
| 都没有 + 有输入 | `模板 + "\n\n" + 输入` 拼接（"没有占位符就当带上下文的追加"） |
| `` !`cmd` `` | **shell 插值**：用 `ShellSelect.resolve({ priority: "config" })` 选出的 shell 真正执行，`cwd` = location 目录，并发度 2，stdout+stderr 合并替换回文本；失败抛 `Shell interpolation failed for ...` |

参数切分 `parseArguments` 与 14.4 的内置命令共用同一套正则（引号成组、`[Image N]` 整体算一个 token）。

### ③ 投递：三条分支

```ts
if (subagent ?? commandAgent?.mode === "subagent") {
  // A. 派生子代理：父会话不被阻塞
  create child session（parentID、title、agent、model）
  → child.prompt("You are a subagent spawned by another session.\n" + text, { resume: false })
  → SubagentJob.start(recovery) + subagents.background(recovery)   // 后台任务见第 12 课
} else {
  // B. agent 覆盖：先切会话的 agent
  if (session.agent !== agent) ctx.session.switchAgent(...)
  // C. model 覆盖：再切模型
  if (model) ctx.session.switchModel(...)
  // 共同终点：把求值后的文本作为 prompt 投进本会话
  ctx.session.prompt({ ...input.prompt, sessionID, text, delivery: input.delivery })
}
```

注意终点永远是 **`ctx.session.prompt`**——命令不是"另一种执行模型"，只是
"一段会把文本送进 inbox 的前置逻辑"。之后的准入、steer/queue、drain 全走第 02/03 课
的既有链路。`delivery` 由客户端请求透传（TUI 提交时的模式），服务端兜底默认 `"steer"`。

---

## 14.4 内置命令与 MCP 命令：`core/src/plugin/command.ts`

同一个 `ctx.command.transform`，注册三类定义：

| 命令 | 模板来源 | execute 做的事 |
|---|---|---|
| `init` | 编译进包的 `plugin/command/initialize.txt` | `${path}` 替换成项目目录 → `append()` 拼用户参数 → `ctx.session.prompt` |
| `review` | `plugin/command/review.txt` | 同上 |
| `<server>:<prompt>` | MCP server 的 prompts | 按位置把用户参数填进 `prompt.arguments` → `mcp.prompt()` 取回消息文本 → 拼接后 `ctx.session.prompt` |

内置命令的参数拼接规则在 `append()`：

```ts
function append(template: string, input: string) {
  const value = input.trim()
  if (template.includes("$ARGUMENTS")) return template.replaceAll("$ARGUMENTS", () => value)
  return [template, value].filter(Boolean).join("\n\n")
}
```

（与 14.3 的规则同源：`$ARGUMENTS` 替换优先，否则整段拼接。）

MCP 命令的细节：

- 命名 `sanitize(server) + ":" + sanitize(prompt)`（非法字符换 `_`），天然与内置/自定义命令错开命名空间；
- `bus.subscribe(Mcp.PromptsChanged)` → 重新 `mcp.prompts()` → `ctx.command.reload()`，
  MCP server 连上/断开命令列表自动增删；
- execute 里 `parseArguments(input.prompt.text)` 按位置映射到 prompt 声明的 arguments，
  缺位补 `""`。

**结论：内置命令与扩展命令的"运行方式"没有任何区别**——同一张表、同一个
`Command.Service.execute`、同一个终点 `session.prompt`。差别全在装填阶段：

| | 内置 `init`/`review` | MCP 命令 | md 扩展命令 |
|---|---|---|---|
| 定义来源 | 包内 txt | MCP server | md 文件 / json `commands` |
| 模板能力 | `${path}`、`$ARGUMENTS` | 参数位置映射 | `$N` / `$ARGUMENTS` / `` !`shell` `` |
| agent/model/subagent | ✗ | ✗ | ✓ |
| 热重载 | 随进程 | `PromptsChanged` | 配置 watch + 100ms 防抖 |
| 可被覆盖 | 可（post 阶段后写覆盖） | —（命名空间隔离） | 可（同为 post，后写覆盖） |

---

## 14.5 入口与路由：从按键到 `session.prompt`

### TUI：`tui/src/component/prompt/index.tsx` 的 submit 顺序

```ts
const slash = argumentSlash(inputText, keymapCommands())   // ① 本地命令（含带参数的 /cd）
if (delivery === "queue" && (store.mode === "shell" || exitWord || slash))
  return toast("This prompt cannot be queued")             //    shell/exit/本地 slash 不允许排队
if (exitWord) return exit()
if (slash) { clearPrompt(); await slash.command.run(slash.input); return true }   // ① 纯本地执行

const slashHead = parseSlashHead(inputText, /\s/)
const isCommand = slashHead && (data.location.command.list(location) ?? [])
  .some((command) => command.name === slashHead.name)      // ② 名字在 server 注册表里
...
} else if (slashHead && isCommand) {
  const send = async () => {
    // 命令继承 composer 的 agent/model 选择；命令自己的覆盖在服务端之后执行
    await commitSelection()
    return client.api.session.command({ sessionID, name: slashHead.name, text: slashHead.arguments,
                                        files: entry.files, agents: entry.agents, skills: entry.skills, delivery })
  }
}
```

顺序就是优先级：**本地命令 > server 命令 > 普通 prompt**。撞名时本地命令先命中，
server 命令根本没机会——这也是 QA 里"插件无法限制 `/new` `/models`"的根源
（它们压根不在 server）。

### App：同构的两条路

- `app/src/composer/model.ts`：补全列表 = `location.command.list(...)`（server 命令）
  `+ command.options`（本地注册的 `useCommand` 选项）合并；
- `app/src/composer/submit.ts`：`findCommand` 命中 server 命令 → `session.api.command(...)`；
  `parseClientSlashCommand`（如 `/btw`）在客户端就地处理。

本地命令的定义处 `app/src/session/commands/use-session-commands.tsx` 集中罗列了
`slash: "new" | "undo" | "redo" | "compact" | "fork" | "export" | "open" | "mcp"`——
想确认某个斜杠命令归属，先查这里和 TUI 的 `slash:` 定义。

### Server 端：`server/src/handlers/session.ts` 的 `session.command`

```
HTTP session.command
  → SessionCommand.execute（core/src/session/command.ts）
      Plugin.awaitActivation   ← 关键
      instances.provide(input.session) → Command.Service（该 location 的那份）
      commands.execute({ name, invocation })
```

`Plugin.awaitActivation`（`core/src/plugin/service.ts`）不是可有可无的等待：**冷
location 的插件是异步激活的**，不等的话早到的请求会看到空注册表，把 `/init` 误报成
"command not found"。session 入口统一在这里等激活收敛（13 课的激活代际）。

错误映射：`Command.NotFoundError` / `Command.ExecutionError` 在 handler 里转成对应的
HTTP 错误（`CommandNotFoundError` / `CommandExecutionError`），客户端拿到的是可展示的
报错而不是 500。

---

## 14.6 三种扩展姿势

### 姿势一：md 文件（零代码，最常用）

`.opencode/command/commit.md`：

```md
---
description: 生成提交信息
agent: build
---
基于以下 diff 生成 conventional commit：

!`git diff --staged`

补充要求：$ARGUMENTS
```

保存即生效（100ms 防抖 reload），`/commit 说明文字` 里 `$ARGUMENTS` 换成"说明文字"。
全局版本放 `~/.config/opencode/command/`，对所有项目可用。

### 姿势二：`opencode.json` 的 `commands` 键

```json
{
  "commands": {
    "commit": {
      "description": "生成提交信息",
      "template": "基于 !`git diff --staged` 生成 conventional commit：$ARGUMENTS"
    }
  }
}
```

字段与 md frontmatter 完全一致（同一张 `ConfigCommand.Info` schema）。

### 姿势三：插件运行时注册（动态命令）

```ts
import { define } from "@opencode/plugin/effect/plugin"
import { Effect } from "effect"

export const Plugin = define({
  id: "my.commands",
  effect: Effect.fn(function* (ctx) {
    yield* ctx.command.transform((editor) => {
      editor.add({
        name: "deploy",
        description: "部署当前分支",
        execute: (input) =>
          ctx.session.prompt({
            ...input.prompt,
            sessionID: input.sessionID,
            text: `请先跑测试再部署 ${input.prompt.text}`,
            delivery: input.delivery,
          }).pipe(Effect.asVoid),
      })
    })
  }),
})
```

插件拿到的 `ctx.command`（`core/src/plugin/host.ts`）只有三个方法：
`list()` / `reload()` / `transform()`——与 14.1 的 `Interface` 一一对应。
`execute` 收到的 `Invocation` 与 server 命令完全同构，所以动态命令能无缝混进
同一个斜杠补全与路由。

---

## 14.7 追问速答

| 追问 | 答案 |
|---|---|
| 我的 `/foo` 提示 command not found？ | 依次查：文件在 `{command,commands}/` 下且后缀 `.md`；frontmatter 字段能过 `ConfigCommand.Info` 校验（类型不对整条丢弃）；目录是配置目录（`.opencode` 等）；是否与本地命令撞名被客户端先行处理。 |
| 改 md 要重启吗？ | 不用。配置 watch → 防抖 100ms → `reload()` → `command.updated`，客户端补全自动更新。 |
| 自定义命令能覆盖 `/init` 吗？ | 能。`ConfigCommandPlugin` 在 `post` 阶段注册，后写覆盖 `pre` 阶段的内置定义。 |
| 命令能带文件、选区、agent、skill 吗？ | 能。`files` / `agents` / `skills` 随提交原样进 `Invocation.prompt`，与普通 prompt 同一准入路径。 |
| 命令执行时用什么模型？ | composer 当前选择先提交（`commitSelection`），命令的 `agent`/`model` 字段在服务端再覆盖。 |
| 命令能排队吗？ | server 命令可以（`delivery: "queue"` 透传给 `session.prompt`）；本地 slash 命令与 shell 模式不能排队（客户端直接拒绝）。 |
| 内置命令和扩展命令的本质区别？ | 没有执行层面的区别，只有装填来源与模板能力的区别（14.4 对比表）。真正的"另一套"是客户端本地命令。 |

---

## 小结

- **内核**：`Command.Service` 一张 per-location 的 `Map<name, Definition>`，
  `execute` 查表调用，`transform/reload` 由 State 驱动。
- **装填**：三条管线（内置 txt、MCP prompts、配置 md/json）全部通过
  `ctx.command.transform` 落进同一张表；post 阶段后写覆盖 pre，自定义可覆盖内置。
- **执行**：殊途同归到 `ctx.session.prompt`——命令是"往 inbox 送文本的前置逻辑"，
  不是第二套执行引擎；`subagent` 分支例外，派生子会话交给 SubagentJob 后台跑。
- **路由**：客户端先匹配本地 keymap 命令（纯本地执行），再查
  `location.command.list` 发 `session.command`；服务端入口先
  `Plugin.awaitActivation` 再查表。

## 参考文件

| 文件 | 职责 |
|---|---|
| `packages/core/src/command.ts` | 命令注册表本体（Definition / execute / State 驱动） |
| `packages/core/src/config/plugin/command.ts` | 扩展命令装填管线（扫描 / 解码 / 热重载 / execute 闭包） |
| `packages/core/src/plugin/command.ts` | 内置 `init`/`review` 与 MCP 命令 |
| `packages/core/src/session/command.ts` | session 入口（awaitActivation + location 定位） |
| `packages/core/src/plugin/internal.ts` | `pre`/`post` 清单（注册顺序 = 覆盖权） |
| `packages/core/src/plugin/host.ts` | 插件侧 `ctx.command` 表面（list/reload/transform） |
| `packages/schema/src/config/command.ts` | `ConfigCommand.Info` 契约 |
| `packages/server/src/handlers/session.ts` / `handlers/command.ts` | HTTP 路由与错误映射 |
| `packages/tui/src/component/prompt/index.tsx` | TUI 提交时的命令判定顺序 |
| `packages/app/src/composer/submit.ts`、`model.ts` | App 侧同构路由与补全合并 |
| `packages/app/src/session/commands/use-session-commands.tsx` | App 本地 slash 命令清单 |
