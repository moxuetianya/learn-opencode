# OpenCode V2 源码学习笔记

> 本目录**只讲 OpenCode V2**（当前仓库 `package.json` 版本 2.0.24）。
> 所有代码位置以 `packages/core`、`packages/cli`、`packages/server`、`packages/protocol`、
> `packages/tui`、`packages/client`、`packages/schema` 为准。
>
> **V1 仅作一句带过**：V1 运行时（`packages/opencode` 的 `SessionPrompt`、`runLoop`、
> `session_input` 等）已经从源码树移除，`packages/opencode` 只剩构建产物。
> 当前仅保留少量兼容代码，主要有 `packages/core/src/v1/config/*`（把旧配置键归一化到 V2）、
> `packages/core/src/database/v1-migration*`（旧数据导入），以及 CLI 的旧参数桥接
> （`packages/cli/src/run/v1.ts`）。它们属于迁移/入口细节，不是本教程的阅读对象；
> 正文只在「迁移/历史」小注里提一句。
>
> **写法约定**：以**讲清原理和扩展点**为主，代码只作为佐证与上手示例。
> 若你主要想开发插件/工具，先读 **06 → 05 → 02**，再直接看 `code-examples.md`。

---

## 📚 课程目录

| 课 | 文件 | 主题 |
|---|---|---|
| 总览 | [`OpenCode-MultiAgent-Learning-Guide.md`](./OpenCode-MultiAgent-Learning-Guide.md) | 五条主线速览 + 学习路径 |
| 01 | [`01-tui-startup-and-config.md`](./01-tui-startup-and-config.md) | 一次启动：命令 → daemon/standalone → TUI 就绪 |
| 02 | [`02-conversation-agent-loop.md`](./02-conversation-agent-loop.md) | 一次对话：提交 → 准入 → runner → 流式事件 |
| 03 | [`03-input-concurrency.md`](./03-input-concurrency.md) | 执行中的新输入：Inbox、steer/queue、协调器 |
| 04 | [`04-v2-session-core-map.md`](./04-v2-session-core-map.md) | V2 Session Core 术语、不变式、入口总表 |
| 05 | [`05-agent-core.md`](./05-agent-core.md) | Agent / Tool / Skill / System Prompt 的 V2 内核 |
| 06 | [`06-hook-mechanism.md`](./06-hook-mechanism.md) | Plugin 与 Hook：扩展点、注册顺序、执行语义 |
| 07 | [`07-ui-layer.md`](./07-ui-layer.md) | CLI / TUI / HTTP Server / Client 接入层 |
| 08 | [`08-config-loading.md`](./08-config-loading.md) | 配置全景：来源、发现顺序、`cli.json`、状态文件 |
| 09 | [`09-server-client-architecture.md`](./09-server-client-architecture.md) | Server / Client 职责、工具执行位置、daemon 共享 |
| 10 | [`10-storage-sqlite.md`](./10-storage-sqlite.md) | 全局 SQLite、事件溯源、表结构、备份 |
| 11 | [`11-service-lifecycle.md`](./11-service-lifecycle.md) | 后台服务生命周期：发现、拉起、停止、重启恢复 |
| 12 | [`12-background-task-notify.md`](./12-background-task-notify.md) | 后台任务完成通知与自动唤醒 |
| 13 | [`13-plugin-loading-pipeline.md`](./13-plugin-loading-pipeline.md) | 插件系统全链路：TUI/Server 双端加载、Effect Layer 依赖图、入口与目录 |
| 附 | [`code-navigation.md`](./code-navigation.md) | V2 代码地图 |
| 附 | [`code-examples.md`](./code-examples.md) | V2 API / 插件 / 配置示例 |
| 附 | [`QA.md`](./QA.md) | 学习问答：steer/queue、execution、drain、收件箱与控制项；构建/channel、配置与数据目录、多实例定制、location 与环境变量 |
| 附 | [`effect-yield-pipe-fork.md`](./effect-yield-pipe-fork.md) | 读 Effect 代码的读法：`yield*` / `pipe` / `forkScoped`、Queue 生产者-消费者、与 Rust 对照 |
| 附 | [`local-release-build.md`](./local-release-build.md) | 本地构建正式版：`script/build-release.sh` 用法、channel/version 语义、冒烟与排错 |
| 附 | [`instruction-delta-and-cache.md`](./instruction-delta-and-cache.md) | 指令变更如何进入会话：基线 vs 增量、会话账本、AGENTS.md/skill 检测矩阵、缓存账、compaction/revert/fork |

阅读顺序就是编号顺序：**01 → 02 → 03 → 04 → 05 …**。
前四课先把"一次启动 + 一次对话 + 并发边界 + 核心不变式"跑通；
05 之后按兴趣深入 Agent、插件、UI、配置、存储与服务生命周期。

### 想开发插件 / Tool？走这条

```
06（Transform / Hook / 加载顺序）
  → 05（Agent / Tool / Skill 的数据结构）
  → 02（一次请求里 hook 的触发位置）
  → code-examples.md（最小可运行骨架）
  → 按需回查 01（启动） / 08（配置） / 10（持久化）
```

想搞清插件**是怎么被发现、安装、加载、热重载**的（含双端入口与目录规则），再读 **13（插件全链路）**。

不要在没读 06 的情况下直接抄旧版 `Hooks` 接口——V1 的 hook 名称已经全部改名。

---

## 🧭 先记住这张分层图

```
@opencode/schema     纯协议/存储契约（无运行时行为）
        ▲
        ├── @opencode/protocol   HTTP HttpApi 定义（/api/*）
        │           ▲
        │           └── @opencode/server   协议 → Core handler 绑定
        │
        └── @opencode/core      领域运行时（SQLite、Session、Runner、Tool…）
                    ▲
                    ├── @opencode/cli       命令 + TUI 宿主
                    ├── @opencode/tui       Solid/OpenTUI 界面
                    └── @opencode/client    浏览器安全的客户端运行时
```

依赖方向是硬规则：**client 只能依赖 schema / protocol，不能依赖 core / server**。
`packages/sdk-next` 才把 client + core + server 组装在一起。

---

## ▶️ 本地跑起来

```bash
# 默认 TUI（连接当前安装的 opencode 后台服务）
bun run dev:live

# 指定项目目录
bun run dev:live /path/to/project

# 只看 CLI 非交互输出
bun run dev -- run "解释这个仓库的目录结构"

# 起一个前台 server（不做服务发现）
bun run dev -- serve
```

`dev:live` 会自动读取 `opencode service status` / `opencode service get password`，
让开发中的 TUI 连上正在运行的 daemon。后台服务生命周期见第 11 课。

---

## ✅ 读代码时的三个提醒

1. **先看 `packages/core/src/session/`**：`inbox.ts` → `run-coordinator.ts` →
   `execution.ts` → `runner/llm.ts` → `runner/step.ts`，这是 V2 的心脏。
2. **不要用行号定位**：V2 迭代很快，本目录优先引用**文件 + 导出名/函数名**。
3. **看到 `v1/` 目录可以跳过**：那是配置/数据迁移兼容层，不属于现行运行时。

---

## 🔗 参考

- 仓库源码：当前工作区（`packages/*`）
- 根约束：`AGENTS.md` 的 **V2 Session Core** 一节
- 协议契约：`packages/schema/src/session-*.ts`、`packages/protocol/src/groups/*.ts`
- Effect 文档：https://effect.website
