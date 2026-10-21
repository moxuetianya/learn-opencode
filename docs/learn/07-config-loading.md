# 07. 配置加载全景：来源、优先级与三类数据

> 本课回答：V2 的配置到底分几种？`opencode.jsonc` 从哪里读、谁覆盖谁？
> `cli.json` 是什么？`model.json` / `service.json` 算配置吗？
> 以及**开发插件时应该读写哪一类**。
>
> V1 的 `ConfigV1.Info` 九层深合并、`tui.json`、`server.json` 已经不是现行概念；
> 现在只有 V2 原生配置 + 迁移归一化。

---

## 7.0 先分清三个世界

| 类别 | 文件 | 加载方 | 影响 |
|---|---|---|---|
| **① Server 配置** | `opencode.json` / `opencode.jsonc` | Core 的 `Config.Service`（按 Location） | agent、model、provider、MCP、permission、plugin、tool… |
| **② 客户端偏好** | `cli.json` | CLI/TUI 进程 | 主题、keymap、鼠标、滚动、diff 展示 |
| **③ 运行状态** | `model.json`、`service.json`、`auth` / credential DB、TUI storage | 各自业务 | 最近模型、后台服务注册、凭据、历史 |

**核心区别**：① 是"程序行为"，② 是"界面偏好"，③ 是"运行记录"。
插件通常只关心 ①；不要在插件里改 `cli.json`。

---

## 7.1 Server 配置：加载时机

`Config.Service` 是 **Location 范围**服务，在 `Instance.layer(ref)` 启动时构建
（`core/src/instance.ts`）。也就是说：

- 不是 server 进程启动时加载；
- 每个目录第一次被请求时加载一次；
- 之后常驻该 Location（`LocationServiceMap` 不按空闲时间回收）；
- 文件变化会触发重新发现与重算，并发布 `config.updated`（watcher + 100ms debounce）。

所以同一个 daemon 打开两个项目，各自有一份独立的配置合并结果。

---

## 7.2 来源与优先级

`ConfigDiscovery.discover()` + `Config.load()` 的合并顺序（**后者覆盖前者**）：

```
1. well-known 远程配置
     来自已连接集成（Integration）的 manifest
     → 失败时保留上一次缓存

2. 全局配置目录
     $OPENCODE_CONFIG_DIR（若设置）或 ~/.config/opencode/
     依次加载：
       opencode.json
       opencode.jsonc
       （目录本身作为一个 Directory entry，供 .opencode 资产发现）

3. OPENCODE_CONFIG 指定的文件

4. 项目级 opencode.json / opencode.jsonc
     从 cwd 向上逐级查找（到 home 或全局目录为止）
     远的先、近的后 → 离 cwd 最近的优先级最高

5. 各级 .opencode 目录
     目录内的 opencode.json(c)，以及
     agent/agents/*.md、mode/modes/*.md、
     command/commands/**/*.md、plugin|plugins/*.ts、
     skill|skills/**/SKILL.md 等资产
     同样远的先、近的后

6. OPENCODE_CONFIG_CONTENT
     内联 JSON 字符串，优先级最高
```

补充：

- `OPENCODE_CONFIG_PROJECT_DISABLE=1`（或 `OPENCODE_DISABLE_PROJECT_CONFIG=1`）
  会关闭项目扫描，只保留全局/显式/内联来源；
- `--server` / `--standalone` 只影响连接哪个 server，不改变 server 自己的配置来源；
- 没有 `opencode.jsonc.local` 这种约定；个人覆盖请用 `OPENCODE_CONFIG` 指向私有文件。

### 7.2.1 “后覆盖前”到底怎么合并

V2 **没有统一 deep merge**。`Config.entries()` 返回一个有序的 `Entry[]`，
每个域所有者决定自己的合并方式：

| 域 | 合并方式 | 位置 |
|---|---|---|
| `model`、`default_agent`、`shell`、`share`… | 取**最后一份包含该键的文档**（`Config.latest`） | 各 config plugin |
| `providers` | 按文档顺序 fold，后来的字段覆盖 / 合并 | `config/plugin/provider.ts` |
| `agents` | 按文档顺序逐个 `update`，后来的字段覆盖 | `config/plugin/agent.ts` |
| `plugins` | 按文档顺序拼成操作列表 | `plugin/supervisor.ts` |
| markdown 资产 | 每个文件生成一个 Document，按目录顺序合并 | `config/plugin/*` |

这比"一个巨大的递归 merge"更好预测，也避免数组/对象语义混乱。

### 7.2.2 配置目录里的 markdown

`opencode.json(c)` 不是唯一来源。每个配置目录（包括 `.opencode`）还会被发现：

| glob | 变成 |
|---|---|
| `agent/agents/**/*.md` | agent 定义（front-matter + 正文 system） |
| `mode/modes/*.md` | agent 定义，强制 `mode: "primary"` |
| `command/commands/**/*.md` | slash command 模板 |
| `plugin/plugins/*.{ts,js}` | 本地插件 |
| `skill/skills/**/SKILL.md`、`skills/*.md` | skill |

所以插件开发者可以把"配置 + 指令 + 工具"打包成目录结构，而不是只依赖 JSON。

### 7.2.3 AGENTS.md

`AGENTS.md` **不是** `opencode.jsonc` 的一部分，而是 `InstructionDiscovery` 的来源：

- 全局：`$OPENCODE_CONFIG_DIR/AGENTS.md`
- 项目：从 cwd 向上逐级到项目根（受 `global/project` 开关控制）
- 文件变化会重新渲染指令增量

这与 `config.instructions` 字段不同：当前 V2 的运行时指令发现主要走 AGENTS.md
与代码内建来源。开发插件时，如果要注入"每轮都生效"的规则，
优先用 `session.context` hook 或注册 instruction source，而不是改 AGENTS.md。

---

## 7.3 V2 配置 schema 速查

定义在 `packages/schema/src/config.ts` 的 `Config.Info`：

| 键 | 作用 |
|---|---|
| `$schema` | JSON Schema 引用 |
| `model` | 默认模型（`{ providerID, model, variant? }`） |
| `default_agent` | 默认 primary agent |
| `agents` | agent 定义/覆盖（`system`、`mode`、`permissions`、`steps`…） |
| `permissions` | 有序权限规则（action / resource / effect） |
| `providers` | provider 与模型覆盖（settings、headers、body、models…） |
| `plugins` | 插件声明（字符串或 `{ package, options }`） |
| `mcp` | MCP servers 与 timeout |
| `compaction` | `auto`、`buffer`、`keep.tokens` |
| `commands` | 内联 slash command |
| `skills` | 额外 skill 路径/URL |
| `references` | 外部参考目录/Git 仓库 |
| `formatter` / `lsp` | 格式化器 / 语言服务器 |
| `snapshots` | 是否启用文件快照 |
| `share` / `update` / `enterprise` / `username` | 分享、更新、企业、身份 |
| `watcher.ignore` | 忽略的 watcher 路径 |
| `tool_output` | 工具输出截断阈值 |
| `websearch` | 搜索 provider |
| `experimental` | 实验开关与组织策略 |

### 7.3.1 权限规则

```jsonc
{
  "permissions": [
    { "action": "*", "resource": "*", "effect": "allow" },
    { "action": "read", "resource": "*.env", "effect": "ask" },
    { "action": "shell", "resource": "rm -rf *", "effect": "deny" }
  ]
}
```

- 规则**有序**，评估时取最后一条同时匹配 action 与 resource 的规则；
- 没有匹配 → `ask`；
- 配置里的全局 permissions 会进入每个 agent 的规则集；最终叠加顺序是
  agent（含配置）→ 会话 permissions → 已保存的 always 授权。

### 7.3.2 插件声明

```jsonc
{
  "plugins": [
    "opencode-my-plugin",
    { "package": "opencode-my-plugin", "options": { "level": 2 } },
    "/abs/path/to/plugin-dir"
  ]
}
```

加载与排序见第 02 课。`options` 会原样传给插件 context。
旧配置里的 `[target, options]` 元组会被归一化成对象形式，新配置请直接写对象。

### 7.3.3 旧配置键

`packages/core/src/config/normalize.ts` 会把旧键归一化成 V2：

- `agent` → `agents`、`command` → `commands`、`plugin` → `plugins`；
- `permission` / `tools` → `permissions`；
- `attachment` → `media`、`snapshot` → `snapshots`；
- `provider` → `providers`、`mode` → `agents`；
- `compaction.preserve_recent_tokens` → `keep.tokens`、`reserved` → `buffer`。

冲突时保留原生键并记录诊断；不支持/畸形的值会被跳过并警告。
这是**兼容层**，新插件/新配置请直接写 V2 键。

---

## 7.4 解析管线

```
磁盘文件
  → ConfigVariable.substitute   {env:VAR}、{file:path} 展开
  → jsonc-parser               容忍尾逗号；语法错误 → 跳过该文件并告警
  → ConfigNormalize.normalize  旧键 → V2 键；未知键忽略；诊断日志
  → Schema.decode(Config.Info) 严格类型；失败 → 跳过该文档
  → 进入 Entry[]（Document / Directory）
```

- 单文件失败不会拖垮整个配置；其余来源继续合并；
- 诊断通过 `configuration normalization diagnostic` 日志输出；
- 没有"自动补 `$schema`"的副作用。

---

## 7.5 `cli.json`：客户端偏好

`packages/cli/src/config/config.ts`：

- 路径：`~/.config/opencode/cli.json`（`$OPENCODE_CONFIG_DIR` 会改变全局目录）；
- 也可用 `OPENCODE_CLI_CONFIG_CONTENT` 注入；
- 只读**全局**文件，没有项目级 `cli.json`；
- 读取/写入都加文件锁（Flock），写入是原子 rename；
- 解析失败只警告，TUI 不会因配置崩溃。

Schema 是 `@opencode/tui/config` 的 `Info`，常见内容：

```jsonc
{
  "$schema": "https://opencode.ai/v2/cli.json",
  "theme": { "name": "opencode" },
  "diffs": { "wrap": "word" },
  "session": { "sidebar": "auto", "scrollbar": false },
  "animations": true,
  "mouse": true,
  "scroll": { "speed": 1, "acceleration": true }
}
```

它**不会**发给 server，也不影响 agent 行为。
旧版 `tui.json` 由迁移逻辑转换成 `cli.json`（`cli/src/config/migrate.ts`），
新代码不再读 `tui.json`。

---

## 7.6 状态文件

| 文件 | 位置 | 谁写 | 用途 |
|---|---|---|---|
| `model.json` | `$XDG_STATE_HOME/opencode/` | TUI 模型选择 | 最近模型、favorite、variant |
| `service.json`（注册） | 同上 | daemon 注册 | `{ id, version, url, pid, password }` |
| `service.json`（配置） | `~/.config/opencode/` | `opencode service set` | disabled/remote/hostname/port/cors/env |
| `service-<channel>.json` | 同上 | 非默认 channel | 开发/本地渠道隔离 |
| `prompt-history.jsonl` | 同上 | TUI 输入历史 | 上下键历史 |
| `frecency.jsonl` | 同上 | TUI 文件提及 | `@` 补全排序 |
| TUI storage `<channel>/tui/*.json` | 同上 | TUI 插件/界面状态 | 会话选择、终端选择等 |
| `auth` / credential | SQLite / credential 服务 | 登录流程 | API key / OAuth |
| `opencode.db` | `$XDG_DATA_HOME/opencode/` | server | 会话、事件、收件箱（第 09 课） |

这些都不是 `Config.Service` 的输入。插件若需要持久化自己的状态，应使用
`ctx.storage`（按插件 ID 隔离的 KV），而不是写这些文件。

---

## 7.7 热更新与诊断

### 热更新

- **配置文件 / AGENTS.md / skill / plugin 文件变化**：watcher 触发重载；
- 配置变化发布 `config.updated`，各 config plugin 重新加载并刷新对应注册表；
- 插件变化触发 `PluginSupervisor.activate()`，按代际只重载变化的插件；
- 客户端不需要重启；TUI 通过事件收到更新后的状态。

### 诊断

| 目的 | 方法 |
|---|---|
| 看配置来源与合并结果 | `opencode debug config` |
| 看 agent | `opencode debug agents` |
| 看路径 | `opencode debug paths`（db/home/data/config/cache/state…） |
| 看插件 | `opencode plugin list`、`opencode plugin check` |
| 看服务 | `opencode service status`、`opencode api get /api/info` |
| 日志 | `--print-logs`；server 日志在 `~/.local/share/opencode/log/` |

> `opencode debug config` 打印的是脱敏后的**有效配置文档列表**，
> 不是简单的 JSON merge 结果；排查"为什么我的值没生效"时，
> 先看目标键最后出现在哪个文档里。

---

## 7.8 插件开发者应该关心什么

| 需求 | 推荐做法 |
|---|---|
| 自己的配置项 | 用 `ctx.storage` 存状态；需要用户可配的项，向 `Config.Info` 提议新字段或使用插件 options |
| 读用户配置 | `Config.Service.entries()` / `Config.latest(entries, key)` |
| 监听配置变化 | `config.changes()` 或订阅 `config.updated` 事件 |
| 改 agent/skill/tool/provider | 对应 `ctx.*.transform`，不要直接改配置文件 |
| 客户端偏好 | 不要碰；那是 TUI 的 `cli.json` |
| 密钥 | 用 Credential / Integration，不要写入 `opencode.jsonc` |

---

## 7.9 小结

1. **三类数据分开**：server 配置、客户端偏好、运行状态。
2. **配置按 Location 懒加载**，不是进程启动时一次性读完。
3. **来源有序**：well-known → 全局 → 显式 → 项目 → `.opencode` → 内联。
4. **没有统一 deep merge**：每个域按自己的规则取最后文档或 fold。
5. **`cli.json` 只属于客户端**，不影响 server/agent。
6. **状态文件不是配置**：插件状态用 `ctx.storage`。

> **迁移小注**：旧文档的 `ConfigV1.Info`、`loadInstanceState`、`tui.json`、
> `server.json`、`v2-compat.lower()` 都是 V1/过渡期概念；
> V2 对应 `Config.Info`、`Config.Service.entries()`、`cli.json`、`service.json`、
> `ConfigNormalize`。
