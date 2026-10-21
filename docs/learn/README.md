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
> 若你主要想开发插件/工具，先读 **02 → 01 → 06**，再直接看 `code-examples.md`。

---

## 📚 课程目录

| 课 | 文件 | 主题 |
|---|---|---|
| 总览 | [`OpenCode-MultiAgent-Learning-Guide.md`](./OpenCode-MultiAgent-Learning-Guide.md) | 五条主线速览 + 学习路径 |
| 01 | [`01-agent-core.md`](./01-agent-core.md) | Agent / Tool / Skill / System Prompt 的 V2 内核 |
| 02 | [`02-hook-mechanism.md`](./02-hook-mechanism.md) | Plugin 与 Hook：扩展点、注册顺序、执行语义 |
| 03 | [`03-ui-layer.md`](./03-ui-layer.md) | CLI / TUI / HTTP Server / Client 接入层 |
| 04 | [`04-input-concurrency.md`](./04-input-concurrency.md) | 执行中的新输入：Inbox、steer/queue、协调器 |
| 05 | [`05-tui-startup-and-config.md`](./05-tui-startup-and-config.md) | 一次启动：命令 → daemon/standalone → TUI 就绪 |
| 06 | [`06-conversation-agent-loop.md`](./06-conversation-agent-loop.md) | 一次对话：提交 → 准入 → runner → 流式事件 |
| 07 | [`07-config-loading.md`](./07-config-loading.md) | 配置全景：来源、发现顺序、`cli.json`、状态文件 |
| 08 | [`08-server-client-architecture.md`](./08-server-client-architecture.md) | Server / Client 职责、工具执行位置、daemon 共享 |
| 09 | [`09-storage-sqlite.md`](./09-storage-sqlite.md) | 全局 SQLite、事件溯源、表结构、备份 |
| 10 | [`10-service-lifecycle.md`](./10-service-lifecycle.md) | 后台服务生命周期：发现、拉起、停止、重启恢复 |
| 11 | [`11-background-task-notify.md`](./11-background-task-notify.md) | 后台任务完成通知与自动唤醒 |
| 12 | [`12-v2-session-core-map.md`](./12-v2-session-core-map.md) | V2 Session Core 术语、不变式、入口总表 |
| 附 | [`code-navigation.md`](./code-navigation.md) | V2 代码地图 |
| 附 | [`code-examples.md`](./code-examples.md) | V2 API / 插件 / 配置示例 |

建议顺序：**总览 → 05 → 06 → 04 → 12 → 其余专题**。
05/06 先把"一次启动 + 一次对话"跑通，04/12 再收口并发与不变式。

### 想开发插件 / Tool？走这条

```
02（Transform / Hook / 加载顺序）
  → 01（Agent / Tool / Skill 的数据结构）
  → 06（一次请求里 hook 的触发位置）
  → code-examples.md（最小可运行骨架）
  → 按需回查 05（启动） / 07（配置） / 09（持久化）
```

不要在没读 02 的情况下直接抄旧版 `Hooks` 接口——V1 的 hook 名称已经全部改名。

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
让开发中的 TUI 连上正在运行的 daemon。后台服务生命周期见第 10 课。

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
