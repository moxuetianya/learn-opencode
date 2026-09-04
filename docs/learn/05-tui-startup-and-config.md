# 5. TUI 启动链路：从 `opencode` 命令到界面就绪

> 本课梳理 `opencode` TUI 从进程启动、server 拉起、config/plugin/provider 装配，到 TUI 同步完成、可以开始对话的完整过程。所有代码位置基于当前仓库 `dev` 分支。

## 5.0 总览

open code 的 TUI 是"CLI 客户端 + 常驻 server"结构：

```
opencode                (packages/opencode, yargs 入口)
  │  TuiThreadCommand
  ▼
bun worker              (cli/tui/worker.ts, 内嵌 HTTP Server)
  │  rpc.server → Server.listen()
  ▼
实例路由树              (server/routes/instance/httpapi/server.ts createRoutes)
  ├─ v1 InstanceHttpApi   /config /provider /agent /session/...   ← TUI 主力
  ├─ v2 Api               /api/... (SessionV2 协议, 迁移中)
  └─ /doc + /            (OpenAPI + Web UI fallback)
  ▲
  │ 第一次请求 /config 或 /agent 时按 directory 懒加载
  ▼
InstanceBootstrap           (project/bootstrap.ts)
  ├─ config.get()    加载/合并全局+项目配置
  ├─ plugin.init()   加载内部/外部插件
  └─ (Provider/Agent/...) 在各自 State 首次使用时构建
```

关键设计：**配置与插件不是 server 启动时加载，而是按"实例（directory）"懒加载的**。每次请求由中间件解析出目录，缓存一条 `InstanceState`，服务在实例内存活、随实例释放。

## 5.1 命令入口：`opencode` → 默认 TUI 线程

- `packages/opencode/bin/opencode` 是原生二进制启动器（下载/调用 `opencode-<platform>-<arch>`）。
- 源码入口 `packages/opencode/src/index.ts` 用 yargs 注册命令，TUI 即默认命令 `$0 [project]`（`src/cli/cmd/tui.ts:30` `TuiThreadCommand`）。
- `TuiThreadCommand.handler`（`cli/cmd/tui.ts:149` 起）：
  1. `process.chdir(目录)` 后 spawn 一个 bun `Worker`（`tui.ts:210-214`，worker 文件由 `target()` 解析：`cli/tui/worker.ts`）。
  2. 与 worker 建立 `Rpc.client`（`util/rpc`），拿到 `createWorkerFetch` / `createEventSource` 两个桥（`tui.ts:24-57`）：TUI 的 `fetch` 被转发为 `rpc.fetch` → `Server.Default().app.fetch`，SSE 事件转发为 `rpc.on("global.event")`。
  3. 「内嵌模式」URL 固定 `http://opencode.internal`（`tui.ts:239`）；带 `--port/--hostname/--mdns` 时走外部模式，`client.call("server", network)` 由 worker 真正 `Server.listen`（`worker.ts:44-50`）。
  4. **TUI 专用配置** `TuiConfig.get()`（`tui.ts:231`，见 5.5）。
  5. `runTui(...)`（`cli/tui/layer.ts` → `packages/tui/src/app.tsx` 的 `run`），并把 `createLegacyTuiPluginHost()` 作为 TUI 插件宿主（`tui.ts:272`）。
- worker 启动即订阅 `GlobalBus` 事件转发（`worker.ts:24-26`），并注册 `rpc.reload`（`Config.invalidate()` + `disposeAllInstancesAndEmitGlobalDisposed`，`worker.ts:63-71`）和 `rpc.shutdown`。

## 5.2 Server：路由树组装与监听

- `Server.listen`（`packages/opencode/src/server/server.ts:73-115`）：`listenEffect` + `listenerLayer`，用 `HttpApiApp.createRoutes(opts)` 建 app。
- 路由树（`server/routes/instance/httpapi/server.ts:271-313` `createRoutes`，注释 130-135 解释了四段路由）：
  - `rootApiRoutes`：`/global/*`、control 路由（`server.ts:141-145`）。
  - `eventApiRoutes`：SSE 事件路由（`server.ts:146-149`）。
  - `ptyConnectApiRoutes`：WebSocket(pty)（`server.ts:150-153`）。
  - `instanceRoutes`：**v1 实例 API**（`server.ts:154-176`），配 `workspaceRouting` + `instanceContext` 中间件。
  - `serverRoutes`：**v2 `packages/server` 的 `Api`**（`server.ts:177-181`，`/api/session`、`/api/model`…）。
  - `docRoute`/`uiRoute`：OpenAPI `/doc` 与 Web UI fallback（`server.ts:188-203`）。
- 服务图 `app = LayerNode.group([...])`（`server.ts:212-269`）把全部 v1 服务（`Config`/`Plugin`/`Provider`/`Agent`/`Session`/`SessionPrompt`/`LLM`/`ToolRegistry`…）一次性挂上。
- 两套核心并存：`SessionV2.node`（`packages/core/src/session`）在 `server.ts:298-303` 被显式提供（注入 `SessionExecutionLocal.node`）；v1 `SessionPrompt.node`（`packages/opencode/src/session/prompt.ts:1598`）仍在实例图里。**当前 TUI 走 v1 路径**，v2 是稳定迁移中的目标形态（见第 6 课 §6.7）。

## 5.3 实例懒加载：第一个请求触发 config/plugin

- 每次实例请求先过 `WorkspaceRoutingMiddleware`（解析 `WorkspaceRouteContext`），再 `InstanceContextMiddleware`（`middleware/instance-context.ts:23-35`）：由目录 → `InstanceStore.load({directory})` → 提供 `InstanceRef`。
- `InstanceStore.load`（`project/instance-store.ts:108-124`）→ `boot`（`instance-store.ts:45-63`）→ `project.fromDirectory` → `bootstrap.run`（`project/bootstrap.ts:32-46`）：
  - `bootstrap.ts:36` **`yield* config.get()`** — 注释：一切依赖 config，先急切加载便于 trace。
  - `bootstrap.ts:38` **`yield* plugin.init()`** — 注释：*插件可以改写 config，所以初始化必须最早*。
- 实例按目录缓存（`effect/instance-state.ts:26-50` `ScopedCache`），`server.instance.disposed` 事件触发重新 boot。

## 5.4 配置加载（Config）

### 5.4.1 分层合并顺序

入口 `Config.get`（`src/config/config.ts:611-613`）→ `loadInstanceState`（`config.ts:314-603`）。**后合并的覆盖先合并的**（`mergeConfigConcatArrays`，`config.ts:41-51`）。

| # | 层 | 代码位置 | 说明 |
|---|----|---------|------|
| 1 | 远程 well-known 配置 | `config.ts:356-396` | 从 auth provider 的 `/.well-known/opencode` 拉取 |
| 2 | 全局配置（优先级最低） | `config.ts:398-399` → `loadGlobal` `config.ts:246-279` | 依次读 `config.json` / `opencode.json` / `opencode.jsonc`（`config.ts:258-261`），遗留 TOML 迁移 `:262-276` |
| 3 | `OPENCODE_CONFIG` 指向的文件 | `config.ts:401-404` | |
| 4 | 项目级 `opencode.json(c)` 向上遍历 | `config.ts:406-410` via `ConfigPaths.files`（`config/paths.ts:10-21`） | 距 cwd 最近的优先级最高 |
| 5 | 各 `.opencode` 目录内的配置 + agents/commands/plugins | `config.ts:425-471` | 目录来自 `ConfigPaths.directories`（`paths.ts:23-41`）：全局配置目录、逐级 `.opencode`、`$HOME/.opencode`、`OPENCODE_CONFIG_DIR`；内部会 `ConfigCommand.load`（`:462`）、`ConfigAgent.load`（`:463`）、`ConfigAgent.loadMode`（`:464`）、`ConfigPlugin.load`（`:467-469`） |
| 6 | `OPENCODE_CONFIG_CONTENT` 环境变量 | `config.ts:473-481` | scope = local |
| 7 | 组织远程配置 | `config.ts:483-519` | 同时写入 `OPENCODE_CONSOLE_TOKEN`（`:496-497`） |
| 8 | Managed 配置目录 | `config.ts:521-527` | global scope |
| 9 | macOS `managedPreferences` | `config.ts:530-539` | 优先级最高 |
| - | 派生 | `config.ts:541-589` | modes→agents（`:541-548`）、`OPENCODE_PERMISSION`（`:550-556`）、`tools`→permissions（`:558-569`）等 |

### 5.4.2 解析与校验

- `config/parse.ts`：`jsonc()`（`parse.ts:8-33`，jsonc-parser，容忍尾逗号）→ `schema()`（`parse.ts:35-79`，Effect Schema 解码，**拒绝未知顶层键**见 `:74-78`）。
- 解析前做变量替换（`{env:VAR}` 等，`config.ts:219-225`）；插件路径按声明文件相对化（`config.ts:101-109`）。
- Agent/Command/Plugin 从 `.opencode` 目录发现：
  - `ConfigAgent.load`（`config/agent.ts:11-32`）：glob `{agent,agents}/**/*.md`，front-matter 解析 + `ConfigMarkdown.parse`。
  - `ConfigAgent.loadMode`（`config/agent.ts:34-58`）：`{mode,modes}/*.md`，强制 `mode:"primary"`（`:54`）。
  - `ConfigPlugin.load`（`config/plugin.ts:18-30`）：`{plugin,plugins}/*.{ts,js}`，与配置内 `plugin` 数组去重（`config/plugin.ts:64-77`）。
- 全局配置缓存：`Effect.cachedInvalidateWithTTL(loadGlobal, Duration.infinity)`（`config.ts:281-289`），`Config.invalidate()` 或 rpc reload 时失效。

### 5.4.3 Agent 运行时注册表（v1）

`src/agent/agent.ts` 在 InstanceState 内构建：内置 agent `build`/`plan`/`general`/`explore`/`compaction`/`title`/`summary`（`agent.ts:140-265`），权限默认值合并（`agent.ts:119-136`）；再把配置 `cfg.agent` 逐个 merge（`agent.ts:267-294`：`disabled` 删除、新 agent 默认 `mode:"all"`、`Provider.parseModel` 解析 model、permissions 合并）。对外 `agents.get/list/defaultInfo`（`agent.ts:312`、`:316-326` 排序 `default_agent` 置顶、`:328-340` 默认 agent 解析）。

## 5.5 TUI 专用配置（TuiConfig）

- `src/config/tui.ts`：加载顺序 全局 → `OPENCODE_TUI_CONFIG` → 项目 `tui.json` → `.opencode` 目录（`tui.ts:183-210`），由 `cli/cmd/tui.ts:231` 调用后通过 `<TuiConfigProvider config={...}>` 注入（`packages/tui/src/app.tsx:296`）——keybinds/themes/mouse 等是**纯前端**配置，不走 server。

## 5.6 插件加载（Plugin）

### 5.6.1 触发点与状态

- `Plugin.node` 在实例图（`server.ts:224`）；`InstanceBootstrap.run` 的 `plugin.init()`（`bootstrap.ts:38`）是严格入口。
- Plugin 状态在 `src/plugin/index.ts:130-283` `InstanceState.make` 构建：`State = { hooks: Hooks[] }`（`plugin/index.ts:35-38`）。

### 5.6.2 加载流程（`plugin/index.ts`）

1. 组装 `PluginInput`（client/project/directory/worktree/serverUrl/`$`…，`:149-164`）。
2. **内部插件**（不打 npm、直接 import）：`internalPlugins()`（`:65-82`，Codex/Copilot/Gitlab/Poe/Cloudflare/Azure…），逐个 `plugin(input)` 得到 hooks（`:166-175`）。
3. **外部插件**：`PluginLoader.loadExternal({ items: cfg.plugin_origins, kind: "server", report })`（`:187-219`），之前先 `config.waitForDependencies()` 等后台 npm 安装（`:183`）。
4. 每个模块 `applyPlugin`（`:110-121`）→ `readV1Plugin`（`plugin/shared.ts:272-304`，期待 `default` 导出形如 `{ id?, server() }`）→ `hooks.push(await plugin.server(input, load.options))`（`:114`）。**同一次会话内按顺序跑**（`:220-243`），保证 hook 顺序可预测。
5. 全量 hooks 就位后，对每个 hook 调 `hook.config?.(cfg)`（`:246-254`）——这就是插件"改写 config"的时刻。
6. `hook.event` 订阅到 `EventV2Bridge`（`:256-264`）；`hook.dispose()` 在实例释放时执行（`:266-279`）。

### 5.6.3 外部插件的装/载（`plugin/loader.ts` + `shared.ts`）

- `resolve()`（`loader.ts:86-133`）：  路径型 spec → `resolvePathPluginTarget`（`shared.ts:175-192`）；npm spec → `Npm.add(pkg)`（`core/src/npm.ts:80-140`，按需安装到 npm cache）；包入口 `exports["./server"]` → `main` → 目录 index（`shared.ts:103-169`）；`engines.opencode` 兼容性校验（`shared.ts:194-205`）。
- `load()`（`loader.ts:136-145`）：纯 `await import(entry)`（不是 vm），失败即终态（`loader.ts:205-207` 注释）。
- `loadExternal()`（`loader.ts:208-236`）：并行尝试所有候选，file 型做一次重试；`install/entry/compatibility/load` 阶段回调用 `report` 上报错误事件（`plugin/index.ts:191-217`）。

### 5.6.4 Hook 触发（`Plugin.trigger`）

- `plugin/index.ts:285-298`：顺序遍历 `s.hooks`，有该 hook 就传 `(input, output)`，**output 被改写后传给下一个 hook** —— 这就是所有 `chat.message`/`select` 类 hook 的合并语义。触发点汇总见第 6 课 §6.5 表格。

### 5.6.5 TUI 侧插件

- `packages/tui/src/app.tsx:237` `createPluginRuntime()`，`App` 内 `createTuiApi(createTuiApiAdapters({...}))`（`app.tsx:388-406`），然后 `props.pluginHost.start({ api, config, runtime, dispose })`（`app.tsx:408-420`）。
- `app.tsx` 的 TuiPluginHost 来自 `createLegacyTuiPluginHost()`（`src/plugin/tui/runtime.ts:1124-1129`）：先内建 `internalTuiPlugins`（`feature-plugins/builtins.ts`），再 `PluginLoader.loadExternal({ kind: "tui" })`（`plugin/tui/runtime.ts:676-774`），按 `plugin_enabled` KV 激活（`runtime.ts:516-556`），`tui()` 模块跑 `plugin(api, options, meta)`。
- 注：`packages/cli`（lildax 实验入口）的 `src/tui.ts:14-17` 用了空 pluginHost —— 那是另一条 v2 实验链路，不是当前主 TUI。

## 5.7 Provider / Model 装配（v1 实例侧）

`src/provider/provider.ts` 的 InstanceState（`:1336-1661`）：

| 步骤 | 行 | 内容 |
|---|---|---|
| models.dev 目录 | `:1339-1341` | `catalog = mapValues(modelsDev, fromModelsDevProvider)` |
| 先读插件 | `:1376-1377` | `plugin.list()` —— config hook 已改完 `cfg.provider` |
| config 的 provider | `:1380-1388` | `cfg.provider` / `disabled_providers` / `enabled_providers` 过滤 |
| 插件模型 | `:1390-1415` | `hook.provider.models` 合并 |
| config 覆盖 | `:1418-1513` | per-provider `Info` merge，per-model 默认（capabilities/cost/headers/variants…） |
| 环境变量 key | `:1516-1526` | `mergeProvider(source:"env", key)` |
| auth.json 的 API key | `:1529-1539` | `auth.all()`（`src/auth/index.ts:58-67`）|
| 插件 auth loader | `:1542-1560` | `plugin.auth.loader` → options |
| 内置自定义 provider | `:1562-1578` | `custom(dep)`（`:168-961`，autoload/getModel/vars/discoverModels…）|
| 过滤 | `:1604-1651` | disabled/alpha/deprecated/黑名单/零模型删除 |

对外接口：`list`（`:1664`）、`getModel`（`:1804-1826`，`ModelNotFoundError` + fuzzysort 建议）、`getLanguage`（`:1828-1857`，**LLM client 实例缓存**，key `${providerID}/${id}`，cache 存 `s.models`）、`resolveSDK`（`:1666-1798`，options/baseURL 变量插值/apiKey/header/自定义 fetch 超时/`BUNDLED_PROVIDERS` 或 `Npm.add` 动态 import）、`defaultModel`（`:1940-1973`：`cfg.model` → `model.json` 的 recent → 第一个 provider 的排序首个模型）、`getSmallModel`（`:1871-1938`）、`parseModel`（`:1990-1996`）。

模型状态：`ModelStatus`（`provider/model-status.ts:5`，alpha/beta/deprecated/active），TUI 与 server 均过滤 deprecated。

## 5.8 HTTP 暴露（TUI 消费的接口）

- v1：`GET /config`（`groups/config.ts:9-25` → `handlers/config.ts:14-16`）、`GET /config/providers`（`:38-47` → `config.ts:24-30`：`{providers, default}`）、`GET /provider`（`groups/provider.ts:38-47` → `handlers/provider.ts:40-59`：全量 + `connected` 列表）、`GET /agent`（`groups/instance.ts:149-158` → `handlers/instance.ts:80-82`）、`GET /session`（v1 `groups/session.ts`）等。
- v2：`GET /api/model`、`GET /api/provider`（`packages/server/src/handlers/{model,provider}.ts`），data 来自 `core/src/catalog.ts:184-213`（models.dev 插件 + integration 连接过滤）。

## 5.9 TUI 启动后第一次同步（SyncProvider + DataProvider）

- SDK 基座：`packages/tui/src/context/sdk.tsx:24-31` `createOpencodeClient({ baseUrl, fetch, headers })`（`@opencode-ai/sdk/v2` 的 gen client，`OpencodeClient` 里 `client.session` 其实是 v1 `Session2` 段，`client.v2` 才是新协议——见 `sdk/js/src/v2/gen/sdk.gen.ts:120` 与 `:7195`）；SSE 订阅在 `sdk.tsx:82-117`（`sdk.global.event` 流，指数退避重连），事件带 16ms 批量 flush（`sdk.tsx:54-80`）。
- `SyncProvider.bootstrap`（`context/sync.tsx:445-546`）：
  - **阻塞批**（`:452-472`）：`config.providers`（→ store.provider/provider_default）、`provider.list`（→ provider_next）、`app.agents`（→ agent）、`config.get`（→ config）、`experimental.capabilities`、`experimental.console`、以及 `--continue` 时的 `session.list`。
  - reconcile 进 Solid store（`:499-508`），状态机 `loading → partial（:512）→ complete（:531）`。
  - **非阻塞批**（`:514-530`）：session 列表、command.list、lsp/mcp/formatter 状态、`session.status`、`provider.auth`、vcs…
- `DataProvider`（`context/data.tsx:551-565`）另拉 **v2 location 目录**（`v2.agent.list`、`v2.model.list`、`v2.provider.list`、skill/command/integration…），供侧边栏与 `/models` 等面板使用。
- ProjectProvider 先拉 `/path` + `/project/current`（`context/project.tsx:38-53`）确定 worktree。
- 首屏路由：`app.tsx:Read` `<Home/>`/`<Session/>`（`app.tsx:1112-1120`）；`--continue`/`--session` 的处理在 `app.tsx:501-538`；`args.model/agent` 在 `app.tsx:479-499` 写入 local store。

## 5.10 更新模型 / 更新 Provider（运行期）

- **模型切换**：`/models` 命令（`app.tsx:629-640`）→ `DialogModel` → `onSelect` → `local.model.set({providerID, modelID},{recent:true})`（`component/dialog-model.tsx:142-155`；实现见 `context/local.tsx:320-338`）——只改本地 store 与 `model.json`（`paths.state`），并写 per-agent 记忆。**会话模型在下次 `session.prompt` 时随 message 带上**（见第 6 课 §6.2）。
- **Provider 连接**：`provider.connect`（`app.tsx:739-747`）→ `DialogProviderList`（`component/dialog-provider.tsx`）→ oauth/`auth` 接口（`src/provider/auth.ts:163-221`，落盘 `auth.json`）→ **`sdk.client.instance.dispose()` + `sync.bootstrap()`**（`dialog-provider.tsx:281-282, 332-333, 405-406`）。dispose 触发 `server.instance.disposed` → 实例重建 → provider 注册表带着新 key 重建 → TUI 重新 bootstrap。
- **改配置热更新**：`PATCH /config`（`handlers/config.ts:18-22`）写盘后 `markInstanceForDisposal`；worker `rpc.reload`（`worker.ts:63-71`）走 `Config.invalidate()` + 全量 dispose，事件广播 → `sync.tsx:172-174` 重新 bootstrap。

## 5.11 小结：一次启动的"时间线"

1. `opencode` → yargs `$0` → chdir + Worker + Rpc（`cli/cmd/tui.ts`）。
2. worker `Rpc.listen`（`worker.ts:83`），`rpc.fetch` 桥通往 `Server.Default().app.fetch`。
3. TUI `run`（`packages/tui/src/app.tsx:186`）：渲染器初始化、keymap、Provider 树组装，`App` 挂载。
4. `SyncProvider` onMount → bootstrap：阻塞批（providers/provider_list/agents/config）用户可见 UI ready。
5. 任一实例请求命中 → `InstanceBootstrap.run`：config.get（分层合并）→ plugin.init（hooks 就绪）→ Provider/Agent 首次 use 时构建注册表。
6. 用户开聊：`session.create` + `session.prompt`（第 6 课）。
