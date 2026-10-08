# 9. 数据存储：一个全局 SQLite、事件溯源、以及怎么管理它

> 本课回答：v2 的后端到底存成什么（是 SQLite）、存在哪、有哪些表、一条 prompt 是怎么"落库"的、怎么安全地查看/备份/统计。所有路径基于本仓库 `dev` 分支，并在结尾标注官方 v2.0.7 release 的表名演进。

## 9.0 一句话模型

**一个全局 SQLite 数据库服务所有项目**：`~/.local/share/opencode/opencode.db`（Linux；macOS `~/Library/Application Support/opencode/`，Windows `%LOCALAPPDATA%\opencode\`）。没有"每个项目一个库"；多项目靠 `project_id` 外键区分。多进程并发安全由 **WAL + `busy_timeout`** 保证——这也是"同目录/跨目录多个 client 看到同一份会话"的物理基础（第 8 课 §8.4）。

```
packages/core/src/database/database.ts
  └─ makeDatabase: EffectDrizzleSqlite.makeWithDefaults()
       └─ packages/effect-drizzle-sqlite（Drizzle↔Effect 适配）
            └─ packages/effect-sqlite-node（NodeSqliteClient）
                 └─ bun:sqlite / node:sqlite（#sqlite 条件导入，core/package.json:25-30）
```

## 9.1 数据库文件在哪

`Database.path()`（`packages/core/src/database/database.ts:43-55`）：

```ts
if (Flag.OPENCODE_DB) {                                    // 环境变量覆盖（":memory:" 或绝对/相对路径）
  ...
}
if (["latest","beta","prod"].includes(InstallationChannel))
  return join(Global.Path.data, "opencode.db")             // 稳定渠道
return join(Global.Path.data, `opencode-${channel}.db`)    // 其他渠道带后缀
```

本机实测（`~/.local/share/opencode/`）：

```
opencode.db / opencode.db-wal / opencode.db-shm     ← v2.0.7 release（955 个会话）
opencode-dev.db + wal/shm                           ← dev 渠道构建（13 个会话、3662 条事件）
opencode-local.db + wal/shm                         ← local 渠道
```

**同一个用户可以同时有多个库**（按安装渠道隔离），这是排查"我开的 opencode 怎么看不到那个 opencode 的会话"时的第一检查项。

## 9.2 打开即调优：PRAGMA 与启动迁移

`database.ts:22-37`：

```ts
yield* db.run("PRAGMA journal_mode = WAL")        // 写不阻塞读，多进程并发
yield* db.run("PRAGMA synchronous = NORMAL")      // WAL 下的常用平衡点
yield* db.run("PRAGMA busy_timeout = 5000")       // 锁竞争最多等 5s
yield* db.run("PRAGMA cache_size = -64000")       // 64MB 页缓存
yield* db.run("PRAGMA foreign_keys = ON")         // 级联删除生效
yield* db.run("PRAGMA wal_checkpoint(PASSIVE)")
yield* DatabaseMigration.apply(db)                // ← 启动即应用迁移
```

`Database.node` 用 `makeGlobalNode`（`core/src/effect/app-node.ts`）注册为**进程级单例**。

## 9.3 表结构全景

Schema 全部以 Drizzle `sqliteTable` 定义在 `packages/core/src/**/*.sql.ts`（生成配置 `core/drizzle.config.ts`）。按域分组：

### 会话域

| 表 | 定义 | 用途 |
|---|---|---|
| `session` | `session/sql.ts:22-66` | 会话元数据：`project_id` FK、`workspace_id`、`parent_id`、`directory`、title、model/agent、分享 URL、成本/token 汇总、revert 状态、权限、时间戳 |
| `session_message` | `session/sql.ts:119-138` | **v2 投影消息**，键为 `(session_id, seq)`——seq 是聚合事件序号；`type` ∈ user/assistant/shell/compaction/system；内容在 `data` JSON |
| `session_input` | `session/sql.ts:140-166` | **v2 耐久收件箱**：`prompt` JSON、`delivery`（steer/queue）、`admitted_seq`、`promoted_seq`（NULL = 还没被推进成可见消息） |
| `session_context_epoch` | `session/sql.ts:168-176` | System Context 基线（baseline/snapshot JSON），会话所属 |
| `todo` | `session/sql.ts:100-117` | 每会话 todo 列表（`session_id + position` 主键） |
| `message` / `part` | `session/sql.ts:68-98` | **v1 兼容投影**（老 API/老 TUI 读写的形状，`data` JSON blob） |

### 事件域（事件溯源的心脏）

| 表 | 定义 | 用途 |
|---|---|---|
| `event` | `event/sql.ts:10-25` | 耐久事件日志：`aggregate_id`、`seq`、版本化 `type`、`data` JSON |
| `event_sequence` | `event/sql.ts:4-8` | 每聚合的 seq 游标 + 重放所有权（owner claim） |

### 项目/账户/治理域

| 表 | 定义 | 用途 |
|---|---|---|
| `project` / `project_directory` | `project/sql.ts:6-35` | 项目（worktree、vcs、名称、sandboxes）及其附属目录 |
| `workspace` | `control-plane/workspace.sql.ts:6-20` | workspace（类型/分支/目录） |
| `account` / `account_state` / `control_account` | `account/sql.ts:6-39` | opencode.ai 账户、活跃账户/组织指针、遗留表 |
| `credential` | `credential/sql.ts:5-14` | 集成凭据（OAuth 值等） |
| `permission` | `permission/sql.ts:7-20` | 已保存的权限授权（唯一键 `project_id+action+resource`） |
| `session_share` | `share/sql.ts:5-13` | 会话分享 id/secret/url |
| `data_migration` / `migration` | `data-migration.sql.ts`、`migration.ts:29-46` | JSON→DB 数据迁移标记 / SQL 迁移日志 |

## 9.4 事件溯源：一条 prompt 的落库之旅

v2 的写入模型是"**先发事件，投影同事务落库**"（`EventV2.publish` → `commitDurableEvent`，`packages/core/src/event.ts:205-367`）：

```
① SessionV2.prompt
     └─ SessionInput.admit                      session/input.ts:41-81
          publish(SessionEvent.PromptAdmitted)
          └─ 事务：分配 seq ──▶ projector 写 session_input 行（promoted_seq=NULL）
                                └─ 插入 event 行（journal）
② wake → Runner 推进                           runner/llm.ts:187-196
     SessionInput.promoteSteers/promoteNextQueued
          publish(SessionEvent.Prompted)
          └─ 事务：session_input.promoted_seq=seq + session_message 追加 user 行
③ 每个 provider turn
     llm.stream 的 text/reasoning/tool-call 增量逐个 publish
          └─ 投影成 assistant 消息/part 行（v1 兼容层同步写 message/part）
     工具结果 publish(Tool.Success/Failed)
④ 读取侧
     · 投影历史：session_message（SessionHistory.entriesForRunner，带 compaction/epoch 感知）
     · 原始日志：event 表按 aggregate 回放（EventV2.readAggregate / /api/session/:id/event SSE）
```

这个设计带来三个直接后果：

1. **崩溃可恢复**：收件箱和事件都先于副作用持久化，工具"执行中被杀"在日志里可见（`Tool.Called` 已写、`Tool.Success/Failed` 缺席）。
2. **重连不丢事件**：SSE 会话流支持 `after` 序号重放（第 8 课 §8.5）。
3. **投影可重建**：`session_message` 等表理论上都能从 `event` 重放出来。

## 9.5 迁移怎么管理

- **迁移是 TypeScript 文件**：`packages/core/src/database/migration/*.ts`（38 个），在 `migration.gen.ts` 注册；每个导出 `{ id, up(tx) }`。
- **启动自动应用**：`DatabaseMigration.apply`（`migration.ts:18-41`）——全新库直接灌 `schema.gen.ts` 全量 DDL 并播种日志；老库逐个事务跑 pending 迁移，写入 `migration` 表。
- **开发侧生成**：`packages/core` 里 `bun run migration`（drizzle-kit generate + 渲染 `.sql`→`.ts` + 更新快照），`bun run db` 直接用 drizzle-kit。
- 规则（`packages/opencode/AGENTS.md`）：*Schema 在 `packages/core/src/**/*.sql.ts`；迁移在 `packages/core` 由 core 应用*。

## 9.6 遗留 JSON 存储几乎退役

v1 时代的键值 JSON 存储根目录是 `~/.local/share/opencode/storage/`（`packages/opencode/src/storage/storage.ts:224`，带自己的文件布局迁移）。现在**唯一还在写**的路径是 `session_diff`（`session/revert.ts:77`）。本机该目录也只剩 `session_diff/` 和迁移标记。读老会话时它仍是回退数据源。

## 9.7 其他磁盘数据速查（`Global.Path`，`core/src/global.ts:10-43`）

| 路径 | 内容 |
|---|---|
| `~/.config/opencode/` | `opencode.jsonc`、`tui.json`（dev）/`cli.json`（release）、`package.json`+`node_modules`（全局插件依赖）、`plugins/`、`skills/` |
| `~/.local/share/opencode/auth.json` | provider 凭据（0o600）；旁边 `mcp-auth.json` |
| `~/.local/share/opencode/snapshot/<projectID>/<hash>/` | 文件快照（bare git 目录，供 diff/回滚） |
| `~/.local/share/opencode/worktree/<projectID>/` | 任务用临时 worktree |
| `~/.local/share/opencode/tool-output/` | 超限工具输出的落盘截断 |
| `~/.local/state/opencode/` | `model.json`、`service.json`（daemon 注册）、`kv.json`、`prompt-history.jsonl`、`frecency.jsonl`、`plugin-meta.json`、`locks/`（跨进程文件锁） |
| `~/.cache/opencode/`、`.../log/` | 缓存与日志 |

跨进程互斥不用数据库锁的地方（config 写入、插件元数据、MCP auth）用 **Flock**：`~/.local/state/opencode/locks/<hash>.lock/`（`core/src/util/flock.ts:310-346`）。

## 9.8 实操：查看、统计、备份

### 查询

- **本仓库 dev 分支 CLI**：`opencode db "<sql>" --format json|tsv`；不带参数进交互 `sqlite3`；`opencode db path` 打印库路径（`packages/opencode/src/cli/cmd/db.ts`）。
- **v2.0.7 release**：没有 `db` 子命令，直接 `sqlite3 ~/.local/share/opencode/opencode.db`（WAL 模式下外部读取安全，不会阻塞正在运行的 server）。

常用 SQL：

```sql
-- 最近会话
select id, directory, title, time_created from session
  order by time_created desc limit 10;

-- 每项目会话数（release 库用 session_v2 表）
select p.worktree, count(*) from session s join project p on p.id = s.project_id
  group by 1 order by 2 desc;

-- 某会话的可见消息（投影）
select seq, type, substr(json_extract(data,'$.text'),1,80)
  from session_message where session_id = 'ses_xxx' order by seq limit 50;

-- 待推进的收件箱（steer/queue 积压）
select * from session_input where promoted_seq is null;
```

### 统计

`opencode stats`（dev 分支）直接从 `SessionTable` 聚合 token/成本。

### 备份与维护

- **在线备份**（推荐，server 运行中也能做）：`sqlite3 opencode.db "VACUUM INTO '/backup/opencode-$(date +%F).db'"`。
- 冷拷贝要连 `-wal`/`-shm` 一起，或先 `wal_checkpoint(TRUNCATE)`。
- 迁移在启动时自动跑，**降级二进制可能打不开新库**（迁移日志版本更高）——回滚前先备份。
- 彻底重置：退出所有 opencode 进程后删掉 `opencode.db*`（或换 `OPENCODE_DB` 指到新文件做实验）。

## 9.9 版本演进提示（v2.0.7 release 实测）

正式版相对本仓库 dev 分支已继续演进（本机 release 库实测表名）：

| dev 分支 | v2.0.7 release | 说明 |
|---|---|---|
| `session_input` | `session_inbox` | 收件箱改名 |
| `session`（v2 行） | `session_v2`（+`session` 保留 v1） | v2 会话独立成表 |
| — | `session_pending`、`kv`、`worktree`、`instruction_blob/entry/state` | 新增：待处理状态、KV、worktree 记录、instruction 存储 |

机制相同（投影 + 收件箱 + 事件），读源码时以 `packages/core/src/**/sql.ts` 为准，查正式版数据时先 `.tables` 看实际表名。

## 9.10 小结

1. 存储是**单个全局 SQLite**（按渠道可能多份），WAL + busy_timeout 保证多进程并发；没有 per-project 库。
2. v2 是**事件溯源**：`event`/`event_sequence` 是真相源，`session_message`/`session_input` 是同事务投影；工具副作用之前必有 durable 事件。
3. 迁移是 TS 文件、启动自动应用、记录在 `migration` 表。
4. 日常管理：`sqlite3` 随便读（WAL 不阻塞）、`VACUUM INTO` 备份、注意渠道后缀库和 release 的表名演进。
5. 数据之外还有 snapshot（bare git）、worktree、tool-output、auth/state 目录——第 7 课的"三个世界"在这里落地。
