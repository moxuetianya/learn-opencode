# 本地构建正式版（channel=latest）

> 目标：在本地打出与官方 release 同形态的二进制 —— `channel=latest`、明确的 semver、
> 使用正式数据目录（`opencode.db` / `service.json`），而不是 `0.0.0-v2-<时间戳>` 的预览版。
>
> 一键脚本：[`script/build-release.sh`](../../script/build-release.sh)。
> 本文记录手动步骤、参数语义、实测结果和踩过的坑。

---

## 1. 一键脚本

```bash
# 版本取仓库 package.json（当前 2.0.24），host 平台，含完整 web UI
./script/build-release.sh

# 指定版本 + 跑 CI 的 service 冒烟
./script/build-release.sh --version 2.0.24 --smoke

# 只编某一个 target（跨平台交叉编译由 build.ts 负责）
./script/build-release.sh --version 2.0.24 --target linux-x64 --outdir=/tmp/oc-dist

# 全平台（12 个 target），并让 build.ts 安装跨平台依赖
./script/build-release.sh --version 2.0.24 --all --with-cross-install
```

| 参数 | 作用 |
|---|---|
| `--version <semver>` | 写入二进制的版本（默认读根 `package.json`） |
| `--channel <name>` | `OPENCODE_CHANNEL`，默认 `latest`；非 latest 会提示这是预览版 |
| `--target <triple>` | 单个 target，如 `linux-x64`、`linux-x64-musl` |
| `--all` | 替代 `--single`，编译全部 target |
| `--outdir <path>` | 输出目录，默认 `packages/cli/dist` |
| `--skip-web-ui` | 嵌入**空**的 web UI 归档（更快，但浏览器端没有 UI） |
| `--with-cross-install` | 不传 `--skip-install`，让 build.ts 为所有平台装 `@opentui/core` / pty |
| `--ci-compiler` | `BUN_COMPILE_RELEASE=bun-v<required>`，用官方 bun 作为 compiler（与 CI 一致） |
| `--smoke` | 构建后跑 `packages/cli/script/service-smoke.ts` |
| `--no-lockfile-guard` | 保留 build 内部 `bun install` 对 `bun.lock` / `package.json` 的改动 |

脚本自动做的事：

1. 读根 `package.json` 的 `packageManager`，要求 bun 满足 `^1.4.2`；当前 bun 不合格就下载到
   `~/.cache/opencode-build/bun-v<ver>/`（`OPENCODE_BUILD_CACHE` 可改），**不动全局 bun**。
2. 缺少 `node_modules/@opencode/script` 时自动 `bun install --frozen-lockfile`。
3. 构建前后对比 `bun.lock` / `packages/cli/package.json`；若原本是干净的而被 build 内部的
   `bun install` 改写，自动 `git checkout` 还原（可用 `--no-lockfile-guard` 关闭）。
4. 校验产物：打印路径、大小、`--version` 输出，并警告当前 shell 里会改变运行时布局的变量
   （`OPENCODE_*` / `XDG_*` / `TMPDIR`）。
5. `--smoke` 时先检查默认 service 端口 `49374` 是否被占；被占则跳过并打印占用者，而不是报一个
   看起来像构建失败的错。

---

## 2. 手动等价步骤

```bash
# 1) bun 1.4.2（与仓库 packageManager 对齐；不必替换全局 bun）
mkdir -p ~/.local/opt/bun-1.4.2 && cd ~/.local/opt/bun-1.4.2
curl -fsSL -o bun.zip \
  https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-linux-x64.zip
unzip -oq bun.zip
export PATH=~/.local/opt/bun-1.4.2/bun-linux-x64:$PATH
bun --version        # 1.4.2

# 2) 工作区依赖（`@opencode/script` 等是 workspace 包，不装就解析不到）
cd /path/to/learn-opencode
bun install --frozen-lockfile

# 3) 正式版构建
cd packages/cli
OPENCODE_CHANNEL=latest OPENCODE_VERSION=2.0.24 \
  bun run script/build.ts --single --skip-install
```

CI 的 `build-cli` job 等价于（多两个变量）：

```bash
OPENCODE_CHANNEL=latest \
OPENCODE_VERSION=2.0.24 \
BUN_COMPILE_RELEASE=bun-v1.4.2 \
OPENCODE_RELEASE=1 \
bun run script/build.ts
```

- `BUN_COMPILE_RELEASE`：下载官方 bun 作为 compiler，产物与 CI 一致（需要网络；`GH_TOKEN` 可避免限流）。
- `OPENCODE_RELEASE`：只影响 `publish.ts` / desktop 的 finalize，本地编译不需要。

---

## 3. 为什么必须给 `OPENCODE_CHANNEL` 和 `OPENCODE_VERSION`

channel 是**编译期 `define`** 进二进制的（`packages/cli/script/build.ts`）：

```ts
define: {
  OPENCODE_CHANNEL: `'${Script.channel}'`,
  OPENCODE_VERSION: `'${Script.version}'`,
}
```

取值规则（`packages/script/src/index.ts`）：

```ts
if (env.OPENCODE_CHANNEL) return env.OPENCODE_CHANNEL
if (env.OPENCODE_BUMP) return "latest"
if (env.OPENCODE_VERSION && !env.OPENCODE_VERSION.startsWith("0.0.0-")) return "latest"
const branch = await $`git branch --show-current`.text()   // 本地在 v2 分支 → "v2"

const VERSION = env.OPENCODE_VERSION
  ?? (IS_PREVIEW ? `0.0.0-${CHANNEL}-${previewBuildNumber()}`
                 : 查 npm 最新版并 +1 patch)               // 需要网络、结果不确定
```

不同 channel 的后果：

| | `channel=latest`（正式） | 本地默认（分支名，如 `v2`） |
|---|---|---|
| 版本号 | `2.0.24` | `0.0.0-v2-<时间戳>` |
| 数据库 | `~/.local/share/opencode/opencode.db` | `opencode-v2.db` |
| service 注册 | `service.json` | `service-v2.json` |
| 默认端口 | `0xc0de`（49374） | hash 派生（10000–60000） |
| 更新通道 | `latest` | `v2` |

---

## 4. 产物与验证

```bash
# --single（host）
packages/cli/dist/cli-linux-x64/bin/opencode        # ~201 MB 单文件
packages/cli/dist/cli-linux-x64/package.json        # @opencode/cli-linux-x64 / 2.0.24

# 目录命名规则：target 里的 "opencode" 换成 "cli"
#   linux-x64 / linux-x64-baseline / linux-x64-musl / darwin-arm64 / windows-x64.exe ...

# Node SEA 版（另一个脚本）
bun run script/build-node.ts --single
packages/cli/dist/cli-node-linux-x64/bin/opencode2-node
```

验收：

```bash
./dist/cli-linux-x64/bin/opencode --version      # opencode v2.0.24
./dist/cli-linux-x64/bin/opencode debug paths    # 必须是 .../opencode.db
cd packages/cli && bun run script/service-smoke.ts
```

运行前清掉实验用的 `OPENCODE_CONFIG_DIR`、`OPENCODE_DB`、`XDG_*`，否则 `debug paths` 会显示
实验布局，看起来像构建错了。

---

## 5. 实测记录（2026-10-22，本机）

| 步骤 | 结果 |
|---|---|
| `bun install --frozen-lockfile` | 1106 个包，约 9 秒（缓存热） |
| build（含 web UI 构建 + `--single --skip-install`） | 约 1–2 分钟；vite 部分约 13 秒 |
| 产物 | `dist/cli-linux-x64/bin/opencode`，201 MB |
| `--version` | `opencode v2.0.24` |
| `debug paths` | `config ~/.config/opencode`，`db ~/.local/share/opencode/opencode.db` |
| 隔离启动 | `serve --port 4097` → `{"version":"2.0.24","pid":…,"capabilities":{"persistentPty":true}}` |
| `service-smoke` | 首次失败，原因是 49374 被占（见下），不是构建问题 |

---

## 6. 踩过的坑

### 6.1 `Cannot find module '@opencode/script'`

`@opencode/script` 是 workspace 包（`packages/script`），需要仓库根的 `bun install` 才会被链接。
只跑了 `packages/cli/script/build.ts` 而没装依赖，就解析不到。

### 6.2 bun 版本闸门

`packages/script/src/index.ts` 启动即校验：

```
This script requires bun@^1.4.2, but you are using bun@1.3.14
```

哪怕依赖装好了，bun 版本不对也会失败。脚本会自动准备一个隔离的 1.4.2。

### 6.3 `bun.lock` 被改写

`build.ts` 默认会执行：

```ts
await $`bun install --os="*" --cpu="*" @opentui/core@… @opencode-ai/pty@…`
```

这台机器配置了 npmmirror 源，于是 `bun.lock` 里 3855 行解析 URL 从 `""` 变成
`https://registry.npmmirror.com/...`，`packages/cli/package.json` 的依赖顺序也被重排。

单平台构建用 `--skip-install` 即可避免（host 依赖已由普通 `bun install` 装好）。脚本默认
`--skip-install`，并额外做了锁文件守卫：构建前干净、构建后被改 → 自动还原。

需要跨平台产物时再 `--with-cross-install`，接受锁文件改动或自己还原。

### 6.4 smoke 失败：默认端口 49374 被占

现象：

```
error: Compiled service did not publish registration
```

真实原因：默认 service 端口 `0xc0de`（49374）已被另一个进程监听，冒烟脚本启动的两个 contender
都绑定失败，因此没有写出注册文件。当时占用者是一个早先实验残留的服务：

```
pid 4183086  /home/peter/.opencode/bin/opencode serve --service
env          XDG_STATE_HOME=/tmp/bh-tui-test3/.bughunter/opencode/state
```

排查：

```bash
ss -ltnp | grep 49374
# 或
lsof -nP -iTCP:49374 -sTCP:LISTEN
```

清理后重跑即可。脚本已内置这个检查，被占时只警告并跳过，不再把环境问题伪装成构建失败。

### 6.5 `--skip-web-ui` 不是“复用已有归档”

`script/app-assets.ts` 里 `skipBuild` 直接返回 `AppArchive.encode([])`，即**空归档**。产物能跑，
但浏览器打开没有 UI。正式版不要加这个 flag。

### 6.6 产物与已装版本共用数据

`channel=latest` 意味着和官方安装共享 `opencode.db`、`service.json`、端口配置：

- 直接运行新二进制：只作为客户端连现有 service（`mismatch` 默认 `ignore`，不会替换）。
- `opencode service restart`：用**当前进程的二进制**重新 spawn（`selfCommand()` 取
  `process.execPath`），等于把本地构建变成后台服务。测完用官方二进制再 restart 还原。
- 想并行测试：`--standalone`，或临时 `OPENCODE_DB=/tmp/x.db OPENCODE_CONFIG_DIR=/tmp/x-config`。

### 6.7 `opencode upgrade` 会覆盖本地构建

安装方式检测会看二进制旁边的 `package.json.name` 是否为 `@opencode/cli*`
（`packages/cli/src/services/updater.ts`）。保持 `dist/cli-*/` 目录结构最接近官方布局；
只把单个二进制复制到 PATH 时，升级可能走 npm 路径，把本地版替换掉。

---

## 7. 安装

```bash
install -m 755 packages/cli/dist/cli-linux-x64/bin/opencode ~/.local/bin/opencode
# 或直接跑：
packages/cli/dist/cli-linux-x64/bin/opencode --standalone
```

清理构建产物（都在 `.gitignore` 内）：

```bash
rm -rf packages/cli/dist packages/cli/.cache packages/app/dist
```

---

## 8. 排查表

| 现象 | 原因 / 处理 |
|---|---|
| `Cannot find module '@opencode/script'` | 没跑 `bun install`（workspace 未链接） |
| `This script requires bun@^1.4.2` | bun 版本不满足；用脚本自动准备的 1.4.2 |
| 版本是 `0.0.0-v2-…` | 没设 `OPENCODE_CHANNEL=latest` |
| 版本号每次不同 | 没设 `OPENCODE_VERSION`，脚本去 npm 查版本并 bump |
| 用了 `opencode-v2.db` / 奇怪端口 | channel 取自分支名 |
| 产物无 Web UI | 加了 `--skip-web-ui` |
| `--version` 对但路径是 `opencode-local.db` | 运行 shell 里残留 `OPENCODE_DB` / `XDG_*` |
| `bun.lock` 出现大量 npmmirror URL | build 内部 `bun install`；用默认的锁文件守卫或 `--skip-install` |
| smoke 报 “did not publish registration” | 49374 被占；先 `ss -ltnp` 查占用 |
