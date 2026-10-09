# 12. V2 Session Core 知识地图：术语、不变式与代码索引

> 本课是前 11 课的收口：把 v2 会话核心的**术语、不变式、所有"主动发起"入口**汇总成一张地图，
> 并给出按图索骥的源码阅读顺序。内容依据仓库根 `AGENTS.md` 的 "V2 Session Core" 约束与
> `packages/core/src/session/` 当前实现整理；与前几课重叠处只放索引。

## 12.1 词汇表（严格语义）

| 术语 | 定义 | 代码 |
|---|---|---|
| **Step** | 一次**逻辑 LLM 调用**；durable 记录只覆盖模型可见区间。不要把单次调用叫 "provider turn"，更不要叫 "turn" | `runner/step.ts` |
| **Turn** | 保留词：未来的 assistant-turn 单位 = 从 prompt 提升到会话将空闲之间的**所有** step。目前代码中不要用它指单次调用 | AGENTS.md 约定 |
| **Physical Attempt** | 一次真实的 provider 请求尝试；**每个 Attempt 恰一次 `llm.stream`**。逻辑 step 可含：通用重试（不消耗 step 配额）、拒绝后全量上下文重试、不完整流续流、超限压缩重建 | `runner/retry.ts`、`model-transport.ts` |
| **Delivery** | 收件箱投递模式：`steer`（默认，边界插队）/ `queue`（挂起，空闲边界一次一条） | `session/inbox.ts`、`@opencode/schema/session-inbox` |
| **Promote / Deliver** | promote = 把 pending inbox 行变成可见消息；deliver = `session.inbox.delivered` 事件，**同事务**消费行 + 插入消息投影 | `inbox.ts:496` `promote` |
| **Claim / Release** | write-ahead 执行声明：started 事件同事务写 `time_suspended`；终态释放；shutdown/崩溃保留 → 重启恢复标记 | `execution.ts:81`、`store.ts:205` |
| **Wake** | 协调器的"门铃"：运行中合并（`pendingWake`），空闲起新 drain；`resume: false` 的 admit 不产生 wake | `run-coordinator.ts:136` |
| **Admit-only** | `resume: false` 语义：只准入不调度执行（用户 shell 通知、重启恢复通知） | `session.ts:145-177` |
| **Location** | `{directory, workspaceID?, project}`：runner/模型解析/工具/权限/FS 的放置单元；缺省 workspaceID = 隐式本地 | 第 8 课 §8.6 |
| **Instruction epoch** | 指令纪元：compaction 完成推进 epoch；会话移动保留；revert 提交清除 | AGENTS.md V2 Session Core |
| **Contender** | 客户端为拉起服务 spawn 的候选 daemon 进程；多者竞争由注册文件仲裁 | 第 10 课 §10.4 |

## 12.2 不变式清单（AGENTS.md 约束 ↔ 代码落点）

**准入与执行分离**

- `Session.prompt` 发布 `session.inbox.enqueued` → 投影插入一行 `session_inbox` →
  才调度 advisory `wake`；`resume: false` 只准入。
  `packages/core/src/session/session.ts:145`；`session_inbox` 只存未消费工作。
- 复用收件箱/会话 ID 的幂等规则：复用 Session ID = 收养既有会话；同 Session 同类型复用
  user/synthetic 条目 ID 幂等（首次准入获胜，重试负载被忽略）；跨 Session/跨类型失败。

**投递秩序**

- steer 默认。安全 step 边界：steered compaction 优先（直到第一个 steered move 控制项为止），
  其余 steer 保持入队顺序；空闲边界：steer 优先，否则一次只提升一条 queue，随后重新评估续跑。
- 提升（新用户输入）重置所选 agent 的 step 配额；一批 steer 只重置一次。
  `runner/llm.ts:71-195`、`inbox.ts:496-531`。

**模型调用与压缩**

- 每 Physical Attempt 恰一次 `llm.stream`；续跑前重载投影历史；durable continuation。
- provider 专属的原生压缩封在 `@opencode/ai` 的 `LLMClient.compact` 之后；
  `SessionCompaction` 依据模型 `compaction` 设置选 summary 或 native，并独占
  路由来源、请求收缩、重试策略、中断、用量记账、checkpoint 持久化。
  `packages/core/src/session/compaction.ts`（触发器：`auto`/`overflow`/`manual`，§12.4）。

**指令系统**

- Instructions 代数与内建在 `src/instructions`；指令生产者跟着它们的观察域走；
  会话历史选择 + `InstructionState`/`InstructionEntry` 持久化归 Session 所有；
  `InstructionDiscovery` 观察环境级与向上投影的指令；runner 在 `loadInstructions` 里显式组装
  —— **没有指令注册表**。
- `session.instructions.updated` 只存变更源的 key + 内容 hash；blob 值单份存 `instruction_blob`；
  投影行 `instruction_state` 是常规读取边界。epoch 规则见词汇表。
  `packages/core/src/session/instructions.ts`、`instruction-state.ts`。

**所有权与放置**

- `SessionExecution` 进程全局、按 Session ID；本地实现拥有进程内协调器，仅在 drain 开始时经
  `SessionStore` + `LocationServiceMap.get(session.location)` 发现放置——**任何层都不该持有
  Session ID 之外的东西**。
- `SessionRunner`、模型解析、工具注册表、权限、文件系统都是 **Location 范围**。
- V2 中断目标是本进程的活跃所有权链：已知名但空闲/非本进程所有 → no-op；公共 API 对未知
  Session 报错。`execution.ts:150-174`。
- 本地 drain 是进程内的（集群化之前）；`SessionRunCoordinator` 合并同 Session resume、
  合并 prompt wake，允许不同 Session 并行。

**事件与投影**

- durable 事件只记**不可约新事实**；可由有序聚合史推导的状态不要重复记录；
  消费者需要自洽视图时把先前/派生状态放进**投影与读模型**（enrichment）。
  `bus.ts`（发布=单事务：投影 + event 行 + PubSub 扇出）、第 9 课。

## 12.3 "谁会主动发起/推进对话"——全部入口总表

| 入口 | 准入类型 | 默认 delivery | wake? | 代码 |
|---|---|---|---|---|
| 用户 prompt | `user` | `steer` | ✅（`resume:false` 可关） | `session.ts:145` |
| synthetic（通用） | `synthetic` | `steer` | ✅（`resume:false` 可关） | `session.ts:273` |
| agent 后台 shell 完成 | `synthetic` | `steer` | ✅ | 第 11 课 |
| 用户提交 shell 完成 | `synthetic` | `steer` | ❌ admit-only | `session.ts:213` |
| 重启恢复通知（shell/重启提示） | `synthetic` | `steer` | ❌（shell）/ 会话本身被 resume | `restart.ts` |
| subagent 完成 | `synthetic`（父会话） | `steer` | ✅（默认；仅重启恢复且父会话 suspended 时 `resume:false`） | `subagent-completion.ts` |
| `/compact`（手动压缩） | `compaction` 控制项 | `steer` | ✅ | `session.ts:246` |
| 会话移动（move） | `move` 控制项 | — | ✅（换 Location 重入） | `move.ts`、`inbox.ts` |
| skill 激活 | 事件 + 可见消息 | — | ✅（`resume:false` 可关） | `session.ts:223` |
| 上/下文指令文件变化 | synthetic 注入（去重账本） | — | 随当前执行 | `instructions.ts` |
| 重启恢复（claim 存活） | resume 整个会话 | — | ✅（resume 本身） | 第 10 课 §10.7 |

控制项优先级：`promote` 在任何边界都不越过第一个 `compaction`/`move` 控制项；
steered compaction 在 step 边界插队到最前（`inbox.ts:533` `pendingSteers` 的重排）。

## 12.4 Compaction 触发速查（`compaction.ts:53`）

| reason | 触发 | 行为 |
|---|---|---|
| `auto` | 上下文接近模型上限（`buffer` 默认留 10% 空闲，`keep` 保留近期原文） | 放得下/关闭自动则跳过 |
| `overflow` | provider 刚拒绝：上下文超长 | 一个 step 的兜底重建 |
| `manual` | `/compact` inbox 条目（inputID 对应用户可见消息） | steered，边界优先 |

## 12.5 源码阅读路径建议

按依赖顺序读，每步都有前几课对应：

```
1. schema          @opencode/schema/session-inbox、persistent-pty   # 数据形状
2. 收件箱          core/src/session/inbox.ts                        # 第 4/11 课
3. 协调器          core/src/session/run-coordinator.ts              # wake/claim 语义
4. 执行            core/src/session/execution.ts                    # claim 同事务、中断
5. runner          core/src/session/runner/llm.ts                   # 边界循环、step 配额
6. 恢复            core/src/session/execution/restart.ts            # 第 10 课
7. 服务生命周期    client/src/effect/service.ts + cli/src/services/ # 第 10 课
8. 工具            core/src/tool/plugin/{shell,subagent}.ts         # 第 11 课
9. 压缩/指令      core/src/session/{compaction,instructions}.ts    # 本课 §12.2
```

对照根 `AGENTS.md` 的 "V2 Session Core" 一节逐条核对——那份约束就是这套代码的规格说明。

## 12.6 易混点澄清

- **"turn" 不要乱用**：文档/代码评审里说单次 LLM 调用用 **step**；"turn" 留给未来
  assistant-turn 单位。
- **wake ≠ 执行**：wake 只是 advisory 门铃；真正的调度在协调器；admit-only（`resume:false`）
  完全不响铃。
- **交付 ≠ 可见**：inbox 行只有在 `promote`（delivered 事件）后才变成可见消息；
  `session_inbox` 里永远只有未消费的工作。
- **共享状态 ≠ 共享进程**：老 TUI 每个 worker 一个内嵌 server，但全局 SQLite（WAL）让它们
  看到同一份数据（第 8 课 §8.4.2）。
- **服务死 ≠ 会话丢**：执行状态全在 SQLite（claim、inbox、消息投影、Job KV），
  daemon 死了被调活后一切续上（第 10 课）。
