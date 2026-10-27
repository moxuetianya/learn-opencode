# 13. 插件系统全链路：从 CLI 入口到插件代码被执行

> 本课回答一组连环追问：**`opencode` 敲下去之后，插件到底是怎么被找到、装上、跑起来的？**
> 答案横跨两个进程（TUI / server）、两套调度器、一双共享的底层加载器。
> 沿路顺带讲清三个支撑概念：Effect 的 `provide` 与 LayerNode 依赖图（为什么沿着调用链搜不到
> PluginSupervisor）、`Effect.fn` 标签的真实作用、`#plugin-source` 这类条件导入。
>
> 承接 06（Hook 的语义与注册顺序——本课讲"怎么装上"，06 讲"装上之后怎么触发"）、
> 11（后台服务生命周期——本课的 server 就是它拉起的那个 daemon）、
> 附 `effect-yield-pipe-fork.md`（Effect 基本读法）。

## 13.0 全景图：两套调度器踩同一双底层加载器

```
┌─────────────── TUI 进程（opencode 前端）───────────────┐   ┌──────────── server 进程（daemon / serve）────────────┐
│ cli/index.ts → handlers/default.ts                     │   │ cli/index.ts → handlers/serve.ts                      │
│   → tui/app.tsx run()                                  │   │   → cli/server-process.ts run()                       │
│     → <PluginProvider packages directories>            │   │     → server/process.ts start()                       │
│                                                        │   │       → createRoutes → Instance.node（全局路由器）     │
│ 调度器①：tui/plugin/context.tsx PluginProvider          │   │         → LayerMap 懒构建 per-location Instance 图     │
│   reconcile：watch→discover→resolve→compare→swap        │   │           → instance.ts nodes[] :77 PluginSupervisor  │
│   调用插件：plugin.setup(ctx)          ← context.tsx:639 │   │ 调度器②：core/plugin/supervisor.ts PluginSupervisor   │
│                                                        │   │   调用插件：plugin.effect({...host})  ← plugin.ts:65   │
└──────────────────────────┬─────────────────────────────┘   └──────────────────────────┬──────────────────────────┘
                           │            共享底层（@opencode/plugin）                     │
                           ├─ host.ts    Host.resolve → {server,tui,rpc} 入口探测        │
                           ├─ host.ts    Host.load → importModule                         │
                           └─ source.ts  createPluginSources → #plugin-source（bun/node 双实现，热重载）
```

一句话总纲：**TUI 摘"有 tui 入口"的枝，server 摘"有 server 入口"的枝；双入口插件一份安装、两个进程各取所需，靠 `plugin.list` / `plugin.updated` 保持清单同步。**

## 13.1 预备：几处 TS 语法读法

读这条链路前先扫清几个语法障碍（都以真实代码为例）。

### 13.1.1 `{ sessionID }` 与 `...requestOptions(signal)`

`packages/cli/src/session-target.ts:135`：

```ts
return client.session.get({ sessionID }, ...requestOptions(signal)).catch((error) => { ... })
```

- `{ sessionID }` 是属性简写，等价 `{ sessionID: sessionID }`；
- `...` 在**函数调用位**的含义是"把数组拆开、元素逐个摆成参数"（数组壳消失），不是传数组本身：

| signal | 实际调用 |
|---|---|
| 有 | `client.session.get({ sessionID }, { signal })` |
| 无 | `client.session.get({ sessionID })` |

配合底部的辅助函数（`session-target.ts:169`）：

```ts
function requestOptions(signal?: AbortSignal): [] | [{ signal: AbortSignal }] {
  return signal ? [{ signal }] : []
}
```

这是 TS 里"**条件性完全不传可选尾参**"的惯用手法——比永远传 `{ signal: undefined }` 语义更精确。

### 13.1.2 `...` 的三种位置三种语义

```ts
f(...[{signal:a}, {signal:b}])   // ① 函数调用：按位置摆成两个参数，不合并、不覆盖
[...arr, 4]                       // ② 数组字面量：元素铺进新数组
{ ...{signal:a}, ...{signal:b} }  // ③ 对象字面量：按属性名合并，后者覆盖前者 → { signal: b }
```

"同名谁生效"只发生在 ③；①里两个对象是平行参数，位置决定一切。

### 13.1.3 catch 里的 unknown 收窄

```ts
.catch((error) => {
  if (error && typeof error === "object" && "_tag" in error && error._tag === "SessionNotFoundError")
    return undefined   // 找不到不算失败
  throw error          // 其他错误继续抛
})
```

`error` 类型是 `unknown`，必须逐层"证明"才能访问属性：`error &&` 排 falsy → `typeof === "object"` 证明是对象 → `"_tag" in error"` 既检查存在又让 TS 认可该属性（下一处才能合法写 `error._tag`）。`_tag` 是 Effect 风格错误经网络序列化后的判别字段，本仓库大量使用（如 `server.address._tag === "TcpAddress"` 同款）。

## 13.2 CLI 默认命令：TUI 的启动边界

链路：`cli/src/index.ts:28`（命令表把 `$` 映射到 `import("./commands/handlers/default")`）→ `handlers/default.ts:96` 的 `yield* run({...})`（`run` 来自 `@opencode/tui`，定义在 `tui/src/app.tsx:204`）。

### 13.2.1 `run(input)` 传的是什么

`TuiInput`（app.tsx:179）本质是一个**依赖注入包**——TUI 包不 import CLI 内部模块，所有能力从这一个对象灌进去：

| 字段 | 作用 |
|---|---|
| `app` | 名字/版本/更新通道 |
| `server` | daemon 的 endpoint + 可选 reconnect/restart 句柄 |
| `args` | CLI 旗标翻译（continue / sessionID vs newSessionID / prompt / auto） |
| `config` | 让 TUI 读写 opencode 配置 |
| `updater` | 自动更新三件套（subscribe/check/apply），信号量保证安装不并发 |
| `packages` | `prepare: (spec, install) => npm.add/resolve(spec)` —— **TUI 触达 npm 的唯一通道** |
| `environment` | 本地运行时的会话环境变量 |
| `terminalHandoff` | TUI 接管终端时结束"正在更新"过渡画面 |
| `log` | TUI 日志桥接回 CLI 的 Effect 日志 |

关键设计：**TUI 回调全是 Promise 风格，CLI 侧全是 Effect**，所以 handler 先造翻译器（default.ts:91-94）：

```ts
const runFork = Effect.runForkWith(context)      // Effect → 立即执行、不等结果
const runPromise = Effect.runPromiseWith(context) // Effect → 立即执行并返回 Promise
// 用法：get: () => runPromise(config.get())   /   log: (...) => runFork(effect)
```

这是"两个世界的显式边界"——storybook、模拟器等其他宿主能用同样方式驱动 TUI。

### 13.2.2 `Effect.fn("Tui.run")` 的标签只影响观测

`run` 的定义是 `Effect.fn("Tui.run")(function* ...)`. 查 effect 源码（`internal/effect.ts:1197`）：

- 包装函数**原样透传** `this`/参数/返回值，`.length` 都被保留；
- 名字只用在两处：①`useSpan(name)` 建 tracing span；②`CurrentStackFrame` 造两条"人造堆栈帧"（`Tui.run` 调用点 + `Tui.run (definition)` 定义点），因为 Effect 惰性执行，报错时原生堆栈早已丢失；
- **没有任何运行时逻辑依据 name 分支**——不影响调用方式、重试、错误处理。

对照：`Effect.fnUntraced` 不建 span 不捕堆栈（最廉价）；何时选哪个见 13.4.1 的真实案例。

## 13.3 `Effect.provide` 与 LayerNode 依赖图

### 13.3.1 provide：对"环境参数"做偏应用（Rust/C++ 视角）

`Effect<A, E, R>` 的 R 是需求集合，近似 `Box<dyn FnOnce(Context<R>) -> Result<A, E>>`。
Context 就是 typemap（Rust 的 anymap / axum State 同款）：

```rust
struct Context { map: HashMap<TypeId, Arc<dyn Any + Send + Sync>> }  // yield* Foo.Service ≈ ctx.get::<Foo>()
```

`provide` 只做两件事：

```rust
fn provide(effect, layer) -> impl FnOnce(Context<R - Out>) -> Result<A, E> {
    move |mut env| {
        let produced = layer(...)?;   // ① 运行时：按 Layer 配方构建服务（懒构建、同图共享单例）
        env.merge(produced);          // ② 合并进环境
        effect(env)                   // ③ 内层在补全的环境里执行
    }
}
```

- **类型上做集合减法** `R - Out`；R 没清零（`{}`）之前 `Effect.runPromise` 直接编译不过——缺依赖是编译错误，不是运行时 panic；
- `Effect.scoped` + `acquireRelease` ≈ RAII：Layer 构造 = 构造函数，finalizer = `Drop`，scope 结束按构造逆序析构。

### 13.3.2 LayerNode：声明式依赖图（所以调用链搜不到 PluginSupervisor）

`PluginSupervisor.node`（supervisor.ts:268 经 `makeLocationNode` 包装）本质是**一个普通对象**：

```
{ kind: "layer", name: "plugin-supervisor",
  implementation: <Effect Layer>,
  dependencies: [Plugin.node, SdkPlugins.node, Bus.node, ...] }   // ← 边
```

- **节点** = 服务提供方说明书（叫什么/怎么构建/依赖谁）；**边** = dependencies 数组；
- `instance.ts:59` 的 `const nodes = [...]` 只是把几十份说明书**堆成一摞数据**——声明不执行；
- `LayerNode.compile`（layer-node.ts:238）= 一个小型构建系统，与 make/CMake 精确对应：

| Make/CMake | LayerNode |
|---|---|
| target | node |
| prerequisites | `dependencies` |
| make 拓扑排序 | `resolve` DFS 展开 |
| 环依赖报错 | `Cycle detected in layer graph: A -> B -> A`（:259） |
| 重复目标只建一次 | 按 implementation 去重 + memoMap 缓存 |
| `-D` 覆盖 | `replacements`（`Global.node.replace(...)`，类型系统禁止弱化替换物） |

命令式 vs 声明式对照：

```ts
// 命令式（没人写这种，调用链可见）：
const supervisor = new PluginSupervisor(new Config(...), new Watcher(...), ...)
// 声明式（本仓库实际，调用链不可见）：
const nodes = [Config.node, ..., PluginSupervisor.node]   // 数据!
LayerNode.compile(LayerNode.group(nodes))                  // 顺序自动推导
```

**结论：生产代码里 `PluginSupervisor` 全仓只出现在 `core/src/instance.ts:29,77` 的数组里。找它要顺着 Layer 图，不能顺着函数调用。**

### 13.3.3 `#plugin-source`：包内条件导入

`plugin/src/source.ts:29` 的 `await import("#plugin-source")` 是 Node 标准的 **subpath imports**（`package.json` 的 `imports` 字段，`#` 开头、仅包内可用）：

```json
"imports": {
  "#plugin-source": {
    "bun": "./src/source.bun.ts",
    "node": "./src/source.node.ts",
    "default": "./src/source.node.ts"
  }
}
```

同一行 import，Bun 下解析到 bun 实现、Node 下解析到 node 实现——**另一份实现完全不会被加载**（这正是要点：source.node.ts 用 `node:module` 的 `registerHooks`，source.bun.ts 用 Bun 插件 API，互相不能进对方运行时）。业务代码零分支。`packages/tui/package.json:28-49` 还有一整排同款（`#zed-sqlite`、`#string-width`、`#runtime-plugin-support`），是仓库惯用模式。

## 13.4 server 进程：`opencode serve` 的完整链路

### 13.4.1 入口与依赖装配

`handlers/serve.ts:10` → `ServerProcess.run({ mode: "service"|"stdio"|"default", ... })`（`cli/src/server-process.ts:31`）：

```ts
// The process effect lives until server shutdown; tracing it would parent every request to one process-lifetime trace.
export const run = Effect.fnUntraced(function* (options: Options) {
  return yield* processEffect(options).pipe(
    Effect.provide(
      LayerNode.compile(LayerNode.group([Global.node, AppProcess.node]), {
        replacements: [
          Global.node.replace(Global.layerWith(process.env.OPENCODE_CONFIG_DIR ? { config: ... } : {})),
        ],
      }),
    ),
    Effect.provide(NodeServices.layer),
  )
})
```

三个要点：

1. **`fnUntraced` 的理由就写在注释里**：进程级 Effect 活到 server 关闭；若加 span，每个请求的 trace 都会挂到一个横跨进程生命周期的巨型父 trace 下。进程外壳刻意不加 span——这是"要不要 trace"的真实工程决策。
2. **职责分离**：`processEffect` 描述"做什么"（R 写在类型里），`run` 只装配"用什么环境跑"。
3. **`Global.node.replace` 是类型安全的 DI 覆盖**：`OPENCODE_CONFIG_DIR` 的唯一生效点——在入口替换 Global 实现，下游全部自动生效，代码里不会到处读这个环境变量。

### 13.4.2 `bound.http.serve()` 不阻塞——"上膛"不是"站岗"

`server/src/process.ts:69` 的 `yield* bound.http.serve(app, ...)` 看似会阻塞服务请求，实际**只安装处理器就返回 void**。证据两处：

- 类型签名（effect `HttpServer.ts:100`）：`serve: (...) => Effect<void, never, Scope>`；
- Node 实现（`NodeHttpServer.ts:140-158`）：构建中间件链一次 → `server.on("request", handler)` 注册回调 → 注册 scope finalizer 反注册 → 生成器结束。

心智模型：不是 `while(true){accept();handle();}`（占线程），而是 **epoll/libuv 注册回调**（立刻返回）。每个请求到达 → 事件循环 → handler 把 app Effect 丢进一个新 fiber。

真正的挂起点在链路末端（`cli/src/server-process.ts:192-196`）：

```ts
return yield* options.mode === "service"
  ? server.shutdown           // 挂在 Latch 上等关闭
  : options.mode === "stdio" ? waitForStdinClose()
  : Effect.never              // 前台模式：永不完成
```

而 `serve` 之后"往下执行"的内容恰是启动后半程：`lifecycle.onListen`（service 模式注册进 ServiceRegistration）→ `boot` 构建完整 routes Layer → `Ref.set(application, Option.some(router))` **原子换入真 app** → `status.ready`。配合外层兜底 app `dispatch`（process.ts:172）：早期请求拿到 `/api/info` 或 503 `{"code":"service_starting"}`，就绪瞬间切换——"先装门卫、后装修店铺"，这个设计本身就要求 serve 不阻塞。

顺带：`.pipe(Effect.provide(NodeHttpServer.layerHttpServices), withoutParentSpan)` 里的 `withoutParentSpan` 与 13.4.1 同理——**请求 fiber 不得继承"服务器启动"这个父 span**。

### 13.4.3 RemoteTunnel 块：成功路径上的增值服务

`cli/src/server-process.ts:176-188`，执行到这说明 server 已成功监听。三个条件：`serviceOptions !== undefined`（仅托管服务模式）&& `config.remote === true`（用户主动 `opencode service set remote true`）&& `TcpAddress`（`_tag` 收窄后才能访问 `.hostname/.port`）。

- **host 归一化**：`0.0.0.0`/`::` 通配 → 降级 `127.0.0.1`（隧道客户端在本机，回环可达即可）；IPv6 字面量包 `[]`；其余原样；
- `Effect.forkScoped(RemoteTunnel.run(...))` ≈ Rust `std::thread::scope` 里 spawn worker：不阻塞、生命周期绑定 scope、server 关闭时自动 interrupt；隧道自身失败（断网重连、证书问题）在 `remote-tunnel.ts` 内部消化（指数退避，致命错误仅 log），绝不带崩 server；
- `onURL` 写入闭包变量 `remote.urls`，而 `launch(...)` 收到的是 `() => remote.urls` 惰性 getter——"启动后才异步产生的值"的典型喂法。

## 13.5 TUI 端插件链路（调度器①：PluginProvider）

### 13.5.1 代码地图

```
tui/app.tsx run()
 ├─ :217  localPluginDirectories(process.cwd(), global.config)   ← 算候选目录
 └─ :396  <PluginProvider packages directories>
      ▼
tui/plugin/context.tsx:88  PluginProvider（Solid Provider + reconcile 代际制）
 ├─ 三路输入合并(:290-309)：本地目录发现 / 服务端清单(serverTuiPlugins) / config.plugins
 ├─ builtins 先入列(:313，builtins.ts → feature-plugins/*)
 ├─ 每条目 → resolvePlugin(:652)
 ├─ 代际 compare/swap(:400-457)：失败保留旧版本继续跑
 ├─ activate(:150) → createPluginContext(api.tsx:91) → plugin.setup(context)(:639)
 └─ 消费：structure.ts resolveSlots + render.tsx <Slot>/<PluginRoute>
```

支撑设施：

- **discovery.ts**：`localPluginDirectories`(:8) = 全局配置目录 + 项目 `.opencode` + 向上各级配置目录，各拼 `/plugins`；`discoverPluginTargets`(:24) readdir 取目录/symlink；`mergePluginTargets`(:55) 按本地 URL 去重；
- **代际与串行化**：所有生命周期变更经 `enqueue`(:243) 串行链，watch 事件防抖 100ms(:256)；resolve→compare→swap，**导入失败保留 last-good**；
- **watch**：`createSourceWatcher` 监听发现目录与本地入口文件。

### 13.5.2 单个插件的解析：`resolvePlugin`（context.tsx:652）

```
① 本地路径 → {directory}；npm spec → packages.prepare(spec, install)
   （= 13.2.1 注入的 npm.add/resolve，回到 CLI 的唯一 npm 通道）
② Host.resolve(target).tui → tui 入口 URL；没有 → unsupported
③ 本地走 readSource(entrypoint)（带指纹缓存）；包走 Host.load(entrypoint)
④ 校验 mod.default 是合法 TUI Plugin(isPlugin, :694)
```

### 13.5.3 底层：`createPluginSources` 与热重载

`@opencode/plugin/source` 的 `createPluginSources.read`：

- 对文件做 **sha256 指纹**，内容没变直接复用上次 import（一次保存多次 watch 事件不重复求值）；
- 委托 `#plugin-source`（13.3.3）——Node 版用 `registerHooks` 给本地模块 URL 加 `?__opencode_reload=<gen>` 查询串**击穿 ESM import 缓存**，同时 track 依赖文件进 watch：**保存即热重载的机制核心**；
- `Host.load` = `importModule`（`@opencode/util/runtime-import`）。

进程启动时另有 `ensurePluginRuntime()`（cli/index.ts:21 → plugin/src/runtime.ts:12）：Bun 下注册 `Bun.plugin`，把插件代码里 `import "@opencode/plugin"`、`import "effect"` **重定向到宿主已加载的版本**——插件包不必自带一整套 runtime。

## 13.6 服务端插件链路（调度器②：PluginSupervisor）

### 13.6.1 接线路径与懒加载时机

```
cli/index.ts → handlers/serve.ts → cli/server-process.ts:76 import("@opencode/server/process")
 → server/process.ts:97 createRoutes(...)
 → server/routes.ts:62 applicationServiceNodes 里的 Instance.node（全局）
 → core/location-services.ts:20 LayerMap：按 Location.Ref 懒构建，idleTimeToLive = infinity
 → core/instance.ts:148 Instance.layer(ref) → :59-112 nodes[] :77 PluginSupervisor.node
 → supervisor.ts:124 layer 启动 → :236 首轮 activate 立即执行
```

全局图里的 `Instance.Service` 只是路由器（location-services.ts:78：`provide: (session) => Effect.provide(map.get(session.location))`）；真正含 PluginSupervisor 的 per-location 图在**第一次有人 `map.get(ref)`** 时才构建。

**"server 启动不加载插件，等 TUI 连接才加载"——基本正确，准确说法是 per-location 懒加载**：

- server 启动只建全局服务（Bus/Database/…）；
- 某目录的**第一个请求**到达才为它构建 Instance 图并加载该目录的插件，建好常驻；
- TUI 是最常见触发者（连接后立即 `api.file.list({ location: { directory: process.cwd() } })`，tui/app.tsx:212），但任何客户端的首个 location 级请求都会触发；
- 旁证：`core/src/plugin/service.ts:31` 注释 *"A cold Location activates its plugins asynchronously"*。

### 13.6.2 调度中枢：`PluginSupervisor.layer`（supervisor.ts:124）

- **7 路 watcher**(:219-234)：配置变更 / 插件源码文件变更 / ManagedPolicy 变更 / 24h 定时 / 总线事件 / 更新检查 → 防抖 100ms 合并 → `activate()`；首轮立即执行(:236 `Stream.succeed(0)`)；
- **activate**(:147)：汇总 pre（内置 + SDK + 实例插件）与 post 内置 → `sources.operations()` 拿操作列表 → **两阶段 resolve**(:163-182)：先 `install:false` 激活本地已有的，再对 pending 的 npm 包 `install:true`——装新包的耗时阻塞不了已有插件可用；
- 装什么由 **ConfigPluginSource** 决定（`core/src/config/plugin/source.ts:75`）：config entries 的 directory 条目经 `PluginSourceDirectory.discover`（`source-directory.ts:9`，认 `plugin/` **和** `plugins/` 两种子目录名，且**接受单个 .ts/.js 文件**）+ document 条目里的 `plugins` 数组（`-name` = 禁用，相对路径按配置文件目录解析，`file://` 支持）。

### 13.6.3 单个装载：`PluginModule.load` 五步（module.ts:98）

```
① 策略门(:52-59)：ManagedPolicy 查 "integration.use / plugin:<target>"，deny → blocked
② 定位(:103-109)：绝对路径 = 本地；否则 npm.add（安装）/ npm.resolve（只解析）
③ 入口(:112-115)：Host.resolve(installed ?? {directory}) → {server, tui, rpc}
④ 加载(:120-124)：本地 → sources.read（指纹缓存热重载）；包 → Host.load
⑤ 校验(:125-134)：Schema 解码 default 导出，两种合法形态：
   { id, effect }（Effect 版）或 { id, setup }（Promise 版，经 PluginPromise.fromPromise 适配）
   产出 Generation: { id, features:{tui?,rpc?}, revision: JSON.stringify([op, version]),
                      source: local|package, effect: (host) => plugin.effect({...host, options}) }
```

### 13.6.4 注册表：真正调用插件代码（core/src/plugin.ts）

- **调用点** `:65`：`plugin.effect({ ...host, storage })` —— host 由 `PluginHost.make`（`core/src/plugin/host.ts:47`）构造，是把 Agent/Tool/Command/MCP/Session/Hook… 几十个服务打包给插件用的巨型 Host API；每个插件独立 fork scope（RAII）+ span `"Plugin.load"`；
- **前缀 diff**(:108-116)：新旧代际按激活顺序对齐，找到第一个变化位置，只有其后才 teardown/重建——文件保存事件、无关插件更新都不打扰在跑的插件；
- **广播** `:121`：inventory 更新即 `bus.publish(Plugin.Event.Updated)` —— 这就是 TUI 端 `client.event.on("plugin.updated", syncServerPlugins)`（tui context.tsx:569）订阅的事件**源头**，闭环完成。

## 13.7 双端对照与"入口"概念

### 13.7.1 什么是 server 入口 / tui 入口

一个插件包可以做成**多面体**：面向 server 宿主一个模块、面向 TUI 宿主另一个模块。"入口" = 包暴露给某个宿主的模块路径。`Host.resolve`（plugin/src/host.ts:17）的探测规则：

```ts
return { server: entry(["server", ""]), tui: entry(["tui"]), rpc: entry(["rpc"]) }
// 包：试 "pkg/server" 子路径 → 包主入口；然后 "pkg/tui"、"pkg/rpc"
// 目录：目录/server/index、目录/tui/index、目录/rpc/index
```

一个双入口插件长这样：

```
~/.config/opencode/plugins/my-plugin/
├── package.json   { "exports": { ".": "./server.ts", "./tui": "./tui.ts" } }
├── server.ts      ← server 入口：export default { id, effect } → 注册 tool/hook/command
├── tui.ts         ← tui 入口：  export default { id, setup }  → 注册 slot/route/markdown
└── (rpc.ts)       ← 可选：rpc 入口
```

同一个 `id`、两个进程各跑一半：**server 入口管"能做什么"，tui 入口管"长什么样"**。`opencode plugin add`（handlers/plugin/add.ts:21）也用 `Host.resolve` 预检插件都有哪几面。

### 13.7.2 双端差异总表

| 维度 | TUI 插件 | 服务端插件 |
|---|---|---|
| 运行进程 | TUI 前端进程 | server 进程 |
| 调度器 | `tui/plugin/context.tsx` PluginProvider（Solid 响应式，per-TUI 会话） | `core/plugin/supervisor.ts` PluginSupervisor（Effect Layer，per-Location） |
| 入口 | `Host.resolve().tui` | `Host.resolve().server`（或包主入口） |
| 形态 | `{ id, setup }`（`@opencode/plugin/tui`） | `{ id, effect }` 或 `{ id, setup }` |
| 注册物 | routes / slots / markdown 渲染器 | tools / agents / commands / hooks / MCP / skills / providers |
| 内置 | `tui/src/feature-plugins/*`（builtins.ts） | PluginInternal pre/post + ollama 等 provider 插件 |

**目录：根相同，筛法不同**（两边都扫"全局配置目录 + 项目 `.opencode` 及向上各级"）：

| 规则 | 服务端（source-directory.ts:7,23-27） | TUI（discovery.ts:21,35） |
|---|---|---|
| 子目录名 | `plugin/` **和** `plugins/` | 只认 `plugins/` |
| 条目类型 | 目录、symlink、**单个 .ts/.js 文件** | 只认目录和 symlink |

### 13.7.3 双入口插件的协作闭环

```
server 装载 my-plugin → 探测到 tui 入口 → features.tui = true (module.ts:137-139)
  → plugin.list 清单广播 / plugin.updated 事件
TUI syncServerPlugins (context.tsx:539) 收清单 → 把 features.tui 条目并入本地代际
  → install: false (:301-305) —— server 已 npm 安装过，TUI 复用同一份拷贝加载 tui 入口
纯 TUI 插件（无 server 入口）：server 扫描直接丢弃 (source.ts:167)，TUI 靠自己的目录发现独立加载
```

## 13.8 FAQ：本课讨论过的问题清单

**Q1：从 index.ts 一路索引，为什么看不到 PluginSupervisor？**
因为接线是**数据**（`const nodes = [...]` 数组 + dependencies 边）不是**代码流**。`LayerNode.compile` 构建时按图编译才实例化。搜索入口应是 `core/src/plugin/supervisor.ts:124`（中枢）与 `core/src/instance.ts:77`（唯一声明处）。

**Q2：server 启动后不加载插件，要等 TUI 连接才加载？**
per-location 懒加载：server 启动建全局图；某目录**第一个请求**到达才构建该目录的 Instance 图（含 PluginSupervisor）并加载插件，`idleTimeToLive: infinity` 建好常驻。TUI 是最常见触发者但不是唯一。

**Q3：`process.ts` 哪个分支加载插件？**
没有显式分支。`boot` 里 `Layer.buildWithScope(createRoutes(...))`（process.ts:96）构建 Layer 的**副作用**：Instance 图 → PluginSupervisor.layer 的 body 本身就是 Effect，构建即启动 watcher 与首轮激活。

**Q4：`bound.http.serve()` 不是该阻塞处理请求吗？**
它只"上膛"（注册 `request`/`upgrade` 回调 + finalizer，返回 void），不"站岗"。真正的挂起点在最外层 `Effect.never` / `server.shutdown`。serve 之后往下走的正是启动后半程（onListen 注册、boot 构建、Ref 换真 app、ready）。

**Q5：`Effect.fn("Tui.run")` 的标签会影响函数调用吗？**
不会。参数/this/返回值原样透传；标签只出现在 tracing span 和错误堆栈的人造帧里。选 `fn` 还是 `fnUntraced` 是观测性决策（对照 13.4.1 的进程级 span 污染问题）。

**Q6：`...[{signal:a},{signal:b}]` 同名参数谁生效？**
函数调用位的 `...` 按位置摆参数、不合并——两个对象是两个平行参数，不存在覆盖；覆盖只发生在对象字面量 `{...a, ...b}`（后者赢）。

**Q7：`#plugin-source` 是什么？**
package.json `imports` 字段定义的包内私有映射，按运行时条件（bun/node）分发到不同实现文件，另一份实现完全不被加载。TUI 包里还有一排同款。

**Q8：用 `@opencode/sdk` 开发也要启动后台 service 吗？**
不需要。SDK 是**嵌入式**模式：`create()`（`sdk/src/promise.ts:33` → `internal/host.ts:28`）用 `createEmbeddedRoutes` 把整个 server 跑在调用方进程内——不开 TCP 端口、无密码、默认 `:memory:` 数据库，客户端经 `OwnedFetch` 进程内 fetch 直通路由（`baseUrl: "http://opencode.local"` 只是占位假 URL）。与 daemon 机制（`Service.ensure` / `service.json`）零关联。插件不走目录发现/npm，而是 `create({ plugins: [...] })` 直接传 JS 对象，经 `SdkPlugins.Service` 进入 supervisor 的 pre 序列（supervisor.ts:154 `sdk.all()`）；13 课的 per-location 懒加载在嵌入式 server 里照常生效。

---

**延伸阅读**：06（插件装上之后 Hook 怎么触发）、05（插件能注册的 Tool/Agent 数据结构）、11（server 进程如何被客户端调活）、附 `effect-yield-pipe-fork.md`（Effect 基础读法与 Rust 对照）。
