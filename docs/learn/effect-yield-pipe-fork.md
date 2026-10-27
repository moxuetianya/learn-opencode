# 附：读 Effect 代码的三个关键词 —— `yield*`、`pipe`、`forkScoped`

> 起因：`packages/cli/src/commands/handlers/default.ts` 里那段「建队列 → 后台消费 → 回调里塞事件」，
> 一度读成「`Effect` 是全局模块、`yield*` 在改全局状态、`Queue.take` 把主流程阻塞了」。
> 这篇文档把那三个误解逐条纠正，并给出一套看到 Effect 代码时可以直接套用的读法。

涉及的真实代码（`packages/cli/src/commands/handlers/default.ts`，`Runtime.handler(Commands, ...)` 内）：

```ts
const serviceStarts = yield* Queue.unbounded<{
  readonly reason: "missing" | "version-mismatch"
  readonly previousVersion?: string
}>()
yield* Queue.take(serviceStarts).pipe(
  Effect.flatMap((event) => Effect.logInfo("background service starting", event)),
  Effect.forever,
  Effect.forkScoped,
)

const server = yield* ServerConnection.resolve({
  // ...
  onStart: (reason, previousVersion) => {
    Queue.offerUnsafe(serviceStarts, { reason, previousVersion })
    // ...
  },
})
```

---

## 0. 结论先给

| 问题 | 答案 |
|---|---|
| `Effect` 是全局模块吗？ | 是**普通模块命名空间**（`import { Effect } from "effect"`），里面是纯函数。项目里没有全局 Effect 状态。 |
| `yield*` 会并发吗？ | 不会。`yield*` 的语义是「**在当前 fiber 内顺序执行完，把结果绑给左边**」，等价于 `await` / do-notation 的 `<-`。 |
| `pipe` 会执行吗？ | 不会。`a.pipe(f, g)` 就是 `g(f(a))`，只把描述拼装得更大。 |
| 那么主流程为什么没卡在 `take` 上？ | 因为整句 `yield*` 的对象是**最外层的 `forkScoped`**，它派生一个子 fiber 后立刻完成。`take` 只挂在那个子 fiber 上。 |
| `serviceStarts` 是空队列，`take` 它干什么？ | 空队列上的 `take` = **阻塞等待生产者**（挂起 fiber，不是返回 `undefined`）。这是「事件队列 + 常驻消费者」的经典写法。 |
| 谁往里塞东西？ | `ServerConnection.resolve` 的 `onStart` 回调，用 `Queue.offerUnsafe` 同步入队。 |

一句话记忆：

> **`yield*` 负责顺序，`pipe` 负责组合，`fork*` 负责换 fiber。**
> 一个 `yield*` 会不会卡住当前流程，只看它右边那串组合**最外层**是哪个 combinator。

---

## 1. `Effect` 是模块，不是全局 store

```ts
import { Context, Effect, FileSystem, Option, Queue, Schedule, Semaphore } from "effect"
```

`Effect` 就是一个对象，`Effect.logInfo` / `Effect.forkScoped` / `Effect.forever` 是它上面的纯函数。
调用它们不写任何全局状态，返回的是**一段描述**（不可变的普通对象），说明「将来要执行这件事」。

所以「共享」不是靠全局变量，而是靠**闭包捕获**：

```
serviceStarts (局部 const)
   ├─ 被 30 行的消费循环捕获（yield* 拿到队列句柄）
   └─ 被 39 行的 onStart 回调捕获（同步往队列塞）
```

两处引用的是同一个队列对象。这是「共享可变对象 + 闭包」，不是「全局单例」。

### 描述 vs 执行（和 Promise 最大的区别）

```ts
const a = Effect.logInfo("hi")   // 什么都没打印，只是描述
const b = Promise.resolve(1).then(() => console.log("hi"))  // 立刻入微任务队列
```

Effect 是惰性的：描述只有在被 runtime 执行时（`yield*`、`Effect.runPromise`、`Layer` 装配）才真正干活。
这条性质是后面所有讨论的前提——它解释了为什么「`pipe` 不执行」「`fork` 本身也是个 Effect」。

---

## 2. `yield*` 的真实语义

`Effect.gen(function* () { ... })` 里面是**生成器**，由 runtime 驱动：

```
生成器:  yield Queue.unbounded()  ──►  runtime 收到「创建队列」的描述
                                  ──►  runtime 执行它，得到 Queue<A, never>
生成器:  ◄── gen.next(queue) ─────  queue 被赋给 serviceStarts，生成器继续
```

等价伪代码：

```ts
const serviceStarts = await Queue.unbounded()   // 只不过 await 换成了 yield*
```

对照其他语言的说法：

| 语言 | 写法 | 含义 |
|---|---|---|
| TypeScript/Effect | `const q = yield* Queue.unbounded()` | 把 effect 的结果绑到变量 |
| Haskell do | `q <- Queue.unbounded` | bind |
| Rust | `let q = foo().await?` | await（`?` 是错误传播） |
| Promise | `const q = await foo()` | await |

所以重点是：**`yield*` 不产生并发，也不「跳出去」。它只是「在这一条 fiber 上按顺序执行」的语法。**

### 为什么 `Queue.unbounded()` 这种构造也要 `yield*`？

两个原因，都能在 `effect` 源码里看到：

1. **签名就是 Effect**（`effect` 包源码 `src/Queue.ts`，本仓库锁定 `4.0.0-rc.112`，见 `packages/cli/node_modules/effect/`）：

   ```ts
   export const unbounded = <A, E = never>(): Effect<Queue<A, E>> => make()
   ```

   所以 `const q = Queue.unbounded()` 拿到的是 `Effect<Queue>` 描述，不是队列；
   `Queue.take(q)` 要求真 `Queue`，直接用会被类型挡住。

2. **队列在构造时抓取了当前 fiber 的调度器**（`Queue.make` 内部）：

   ```ts
   core.withFiber((fiber) => {
     const self = Object.create(QueueProto)
     self.dispatcher = fiber.currentDispatcher   // ← 唤醒消费者时用它调度
     ...
     return internalEffect.succeed(self)
   })
   ```

   造队列必须知道「谁来调度」，所以它天然是个需要 fiber 上下文的 Effect。

---

## 3. `pipe` 只做组合，不执行

```ts
a.pipe(f, g)   //  ===  g(f(a))
```

原句的真实括号：

```ts
yield* ( Queue.take(serviceStarts).pipe(
  Effect.flatMap((event) => Effect.logInfo("background service starting", event)),
  Effect.forever,
  Effect.forkScoped,
) )
// 展开后：
yield* forkScoped( forever( flatMap(take(q), log) ) )
```

`pipe` 从头到尾只是在**拼装描述**：先「取一条」，再「拿到就记日志」，再「永久重复」，最后「派生到子 fiber」。

顺序很重要：`forkScoped` 在最外层，所以被 `yield*` 的是「派生」这个动作，而不是「循环」这个动作。
写成 `.pipe(Effect.forkScoped, Effect.forever)` 就变成「反复派生 fiber，每个只 take 一次」——语义完全不同。

---

## 4. 谁决定「会不会卡住」：最外层 combinator

`yield*` 的规则可以压缩成一句话：

> **在当前 fiber 内把右边的 effect 跑到完成，然后继续。**

于是「卡不卡」= 「右边的东西多久才完成」：

| 右边写的是什么 | 谁在跑 | 这句 `yield*` 何时返回 |
|---|---|---|
| `Effect.logInfo(...)` | 当前 fiber | 日志写完后 |
| `Effect.sleep("1 second")` | 当前 fiber | 1 秒后（期间当前 fiber 挂起） |
| `Queue.take(emptyQueue)` | 当前 fiber | 有人 offer 之后（**真的会卡住**） |
| `Effect.never` | 当前 fiber | 永不返回 |
| `fx.pipe(Effect.forever)` | 当前 fiber | 永不返回（类型是 `never`，只能被中断/失败终止） |
| `fx.pipe(Effect.forkScoped)` | 新子 fiber | **立刻**，因为「派生」这个动作本身就是瞬间完成的 |

`Effect.forever` 的类型是 `Effect<never, E, R>`——它在类型层面就告诉你了：这东西不会返回值，只能被打断。
所以永远不要直接 `yield*` 一个 `forever`；那等于让当前 fiber 一去不回。

---

## 5. Queue 的两端：消费者挂起、生产者同步塞

### 消费者：`take` 在空队列上挂起

`Queue.take` 的实现（`effect` 包 `src/Queue.ts`）：

```ts
export const take = <A, E>(self: Dequeue<A, E>): Effect<A, E> =>
  internalEffect.suspend(
    () => takeUnsafe(self) ?? internalEffect.andThen(awaitTake(self), take(self))
  )
```

拆开就是：

1. `takeUnsafe` 尝试同步取一个；取到了就返回；
2. 取不到 → `awaitTake` 把自己注册进 `state.takers`，**让出当前 fiber**；
3. 被唤醒后重新 `take(self)`（回到第 1 步）。

所以空队列上的 `take` 不是「读个空值返回」，而是「**登记等待 + 挂起**」。
挂起的是**执行这个 effect 的那条 fiber**，不是 JS 线程——线程立刻被还给调度器去跑别的 fiber。

这正是这段代码必须 `forkScoped` 的原因：

```
主 fiber:  [建队列] → [fork 子fiber] → [resolve 服务] → [跑 TUI] → ...
子 fiber:                 └→ take(q) …挂起…  ← offer 唤醒 → log → take 又挂起
```

### 生产者：`offerUnsafe` 同步入队

`onStart` 的签名是普通回调 `(reason, previousVersion) => void`，没有 Effect 上下文可以 `yield*`，
所以用同步逃逸口：

```ts
Queue.offerUnsafe(serviceStarts, { reason, previousVersion })
```

它直接改队列状态并 `scheduleReleaseTaker(...)`——**唤醒是被调度出去的**，不会在 offer 的调用栈里就地跑消费者。
因此 `onStart` 不会因为下游在打日志而变慢。

### 为什么用队列，而不是在回调里直接 `runFork(Effect.logInfo(...))`

对照 `packages/desktop/src/main/service/background-service.ts`：那里就是直接
`runFork(Effect.logInfo("v2 CLI background service starting", { reason, previousVersion }))`。
CLI 这边改用队列，换来三件事：

1. **保序**：offer 顺序 = 日志顺序，且都在同一个 fiber 里，不会交叉；
2. **不占额外 Runtime**：`forkScoped` 复用当前 handler 的 Scope，生命周期天然对齐；
3. **生产者零阻塞**：`offerUnsafe` 是纯同步写。

代价：日志是**稍后**由子 fiber 打的，不保证在下一行（`preflight.begin`）之前已经输出。对一条日志来说无所谓。

### 启动顺序也是设计的一部分

消费者 fork 在第 30 行，可能触发 `onStart` 的 `resolve` 在第 35 行——先起消费者再起生产者。
unbounded 队列本身会缓存未被消费的元素，所以即使顺序反了也不丢；但先起消费者才能做到「事件发生即刻记录」。

---

## 6. `fork*` 家族与 Scope（v4 命名）

v4 已经改名，`Effect.fork` / `forkDaemon` 不再存在，对应关系：

| v4 API | 依附对象 | 谁能终止它 | 典型用途 |
|---|---|---|---|
| `Effect.forkChild` | 父 fiber 的 scope | 父 fiber 结束时（auto supervision） | 一次性并行子任务，之后 `Fiber.join` |
| `Effect.forkScoped` | 当前 `Scope`（类型里多出 `Scope.Scope`） | scope 关闭时 | 结构化后台任务，和所在作用域同生共死 |
| `Effect.forkIn(scope)` | 指定 scope | 该 scope 关闭时 | 把任务挂到更外层/更早创建的作用域 |
| `Effect.forkDetach` | 全局 scope | 永不（需自行 `Fiber.interrupt`） | 真正的 daemon 任务 |

两个容易忽略的细节：

1. **fork 是惰性的**：`fx.pipe(Effect.forkScoped)` 只生成描述，子 fiber 要等 runtime 走到它才启动。
   想让它「派生即开跑」可以传 `{ startImmediately: true }`。这和 Rust 的 `tokio::spawn` 语义不同。
2. **Scope 是类型可见的**：`forkScoped` 的 `R` 里带 `Scope.Scope`。
   `packages/cli/src/framework/runtime.ts` 的 `RuntimeHandler` 显式把它列进 requirements，
   说明这些 handler 是在一个被打开的作用域里跑的——所以命令结束时，日志循环会被自动中断，不会泄漏。

---

## 7. 反证：去掉 `forkScoped` 会怎样

```ts
// 假设改成这样
yield* Queue.take(serviceStarts).pipe(
  Effect.flatMap((event) => Effect.logInfo("background service starting", event)),
  Effect.forever,
)
const server = yield* ServerConnection.resolve({ onStart: ... })   // 永远走不到
```

1. 主 fiber 在 `take` 上挂起；
2. 因为走不到第 35 行，`onStart` 永远不会被调用；
3. 于是永远没人 `offer`；
4. 队列永远空 → `take` 永远不醒 → **自己等自己，死锁**。

这个反证说明：`forkScoped` 不是「优化」，而是这段代码成立的必要条件。
同时也说明 `yield*` 的默认语义是**顺序**的——并发必须显式写在 `fork*` 上。

---

## 8. 和 Rust 的对照

```rust
let handle = tokio::spawn(async move {
    while let Some(e) = rx.recv().await { tracing::info!(?e, "background service starting") }
});   // 立即返回 JoinHandle
```
```ts
yield* Queue.take(serviceStarts).pipe(Effect.forever).pipe(Effect.forkScoped)   // 立即返回 Fiber
```

| Rust | Effect | 备注 |
|---|---|---|
| `.await` | `yield*` | 都只阻塞「当前任务/fiber」 |
| `tokio::spawn` | `Effect.forkChild` | Effect 默认 auto supervision，比 tokio 更强 |
| scoped task（scope 结束即 abort） | `Effect.forkScoped` | 结构化并发的正统做法 |
| detached task（丢 `JoinHandle`） | `Effect.forkDetach` | 必须显式写出来 |
| `join!` / `try_join!` | `Effect.all(..., { concurrency: "unbounded" })` | |
| `select!` | `Effect.race` | |
| `JoinHandle.await` | `yield* Fiber.join(fiber)` | |
| `tokio::spawn` 立即入队 | fork 惰性启动（`startImmediately`） | 见上 |

还有一处本质差异：Effect 的 fiber 是**单线程绿色线程**，`take` 挂起只是把控制权还给调度器；
`tokio::spawn` 要求 `Send + 'static`，而 Effect 的 fiber 没有 `Send` 约束。

---

## 9. 阅读启发式（建议背下来）

看到 `yield*`，按顺序问三句：

1. **右边最外层是什么 combinator？** → 决定当前 fiber 会不会继续（只有 `fork*` 会立刻返回；`race` 等赢家；`sleep`/`take`/`timeout` 会挂起）。
2. **这串 `pipe` 展开后的括号是什么？** → 从左到右当成 `g(f(a))` 手写一遍，别把 `yield*` 和前面的变量名错配成一组。
3. **这个东西在哪个 fiber / 哪个 scope 上跑？** → 找 `forkScoped` / `forkIn` / `scoped`，以及 `R` 里有没有 `Scope.Scope`。

如果一段代码读起来像「这里突然并发了」，几乎总是漏看了最外层那个 `fork*`。
反过来，如果读起来像「这里莫名其妙不阻塞」，也几乎总是漏看了最外层那个 `fork*`。

想进一步降噪，可以给长链起名字（语义上更清楚，也更好 review）：

```ts
const logServiceStarts = Queue.take(serviceStarts).pipe(
  Effect.flatMap((event) => Effect.logInfo("background service starting", event)),
  Effect.forever,
)
yield* Effect.forkScoped(logServiceStarts)   // ← 一眼看出：这行只是启动后台任务
```

---

## 10. 易错点清单

- ❌ `Effect` 是全局单例 / 在全局变量里存状态 → ✅ 模块 + 闭包捕获的局部对象。
- ❌ `yield*` = 异步跳走 → ✅ 当前 fiber 顺序执行，只是可能挂起。
- ❌ `pipe` 会执行 → ✅ 只组合，`g(f(a))`。
- ❌ `Queue.take` 空队列返回空值 → ✅ 挂起等到有值才返回；空队列上它会一直不完成。
- ❌ 以为 `forkScoped` 之后队列马上有值 → ✅ 它只是启动消费者；值来自后面的 `offerUnsafe`。
- ❌ 以为 `offerUnsafe` 会在调用栈里同步执行消费者 → ✅ 唤醒是调度出去的。
- ❌ 直接 `yield*` 一个 `Effect.forever` → ✅ 一定会卡死，必须 `fork*`。
- ❌ 随便用 `forkChild` 起长任务 → ✅ 依附父 fiber；要跨作用域存活就用 `forkScoped` / `forkIn`，要真 daemon 才用 `forkDetach`。
- ❌ 给 `Queue` 传错泛型（漏了 `E`）→ ✅ `Queue.unbounded<A>()` 的 `E` 默认 `never`；想让队列带失败语义要显式写 `E`。

---

## 参考

- `effect` 包源码（`packages/cli/node_modules/effect/src/`）：
  `Queue.ts` 的 `make` / `unbounded` / `take` / `offerUnsafe`，
  `Effect.ts` 的 `forkChild` / `forkScoped` / `forkIn` / `forkDetach` / `forever`
- 本仓库用例：`packages/cli/src/commands/handlers/default.ts`、`packages/cli/src/framework/runtime.ts`
- 并发背景：第 03 课《执行中的新输入》、第 11 课《后台服务生命周期》
