# 附录 A：V2 代码地图

> 这是**辅助索引**，不是教程主线。建议先读 05/06，再回来按目录查。
> 所有路径基于当前工作区（opencode 2.0.24）。
>
> 不要按行号记代码；V2 迭代快，本页只给目录与职责。

---

## A.1 顶层包

```
packages/
├── schema/       契约：事件、消息、Inbox、Config、Tool、Model、Permission…
├── protocol/     HttpApi 定义：/api/*
├── server/       HTTP 绑定、handler、中间件、进程启动
├── core/         领域运行时（本目录最重要）
├── client/       客户端运行时（promise / effect / solid）
├── cli/          命令树、非交互 run、服务连接、TUI 宿主
├── tui/          终端 UI（Solid + OpenTUI）
├── session-ui/   会话/消息/工具/diff 的共享组件
├── app/          Web 应用
├── desktop/      Electron 壳
├── plugin/       插件类型与运行时（effect / promise / tui）
├── ai/           LLM 抽象：协议、provider 包、LLMEvent、compact
├── util/         Global、FSUtil、Npm、Flock、LayerNode、Effect 工具
└── sdk-next/     client + core + server 的组合包
```

依赖方向：

```
schema → protocol → server
schema → core → server
schema/protocol → client
client + core + server → sdk-next
```

client **不能**依赖 core/server。

---

## A.2 Core 目录

```
packages/core/src/
├── session.ts                  Session.Service：create/fork/prompt/inbox/compact/interrupt…
├── session/
│   ├── session.ts              入口实现：prompt / synthetic / interrupt / revert
│   ├── inbox.ts                durable 收件箱：admit / promote / delivery
│   ├── run-coordinator.ts      每 Session 单 drain、wake 合并
│   ├── execution.ts            进程级执行路由、claim、终态
│   ├── execution/restart.ts    重启恢复扫描
│   ├── runner/
│   │   ├── index.ts            SessionRunner Service / DrainResult
│   │   ├── llm.ts              drain / advanceToStep / runStep
│   │   ├── step.ts             一次 Physical Attempt：llm.stream + 工具 fiber
│   │   ├── model.ts            会话模型解析
│   │   ├── retry.ts            重试策略
│   │   ├── to-llm-message.ts   投影 → LLM 消息
│   │   └── publish-llm-event.ts LLMEvent → SessionEvent
│   ├── context.ts              select/load：agent、instructions、tools、model、history
│   ├── model-request.ts        LLMRequest 组装 + session hooks
│   ├── prompt.ts               输入准备：附件、skill、session.prompt hook
│   ├── history.ts              投影历史读取（compaction/epoch 感知）
│   ├── compaction.ts           auto/overflow/manual 压缩
│   ├── instructions.ts         会话级 instruction 来源
│   ├── instruction-state.ts    指令纪元与增量
│   ├── projector.ts            durable 事件 → 表投影
│   ├── store.ts                会话读模型 + claim
│   ├── system-prompt.ts        默认 system prompt
│   └── sql.ts                  会话域表
├── tool.ts                     Tool.Service：注册、快照、执行
├── tool/plugin/*.ts            内置工具（每个都是插件）
├── skill.ts                    Skill.Service
├── skill/instructions.ts       skill 摘要注入
├── skill/discovery.ts          URL skill 拉取
├── agent.ts                    Agent.Service
├── config.ts                   Config.Service + discovery/load/reload
├── config/plugin/*.ts          配置 → 注册表的桥
├── plugin.ts                   插件激活注册表
├── plugin/hooks.ts             PluginHooks：注册/trigger
├── plugin/supervisor.ts        内置 + 外部插件编排
├── plugin/internal.ts          pre/post 内置插件清单
├── plugin/module.ts            外部插件加载
├── bus.ts                      publish / subscribe / log / replay
├── database/                   SQLite、迁移、pragma
├── job.ts                      Job：后台任务 + KV 恢复
├── permission.ts               权限评估与询问
├── integration.ts              集成/凭据连接
├── provider.ts                 provider 定义与包加载
├── model.ts / model-resolver.ts 模型目录与运行时解析
├── instructions/               Instructions 代数与内建
├── instruction-discovery.ts    AGENTS.md
├── mcp/                        MCP 客户端与工具
├── filesystem/ shell/ pty/     Location 范围基础设施
├── location*.ts                Location 服务图与生命周期
└── v1/config/*                 **旧配置归一化，跳过**
```

---

## A.3 CLI 目录

```
packages/cli/src/
├── index.ts                    入口
├── commands/
│   ├── commands.ts             命令树
│   └── handlers/
│       ├── default.ts          默认 TUI
│       ├── run.ts              非交互
│       ├── serve.ts            server
│       ├── service/*           后台服务
│       ├── auth/ mcp/ plugin/ 管理命令
│       └── debug/*             config/agents/paths
├── run/run.ts                  run 参数与 session target
├── run/noninteractive.ts       事件消费与输出
├── services/
│   ├── server-connection.ts    endpoint 解析
│   ├── service-config.ts       service.json 配置
│   ├── service-registration.ts 注册/自检
│   ├── standalone.ts           私享 server
│   └── updater.ts
├── server-process.ts           serve 进程
├── database-path.ts            库文件选择
└── config/                     cli.json
```

---

## A.4 TUI / Client

```
packages/tui/src/
├── app.tsx                     run() + Provider 树
├── context/
│   ├── client.tsx              client + event emitter
│   ├── data.tsx                createData 包装
│   ├── local.tsx               agent/model 选择
│   ├── session-terminals.tsx   持久终端
│   ├── route.tsx / permission.tsx / prompt.tsx
│   └── storage.tsx             本地状态
├── component/prompt/index.tsx  提交逻辑
├── routes/session/             会话视图
├── prompt/                     历史、frecency、stash
└── plugin/                     TUI 插件宿主

packages/client/src/
├── promise/                    Promise client
├── effect/                     Effect client + Service
└── solid/
    ├── data.ts                 数据仓库 + 乐观提交
    └── connection.ts           SSE 连接、10ms batch、重连
```

---

## A.5 Server / Protocol

```
packages/protocol/src/
├── api.ts                      组合所有 group
├── groups/session.ts           /api/session/*
├── groups/event.ts             /api/event
├── groups/pty.ts               终端
└── groups/*.ts                 agent/model/provider/tool…

packages/server/src/
├── process.ts                  listen / dispatch / boot
├── routes.ts                   LayerNode + HttpApiBuilder
├── api.ts                      Api 实例
├── handlers/*.ts               每个 group 的 handler
├── location.ts                 Location 中间件
├── middleware/                 auth / schema-error / session-location
└── auth.ts / cors.ts / pairing.ts
```

---

## A.6 按主题找代码

| 我想了解/修改 | 先看 |
|---|---|
| 一次对话怎么跑 | `core/src/session/runner/llm.ts`、`step.ts` |
| 新输入怎么排队 | `core/src/session/inbox.ts`、`run-coordinator.ts` |
| 工具怎么注册/执行 | `core/src/tool.ts`、`tool/plugin/*` |
| 插件怎么写 | `plugin/src/effect/*`、`core/src/plugin/*` |
| 配置从哪来 | `core/src/config.ts`、`config/discovery.ts`、`config/plugin/*` |
| TUI 怎么渲染 | `tui/src/app.tsx`、`client/src/solid/data.ts`、`session-ui/src/*` |
| HTTP 有哪些接口 | `protocol/src/groups/*` |
| 数据表 | `core/src/session/sql.ts`、`event/sql.ts`、`database/schema.gen.ts` |
| 后台任务 | `core/src/job.ts`、`session/subagent-*.ts` |
| 服务生命周期 | `client/src/effect/service.ts`、`cli/src/services/*` |
| 重启恢复 | `core/src/session/execution/restart.ts` |

---

## A.7 阅读顺序

### 想开发插件/工具

```
1. 01（组件）+ 02（扩展点）
2. code-examples.md（最小插件/工具）
3. tool.ts + tool/plugin/skill.ts（内置工具长什么样）
4. plugin/hooks.ts + session/model-request.ts（hook 何时触发）
5. 06（请求组装全链路）
```

### 想理解会话内核

```
1. 05 + 06
2. inbox.ts
3. run-coordinator.ts
4. execution.ts
5. runner/llm.ts
6. runner/step.ts
7. context.ts + model-request.ts
8. compaction.ts + history.ts
```

### 想理解数据/恢复

```
1. 09
2. bus.ts
3. session/projector.ts
4. session/store.ts
5. execution/restart.ts
6. job.ts
```

---

*最后更新：2026-10（opencode 2.0.24）*
