# opencode 源码学习文档

按主题组织的 opencode 核心架构学习系列。

## 目录

1. **[Agent 内核](./01-agent-core.md)** — ReAct 循环、Tool-Use、LLM 调用与 Skill 注入
   - ReAct 循环的 while(true) 主循环
   - LLM 双运行时（AI SDK / Native）架构
   - 工具注册、解析与执行流程
   - Skill 发现、注入与运行时加载
   - Processor 事件处理与死循环检测
   - Agent 类型与配置

2. **[Hook 机制](./02-hook-mechanism.md)** — Plugin SDK 与 Hook 系统
   - 23 个 Hook 的类型定义与签名
   - `Plugin.trigger()` 的 (input, output) 模式
   - 插件加载流程（内置 + 外部 npm）
   - Auth Provider 插件（OAuth/API Key）
   - Plugin 提供工具、模型注入

3. **[UI 接入层](./03-ui-layer.md)** — CLI、TUI、HTTP Server
   - CLI 三种运行模式（非交互/交互本地/交互远程）
   - TUI 的 Main Thread + Worker Thread 架构
   - HTTP API Server 的端点与中间件
   - JavaScript SDK 接口
   - 完整数据流示例

## 源码导航

```
packages/
├── opencode/           # 核心运行时（Agent 内核、工具、Plugin、CLI）
│   └── src/
│       ├── session/    # ReAct 循环、LLM 调用、事件处理
│       ├── tool/       # 工具注册、实现
│       ├── skill/      # Skill 发现与加载
│       ├── agent/      # Agent 定义
│       ├── plugin/     # Hook 加载与触发
│       ├── provider/   # LLM Provider 管理
│       ├── cli/        # CLI 命令入口
│       └── server/     # HTTP Server
├── plugin/             # Plugin SDK 类型定义
├── llm/                # LLM 事件与路由定义
├── core/               # 底层抽象（DB、Session V2、Runner）
├── server/             # HTTP API Server
├── tui/                # Terminal UI（React/Ink）
├── ui/                 # Web UI 组件
├── cli/                # CLI boot
├── app/ + desktop/     # Desktop 应用
├── web/                # Web 前端
└── sdk/                # JavaScript SDK
```
