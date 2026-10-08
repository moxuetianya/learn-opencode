# 6. 一次对话的全过程：消息构造 → Agent 循环 → 流式事件

> 承接第 5 课（TUI 启动与配置/插件/provider 装配）。本课追踪：输入框敲回车后，消息在 TUI 如何构造、经 HTTP 到 `SessionPrompt`、如何生成 system prompt 与 model messages、工具怎么执行、thinking/tool-use 是并行还是串行，以及结果怎么"流"回界面。

## 6.0 总览

```
[输入框 submit]                          packages/tui/src/component/prompt/index.tsx
   │  session.create (新会话) / 复用 sessionID
   │  parts = [editorContext?, text, file/agent/subtask...]
   ▼
POST /session/:id/message                 handlers/session.ts → SessionPrompt.prompt
   │
   ▼
createUserMessage(prompt.ts:635)
   ├─ agent 解析 (input.agent ?? defaultInfo)
   ├─ model 解析 (input.model ?? agent.model ?? 会话当前模型) + variant
   ├─ parts 解析 (文本/文件/目录/MCP资源/图片归一化/subtask)
   ├─ plugin.trigger("chat.message")
   └─ 写库 session.message + 逐 part 写库（同时发布 EventV2 事件）
   │
   ▼
loop → SessionRunState.ensureRunning → runLoop(prompt.ts:1081)
   ├─ 每轮 step：
   │   ├─ 过滤压缩历史 filterCompacted → MessageV2.latest
   │   ├─ 终止判断 (finish≠tool-calls 且无工具调用)
   │   ├─ title/summary 后台 fork；subtask→task 工具；compaction→重发
   │   ├─ 组装 system prompt (env + skills + instructions + mcp + agent/provider prompt)
   │   ├─ MessageV2.toModelMessagesEffect(历史→ModelMessage)
   │   ├─ SessionTools.resolve → tools (tool.definition hook)
   │   └─ processor.create + handle.process(...)
   │           │  (LLM stream: AI SDK streamText 执行工具)
   │           ▼
   │   processor.ts: LLMEvent 流 → 写 part + 发事件
   │         reasoning-* / tool-input-* / tool-call / tool-result
   │         step-start/finish(usage+成本+快照) / text-start/delta/end
   │   ▼
   │   "continue" → 回到 runLoop 下一 step；"stop|compact" → 退出
   │
   ▼
EventV2Bridge → GlobalBus → RPC/SSE → TUI sync store → 渲染
```

## 6.1 TUI 侧：回车后发什么

位置：`packages/tui/src/component/prompt/index.tsx` 的 `submit`（`:929`，防重入）→ `submitInner`（`:946`）：

1. 兜底 IME 刷新 `store.prompt.input`；空/不可用直接返回；`exit/quit/:q` 退出。
2. 取当前 agent（`local.agent.current()`）与模型（`local.model.current()`，来自 `context/local.tsx:236-245`；未选模型时弹 `DialogProviderList` 警告）。
3. `sessionID == null` 时先 **`session.create`**（`:999-1008`）——参数：`directory`/`workspace`/`agent`/`model {providerID,id,variant}`；创建失败 toast。
4. 组装 parts（`:1101-1108`）：
   - `editorParts`：编辑器选区上下文（`editor.labelState()==="pending"` 时，`formatEditorContext(...)` 生成 synthetic text part，`:1041-1056`）。
   - `{type:"text", text: inputText}`：正文。
   - `nonTextParts`：粘贴/拖拽产生的 file/agent part（extmark 关联，`:1035-1036`），粘贴内容先经 `expandTrackedPastedText` 内联展开（`:1025-1033`）。
5. 三种模式分发：
   - **shell 模式**（`store.mode==="shell"`）：`session.shell`（`:1060-1068`）。
   - **命令** `/xxx`（`:1070-1090`，且 `sync.data.command` 里存在）：`session.command`（`:1082-1090`，含参数解析与 file parts）。
   - **普通**：`session.prompt({ sessionID, model, agent, variant, parts }, {throwOnError:true})`（`:1093-1111`）——fire & forget（`void ...`），**界面不靠响应体渲染**，靠 §6.7 的 SSE 事件。
6. 清空输入、`history.append`、新会话 50ms 后 `route.navigate` 进 `session` 路由（`:1133-1142`）。

请求体 `PromptPayload` 的契约在 `groups/session.ts:316-330`；`POST /session/:sessionID/message`（`SessionPaths.prompt`，`groups/session.ts:96`）→ `handlers/session.ts:294-309`：`requireSession` 后 `promptSvc.prompt({...payload, sessionID})`，**handler 同步返回**一个 JSON（`HttpServerResponse.stream` 单条），实际对话全在 SSE 事件里。

## 6.2 server 侧：createUserMessage 怎么造出第一条 user message

位置：`src/session/prompt.ts:635-1050` `createUserMessage`（`Effect.scoped`）。

1. **Agent 解析**（`:636-644`）：`input.agent` 命中则 `agents.get`，否则 `agents.defaultInfo()`；不存在 → publish `Session.Event.Error` + 抛 `Agent not found`。
2. **模型解析**（`:646-654`）：`input.model ?? ag.model ?? currentModel(sessionID)`；variant 优先 `input.variant`，否则 agent 的 `ag.variant`（且须在模型 variants 里，`:648-654`）。`currentModel`（`:614-633`）从 `SessionTable.model` 读会话记录模型 → 回退最近一条带 model 的 user message → `provider.defaultModel()`。
3. **user message 记录**（`SessionV1.User`，`:656-670`）：`id`、`agent`、`model{providerID,modelID,variant}`、`tools`、`system`、`format`。
   - **会话级 model/agent 落库**：与 `sessions.get` 的当前值不同则 `sessions.setAgentModel`（`:672-689`）。这就是"切模型后下一条生效"的机制。
4. **parts 解析** `resolvePart`（`:699-993`），对每个用户 part：
   - `file` + `source.type==="resource"`（MCP 资源，`:703-784`）：先写一条 synthetic 文本"Reading MCP resource: ..."，然后 `mcp.readResource`；文本内容转 text part；blob 按 mime/size 过滤（10MB、白名单 `application/pdf,image/*`），超限/不支持写省略提示；读失败写错误文本。
   - `file` + `data:` URL（`:786-807`）：text/plain 展开为 `decodeDataUrl` 的文本 + 判断是否保留原始 file part。
   - `file` + `file:`（`:808-971`）：`text/plain`/`application/x-directory` 走 **Read 工具真身执行**（`registry.named().read.execute`，`:813-828`）；带 `?start=&end=` 区间先用 LSP `documentSymbol` 定位符号（`:839-850`）；返回"Called the Read tool with the following input: {...}" synthetic 文本 + 输出/附件。非文本 mime → 读文件 base64 成 `data:` URL part（`:949-969`）。
   - `agent`（`:974-990`）：把用户召唤的子代理写成 part + synthetic 提示"用 task 工具带 subagent 调用"，并带权限评估（`Permission.evaluate("task",...)`）。
   - 普通 `text`/`subtask`：直通（`:992`）。
5. **`plugin.trigger("chat.message", {...}, { message, parts })`**（`:999-1009`）——插件可改消息与原 parts。
6. **图片归一化**：`mime.startsWith("image/")` 的 file part 过 `image.normalize`（缩小超限图片，`:1011-1020`）。
7. **写库**：`decodeMessageInfo` 校验（`:1022-1044`，失败仅告警）→ `sessions.updateMessage(info)` + 逐 part `sessions.updatePart`（`:1046-1047`）。`updateMessage`/`updatePart`（`session.ts:631-649`）会向 `EventV2Bridge` publish `SessionV1.Event.MessageUpdated/PartUpdated` —— 这是 TUI 渲染的源头。
8. `prompt()`（`:1052-1071`）：`revert.cleanup` → `createUserMessage` → `session.touch` → 把 `input.tools` 转为 session permission（`:1060-1067`）→ `noReply===true` 直接返回，否则 `loop({sessionID})`。

## 6.3 Agent 循环主体：runLoop

`loop`（`prompt.ts:1343-1347`）→ `state.ensureRunning(sessionID, lastAssistant, runLoop(result))`（`run-state.ts:88-93`）：**同一会话只有一个 run 在执行**（重入会被合并/等待），cancel 走 `run-state.ts:77-85`。

`runLoop`（`prompt.ts:1081-1341`）是一个 `while(true)`：

1. **状态**：`status.set(sessionID, {type:"busy"})`（`:1089`）。
2. **取历史**：`MessageV2.filterCompactedEffect(sessionID)`（`:1092-1094`）——把历史重排成模型可读序列（compaction 摘要 + 压缩后保留的尾巴，实现 `message-v2.ts:521-572`）。
3. **latest**（`message-v2.ts:585-601`）：按最大 id 找出 `user/assistant/finished`，并收集未完成的工作任务 `tasks`（compaction part / subtask part）。
4. **终止判断**（`:1111-1130`）：`lastAssistant.finish` 存在、不是 `tool-calls`、且没有残留工具调用（`hasToolCalls`，`:1106-1109`；被 cleanup 标记 `interrupted` 的孤儿工具不算）、且 `lastUser.id < lastAssistant.id` → break（正常结束）。
5. **第一步**：后台 fork `title`（`:1133-1139`，小模型生成标题，`prompt.ts:193-253`）与 `summary`（`:1252-1253`，`session/summary.ts`）。
6. **任务处理**：
   - `task.type==="subtask"` → `handleSubtask`（`:1144-1146`，定义 `:255-449`）：直接执行 **task 工具**，内部走 `taskTool.execute(taskArgs, {...})`——takes `Agent.Info`/`messages`/`abort`/`ask`，递归跑一个"子会话"（主循环通过 `promptOps`（`:144-150` 的 `ops()`）把 `prompt/loop/cancel` 借给 task 工具）。完成写回 tool part；若带 `command` 再补一条 synthetic 用户消息（`:430-448`）。
   - `task.type==="compaction"` → `compaction.process`（`:1149-1159`）。
   - **溢出检查**（`:1161-1168`）：`lastFinished && !summary && compaction.isOverflow(tokens)` → `compaction.create({auto:true})` 后 continue。
7. **Agent 与步数**：`agents.get(lastUser.agent)`（`:1170`）；`maxSteps = agent.steps ?? Infinity`，`isLastStep = step>=maxSteps`（`:1178-1179`）——最后一步会给模型追加 `MAX_STEPS_PROMPT`。
8. **提醒注入**：`SessionReminders.apply`（`:1180-1184`）。
9. **assistant 消息**：`id=MessageID.ascending()`、`parentID=lastUser.id`、`mode/agent`、`path{cwd,root}`、cost/tokens 清零、`modelID/providerID`（`:1186-1201`），`sessions.updateMessage(msg)`。
10. **processor.create**(`:{1213-1219}`)：见 §6.4。
11. **工具集** `SessionTools.resolve`（`:1226-1241`）：见 §6.5；若 `lastUser.format.type==="json_schema"` 再注入 `StructuredOutput` 工具（`:1243-1250`，`json_schema` 时 `toolChoice:"required"`，`:1285`）。
12. **system prompt 组装**（`:1257-1271`）：
    ```
    system = [...env, ...instructions, ...(mcpInstructions?[mcpInstructions]:[]), ...(skills?[skills]:[])]
    ```
    - `sys.environment(model)`（`system.ts:60-96`）：模型身份、cwd/worktree、git、平台、日期 + 可用 references。
    - `sys.skills(agent)`（`system.ts:98-110`）：skill tool 未被禁用时把可用 skills 描述塞进 system（verbose 版，见 `skill/index.ts` 的 `fmt`）。
    - `instruction.system()`：全局指令（`src/session/instruction.ts`）。
    - `sys.mcp(agent, session.permission)`（`system.ts:112-128`）：MCP server 的 `<mcp_instructions>`（被 permission 禁用的工具整段剔除）。
13. **历史转模型消息**：`MessageV2.toModelMessagesEffect(msgs, model)`（`:1262`，`message-v2.ts:131-415`）：
    - 用户消息：text part 直通；file part（非 text/plain、非目录）转 `{type:"file",url,mediaType,filename}`；compaction part 转 "What did we do so far?"；subtask part 转 "The following tool was executed by the user"（`:198-242`）。
    - assistant 消息：text（携带 `providerMetadata`）、`step-start`、tool part 按状态转 `tool-<name>`（completed→output-available；error→output-error；pending/running→`[Tool execution was interrupted]`，防 Anthropic 悬空 tool_use，`:349-360`）；reasoning part 保留（**换模型时降级为普通 text**，`:362-376`）；工具输出里的媒体按 provider 能力抽取为独立 user 消息再发送（`:298-305`、`:380-399`，`supportsMediaInToolResult` 白名单 `:147-159`）。
    - 最后 `convertToModelMessages`（`:406-414`）转成 AI SDK `ModelMessage[]`。
14. **`handle.process({...})`**（`:1272-1286`）→ 产出一个 `Result = "compact"|"stop"|"continue"`（`processor.ts:30`）：
    - `structured !== undefined` → 写入 message 的 `structured` 字段，break（`:1288-1293`）。
    - **stop-filter 语义**（`:1295-1317`）：`finish==="content-filter"` 或 json_schema 未产出 → 写错误并 break。
    - `result==="stop"` → break（`:1319`）；`"compact"` → `compaction.create({auto:true,overflow})`（`:1320-1328`）；否则 continue 下一轮。

整个 loop 结束时 `compaction.prune`（`:1338`）并返回最后一条 assistant 消息（`lastAssistant`，`:1073-1079`）。

## 6.4 processor：LLM 事件流 → 持久化 part

位置：`src/session/processor.ts`。

- `create`（`:98`）：**先** `snapshot.track()` 抓取快照（注释 `:99-101`：AI SDK 可能先执行工具再发 step-start，抓晚了就丢了 diff），构建 `ctx`，返回 `Handle{message, updateToolCall, completeToolCall, process}`。
- `process`（`:627-683`）：
  1. `status.set(busy)`；`llm.stream(streamInput)`（`:640`）。
  2. `Stream.tap(handleEvent)` 逐个消费 `LLMEvent`，`Stream.takeUntil(needsCompaction)`（`:642-646`）。
  3. 中断：`onInterrupt` 标记 `aborted` 并 `halt(AbortError)`（`:648-655`）。
  4. `Effect.retry(SessionRetry.policy(...))`——按 provider 的 API 错误重试策略（`:660-674`，`session/retry.ts`），重试时会先 `status.set({type:"retry", ...})`。
  5. `catch(halt)`（`:599-625`）：ContextOverflow → 开自动 compaction 或（禁止时）报错退出；普通错误写到 `assistantMessage.error` + `Session.Event.Error`。
  6. `ensuring(cleanup)`（`:539-597`）：patch 快照、收尾未结束 text/reasoning part、等待 250ms 内工具结算（`:571-575`）、把仍在 `running` 的工具标 `error + interrupted:true`（`:577-593`）——这样下次循环不会误判成待执行。

### 事件 → part 映射（`handleEvent`，`:278-537`）

| LLMEvent | 处理 | 行 |
|---|---|---|
| `reasoning-start/delta/end` | 建/更新 `reasoning` part（`reasoningMap` 缓冲，delta 走 `updatePartDelta` 流式），end 时写回最终版 | `:280-313` |
| `tool-input-start/delta/end` | `ensureToolCall`：不存在则建 `pending` tool part（`{status:"pending", input:{}, raw:""}`） | `:315-329` |
| `tool-call` | 确保 part 并转 `running`，写入 input、providerMetadata；**doom-loop 检测**（`:358-380`）：最近 3 个 part 全是同一个工具 + 相同输入 → `permission.ask("doom_loop")` | `:331-381` |
| `tool-result` | 工具已在 AI SDK 内执行完 → 归一化 output（附件图片再 resize）→ `completeToolCall` 写 `completed` part 并 `settleToolCall` | `:383-414` |
| `tool-error` | `failToolCall`：`status:"error"`；`PermissionV1.RejectedError || Question.RejectedError` → `blocked=true` | `:416-419` |
| `provider-error` | throw（进 retry） | `:421-422` |
| `step-start` | 补快照 + `step-start` part（snapshot 字段） | `:424-433` |
| `step-finish` | **结算**：usage/cost/`finish` 写到 assistant message（`getUsage`，`session.ts:338`），若溢出则 `needsCompaction=true`；快照 patch 写 `patch` part；后台 `summary` | `:435-484` |
| `text-start/delta/end` | `text` part 流式（delta 走 part-delta 事件）；end 时 `plugin.trigger("experimental.text.complete")`（`:516-524`） | `:486-532` |
| `finish` | 无操作 | `:534-535` |

`Result` 计算（`:679-682`）：`needsCompaction → "compact"`；`blocked || message.error → "stop"`；否则 `"continue"`。注意 `ctx.shouldBreak=(cfg.experimental?.continue_loop_on_deny!==true)`（`:633`）——被拒权限后默认停。

## 6.5 工具与 Hook：每个环节响应什么

### 6.5.1 工具清单怎么来：`SessionTools.resolve`

`src/session/tools.ts:41-493`：

1. **registry.tools(...)**（`tool/registry.ts:286-335`）过滤出内置+自定义工具：
   - 按模型做工具替换（`registry.ts:287-298`）：gpt 系用 `patch`，其余用 `edit/write`；websearch 按 flags。
   - `plugin.trigger("tool.definition", {toolID}, output)`（`registry.ts:313`）——插件可改描述/参数。
   - task 工具描述会注入可用 subagent 列表（`registry.ts:260-273` `describeTask`）。
2. 每个工具包成 AI SDK `tool({description, inputSchema, execute})`（`tools.ts:99-133`），**execute 内部**：`tool.execute.before` 钩子 → `item.execute(args, ctx)` → 附件补 `id/sessionID/messageID` → `tool.execute.after` 钩子 → abort 时同步 `completeToolCall`。
3. **MCP 资源工具**：`list_mcp_resources/list_mcp_resource_templates/read_mcp_resource`（`:136-386`，仅当某 server 有 resources 能力），执行前也 trigger `tool.execute.before` 并 `ctx.ask` 权限（pattern `mcp:<server>:*`）。
4. **MCP server 暴露的工具**（`:390-490`）：`mcp.tools()` 每条 `item.execute` 包装成 hook + `ctx.ask({permission:key, patterns:["*"], always:["*"]})` + 输出规范化（text/image/resource → text+附件，超限截断）。
5. `ctx`（工具执行上下文，`:59-90`）：`sessionID/abort/messageID/callID/extra(model,bypassAgentCheck,promptOps)/agent/messages`；`metadata(val)` → `updateToolCall`（允许把 title/metadata 实时写回 part）；`ask(req)` → `permission.ask({...req, tool:{messageID,callID}, ruleset:merge(agent.permission, session.permission)})`——**权限按 agent+会话叠算**。

### 6.5.2 LLM 请求外层的 hook：`LLMRequestPrep.prepare`

`src/session/llm/request.ts:56-206`：

- **system**（`:58-66`）：`[agent.prompt ? ... : SystemPrompt.provider(model), ...input.system, ...(user.system?...)]` ——即 **agent 自有 prompt 或按模型族挑的 system.txt + 上一步的 env/skills/mcp**（`SystemPrompt.provider` 在 `system.ts:27-42` 按 `api.id` 选 `anthropic/gpt/codex/gemini/...txt`）。然后 `plugin.trigger("experimental.chat.system.transform")`（`:69-73`）。
- **params**（`:114-132`）：`plugin.trigger("chat.params", {sessionID,agent,model,provider,message}, {temperature,topP,topK,maxOutputTokens,options})`——默认来自 `ProviderTransform.*` + agent 覆盖；options 是 `base(provider) ⌢ model.options ⌢ agent.options ⌢ variant` 的 mergeDeep（`:84-99`）。
- **headers**（`:134-146`）：`plugin.trigger("chat.headers", ...)`，再合并 `opencode` provider 的 `x-opencode-*` 头与 `User-Agent`（`:187-205`）。
- **工具过滤**（`:148` 与 `resolveTools` `:208-214`）：`user.tools?.[k]!==false` 且未被 permission 禁用（`Permission.disabled`）。
- provider 适配：OpenAI 系 `strict:false`（`:152-158`）；copilot 空工具但有历史工具调用时塞 `_noop`（`:159-175`）。

### 6.5.3 所有 hook 触发点速查（v1 会话路径）

| Hook | 触发点 |
|---|---|
| `config`（加载时改写配置） | `plugin/index.ts:246-254`（server 客户端）；`tui/runtime.ts`（TUI 侧另行） |
| `event`（全局事件） | `plugin/index.ts:256-264` 订阅 EventV2Bridge |
| `tool.definition` | `tool/registry.ts:313` |
| `chat.message` | `prompt.ts:999-1009`（用户消息+parts 已解析后） |
| `chat.params` | `session/llm/request.ts:114-132` |
| `chat.headers` | `session/llm/request.ts:134-146` |
| `experimental.chat.system.transform` | `request.ts:69-73`；`agent.ts:381`（generate/标题路径） |
| `experimental.chat.messages.transform` | `prompt.ts:1255`（runLoop 每步）；`compaction.ts:350` |
| `experimental.text.complete` | `processor.ts:516-524`（text-end） |
| `experimental.session.compacting` / `.autocontinue` | `compaction.ts:343,454` |
| `tool.execute.before` / `.after` | `tools.ts:107,122,176,209,261,292,339,373,403,420`；`prompt.ts:307,389`（subtask） |
| `command.execute.before` | `prompt.ts:1460-1464` |
| `shell.env` | `prompt.ts:554-558`（session.shell）、`pty.ts:71`、`tool/shell.ts:417` |
| `experimental.provider.small_model` | `provider.ts:1885`（getSmallModel） |

### 6.5.4 会话级别权限

`permission.ask`（`src/permission`）通过事件把 permission request 推给 TUI（`packages/tui/src/routes/session/permission.tsx` 渲染），用户回答 `Permission.Event.Replied` → 工具继续或抛出 `PermissionV1.RejectedError`（→ failToolCall + `blocked`）。

## 6.6 LLM 运行时选择

`src/session/llm.ts`：

- `stream`（`:357-381`）→ `run`（`:85-355`）：并行取 `provider.getLanguage`（§5.7 缓存）、config、provider info、auth。
- 双运行时：
  - **native**：`flags.experimentalNativeLlm` 时 `LLMNativeRuntime.stream`（`:226-269`），`unsupported` 时给出原因并回落 AI SDK。
  - **默认 AI SDK**：`streamText({...})`（`:280-353`）：`temperature/topP/topK/maxOutputTokens` + `providerOptions`（`.providerOptions(...)`）+ `tools` + `toolChoice` + `abortSignal` + `headers` + `messages` + `model: wrapLanguageModel(language, middleware[transformParams])`（`:325-343`，`ProviderTransform.message` 做 provider 特定的 prompt 变换）+ `experimental_repairToolCall`（大小写修复 / 交由 `invalid` 工具，`:296-312`）。
- `Stream.fromAsyncIterable(result.fullStream)` → `LLMAISDK.toLLMEvents`（`llm/ai-sdk.ts`）归一化为统一的 `LLMEvent` 流（`llm.ts:372-378`）——这是 processor 唯一认识的事件类型。

## 6.7 Thinking 与 Tool-use：并行还是串行？

### 结论先给

| 维度 | 行为 | 证据 |
|---|---|---|
| **一次 provider turn 内的多个 tool-call** | **并行**执行（AI SDK `streamText` 对同一步骤的 tool call 并发 dispatch），但结果按事件顺序流回 | `llm.ts:280` `streamText`；各工具 `execute` 是 async，`tools.ts:102-132` |
| **工具互相之间的串行点** | 只有一个：**权限询问** `ctx.ask`/`permission.ask` 阻塞该工具，直到用户回答（`question/permission` 事件） | `tools.ts:81-89`；被拒 → `failToolCall` + `blocked`（`processor.ts:200-202`） |
| **provider turn（step）之间** | **串行**：runLoop 每个 `while` 迭代只有一次 `llm.stream`，等完整流结束才决定 continue | `prompt.ts:1272-1286`、`prompt.ts:1334-1335` |
| **线程内辅助任务** | title/summary/compaction 用 `Effect.forkIn(scope)` **后台并行** | `prompt.ts:1133-1139,1252-1253`、`processor.ts:471-476` |
| **子代理（task/skill）** | 并行：subtask 任务运行时 **父循环在等待**（`handleSubtask` await task 工具），子 agent 自己跑一套 loop（经 `TaskPromptOps`）；不同会话互不阻塞（`run-state` per session） | `prompt.ts:255-449` |
| **thinking（reasoning）** | 与文本/工具**几乎同时**：模型在流里先发 reasoning-* 再发 tool/text；处理上是**顺序消费**同一事件流；**delta 流式写入数据库并推送**（对 TUI 可见，collapse 渲染） | `processor.ts:280-313`；TUI `routes/session/index.tsx:1567-1591`（`reasoningSummary` collapse） |
| **DOOM loop 保护** | 同一工具+相同输入连续 3 次的循环被 `ask("doom_loop")` 打断 | `processor.ts:358-380` |

### 为什么是"流内并行 + 跨 step 串行"

AI SDK 的 `streamText` 会为模型返回的每个 step 的 tool calls 生成 `tool-call` 事件，然后**并发**执行每个 `tool()` 的 `execute`（opencode 的 `execute` 都是纯 promise 回调，无互斥锁），所有 result 以 `tool-result` 流回。因此：

- 模型一次输出 N 个工具调用 → N 个工具**同时跑**（`tools/read + bash + grep` 并行，符合 AGENTS 的"general"设计——**"Execute multiple units of work in parallel"**，`agent.ts` general 描述）。
- **但**：同一个工具内部依赖只能靠模型自己拆成多个串行 turn（比如 bash 里 `&&` 或"分析→再跑"），opencode 不做工具间依赖调度。
- 若模型在同一 turn 再要求"看完 A 的结果再决定 B"，历史里 A 的结果必然先于 B 的 decision turn 进入（因为 result 是同步写库的）。你看到的"一步步来"通常是**模型行为**，不是框架锁。

### 安全/清理语义

- 一次 step 结束时 `step-finish` 立即结算 tokens/cost 并写 `patch` part（快照 diff，`processor.ts:435-470`）。
- 中断（Ctrl-C → `SessionRunState.cancel` → processor 中断）：`cleanup` 正在跑的工具标 `interrupted`，**孤儿工具不会被下次循环当成待办**（`prompt.ts:96-100` `isOrphanedInterruptedTool`；`prompt.ts:1116-1127` 检测退出）。
- 重试：API 错误按 `SessionRetry.policy`（`session/retry.ts`）指数退避；`context_overflow` 直接切 compaction（`processor.ts:607-617`）。

## 6.8 事件如何回到 TUI（渲染侧）

1. **写入即发布**：`session.ts:631-649` `updateMessage/updatePart` → `EventV2Bridge.publish`（`event-v2-bridge.ts:19-33`：为事件带上 InstanceRef 的 location/project/workspace，并透传到 `GlobalBus`，`:35-61`；v2 durable 事件另发 `sync`）。
2. **出 server**：worker 的 `GlobalBus.on("event") → Rpc.emit("global.event")`（`cli/tui/worker.ts:24-26`）；外部模式则走 `global.event` SSE（`event` 路由，`server.ts:146-149`）。
3. **进 TUI**：`context/sdk.tsx:82-117` 订阅，16ms 批量 flush（`:54-80`）→ `context/sync.tsx` 的 `handleEvent`：
   - `message.updated`：按 id upsert（`:315-354`，超 100 条裁剪）。
   - `message.part.updated`（`:370-390`）：upsert part。
   - **`message.part.delta`**（`:392-409`）：对 `text/reasoning` 字段追加 delta——**流式打字机效果**就是这里来的。
   - `session.status`（`:310-313`）：busy/idle/retry（footer 转圈）。
4. **首屏加载**：进入 session 路由时 `sync.session.sync(sessionID)`（`sync.tsx:588-661`）：`session.get` + `session.messages({limit:100})` + `session.todo` + `session.diff` 一次性水合，与 delta 事件合并（`tracker` 防覆盖正在进行中的 part）。对话中的部分用事件增量更新，不再回头拉。
5. **展示**：`routes/session/index.tsx` 把 messages/parts 渲染成列表（text 高亮、tool part 折叠+运行中 spinner、reasoning collapse 见 `thinking.ts`、`message.part.updated` tool 状态切换 plan 模式 `:320-333`）。

## 6.9 一个"完整 turn"的时序（浓缩）

```
T1  TUI submit                POST /session/:id/message {parts}
T2  server                   createUserMessage: agent/model/variant/parts → 写库 → chat.message hook
T3  runLoop step 1           history → system → tools → assistant msg → processor.create
T4  LLM.stream               LLMRequestPrep: system/params/headers hooks → streamText
T5  stream 流                reasoning-start → tool-call × N → [N 个工具并行执行]
                                ├── 每个: tool.execute.before → execute → tool.execute.after
                                └── 权限 ask: 等待 UI 回答
                             tool-result × N → step-finish(usage/快照/patch) → text-delta...
T6  processor              全部事件写库 + EventV2 推送（TUI 实时渲染）
T7  process 返回 "continue"  → runLoop 下一 step（新 assistant msg → T4 再来）
    模型不再调用工具         → finish!==tool-calls → break
T8  compaction.prune        → 返回 lastAssistant → 会话 idle
```

## 6.10 附：V2 Session Core（迁移中的目标形态）

`packages/core/src/session.ts`（`SessionV2`）+ `packages/server/src/handlers/session.ts` 已接上 v2 协议（`POST /api/session`、`POST /api/session/:id/prompt`，`packages/protocol/src/groups/session.ts:129-224`）：

- **耐久输入先行**：`prompt()` 只做 `SessionInput.admit(db, events, {id,sessionID,prompt,delivery})` 写一条 durable `session_input`（`core/src/session.ts:360-386`），`resume!==false` 时再 `execution.wake(sessionID)` 调度执行；冲突 reuse（`PromptConflictError`/`LifecycleConflict`）精确校验。
- **执行编排**：`packages/core/src/session/execution/`（`SessionExecution` 进程级、服务 Session-ID；本地实现 `execution/local.ts` + `run-coordinator.ts`：同 Session resume 去重合并、跨 Session 可并行）。
- **runner**：`packages/core/src/session/runner/*`（含 `max-steps.ts`），序列化 runner 把 admitted input 在安全的 provider-turn 边界推进成可见 user message。
- AGENTS.md 中"V2 Session Core"一节列出的约束（一个显式 `llm.stream` 调用/每次 provider turn、不桥接 `SessionPrompt.loop`、drain 无持久身份等）就是这套运行的护栏；当前 TUI 仍走 §6.1-6.9 的 v1 路径，迁移中不重复实现。

---

## 附：核心文件速查

| 关注点 | 文件 |
|---|---|
| TUI 启动/同步 | `packages/tui/src/app.tsx`、`context/sdk.tsx`、`context/sync.tsx`、`context/data.tsx` |
| 发送消息 | `packages/tui/src/component/prompt/index.tsx` |
| server 入口/实例 | `packages/opencode/src/cli/cmd/tui.ts`、`cli/tui/worker.ts`、`server/server.ts`、`project/bootstrap.ts` |
| 配置/插件/provider | `src/config/config.ts`、`src/plugin/index.ts`、`src/plugin/loader.ts`、`src/provider/provider.ts` |
| 会话主循环 | `src/session/prompt.ts`、`src/session/message-v2.ts`、`src/session/session.ts` |
| 流式处理/工具 | `src/session/processor.ts`、`src/session/tools.ts`、`src/session/llm.ts`、`src/session/llm/request.ts` |
| 事件桥 | `src/event-v2-bridge.ts` |
| V2 核心（迁移） | `packages/core/src/session.ts`、`packages/server/src/handlers/session.ts`、`packages/protocol/src/groups/session.ts` |
