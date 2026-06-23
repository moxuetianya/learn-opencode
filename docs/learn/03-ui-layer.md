# 3. UI 接入层：CLI、TUI、HTTP Server

## 3.1 架构概览

opencode 有三条主要 UI/接入路径，其中 CLI 和 TUI 直接与内核通信（进程内调用），Web/Desktop/外部集成通过 HTTP API Server：

```
                     ┌──────────────────────────────┐
                     │        用户交互入口           │
                     └──────────────┬───────────────┘
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
    ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
    │   CLI (非交互)    │  │  TUI (交互式终端) │  │  Web/Desktop     │
    │  opencode run     │  │  opencode tui     │  │  opencode web    │
    └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘
             │                     │                     │
             │ 进程内调用          │ Worker Thread + RPC  │  HTTP
             │                     │                     │
             ▼                     ▼                     ▼
    ┌──────────────────┐  ┌──────────────────────────────────────┐
    │   opencode 内核   │  │           HTTP API Server            │
    │   (直接调用)      │  │        (packages/server)             │
    │  SessionPrompt    │  │  /session, /message, /agent, /model, │
    │  .loop()         │  │  /provider, /skill, /event,          │
    └────────┬─────────┘  │  /permission, /command, /question,    │
             │            │  /reference, /fs, /pty, /health       │
             │            └──────────────────┬───────────────────┘
             │                               │
             └───────────────┬───────────────┘
                             ▼
                    ┌──────────────────┐
                    │  opencode 内核   │
                    │  (packages/     │
                    │   opencode)      │
                    └─────────────────┘
```

### 核心文件

| 文件 | 职责 |
|------|------|
| `packages/cli/src/index.ts` | CLI 入口 boot 文件 |
| `packages/opencode/src/cli/cmd/run.ts` | `opencode run` 命令（非交互 + 交互式） |
| `packages/opencode/src/cli/cmd/tui.ts` | `opencode tui` 命令（TUI 启动） |
| `packages/opencode/src/cli/cmd/run/tool.ts` | CLI 工具输出渲染（1489行核心渲染逻辑） |
| `packages/tui/src/app.tsx` | TUI 主应用入口（React/Ink） |
| `packages/server/src/api.ts` | HTTP API 定义（Effect HttpApi） |
| `packages/server/src/routes.ts` | HTTP 路由表 |
| `packages/sdk/js/` | JavaScript SDK（外部集成接口） |

---

## 3.2 CLI 命令模式

### 3.2.1 命令注册

CLI 使用 `yargs` 框架，通过 `packages/opencode/src/cli/cmd/cmd.ts` 的 `cmd()` 函数注册命令。

主要命令：
- `opencode run [prompt]` — 发送 prompt 并流式输出
- `opencode tui [project]` — 启动交互式终端 UI
- `opencode serve` — 启动 HTTP API 服务器
- `opencode agent`、`session`、`models`、`providers` 等管理命令

### 3.2.2 `opencode run` 三种模式

`packages/opencode/src/cli/cmd/run.ts`：

```
opencode run "hello"
  │
  ├─ 非交互模式 (默认)
  │  ├─ 发送 prompt → 创建/恢复 session
  │  ├─ 调用 SessionPrompt.loop()
  │  └─ 流式输出 LLM 事件到 stdout，session idle 后退出
  │
  ├─ 交互式本地 (--interactive)
  │  ├─ 启动内嵌 HTTP server
  │  └─ 使用 split-footer 直接模式 (无外部 HTTP)
  │
  └─ 交互式 attach (--interactive --attach)
     ├─ 连接到运行中的 opencode server
     └─ 通过 SDK Client 交互
```

CLI 输出渲染在 `packages/opencode/src/cli/cmd/run/tool.ts`（1489行）中处理，包括：
- 工具调用图标和标题
- 工具输出截断
- 代码 diff 高亮
- 文件操作展示
- 子代理进度

### 3.2.3 交互式输入

`packages/opencode/src/cli/cmd/run/runtime.stdin.ts`：
- 支持管道输入（`echo "..." | opencode run`）
- 支持 stdin 交互（TTY 模式）
- 解析 interactive stdin 指令

---

## 3.3 TUI 终端界面

### 3.3.1 启动流程

`packages/opencode/src/cli/cmd/tui.ts`：

```
opencode tui
  │
  ├─ 1. 解析参数（project, model, continue, session, fork, prompt 等）
  ├─ 2. resolveThreadDirectory() 确定工作目录
  ├─ 3. 启动 Worker Thread：
  │     └─ new Worker(target()) → 运行 tui/worker.ts
  ├─ 4. 通过 RPC 与 Worker Thread 通信：
  │     ├─ createWorkerFetch() — 代理 fetch 请求
  │     └─ createEventSource() — 代理事件订阅
  └─ 5. 加载 TUI UI 组件（packages/tui/）
```

### 3.3.2 Worker Thread 架构

主线程（TUI UI）通过 RPC 与 Worker Thread 通信：

```
┌─ Main Thread ────────────────────┐    ┌─ Worker Thread ───────────────┐
│                                  │    │                               │
│  React/Ink 组件                  │    │  opencode 内核                │
│  ├─ App 组件                     │    │  ├─ SessionPrompt.loop()      │
│  ├─ 聊天界面                     │    │  ├─ Plugin 管理               │
│  ├─ 输入框                       │ RPC│  └─ HTTP Server               │
│  ├─ 工具输出展示                 │◀──▶│                               │
│  └─ 权限确认对话框               │    │  Worker 暴露的方法：          │
│                                  │    │  ├─ fetch(url, opts)          │
│  createWorkerFetch()             │    │  ├─ global.event → 事件推送   │
│  createEventSource()             │    │  └─ 其他 opencode API         │
│                                  │    │                               │
└──────────────────────────────────┘    └───────────────────────────────┘
```

### 3.3.3 TUI 组件架构

`packages/tui/src/`：

```
app.tsx                    # 主应用入口
├── context/               # React Contexts
│   ├── event.ts           # 全局事件流
│   ├── thinking.ts        # 思考状态
│   ├── directory.ts       # 当前目录
│   └── editor.ts          # 编辑器集成
├── component/             # UI 组件
│   ├── bg-pulse-render.ts # 背景脉冲动画
│   └── prompt/            # Prompt 相关组件
│       ├── local-attachment.ts  # 文件附件
│       └── cwd.ts         # 当前目录显示
├── prompt/                # Prompt 渲染
│   ├── traits.ts          # 特性处理
│   ├── part.ts            # Part 渲染
│   └── display.ts         # 显示逻辑
├── routes/                # 路由
├── util/                  # 工具函数
│   ├── tool-display.ts    # 工具输出展示
│   ├── transcript.ts      # 对话转录
│   ├── renderer.ts        # Markdown 渲染
│   ├── revert-diff.ts     # 回退 diff
│   ├── collapse-tool-output.ts  # 折叠工具输出
│   └── ...
├── theme/                 # 主题系统
├── plugin/                # TUI 插件集成
│   ├── api.ts
│   └── command-shim.ts
├── feature-plugins/       # 功能插件
│   ├── builtins.ts
│   └── system/
├── keymap.tsx             # 键盘绑定
├── clipboard.ts           # 剪贴板
├── audio.ts               # 音频
└── editor.ts              # 编辑器集成
```

### 3.3.4 TUI 功能特性

- **React/Ink** 渲染，终端原生体验
- 实时流式文本显示（Markdown 渲染）
- 工具调用的分块/折叠展示
- 权限确认对话框
- 会话历史滚动回溯
- 主题系统（支持自定义颜色）
- 键盘快捷键绑定
- 文件 diff 展示
- 子代理进度跟踪
- 音频提示

---

## 3.4 HTTP API Server

### 3.4.1 API 架构

`packages/server/src/api.ts` 使用 Effect `HttpApi` 定义 REST API：

```ts
// 路由组
agent      → /api/agent/*
session    → /api/session/*
message    → /api/message/*
model      → /api/model/*
provider   → /api/provider/*
skill      → /api/skill/*
event      → /api/event/*
permission → /api/permission/*
command    → /api/command/*
question   → /api/question/*
reference  → /api/reference/*
fs         → /api/fs/*
pty        → /api/pty/*
health     → /api/health
location   → /api/location
```

### 3.4.2 Server 启动

`packages/opencode/src/server/server.ts`：
- 内嵌 HTTP server（基于 Hono? 或自定义）
- 支持 Unix socket 和 TCP 端口
- 自动选择可用端口
- 认证中间件

### 3.4.3 关键 API 端点

**Session API** (`/api/session`)：
- `POST /api/session` — 创建 session
- `GET /api/session/:id` — 获取 session
- `POST /api/session/:id/prompt` — 发送 prompt
- `POST /api/session/:id/cancel` — 取消运行

**Message API** (`/api/message`)：
- `GET /api/session/:id/messages` — 获取消息列表
- 支持分页

**Event API** (`/api/event`)：
- SSE (Server-Sent Events) 实时事件流
- 事件类型包括：`text.delta`、`tool.call`、`tool.result`、`step.finish` 等

**File System API** (`/api/fs`)：
- 文件读写、目录浏览

**PTY API** (`/api/pty`)：
- 伪终端管理

### 3.4.4 中间件

`packages/server/src/middleware/`：
- `authorization.ts` — Token 认证
- `schema-error.ts` — Schema 错误处理
- `session-location.ts` — Session 位置解析

---

## 3.5 JavaScript SDK

### 3.5.1 SDK 生成

`packages/sdk/js/script/build.ts` — 生成 TypeScript SDK

```bash
./packages/sdk/js/script/build.ts
```

### 3.5.2 SDK 使用

```ts
import { createOpencodeClient } from "@opencode-ai/sdk"

const client = createOpencodeClient({
  baseUrl: "http://localhost:4096",
  directory: "/path/to/project",
})

// Session 操作
const session = await client.session.create({})
await client.session.prompt(session.id, {
  parts: [{ type: "text", text: "hello" }],
  agent: "general",
})

// 订阅事件
client.event.subscribe((event) => {
  console.log(event.type, event.data)
})

// 工具执行
const result = await client.session.shell(session.id, {
  command: "ls -la",
  agent: "general",
})
```

---

## 3.6 Web UI 组件

`packages/ui/src/` 提供可复用的 React 组件：

```
components/
├── message-file.ts          # 文件消息展示
├── message-part-text.ts     # 文本消息
├── markdown-stream.ts       # Markdown 流式渲染
├── markdown-code-state.ts   # 代码块状态
├── markdown-worker*.ts      # Web Worker Markdown 渲染
├── apply-patch-file.ts      # Patch 应用
├── session-diff.ts          # Session diff 展示
└── scroll-view.test.ts      # 滚动视图

pierre/                      # Code review 组件
├── file-find.ts             # 文件查找
├── file-selection.ts        # 文件选择
├── diff-selection.ts        # Diff 选择
├── comment-hover.ts         # 注释悬浮
├── virtualizer.ts           # 虚拟滚动
└── ...

theme/                       # 主题系统
├── types.ts                 # 主题类型
├── color.ts                 # 颜色处理
├── resolve.ts               # 主题解析
├── loader.ts                # 主题加载
└── default-themes.ts        # 默认主题

i18n/                        # 国际化（ar, br, bs, da, de, en, es, fr, ja, ko, no, pl, ru, th, tr, uk, zh, zht）

hooks/                       # React hooks

context/                     # React context
```

---

## 3.7 Desktop App 入口

`packages/app/` 和 `packages/desktop/`：
- Electron/Tauri 桌面应用
- 复用 `packages/ui/` 组件
- 通过 Tauri commands 或 IPC 与内核通信

---

## 3.8 完整数据流示例

### 3.8.1 CLI 非交互模式：`opencode run 'fix the bug'`

CLI 非交互模式直接调用内核，不走 HTTP：

```
1. CLI 解析命令
   └─ cli/cmd/run.ts

2. 直接调用 opencode 内核
   └─ session/prompt.ts → SessionPrompt.prompt()
       ├─ 创建 User 消息
       └─ 调用 runLoop(sessionID)

3. ReAct 循环
   └─ session/prompt.ts → loop()
       ├─ 构建 system prompt + skills
       ├─ 解析工具 (tool/registry.ts + session/tools.ts)
       ├─ 触发 chat hooks (plugin/index.ts)
       ├─ LLM 调用 (session/llm.ts → ai-sdk/native)
       ├─ 事件处理 (session/processor.ts)
       │   ├─ text delta → stdout 格式化输出
       │   ├─ tool call → 执行工具 (tool/*)
       │   └─ step finish → 结算成本
       └─ 继续或完成
```

### 3.8.2 Web/外部集成模式：SDK → HTTP API

Web、Desktop、外部集成通过 HTTP API 与内核通信：

```
1. SDK Client 调用
   └─ client.session.prompt(sessionID, { parts: [{ text: "fix the bug" }] })

2. HTTP API Server
   └─ server/handlers/session.ts → prompt handler

3. opencode 内核
   └─ session/prompt.ts → SessionPrompt.prompt()
       ├─ 创建 User 消息
       └─ 调用 runLoop(sessionID)

4. ReAct 循环
   └─ ...（同 CLI 模式，但事件通过 SSE 推送到客户端）
```

### 3.8.3 TUI 模式：Worker Thread + RPC

TUI 主线程通过 Worker Thread RPC 与内核通信（见 3.3.2），不走 HTTP。
