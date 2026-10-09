# 10. 后台服务生命周期：daemon 死了之后，怎么被"调活"

> 本课回答：**v2 的后台进程（daemon）直接结束后，能被主动调起吗？** 结论：能，但不是它自己复活——
> opencode 没有 launchd/systemd 级别的守护或外部 watchdog，**复活是懒式的、由下一个客户端启动驱动的**。
> 任何 `opencode` 命令（TUI / `opencode api` / Desktop / SDK）启动时都会执行一次
> `Service.ensure`：发现服务不在（或假死/版本不符），就**由客户端进程把服务重新 spawn 出来**，
> 对用户表现为透明。
>
> 承接第 8 课（§8.4 daemon 模型）的进程拓扑；本课深入生命周期的每个环节。

## 10.1 一张图：谁发现谁、谁拉起谁

```
客户端进程（TUI / api / run / Desktop）
  │ 1. 读注册文件  ~/.local/state/opencode/service.json
  │ 2. 探活 GET /api/info（Basic Auth，密码取自注册文件）
  │
  ├─ 健康 + 版本匹配 ──▶ 直接复用（reuse），不发起新进程
  ├─ 假死/无响应 ×3 ──▶ SIGTERM→SIGKILL 旧 pid → 重新拉起
  ├─ 版本不匹配 ──────▶ stop（PTY 移交）→ 拉起新版本
  └─ 不存在/已死 ─────▶ spawn("opencode", ["serve","--service"], detached)
                              │
                              ▼
                    新 daemon：起 HTTP → 写注册文件 → 每 5s 自检归属
                              │
                              ▼
                    重启恢复：续跑带 write-ahead claim 的 Session、
                              通知"重启中被取消"的后台任务
```

**核心不变式：server 死了不会自愈；但客户端每次启动都会把它调活。**

## 10.2 发现契约：注册文件 `service.json`

**完整的发现契约就是一个文件**（`packages/client/src/service.ts` 注释："That file is the
complete discovery contract — reading it is all a client needs to connect"）：

- 路径：`$XDG_STATE_HOME/opencode/service.json`，默认 `~/.local/state/opencode/service.json`
  （`packages/client/src/service-probe.ts:39` `fallback()`）
- 权限：`0600`
- 内容（`Service.Info` Schema，`packages/client/src/effect/service.ts:142`）：

```json
{
  "id": "随机 UUID（服务实例标识）",
  "version": "2.x.x",
  "url": "http://127.0.0.1:49374",
  "pid": 1057820,
  "password": "base64url 随机密码"
}
```

客户端**只靠这个文件**就能连接：url + 文件里的 password 组成 Basic Auth（`headers()`，
`service-probe.ts:93`）。密码不在环境变量、不传命令行，避免泄漏给工具子进程。

### 写入与自愈（谁负责这个文件）

| 场景 | 行为 |
|---|---|
| daemon 启动监听后 | 原子写入（tmp + rename），`ServiceRegistration.register`（`packages/cli/src/services/service-registration.ts:13`） |
| daemon 优雅退出 | scope finalizer 里检查"仍拥有注册"则删除文件（self-evict，`service-registration.ts:67-70`） |
| daemon 被 SIGKILL | 文件残留（stale），由客户端探测失败兜底（见 10.3） |
| 文件被别的实例覆盖 | 注册后 fork 的自检 fiber 每 5s 回读文件，五个字段不再全等（`owns()` 失败）→ 记日志并主动 shutdown |

## 10.3 客户端调起：`Service.ensure`

### 10.3.1 入口分发

`packages/cli/src/services/server-connection.ts:21` `resolve()`：

| 启动参数 | 行为 |
|---|---|
| `--server <url>` | 只连接显式 server（探活 `/api/info`，版本不符仅警告），**不拉起** |
| `--standalone` 或 `service.disabled=true` | 起私享 server（`Standalone.start()`），不进共享 daemon |
| 默认 | `resolveManaged` → `Service.ensure`（托管模式，本课主角） |

版本不匹配策略 `--mismatch replace|ignore|error`：`replace` 直接 ensure 替换；
`ignore` 忽略版本差异复用；`error` 先 discover 兼容版，发现仅版本不符的在位者则报错
（`resolveManaged`，server-connection.ts:74-84）。

### 10.3.2 ensure 主循环（`packages/client/src/effect/service.ts:49`）

```
ensure():
  loop（25ms 间隔探测，整体 120s 预算，Schedule.spaced + upTo）:
    1. 读注册文件 → probeResult()：GET /api/info
       - 404            → 协议不兼容（incompatible），不是旧版本
       - 响应 pid ≠ 文件 pid / 版本不一致 → 视为没有有效服务
       - 200 + ok       → state: "ready"
       - 500            → state: "failed"
       - 其他/超时       → state: "waiting" / timedOut
    2. decide(service)（service-probe.ts:22）：
       - reuse   → PtyHandoff.complete → 返回 endpoint ✔
       - replace → onStart("version-mismatch") → stop() → 踢掉旧 pid
       - wait    → 继续轮询（新进程还在启动）
       - fail    → 协议不兼容/启动失败，直接报错
    3. 没有服务回答：
       - pool.shouldRecruit() → onStart("missing") → spawnContender()
       - 假死检测：注册存在但连续 3 次探测超时 →
         清 PTY handoff → terminate(旧 pid) → evict → 立即 recruit
```

### 10.3.3 关键参数（`packages/client/src/service-timing.ts:16`）

| 参数 | 值 | 含义 |
|---|---|---|
| `pollInterval` | 25ms | 探测节拍（新服务 ~250ms 就能注册好，探测节奏决定等待时长） |
| `requestTimeout` | 2s | 单次 `/api/info` 探测超时 |
| `spawnDelay` | 5s | 注册文件存在但未应答时，先给它 5s，再让 contender 竞争 |
| `maxSpawnDelay` | 30s | 失败后退避上限 |
| `promiseTimeout` | 120s | 整个 ensure 的墙钟预算 |
| `stopPollInterval × attempts` | 50ms × 100 ≈ 5s | stop 的 SIGTERM→SIGKILL 升级窗口 |

### 10.3.4 contender：spawn 出来的"竞争者"

`packages/client/src/service-contender.ts:14`：

```ts
const child = spawn(command, args, {
  detached: true,        // 独立进程组：客户端退出不影响新 daemon
  windowsHide: true,
  stdio: ["ignore", "ignore", "pipe"],   // 只收 stderr 用于报错
  env: { ...process.env, ...env },
})
child.unref()            // 从客户端事件循环摘除
```

- 命令默认 `["opencode", "serve", "--service"]`，由 CLI 的 `ServiceConfig.options()` 注入
  （`packages/cli/src/services/service-config.ts:115`，`selfCommand()` 保证 spawn 的是当前二进制）
- `contenderPool`：**最多保留 2 个尝试**；有服务回答就重置退避；尝试干净退出（说明别人赢了）
  则退避翻倍（5s→30s）；收集第一个失败用于最终报错（带 stderr 尾部）
- 竞争是特性不是 bug：多个客户端同时发现服务死了会各自 spawn，由服务端仲裁收敛（见 10.4）

## 10.4 服务端：注册即仲裁（first-writer-wins）

`opencode serve --service` 启动后（`packages/cli/src/server-process.ts:46` `processEffect`）：

1. **在位者检查**：配置了固定端口时先 `Service.incumbent` 探测同 URL——已有协议兼容的服务
   在位（含正在启动）就**静默退出**（server-process.ts:72）
2. 起 HTTP server（默认 hostname 127.0.0.1；端口：channel 默认值见 10.8）
3. `onListen` 回调：密码未持久化则先写入 service 配置（`ServiceConfig.password`，跨重启复用，
   `service-config.ts:147`），然后 `ServiceRegistration.register`：
   - tmp + rename 原子写注册文件（`0600`）
   - **fork 一个 5 秒周期的自检 fiber**：回读注册文件，`owns(found)`（五个字段全等）才继续；
     读失败或被别人覆盖 → 记日志 `managed service registration replaced; shutting down` 并
     **主动 shutdown**（`service-registration.ts:39-66`）
4. 端口被占的兜底：`addressInUse` 时等在位者最多 15s（可能正在启动），仍拿不到就报错并提示
   `opencode service set port`（server-process.ts:153-173）

**仲裁语义**：多个 contender 写同一个文件，只有一个能"拥有"它；输家读到别人的 id 就自杀。
客户端 ensure 轮询注册文件 + 探活，最终只会有一个 daemon 存活并被所有人复用。

## 10.5 停止与替换：信号升级 + PTY 移交

`Service.stop`（`packages/client/src/effect/service.ts:130`）：

```
stop({ pty: "clear" | "handoff" }):
  1. pty === "handoff" → PtyHandoff.prepare（为持久终端准备移交，best-effort）
  2. 读注册 → SIGTERM 旧 pid
  3. 每 50ms 轮询 process.kill(pid, 0)，最多 ~5s
  4. 还活着 → SIGKILL → 再轮询确认
  5. 注册文件仍描述这个 pid → 删除文件
```

`terminate` 的比较基准是 **pid 本身**而不是注册文件：注册可能在信号发出前后易手/消失，
只有被 signalled 的进程能说明自己是否已停（`service.ts:182-197` 注释）。

## 10.6 PTY handoff：持久终端跨 daemon 重启

TUI 里跑的持久终端（`/pty`）属于 daemon，但 daemon 被替换时不应杀掉用户的长跑终端：

- 停旧服务前 `PtyHandoff.prepare(file, info, timeout)` 把终端状态序列化；
- 新 contender spawn 时，客户端把 handoff 注入环境变量 `OPENCODE_PTY_HANDOFF`
  （`packages/client/src/pty-handoff.ts:77`）；
- 新 daemon 启动第一件事就消费并**删除**该环境变量（`server-process.ts:47-58`，避免泄漏给工具子进程），
  解码失败则降级为"终端从头开始"并记警告；
- 复用成功时 `PtyHandoff.complete`，服务假死被强杀时 `PtyHandoff.clear`（终端保不住要明说）。

## 10.7 调活之后：Session 与后台任务的恢复

服务被重新拉起后，"跑一半"的工作靠**数据库里的 durable 状态**接上，不依赖任何内存：

### write-ahead claim（`packages/core/src/session/execution.ts:81`）

- drain 开始：`session.execution.started` 事件与 `SessionStore.claim`（把
  `session.time_suspended` 写入 SQLite）**同一事务**提交——先记账再干活
- 终态（succeeded / failed / 用户中断 / inactivity 中断）释放 claim（`release`，置回 null）
- **shutdown 中断保留 claim**：这是"重启后继续"的标记；进程崩溃/SIGKILL 留下的 claim 同样有效
  —— *"recovery is a property of the database, never of a shutdown hook that may not run"*

### 启动恢复（`packages/core/src/session/execution/restart.ts`）

托管 server 启动时调用（嵌入方也可自己触发）：

1. `store.listSuspended()`：列出所有带 claim 的**顶层** Session（`store.ts:194`）
2. 对每个：`prepareResume` → `countResume` 记账一次恢复尝试（**先持久化再恢复**，崩溃也被
   下次扫描计入，预算无法被规避）；超预算 → 发布 `Execution.Failed(RESUME_EXHAUSTED)` 并释放
3. 预算内 → 注入 synthetic 消息 *"Continuing after restart"*（`metadata.notice: "restart"`），
   然后 `execution.resume(sessionID)` 续跑
4. **后台任务**（Job，见第 11 课）：
   - shell：重启时还在 running → 通知 *Command cancelled because the server restarted*
     （`resume: false`，避免复活空闲会话，restart.ts:101-136）
   - subagent：子会话还能续则续跑子会话，否则向父会话投递完成/失败通知

## 10.8 配置与运维

### service 配置文件（`packages/cli/src/services/service-config.ts`）

独立于 `opencode.jsonc`，位于全局 config 目录：`disabled / remote / hostname / port /
password / cors / env` 七个键；`opencode service get/set/unset <key>` 读写（改端口等会先
stop 服务）。

### channel 决定注册文件名与默认端口（`service-config.ts:32-41`）

| channel | 注册文件 | 默认端口 |
|---|---|---|
| latest / dev / beta / next | `service.json` | `0xc0de` = 49374 |
| local | `service.json` | `0xc0df` |
| 其他 | `service-<channel>.json` | 10000 + hash(channel) % 50000 |

dev worktree 与正式安装共存互不干扰的机制基础（对齐根 AGENTS.md 的 `dev:live` 说明）。

### 常用命令

```sh
opencode service status    # 读注册 + 探活，报告健康/版本
opencode service restart   # stop（PTY handoff）+ ensure 重新拉起
opencode service stop      # SIGTERM→SIGKILL 升级 + 清注册
opencode --standalone      # 私享 server，隔离共享服务问题
opencode api get /api/info # 用与服务相同的发现/认证链路发请求（可能顺带拉起服务）
```

## 10.9 完整时序：kill -9 daemon 后的下一次 `opencode`

```
$ kill -9 <daemon_pid>
   （注册文件 service.json 残留，pid 已死）

$ opencode                 # 任意客户端启动（TUI 默认 mismatch: "replace"）
   ├─ Service.ensure:
   │   读注册 → probe /api/info → 连接拒绝/超时 → service=undefined
   │   → onStart("missing") → stderr "Starting background server..."
   │   → spawn("opencode",["serve","--service"], detached) + unref
   │   → 25ms 轮询：新进程监听 → 写注册 → probe ready
   │   → PtyHandoff.complete → 返回 endpoint
   ├─ 新 daemon 启动:
   │   incumbent 检查（端口空闲，跳过）→ HTTP listen → 持久化密码 → 注册
   │   → 5s 周期自检 owns()
   │   → 启动恢复: listSuspended → 逐个 resume（带重启尝试预算）
   │              → 后台 shell 标记 cancelled（resume:false 通知）
   └─ TUI 连上 endpoint，继续用同一个全局 SQLite 里的全部会话
```

## 10.10 小结

1. **没有守护进程式的自愈**：复活是客户端驱动、懒式发生的（`Service.ensure`）。
2. **一个文件就是全部契约**：`service.json`（0600）提供 url+pid+version+password；读写全原子。
3. **spawn 都是 detached + unref**：客户端只负责"点火"，新 daemon 由系统接管存活。
4. **注册即仲裁**：5s 周期自检 `owns()`，被覆盖就自杀——多客户端并发拉起安全收敛。
5. **停止有升级链**：SIGTERM → ~5s → SIGKILL；替换前走 PTY handoff 保终端。
6. **调活之后的连续性来自数据库**：write-ahead claim + 启动恢复 + Job 恢复，
   崩溃/被杀/正常重启走同一条恢复路径。
