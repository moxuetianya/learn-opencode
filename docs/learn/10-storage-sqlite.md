# 10. 数据存储：全局 SQLite、事件溯源与日常管理

> 本课回答：V2 的数据到底存在哪？为什么用事件溯源？有哪些表？
> 一条输入是怎么落库、怎么变成可见消息的？怎么安全地查看和备份？
>
> V1 的 JSON 文件存储（`storage/`）与 `session_input` 已经退役；
> 现在只有 SQLite 投影 + 事件日志，另保留一个旧库导入器。

---

## 10.0 一句话模型

**一个全局 SQLite 数据库服务所有项目和会话。**

- Linux：`$XDG_DATA_HOME/opencode/opencode.db`（通常 `~/.local/share/opencode/`）
- macOS：`~/Library/Application Support/opencode/`
- Windows：`%LOCALAPPDATA%\opencode\`

文件名由 channel 决定（`cli/src/database-path.ts`）：

| channel | 文件 |
|---|---|
| latest / dev / beta / next / prod | `opencode.db` |
| 其它（local、自定义） | `opencode-<channel>.db` |

`OPENCODE_DB` 可覆盖文件名或设为 `:memory:`。
`OPENCODE_DISABLE_CHANNEL_DB=1` 可强制使用 `opencode.db`。

> 排查"两个 opencode 看不到彼此的会话"时，第一步是确认它们的 **channel / 库文件**
> 是否相同。不同 channel 本来就用不同库。

---

## 10.1 打开即调优

`packages/core/src/database/database.ts`：

```sql
PRAGMA journal_mode = WAL       -- 写不阻塞读
PRAGMA synchronous = NORMAL
PRAGMA busy_timeout = 5000      -- 锁竞争最多等 5 秒
PRAGMA cache_size = -64000      -- 64 MiB 页缓存
PRAGMA foreign_keys = ON        -- 级联删除
PRAGMA wal_checkpoint(PASSIVE)
```

随后 `DatabaseMigration.apply(db)`：

- 空库：直接执行 `schema.gen.ts` 全量 DDL，并把所有迁移标记为已完成；
- 已有库：按 `migration` 表逐个跑未完成的 TS 迁移；
- 如果库里有 `session` / `session_v2`，视为 OpenCode 库；否则拒绝在非空库上建表；
- 文件权限收紧到 `0600`（POSIX）。

---

## 10.2 表结构

Schema 定义在 `packages/core/src/**/sql.ts`，Drizzle 类型由 `schema.gen.ts` 生成。

### 会话域（`session/sql.ts`）

| 表 | 作用 |
|---|---|
| `session_v2` | 会话元数据：project/workspace/parent、directory、title、agent、model、cost/tokens、permissions、revert、claim 时间、resume 次数 |
| `session_message` | **可见消息投影**：`(session_id, seq)`，`type` ∈ user/assistant/synthetic/system/skill/shell/compaction/agent-switched/model-switched/location-switched/idle，内容是 `data` JSON |
| `session_inbox` | **未消费工作**：`type` ∈ user/synthetic/compaction/move，`delivery` ∈ steer/queue，`enqueued_seq`，payload |
| `instruction_entry` | 会话级 instruction 的增量条目（key/value/removed） |
| `instruction_blob` | 指令值的单份存储（按 hash） |
| `instruction_state` | 指令纪元基线：`epoch_start`、`through_seq`、initial/current values |

`session_pending` 仍在 schema 中定义，但当前代码没有读写路径，属于早期 inbox 设计的遗留；
阅读与排查时以 `session_inbox` 为准。

### 事件域（`event/sql.ts`）

| 表 | 作用 |
|---|---|
| `event` | durable 事件日志：`aggregate_id`、`seq`、`type`、`data`、`created` |
| `event_sequence` | 每个聚合的 seq 游标；`owner_id` 用于同步/重放归属 |

### 项目/组织域

| 表 | 作用 |
|---|---|
| `project` | 仓库身份：worktree、vcs、name、sandboxes、commands |
| `project_directory` | 已废弃（改用 `worktree` 表），兼容旧数据 |
| `workspace` | workspace 记录（类型/分支/目录） |
| `worktree` | 任务用 worktree 记录 |
| `account` / `account_state` | 账号与当前组织 |
| `credential` | 集成凭据（OAuth/key） |
| `permission` | 保存的 "always" 授权 |

### 通用

| 表 | 作用 |
|---|---|
| `kv` | 进程/插件 KV；后台 Job 的恢复记录也存在这里（`job.background/<id>`） |
| `migration` | 已完成的 TS 迁移 ID |

---

## 10.3 为什么用事件溯源

### 10.3.1 写入模型

`Bus.publish`（`core/src/bus.ts`）对一个 durable 事件做：

```
1. 取该 aggregate 的下一 seq（event_sequence）
2. 开启事务
3. 依次执行该事件类型的 projector：
     - 写 session_message / session_inbox / session_v2…
     - 更新指令状态、用量、标题等
4. 插入 event 行
5. 提交
6. 事务外 PubSub 扇出给订阅者
```

结果是：

- **投影与事件同事务**：不会出现"事件有了、消息没有"；
- **读模型自洽**：`session_message` 可以直接读，不必每次重放；
- **可重建**：投影表理论上都能从 `event` 重放；
- **可重连**：客户端带 `after` 序号就能补齐 durable 事件。

### 10.3.2 一条 prompt 的落库之旅

```
① Session.prompt
     SessionInbox.admit
       → Bus.publish(SessionEvent.InboxEnqueued)
       → 事务：session_inbox 插入一行 + event 插入一行

② execution.wake → Runner.advanceToStep
     SessionInbox.promote
       → Bus.publish(SessionEvent.InboxDelivered)
       → 事务：删除 inbox 行 + 插入 user 消息投影 + event 行

③ 每个 step
     llm.stream 事件 → Bus.publish(SessionEvent.Text/Reasoning/Tool/Step…)
       → 投影写 assistant 消息的 content/tool 状态
       → delta 是 ephemeral：只扇出，不落库
     step-finish → 用量、snapshot、文件 diff

④ 终态
     SessionEvent.Execution.Succeeded/Failed/Interrupted
       → 更新 session 的 idle/outcome，释放 claim
```

### 10.3.3 durable 与 ephemeral

| 类型 | 例子 | 是否落库 | 用途 |
|---|---|---|---|
| durable | `session.inbox.enqueued`、`session.tool.called`、`session.step.ended`、`session.execution.*` | 是 | 真相、恢复、重放 |
| ephemeral | `session.text.delta`、`session.reasoning.delta`、`session.tool.progress`、`session.usage.updated` | 否 | 实时渲染 |

重连后，客户端先拉当前消息投影，再接收新的 delta；
所以即使错过了一些 delta，最终内容仍然正确。

---

## 10.4 指令与压缩的存储

### 指令

- `instruction_state` 保存会话的**基线**（initial values + epoch）；
- `instruction_entry` 保存后续增量的 key 与 value；
- `instruction_blob` 按 hash 去重存值；
- 每次 `session.instructions.updated` 只记录变化的 key + hash；
- compaction 完成会推进 epoch，把新基线固化下来；会话 move 保留 epoch，
  因此目标目录的指令变化仍然以"增量"出现。

### 压缩

`session_message` 里 `type = "compaction"` 的消息：

- `status`：running / completed / failed；
- `reason`：auto / manual；
- completed 的 summary 或 provider checkpoint 会成为新的历史边界；
- `SessionHistory.latestCompaction` 决定从哪里开始读。

---

## 10.5 迁移

- 迁移是 TypeScript：`packages/core/src/database/migration/*.ts`，
  在 `migration.gen.ts` 注册；每个导出 `{ id, up(tx) }`；
- 启动自动应用，记录在 `migration` 表；
- 生成：在 `packages/core` 里跑 `bun run migration`；
- 规则：Schema 在 `packages/core/src/**/sql.ts`，迁移由 core 应用。

### V1 数据导入

`database/v1-migration*` 只做旧库/旧 JSON 数据导入：

- 把旧的 `session` / `message` / `part` 数据映射到 `session_v2` / `session_message`；
- 建立事件序列水位；
- 不是运行时依赖，也不参与新会话写入。

这是 V1 唯一还需要被提到的部分；本教程不展开其实现。

---

## 10.6 磁盘上的其他数据

| 路径 | 内容 |
|---|---|
| `~/.config/opencode/` | `opencode.jsonc`、`cli.json`、全局插件 `node_modules`、skills |
| `~/.local/share/opencode/` | `opencode.db`、`snapshot/<projectID>/`（文件快照）、`worktree/`、`tool-output/`、`log/`、`repos/` |
| `~/.local/state/opencode/` | `model.json`、`service.json`、`prompt-history.jsonl`、`frecency.jsonl`、TUI storage、locks |
| 凭据 | `credential` 表；旧版 `auth.json` 仅由迁移读取 |
| shell 输出 | `~/.local/share/opencode/shell/<project>/<id>.out`（保留 7 天） |

跨进程文件锁（配置写入、插件元数据）用 Flock：
`~/.local/state/opencode/locks/<hash>.lock/`。

---

## 10.7 查看、统计、备份

### 查看

```bash
# 直接用 sqlite3（WAL 下读不阻塞写）
sqlite3 ~/.local/share/opencode/opencode.db

# 常用
.tables
select id, directory, title, time_updated from session_v2
  order by time_updated desc limit 10;

select seq, type, substr(json_extract(data,'$.text'),1,80)
  from session_message where session_id = 'ses_...' order by seq limit 50;

select * from session_inbox where session_id = 'ses_...';

select aggregate_id, seq, type from event
  where aggregate_id = 'ses_...' order by seq desc limit 20;
```

### 统计

```bash
opencode stats            # token / 成本汇总
opencode debug paths      # 确认使用的是哪个库
```

### 备份与维护

```bash
# 在线备份（推荐，server 运行中也能做）
sqlite3 opencode.db "VACUUM INTO '/backup/opencode-$(date +%F).db'"

# 冷拷贝要连 -wal / -shm 一起，或先 checkpoint
sqlite3 opencode.db "PRAGMA wal_checkpoint(TRUNCATE)"
```

- 迁移在启动时自动跑；**降级二进制可能打不开新库**，回滚前先备份；
- 彻底重置：退出所有 opencode 进程，删除 `opencode.db*`；
- 实验用独立库：`OPENCODE_DB=/tmp/experiment.db`。

---

## 10.8 插件开发者需要知道什么

| 需求 | 做法 |
|---|---|
| 持久化插件状态 | `ctx.storage`（KV 表，按插件 ID 隔离） |
| 读会话历史 | `ctx.session.context` / `session.messages` API，不要直接查库 |
| 监听状态变化 | `ctx.event.subscribe()` |
| 自定义业务数据 | 用 `ctx.storage` 或 `ctx.rpc` + 自己的表；不要往 `session_message` 里塞 |
| 备份/迁移 | 只依赖公开 API；不要假设表结构稳定 |

数据库是 Core 的私有实现；**插件不要直接打开 SQLite 文件**，
否则会绕过投影、事务与 Location 约束。

---

## 10.9 小结

1. **一个全局 SQLite**：按 channel 分文件；WAL + busy_timeout 支持多进程。
2. **事件是真相，投影是读模型**：同事务写入，可重放。
3. **Inbox 只存未消费工作**：delivered 后变成消息行。
4. **delta 不落库**：重连靠 durable 消息 + 新 delta 补齐。
5. **迁移是 TS 文件**：启动自动应用；V1 只保留导入器。
6. **插件用 `ctx.storage`**，不要直接操作数据库。

> **迁移小注**：旧文档的 `session_input`、`session_context_epoch`、
> `message`/`part` 兼容表、`opencode db` 子命令、`storage/*.json` 都是 V1；
> V2 对应 `session_inbox`、`instruction_state`、`session_message`、`sqlite3`。
