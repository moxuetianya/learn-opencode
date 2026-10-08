# 7. 配置加载全景：何时、何地、哪些文件、谁覆盖谁

> 本课把 v2 的"配置"彻底摊开：配置在哪个进程、哪个时刻加载；`opencode.jsonc`、`tui.json`/`cli.json`、各种状态文件各自的分工；9 层合并顺序的权威表格；以及 v2 原生配置的降级（lowering）机制。承接第 5 课 §5.4（启动链路中的配置装配），本课是配置专题的完整版。
>
> **版本对照**：本仓库 `dev` 分支与官方 v2.0.7 release 在文件命名上有少量漂移（`tui.json` → `cli.json`、`server.json` → `service.json`），文中会逐处标注。机制本身一致。

## 7.0 先分清三个世界：配置、偏好、状态

很多人把"配置"混成一团，实际上 v2 里有三类持久化数据，**加载的进程、时机、方式完全不同**：

```
┌─────────────────────────────────────────────────────────────────────┐
│ ① Agent/Server 配置   opencode.jsonc / opencode.json                │
│    决定 agent、model、provider、mcp、permission、plugin 等行为       │
│    → server 进程加载（懒加载，按 directory 实例缓存）                │
├─────────────────────────────────────────────────────────────────────┤
│ ② 客户端偏好          tui.json (dev) / cli.json (v2.0.7 release)    │
│    theme、keybinds、mouse、scroll、diffs、session 显示              │
│    → client 进程（TUI/CLI）自己加载，从不发到 server                │
├─────────────────────────────────────────────────────────────────────┤
│ ③ 运行状态            model.json / auth.json / service.json / ...   │
│    最近用的模型、API key、后台服务注册表、输入历史                   │
│    → 各自的读写方在特定时机读写，不是"配置"，是状态                  │
└─────────────────────────────────────────────────────────────────────┘
```

用户常问的"cli.json 是干嘛的"就属于②：它是 **v2.0.7 release 里客户端（TUI）偏好的文件**，与 agent 行为无关。本仓库 dev 分支对应的文件叫 `tui.json`（由 `TuiConfig` 加载，见 §7.2.2）。

## 7.1 何时、何地加载

### 7.1.1 server 侧：懒加载 + 按 directory 缓存

配置加载**不在进程启动时**，而在**第一个针对某目录的请求到达时**（第 5 课 §5.3）：

```
HTTP 请求（带 directory）
  → WorkspaceRoutingMiddleware        解析 ?directory= / x-opencode-directory 头
  → InstanceContextMiddleware         middleware/instance-context.ts:23-35
  → InstanceStore.load({directory})   project/instance-store.ts:108-124
  → InstanceBootstrap.run             project/bootstrap.ts:32-46
       ├─ yield* config.get()         bootstrap.ts:36  ← 配置在这！急切加载
       └─ yield* plugin.init()        bootstrap.ts:38  ← 插件可以改写 config，必须最早
```

两个设计点：

- **每个目录一份实例**：合并结果缓存在 `InstanceState.make<State>(...)`（`config/config.ts:619-623`，底层是 `effect/instance-state.ts` 的 `ScopedCache`，按 `ctx.directory` 键控）。同一 server 打开两个项目目录 = 两份独立解析的配置。
- **全局层进程级缓存**：`loadGlobal` 的结果用 `Effect.cachedInvalidateWithTTL` 缓存（`config.ts`，`Config.invalidate()` 或 worker 的 `rpc.reload` 时失效）——多个目录实例共享一次全局配置读取。

`InstanceContext = { directory, worktree, project }`（`project/instance-context.ts:5-9`）：项目级配置向上搜索的边界是 **git worktree 根**；非 git 目录 `worktree = "/"`。

### 7.1.2 client 侧：TUI 偏好在客户端进程解析

- 老 TUI（`packages/opencode`）：`cli/cmd/tui.ts:231` 调 `TuiConfig.get()`，结果通过 `<TuiConfigProvider>` 注入 Solid 树（`packages/tui/src/app.tsx:296`）。
- 新 v2 CLI（`packages/cli`）：`src/tui.ts:8` 在**客户端进程**里 `TuiConfig.resolve({})`——注意它压根不问 server。
- v2.0.7 release 对应文件是 `~/.config/opencode/cli.json(c)`，`$schema` 为 `https://opencode.ai/v2/cli.json`。本机实测内容（theme/diffs/session/animations/mouse/scroll）：

```jsonc
// ~/.config/opencode/cli.json —— 纯客户端偏好，server 不感知
{
  "$schema": "https://opencode.ai/v2/cli.json",
  "theme":   { "name": "opencode" },
  "diffs":   { "wrap": "word" },
  "session": { "sidebar": "auto", "scrollbar": false,
               "thinking": "show", "permissions": "autoaccept" },
  "animations": true,
  "mouse": true,
  "scroll": { "speed": 1, "acceleration": true }
}
```

### 7.1.3 状态文件（③类）：各自在业务时机读写

| 文件 | 位置 | 读写时机 | 内容 |
|---|---|---|---|
| `model.json` | `~/.local/state/opencode/` | TUI 切模型时写（`packages/tui/src/context/local.tsx:169-180`，原子写）；server 解析默认模型时读（`provider/provider.ts:2030-2063`：config `model` > `recent` 中第一个仍存在的） | `{recent: [{providerID, modelID}], favorite: [], variant: {"provider/model": "..."}}` |
| `auth.json` | `~/.local/share/opencode/` | OAuth 登录/API key 写入（`src/auth/index.ts`，权限 `0o600`） | `{ [providerID]: {type: "api"\|"oauth"\|"wellknown", ...} }` |
| `mcp-auth.json` | `~/.local/share/opencode/` | MCP OAuth 流程 | 各 MCP server 的 token |
| `service.json`（v2.0.7）/ `server.json`（dev） | `~/.local/state/opencode/` | 后台 daemon 启停时写（第 8 课 §8.5） | `{id, version, url, pid, password?}` |
| `kv.json`、`prompt-history.jsonl`、`frecency.jsonl` | `~/.local/state/opencode/` | TUI 运行期 | 任意 KV / 输入历史 / 文件提及频次 |
| `plugin-meta.json` | `~/.local/state/opencode/` | 插件安装 | 插件安装元数据 |

## 7.2 配置文件全景清单

### 7.2.1 ①类：opencode 主配置（合并成一份 `ConfigV1.Info`）

| 层 | 文件/来源 | 发现逻辑 | 代码 |
|---|---|---|---|
| 全局 | `~/.config/opencode/opencode.jsonc` → `opencode.json` → `config.json` | 读侧：三个**都读**、按此顺序合并（`config.json` 最低、`opencode.jsonc` 最高）；写侧：`globalConfigFile()` 取第一个**存在**的，都不存在则选 `opencode.jsonc` | `config.ts:140-148`、`loadGlobal` `config.ts:260-293` |
| 项目级 | 从 cwd 向上到 worktree 根的每一级 `opencode.json` / `opencode.jsonc` | `afs.up()` 收集后 `toReversed()` → **根先合并、离 cwd 最近的最后合并（优先级最高）** | `config/paths.ts:10-21` |
| `.opencode` 目录 | 各级 `.opencode/opencode.json(c)` + markdown 资产 | 目录序列见下 | `config.ts:430-485`、`paths.ts:23-41` |
| 环境变量 | `OPENCODE_CONFIG`（单文件）、`OPENCODE_CONFIG_CONTENT`（内联 JSON 字符串）、`OPENCODE_CONFIG_DIR`（附加目录，同时重定向全局配置目录） | | `core/src/flag/flag.ts` |
| 远程 | well-known（`auth.json` 里 `type:"wellknown"` 的条目 → `<url>/.well-known/opencode` → `remote_config.url`）；组织 console 配置（`<url>/api/config`） | 加载时 HTTP 拉取，用 auth token 做 `{env:}` 替换 | `config.ts` well-known 段、`fetchRemoteJson` `config.ts:201-225` |
| 托管 | `/etc/opencode`（Linux）、`/Library/Application Support/opencode`（macOS）、`%ProgramData%\opencode`（Windows）；macOS 再叠 MDM `ai.opencode.managed.plist` | 企业统管，"override everything" | `config/managed.ts` |

**`.opencode` 目录的搜索序列**（`ConfigPaths.directories`，`paths.ts:23-41`，依次合并）：

```
~/.config/opencode            （全局配置目录）
<worktree>/.opencode          （从根往 cwd 逐级，每一级）
.../<cwd>/.opencode
$HOME/.opencode               （家目录兜底）
$OPENCODE_CONFIG_DIR          （若设置）
```

每个 `.opencode` 目录不只提供 `opencode.json(c)`，还提供 **markdown 资产**（`config.ts` 内依次 `ConfigCommand.load` → `ConfigAgent.load` → `ConfigAgent.loadMode` → `ConfigPlugin.load`）：

| glob | 变成 | 代码 |
|---|---|---|
| `{command,commands}/**/*.md` | `config.command` 条目（body = 模板） | `config/command.ts:13-39` |
| `{agent,agents}/**/*.md` | `config.agent` 条目（front-matter = 配置，body = prompt） | `config/agent.ts:11-32` |
| `{mode,modes}/*.md` | agent 条目，强制 `mode:"primary"` | `config/agent.ts:34-59` |
| `{plugin,plugins}/*.{ts,js}` | `plugin_origins`（file:// 加载） | `config/plugin.ts:18-30` |

首次使用某个 `.opencode` 目录时还会：写 `.opencode/.gitignore`（`ensureGitignore`，`config.ts:309-326`，忽略 node_modules 等）；后台 `npm install @opencode-ai/plugin`（`config.ts:452-474`，外部插件加载前由 `Config.waitForDependencies()` join）。

> **注意**：v2 **没有** `opencode.jsonc.local` 这类 local 覆盖文件（grep 全仓库无此概念）。个人覆盖请用 `OPENCODE_CONFIG` 指向私有文件，或提交不含密钥的 `opencode.jsonc` + `{env:}` 变量替换。

### 7.2.2 ②类：TUI/CLI 偏好（dev 分支叫 tui.json）

加载顺序（`config/tui.ts:83-226`，后覆盖先）：

```
~/.config/opencode/tui.json(c)          全局（最低）
$OPENCODE_TUI_CONFIG                    显式指定文件
<worktree → cwd> 的 tui.json(c)        项目级（nearest wins，同 ConfigPaths.files）
.opencode 目录 + $OPENCODE_CONFIG_DIR  内的 tui.json(c)
```

细节：嵌套的 `{"tui": {...}}` 会被展平（`tui.ts:55-69`）；未知 keybinds 丢弃；**文件解析失败只警告不崩溃**（TUI 不能因配置挂掉）。老版本写在 `opencode.json` 里的 `theme`/`keybinds`/`tui` 键会被自动迁移到旁边的 `tui.json`（`config/tui-migrate.ts:29-113`，原文件备份为 `*.tui-migration.bak`）——`loadConfig` 读到这些键也会直接剥离（`normalizeLoadedConfig`，`config.ts:54-63`）。

### 7.2.3 写入侧的保形 patch

改全局 `opencode.jsonc` 时不是 `JSON.stringify` 整个重写，而是用 `jsonc-parser` 的 `modify/applyEdits` 做**保注释、保缩进的 patch**（`patchJsonc`，`config.ts:150-162`）；`Config.update` 则把合并结果写到 `<实例目录>/config.json`。通过 `Config.updateGlobal` 改全局配置后，server 会 **dispose 所有实例**（第 5 课 §5.10）。

## 7.3 合并顺序（权威表）

`Config.get()`（接口见 `config.ts:125-134`）→ `loadInstanceState`（`config.ts:328-617`）。合并函数 `mergeConfigConcatArrays`（`config.ts:46-52`，remeda `mergeDeep` 深合并，**后合并的覆盖先合并的**），唯一特例：`instructions` 数组**跨层拼接**而不是覆盖。

**从低到高**（序号大的覆盖序号小的）：

| # | 层 | scope | 代码位置（config.ts） |
|---|---|---|---|
| 1 | 远程 well-known 配置 | global | well-known 段（`config.ts` §328 起 +44 行附近） |
| 2 | 全局配置（`config.json` < `opencode.json` < `opencode.jsonc`，含 TOML 迁移） | global | `loadGlobal` `:260-293` |
| 3 | `OPENCODE_CONFIG` 指定文件 | — | `:415-417` |
| 4 | 项目级 `opencode.json(c)`（根 → cwd，nearest wins） | local | `:420-424` |
| 5 | `.opencode` 目录（配置文件 + markdown 资产 + 插件） | — | `:430-485` |
| 6 | `OPENCODE_CONFIG_CONTENT` 环境变量 | local | `:487-495` |
| 7 | 组织 console 远程配置 | global | `:497-533` |
| 8 | Managed 目录（`/etc/opencode` 等） | global | `:535-541` |
| 9 | macOS MDM managed preferences | global | `:543-553`（最高） |

合并完的**派生/归一化**（`config.ts:555-603`）：

- `mode` 条目折叠进 `agent`（`mode:"primary"`）——mode 是 agent 的旧名；
- `OPENCODE_PERMISSION` 环境变量（JSON 字符串）深合并进 `permission`；
- 遗留 `tools: Record<string,boolean>` 降级成 permission allow/deny（`write/edit/patch` 合并为 `edit`）；
- `username` 缺省取 `os.userInfo().username`；
- `OPENCODE_DISABLE_AUTOCOMPACT` / `OPENCODE_DISABLE_PRUNE` → `compaction.auto/prune = false`。

**CLI flag 不参与这份合并**：`--model`、`--agent`、`--variant` 等在 CLI/TUI 层于配置解析**之后**应用（如 variant 优先级：flag > `model.json` 里保存的偏好 > 会话历史，`cli/cmd/run/variant.shared.ts:1-8` 头注释）。

## 7.4 解析管线：一个配置文件被读成什么样

```
磁盘文件
  → ConfigVariable.substitute     {env:VAR} {file:path} 展开（跳过 // 注释；{file:} 相对配置文件目录）
      config/variable.ts:34-91
  → ConfigParse.jsonc             jsonc-parser，容忍尾逗号；错误带行号/列号/caret
      config/parse.ts:8-33
  → ConfigV2Compat.lower          v2 原生写法 → v1 键（§7.6），冲突产出 Diagnostic 警告
  → ConfigParse.schema            Effect Schema 解码，errors:"all"
      config/parse.ts:35-61       onExcessProperty: "ignore" —— 未知键被忽略而非报错
  → 参与合并
```

顺带的小魔法：`loadConfig`（`config.ts:227-251`）发现文件没有 `$schema` 时会**自动补写** `"$schema": "https://opencode.ai/config.json"` 并回写文件——所以你的配置文件会"自己长出"一行 schema 声明。

## 7.5 主配置 schema 速查（`ConfigV1.Info`）

定义在 `packages/core/src/v1/config/config.ts:32-190`（叫 V1 是历史命名，就是当前 wire 格式）。常用段落：

| 键 | 作用 |
|---|---|
| `model` / `small_model` | 默认模型 / 辅助模型（`provider/model` 格式） |
| `agent` | agent 注册表；内置 `build/plan/general/explore/title/summary/compaction`，配置覆盖或新增（子键：`model/prompt/tools/permission/steps/mode/hidden/...`，未知键折叠进 `options`） |
| `provider` | 自定义 provider、覆盖 models.dev 目录里的模型参数（cost/limits/options/headers） |
| `mcp` | MCP server（本地 command 或远程 url + OAuth） |
| `command` | 命令（通常来自 markdown，也可在此内联） |
| `plugin` | 外部插件（npm spec 或路径，可带 options 元组） |
| `instructions` | 追加 system 指令（**跨层拼接**的特例键） |
| `permission` | 工具权限规则（allow/deny/ask + pattern） |
| `formatter` / `lsp` | 格式化器 / LSP 配置 |
| `server` | `port/hostname/mdns/cors` |
| `compaction` | `auto/prune/tail_turns/preserve_recent_tokens/reserved` |
| `share` / `autoupdate` / `snapshot` / `watcher.ignore` | 分享链接、自动更新、快照、忽略模式 |
| `experimental` | 实验开关（`batch_tool`、`continue_loop_on_deny`、`mcp_timeout`…） |
| `skills` / `references` | skill 路径/URL、参考目录 |

**已搬走**：`theme`/`keybinds`/`tui` → `tui.json`（dev）/ `cli.json`（release）。

## 7.6 v2 原生配置与降级（`v2-compat.ts`）

配置文件可以用**新的 v2 原生键**写，加载时由 `ConfigV2Compat.lower()`（`config/v2-compat.ts:91-132`）重写成 v1 键，带 `Diagnostic {kind: "invalid"|"unsupported"|"conflict", path, message}` 警告：

- **硬错误**：`permissions`（v2 复数形式）任何位置出现都直接 `InvalidError`——"Use V1 'permission' rules or run opencode2"；
- **重命名**：`agents`→`agent`（`system`→`prompt`、`disabled`→`disable`、`request.body`→`options`）、`commands`→`command`、`snapshots`→`snapshot`、`media`→`attachment`、`compaction.keep.tokens`→`preserve_recent_tokens`、`compaction.buffer`→`reserved`；
- **模型串**：`"provider/model#variant"` 或 `{providerID, model, variant}` → `{model, variant}`；
- **MCP**：嵌套 `mcp.servers.{name}` 摊平为 `mcp.{name}`；OAuth 键 snake_case→camelCase；
- **不支持并丢弃**：`plugins`、`providers`、`websearch`、`warming`、agent `request.headers` 等；
- **冲突**：同一含义新旧键并存且值不同 → **保留 v1 值**，产出 conflict 诊断。

## 7.7 观测与热更新

- **看最终合并结果**：`opencode debug config`（`cli/cmd/debug/config.ts`，dump 脱敏后的 `Config.get()`）——排层序问题的第一工具。
- **改实例配置**：`PATCH /config` → 写盘 + `markInstanceForDisposal` → `server.instance.disposed` 事件 → 实例（含配置、插件、provider 注册表）整体重建（第 5 课 §5.10）。
- **改全局配置**：`Config.updateGlobal` → dispose **所有**实例。
- **TUI 内嵌 worker 的 reload 通道**：`rpc.reload` → `Config.invalidate()` + 全量 dispose（`cli/tui/worker.ts:63-71`）。

## 7.8 小结

1. 配置分三类：**server 侧主配置**（`opencode.jsonc` 多层合并）、**客户端偏好**（`tui.json`/`cli.json`，TUI 进程自读）、**状态文件**（`model.json`、`auth.json`、`service.json` 等，各业务自管）。
2. 主配置在**第一个目录请求**时懒加载，按 `InstanceState` 每目录缓存；全局层进程级缓存。
3. 9 层合并：well-known < 全局 < `OPENCODE_CONFIG` < 项目（nearest wins）< `.opencode` 目录 < `OPENCODE_CONFIG_CONTENT` < console < managed < MDM。
4. `cli.json`（v2.0.7）= TUI/CLI 偏好，等价于 dev 分支的 `tui.json`；它不影响 agent/server 行为。
5. v2 原生键会被 `v2-compat` 降级；`permissions`（复数）是硬错误；未知键默认忽略。
6. 排查第一步永远是 `opencode debug config`。
