# 协议兼容性与边界

> 适用版本：CopilotBridge 1.0.0；状态截至 2026-09-10。本文描述当前仓库实际行为，不是对 GitHub Copilot、OpenAI 或 Anthropic 全量 API 的兼容承诺。

## 首要声明

- 当前唯一模型上游是 GitHub Copilot。
- OpenAI Chat Completions、OpenAI Responses 和 Anthropic Messages 是本地客户端协议。它们不表示本项目连接了 OpenAI/Anthropic 官方 API。
- “Claude 模型”仅指当前 GitHub Copilot 账号模型目录中可见、由 Copilot 路由的模型，不表示使用 Claude 网页账号。
- 本项目**不支持也不声称支持 ChatGPT 或 Claude 网页订阅**，不导入浏览器 Cookie、网页 session 或非公开订阅令牌。
- 当前 Copilot 数据面通过未公开的 internal token exchange 工作，属于**实验兼容层**。后续计划以 [GitHub 官方 Copilot SDK](https://github.com/github/copilot-sdk)作为稳定 backend，但 SDK 接入尚未完成。

协议字段定义以 [OpenAI Chat Completions](https://platform.openai.com/docs/api-reference/chat/create)、[OpenAI Responses](https://platform.openai.com/docs/api-reference/responses/create)和 [Anthropic Messages](https://docs.anthropic.com/en/api/messages)官方文档为参照；路由分类借鉴 [Jer-y/copilot-proxy 的兼容原则](https://github.com/Jer-y/copilot-proxy/blob/main/docs/protocol-compatibility.md)。

## 状态定义

| 状态 | 含义 |
| --- | --- |
| **Direct** | 客户端与 Copilot 上游使用同一协议族。本地只做鉴权、模型解析、少量受控字段补充和字节级转发。Direct 不代表上游支持该规范的每个字段。 |
| **Translated** | 本地在两个协议族之间做有边界转换。只有本文列出的语义属于兼容合同，其余不能依赖。 |
| **Unsupported** | MVP 没有可验证的忠实实现。不得依赖偶然直通；公开发行前应本地拒绝，而不是伪造成功。 |

## 路由矩阵

| 客户端路由 | Copilot 上游 | 模式 | 非流式 | 流式 | 严格边界 |
| --- | --- | --- | --- | --- | --- |
| POST /v1/chat/completions、/openai/v1/chat/completions、/chat/completions；或 Azure `/openai/deployments/{model}/chat/completions` | POST /chat/completions | **Direct** | 原样返回上游 JSON | 原样转发上游 SSE；本地强制 stream_options.include_usage=true，并要求 `[DONE]` 或错误终止事件 | 标准路由必须有 model；Azure 路由以 deployment 作为 model。无 Responses/Messages fallback。 |
| POST /v1/responses、/openai/v1/responses、/responses；或 Azure deployment Responses | POST /responses | **Direct** | 原样返回上游 JSON | 原样转发上游 SSE，并严格验证 JSON 与 completed/incomplete/failed/error 终止事件 | 标准路由必须有 model；不回退到 Chat Completions；无 WebSocket；本地不模拟 store、conversation 或 previous_response_id。 |
| POST /v1/messages 或 /anthropic/v1/messages | 按模型目录选择 POST /v1/messages、/chat/completions 或 /responses | **Direct 或 Translated** | 原生 Messages 字节转发；否则经 Chat/Responses codec 转为 Anthropic message | 原生 Messages SSE 校验后转发；Chat 与 Responses-only 都逐事件增量转译 | 必须有 model 和正整数 max_tokens；依据 `supported_endpoints` 路由。目录无端点元数据时兼容旧行为走 Chat；不会在一次请求失败后静默换协议。 |
| POST /v1/messages/count_tokens 或 /anthropic/v1/messages/count_tokens | 无上游调用 | **Translated**，本地估算 | 返回 input_tokens | 不适用 | 计入转换后的消息与工具 schema；ASCII 约 4 字符/token，非 ASCII 按 Unicode scalar 保守估算。不是 Anthropic tokenizer，不能用于计费、配额或精确上下文判断。 |
| GET /v1/models、/openai/v1/models 或 /models；以及对应 `/{id}` | GET /models | **Translated** | 过滤不可选/非 Chat/策略禁用条目，补齐 OpenAI `id/object/created/owned_by`；带非空 `client_version` query 时转 Codex `ModelsResponse` | 不适用 | 目录共享缓存 5 分钟；模型出现只说明账号目录可见。 |
| GET /anthropic/v1/models 及 /anthropic/v1/models/{id} | GET /models | **Translated** | 转为 Anthropic/Claude Desktop 风格列表或单模型 | 不适用 | 提供必填字段与 family/default 扩展；若 Copilot 目录含 limits 就映射 token 上限，否则为 null。模型出现仍不等于能力已验证。 |

根路径 /、/v1 和健康检查不是模型协议；其内容只用于本地发现与存活检查。

## 功能矩阵

表中的 Direct（上游裁决）表示本地按原协议转发，但最终能力取决于 Copilot 账号、模型和实时目录。它不是“已验证支持全部字段”的同义词。

| 能力 | OpenAI Chat | OpenAI Responses | Anthropic Messages |
| --- | --- | --- | --- |
| 文本输入与输出 | **Direct（上游裁决）** | **Direct（上游裁决）** | **Direct 或 Translated（按模型端点）** |
| system / developer / instructions | **Direct（上游裁决）** | **Direct（上游裁决）** | **Direct/Translated**：顶层 system 映射为目标协议的高优先级指令；消息中途的 system 在 Chat/Responses 中保持原位置，原生 Messages 原样转发 |
| URL 或 base64 图片输入 | **Direct（上游裁决）** | **Direct（上游裁决）** | **Translated**：Anthropic image 转 OpenAI image_url；仍取决于模型视觉能力 |
| function 工具定义与 tool call | **Direct（上游裁决）** | **Direct（上游裁决）** | **Translated**：仅 client function tools |
| tool result | **Direct（上游裁决）** | **Direct（上游裁决）** | **Translated**：转 Chat tool message，结构化错误语义会有损 |
| SSE 文本流 | **Direct** | **Direct** | **Direct/Translated**；Chat 与 Responses-only 均增量输出 |
| SSE 工具参数增量 | **Direct（上游裁决）** | **Direct（上游裁决）** | **Translated**：Responses function arguments 逐 delta 转发；Chat 路径线性累计并在工具 block 终止前校验 JSON |
| token usage | **Direct（上游裁决）** | **Direct（上游裁决）** | **Translated**：prompt/completion 映射到 input/output |
| stop reason | **Direct（上游裁决）** | **Direct（上游裁决）** | **Translated，有损** |
| extended thinking / reasoning | **Direct（上游裁决）** | **Direct（上游裁决）** | 原生 Messages **Direct**；转译路径为有边界的实验映射/no-op |
| store、conversation、previous_response_id、background | **Unsupported 作为本地能力** | **Direct 直通但未纳入 MVP 兼容合同** | 原生 Messages 上游裁决；转译路径 **Unsupported** |
| hosted/server tools、web search、computer use、MCP | **Unsupported 作为 MVP 合同** | **Unsupported 作为 MVP 合同** | 原生 Messages 上游裁决；转译路径只支持客户端 function tools |
| audio、PDF/document、file upload | **Unsupported 作为 MVP 合同** | **Unsupported 作为 MVP 合同** | 原生 Messages 上游裁决；转译路径 **Unsupported** |
| prompt caching / cache_control | **Unsupported 作为 MVP 合同** | **Unsupported 作为 MVP 合同** | 原生 Messages **Direct（上游裁决）**；转译路径校验后 no-op |
| WebSocket / Realtime | **Unsupported** | **Unsupported** | **Unsupported** |
| Batch API、Files API、Embeddings、Images API | **Unsupported** | **Unsupported** | **Unsupported** |
| 精确 count_tokens | **Unsupported** | **Unsupported** | **Unsupported**；现有端点仅返回启发式估算 |

“Unsupported 作为 MVP 合同”意味着：即使 Direct 路由当前可能把未知字段送到上游，本项目也不保证行为、事件顺序、状态持久化或未来兼容性。

## OpenAI Chat Completions：Direct 边界

### 本地保证

- 接受 /v1/chat/completions 与 /openai/v1/chat/completions。
- 也接受无 `/v1` 的 `/chat/completions`、尾斜杠，以及 Azure deployment 路径；Azure deployment 会成为上游 model。
- 请求体必须是 JSON 对象，并包含非空 model。
- model 会根据 Copilot 动态模型目录解析常见版本/日期后缀，因此上游实际 model 可能与客户端字符串不同。
- 除 model 外，请求 JSON 原样交给 Copilot；流式请求额外设置 stream_options.include_usage=true。
- 非流式响应 JSON 和流式 SSE 均不做协议重写。
- 上游 request ID、Retry-After 和常见 rate-limit headers 以允许列表方式返回。

### 不保证

- 不验证 OpenAI 规范中的所有字段组合，也不对模型能力做静态承诺。
- 不把失败的 Chat 请求转换到 Responses 或 Anthropic Messages。
- 不模拟 OpenAI 的存储、会话、文件、批处理、Realtime 或 hosted-tool 服务。
- 不保证 n 大于 1、logprobs、audio、modalities、prediction、service tier 等高级字段被 Copilot 接受。
- Direct 上游返回的错误体保持 OpenAI/Copilot 风格，不保证与 OpenAI 官方错误逐字段一致。

## OpenAI Responses：Direct 边界

### 本地保证

- 接受 /v1/responses 与 /openai/v1/responses。
- 请求体必须是 JSON 对象，并包含非空 model。
- HTTP 非流式 JSON 与 HTTP SSE 由上游原样转发。
- Responses 不可用时直接返回上游错误；不会隐式退回 Chat Completions。

### 不保证

- 没有 Responses WebSocket 或 Realtime transport。
- 本地不保存 response、conversation 或 input item，不实现 previous_response_id。
- store、background、conversation、prompt template、file input、hosted tools 和远端 MCP 尚未进入 MVP 验证合同。字段可能被直通，但客户端不能依赖成功或跨版本稳定。
- 本地不会把 Chat/Anthropic 对象“包装”成看似成功的 Responses 对象。

## Anthropic Messages：端点感知边界

Messages 客户端请求会先做不触网的基础 envelope 校验，再解析模型并读取共享目录能力。选择顺序为原生 `/v1/messages`、Chat Completions、Responses；如果目录明确给出端点但没有本桥支持的 HTTP 端点，请求会在本地失败。目录或旧模型缺少端点元数据时保留 Chat 转译兼容；上游已经返回错误后不会换协议重试。

- 原生 Messages：只替换解析后的 model，转发请求 JSON；允许列表转发 `Anthropic-Version`、`Anthropic-Beta`，并补 `X-Initiator: user`。非流式 body 原样返回；流式事件在完整帧通过 JSON、事件名及终止顺序校验后逐帧转发。
- Chat 转译：适用于声明 Chat 或缺少旧端点元数据的模型，使用下文现有 Chat 映射与增量 SSE 转译。
- Responses 转译：适用于只声明 Responses 的模型，使用 Responses 的 `input`、`max_output_tokens`、扁平 function tool/tool result 和 `text.format`，并显式设置 `store=false`。非流式结果转为 Anthropic message；流式文本、refusal 与 function arguments 逐事件转换，同时校验 sequence、item/content 坐标、终值和终止状态。

Copilot 的 Responses 实际流可能在 `response.created` 使用临时响应 ID，随后在 `response.in_progress` 和终态快照切换为提供商响应 ID。桥接层允许这种变化，保留已发送给客户端的单一 `message_start.id`，通过同一 HTTP 流及 item/content 坐标关联内容。此前要求所有快照的 `response.id` 完全一致会错误中止正常流，已撤销；文本与工具参数完整性检查仍保留。

真实文本和 function tool 流还会逐事件重新生成 `item.id` / `item_id`，包括 `output_item.done` 和终态 `output`；这些传输 ID 不适合作为内容关联键。本桥按同一 HTTP 流内稳定的 `output_index` / `content_index` 关联增量，不再要求传输 ID 相等，也不缓存无限增长的 ID 别名。ID 仍必须非空；索引、类型、事件顺序、文本终值、工具 `call_id` / name / 参数和完整终态继续验证，避免把并行工具的参数串在一起。

Responses 的 `reasoning` 项可以不带 `status`，且在 `store=false` 时返回 `encrypted_content`。[OpenAI 官方推理文档](https://developers.openai.com/api/docs/guides/reasoning#preserve-reasoning-without-stored-responses)说明该不透明状态应随后续历史回传。1.0.0 将 summary/content 为空的加密推理项封装为带版本标记的 `redacted_thinking.data`，客户端回传该 block 时恢复为 Responses reasoning input，保持历史顺序。流式路径使用 `output_item.done` 的完整状态；Copilot 终态可能再次生成不同密文，不要求密文相等。不解密、不把密文当正文、不记录其内容；保留大小限制。此封装是本桥的跨协议约定，不是 Anthropic 原生签名；仅保证同一 Responses 模型的回传，非空可见推理摘要事件尚未支持。

下面的详细请求映射主要描述 Chat 转译路径；Responses 路径对等支持文本、HTTP/base64 图片、system、客户端 function tool/tool result、tool choice、temperature/top_p、JSON Schema 与 usage/status。Responses 没有无损对应项的非空 `stop_sequences` 会明确返回 400；非空 citations/annotations 不会静默丢弃。

### 请求映射

| Anthropic 输入 | Chat Completions 映射 | 边界 |
| --- | --- | --- |
| model | 先经 Copilot 目录的版本/日期候选解析，再作为 Chat model | 必填；名称不表示连接 Anthropic 账号 |
| max_tokens | max_tokens | Messages 路由必填，且必须是 `1...Int.max` 的精确整数；`0` 的 prompt-cache-only 语义无法由 Chat 路由忠实模拟，因此显式拒绝 |
| 顶层 system 字符串或 text blocks | 单一 system message | 多段以两个换行拼接；非 text system block 不在合同内 |
| user 文本 | user content | 支持字符串或 text blocks |
| user image | image_url | 支持 URL 与 base64 data URL；依赖上游模型视觉能力 |
| assistant text | assistant content | 多块文本以换行拼接 |
| assistant tool_use | assistant tool_calls/function | input 必须可 JSON 序列化 |
| user tool_result | role=tool、tool_call_id | 文本或嵌套 text 内容；is_error=true 只加 ERROR: 前缀，原结构丢失 |
| tools | OpenAI function tools | 支持 name、description、input_schema 与 strict；strict 仅接受真正的布尔值 |
| tool_choice.auto | auto | 支持 |
| tool_choice.any | required | 支持 |
| tool_choice.none | none | 支持 |
| tool_choice.tool + name | 指定 function | 支持；缺少 name 本地 400 |
| tool_choice.disable_parallel_tool_use | parallel_tool_calls 取反 | 只接受真正的布尔值 |
| temperature、top_p | 同名字段 | 上游裁决 |
| stop_sequences | stop | 支持字符串数组 |
| metadata.user_id | user | metadata 其他字段不保留；UTF-8 超过 64 字节时使用带域分隔的 SHA-256 转成稳定的 64 位小写十六进制值，避免上游长度拒绝与直接截断碰撞 |
| thinking | Claude 目标保留经验证的形状；GPT 目标 no-op | 支持严格的 `adaptive` / `enabled` / `disabled` 配置；解析到的实际模型不是 Claude 时二次移除，避免泄漏给 GPT Chat 上游 |
| output_config.effort | 无 | 对 `low` / `medium` / `high` / `xhigh` / `max` 严格验证后 no-op；不伪造不对等的 Chat reasoning 字段 |
| output_config.format / 过渡期 output_format | response_format.json_schema | 校验 `type=json_schema` 与 schema，映射为严格 JSON Schema 输出；两种输入不能同时提供 |
| context_management | 无 | 接受多个受控 `clear_thinking_20251015 + keep=all` 或 `clear_tool_uses_20250919` 编辑并 no-op；compact、clear_at 和未知形状返回 400 |
| stream | Chat stream | 流式时强制 include_usage=true |

接受 user、assistant，以及新版 Messages 协议用于会话中途控制的 system role。system 在 Chat 和 Responses 转译中保持原始位置，不会提前到会话开头；原生 Messages 路径原样转发并交由实际模型裁决。其他 role 本地拒绝。

当前转译合同覆盖中途 system 的字符串与 text blocks。`clear_at`、message-level `output_config.effort`、`tool_addition` 和 `tool_removal` 尚无可验证的跨协议无损映射；这些扩展在原生 Messages 路径仍会直通，但不能依赖 Chat/Responses fallback。

### 转译路径的 Content block 边界

已纳入合同的 user blocks：

- text
- image，source.type 为 url 或 base64
- tool_result；其 content 仅保留字符串或嵌套 text/thinking/tool_result 可提取的纯文本

已纳入合同的 assistant blocks：

- text
- thinking
- redacted_thinking，仅保留为 opaque reasoning 数据
- tool_use

以下不受支持：

- audio、document/PDF、file、search result、server tool use、computer use 等 block；
- citations、cache_control 和 block 上其他扩展元数据；
- server-side tools、MCP、prompt caching 和持久 container/context；
- tool_choice 中除 `disable_parallel_tool_use` 以外未列出的扩展选项。

遇到缺少 type、未知 user/assistant/system/tool-result block 时，转译 codec 会返回 400。`stream`、工具 strict、stop_sequences、tools、metadata 容器都做严格类型检查。当前 Claude Code 的 `cache_control`、`service_tier`、`top_k`、工具加载提示、`allowed_callers=direct` 与 `thinking.block_binding` 会先校验再在不具备等价语义的转译路径中剥离；高风险或无法忠实表示的 container、MCP、代执行限定与数据驻留字段仍明确拒绝。原生 Messages 路径不做这些有损剥离。

### 非流式响应映射

- 只读取第一个 Chat choice。
- message.content 转 text block。
- reasoning_text 转 thinking block，同时出现的 reasoning_opaque 转 signature。只有 reasoning_opaque 时转为 `redacted_thinking`；两者都没有时不生成 thinking block。
- tool_calls 转 tool_use；function.arguments 必须是完整 JSON object，缺 id/name、截断或解析失败时返回 502，绝不下发半成品工具调用。
- message.refusal 在 Anthropic 没有完全等价的 block，当前作为 text block 保留，并把 stop_reason 设为 refusal。
- usage.prompt_tokens/completion_tokens 转 usage.input_tokens/output_tokens；缺失时为 0。
- finish_reason=tool_calls 映射 tool_use；length 映射 max_tokens；stop 映射 end_turn；content_filter/refusal 映射 refusal。缺失或未知完成原因返回 502。
- stop_sequence 始终为 null；部分完成原因细节不可恢复。

### SSE 响应映射

正常事件顺序为：

1. message_start
2. 零个或多个 content_block_start / content_block_delta / content_block_stop
3. message_delta
4. message_stop

thinking 先于 text 输出；reasoning signature 在 thinking block 关闭前输出。只有 reasoning_opaque 的流会以单个 `redacted_thinking` start/stop block 保留。Chat tool arguments 会按 tool index 缓存，到流结束时按顺序生成 tool_use block 与单个 input_json_delta，因此不是逐 token 的工具参数流。累计 opaque 和 tool arguments 超过配置上限时会中止，不会无界缓存。

上游 `event: ping` 与 SSE comment keep-alive 会转换为 Anthropic `ping` 事件下发；即使上游静默，本地也会约每 20 秒主动发送 ping，避免长 thinking 阶段被 Claude 客户端当作静默超时。

如果上游流在 HTTP 200 和 message_start 之后失败，只能发送 Anthropic SSE error event，HTTP 状态码无法再改成非 2xx。客户端必须同时处理 HTTP 错误和流内 error event。

### count_tokens 限制

本地先运行与真实请求相同的 fail-closed 转换，再序列化转换后的 messages 与 tools。ASCII 部分约按 4 个 Unicode scalar/token，非 ASCII 部分按至少 1 scalar/token，最少返回 1。它会计入工具 schema 与协议结构，但仍不计算图片内容、模型专用 tokenizer、缓存 token 或隐藏 reasoning，绝不能用于计费、硬性上下文截断或与 Anthropic 官方 usage 对账。

## 模型解析与能力判断

- Codex CLI/Desktop 会请求 `/v1/models?client_version=...`。该请求返回 Codex 专用的顶层 `models` 数组，并为每个模型提供非空 `base_instructions`、可见性、优先级、shell 类型、推理档位和截断策略；普通 OpenAI 客户端请求同一路径但不带该 query 时仍收到标准 Copilot/OpenAI `{object,data}` 目录。
- `client_version` 是当前 Codex 客户端无条件追加的区分信号；`originator` 和 User-Agent 只可辅助诊断，不作为唯一判断条件。
- Codex 目录排除 Copilot 明确标记为不可选的内部/旧条目及非 chat 模型；推理档位按 Copilot 实际数组保留，输入窗口以 `max_prompt_tokens` 为安全上界，避免用总 context window 高估可发送 prompt。
- Codex 目录声明 `apply_patch_tool_type=freeform`。该请求 schema 已对实际 Copilot Responses 上游验证可接受；工具最终是否被模型调用仍由所选模型和上游裁决。未发现明确能力字段时，`reasoning.summary` 被显式关闭而不是依赖 Codex 的宽松默认值。
- Core API 可由嵌入方传入 alias；macOS 应用尚无 alias 配置入口。
- 模型列表、单模型查询、版本候选解析和 Messages 端点选择共享同一个 5 分钟缓存；并发 cache miss 合并为一次上游请求。没有候选变体的精确模型 ID 会跳过名称解析读取，但 Messages 仍需读取目录端点能力。
- 原始模型目录、已解析的 ID 集合与端点索引使用同一份缓存快照；只在成功刷新时解析一次 JSON，缓存命中的选路不再反复解析整份目录。过期、失败、取消和重复 ID 的行为保持不变。
- 为常见日期后缀、点号版本和 1M 名称尝试候选 ID；解析失败时仍可能把原请求 ID 交给上游。
- /anthropic/v1/models 提供 capabilities=null、max_input_tokens、max_tokens、is_family_default，以及能从名称可靠识别时的 anthropic_family_tier。token 限制只来自 Copilot 目录现有 limits；未知值保持 null。
- 每个 model × protocol × transport 组合都需要真实探测。HTTP 200、模型在目录中出现或名称包含 claude，都不足以证明 tools、vision、reasoning、Responses 或大上下文可用。

未来应维护按模型缓存的 capability 结果，并区分 stable、conditional、experimental、unsupported；模型预览状态和账号策略变化应使缓存失效。

## 传输、鉴权和资源边界

- 服务仅允许 127.0.0.1、::1 或 localhost。
- `GET /healthz`、`GET /health`、CORS `OPTIONS` 和 `HEAD /api/hello`、`HEAD /anthropic/api/hello` 免鉴权；其余请求必须通过 Authorization: Bearer、X-API-Key、Azure `api-key` 或 `x-goog-api-key` 提供本地 key。
- key 使用常量时间比较；不能为空。
- 默认最大请求体为 4 MiB，超出返回 413。这是本地内存安全边界，低于 [Anthropic Messages 官方 32 MB 上限](https://platform.claude.com/docs/en/api/errors#request-size-limits)，因此大图片/文档请求不属于完全 drop-in 兼容范围。
- 非流式上游响应默认最大 32 MiB；SSE 单行默认最大 4 MiB，同一事件的 data 默认最大 8 MiB。这三个限额相互独立，超出时失败而不继续缓存。
- 非流式响应按 64 KiB 批量汇总，请求 ByteBuffer 在完成或超限后释放；TCP 小包关闭 Nagle 延迟。Anthropic 工具参数流采用线性累计，同时保持原有总量上限。
- 当前支持 HTTP/1.1 keep-alive、有序 pipelining 与 SSE，不支持 HTTP/2/WebSocket。每连接最多缓存 2 个待处理请求，全局最多 16 个活跃请求和 32 个连接；超出请求并发返回 503，超出连接上限直接拒绝。
- 模型目录上游请求超时为 20 秒，推理请求为 600 秒；Anthropic 转译流在此期间持续给下游发送 keep-alive，客户端断开会取消本地转发任务。
- 停止服务时会先关闭 listener 与全部子连接，取消并等待在途请求，再关闭 NIO event loops。
- 每个本地响应都有唯一 `x-request-id` / `request-id`；Anthropic 错误体的 `request_id` 与响应头一致。另以 `x-upstream-request-id` 转发上游请求 ID，并允许 Retry-After 与常见 rate-limit headers。
- token exchange 返回的动态 API endpoint 必须是 GitHub Copilot 官方允许的 HTTPS host、根路径和 443 端口；出站 token exchange 与推理请求均拒绝 HTTP 重定向。
- 当前响应设置 Access-Control-Allow-Origin: *。鉴于浏览器可访问 loopback，公开稳定版应改为可配置 Origin/Host allowlist；本地 bearer key 不能省略。

## 错误与 fallback 规则

- GitHub device flow 使用 `application/x-www-form-urlencoded` 发送 OAuth 请求，并沿用系统代理与 TLS 信任链。申请登录码仅对明确的短暂传输错误和 408/429/部分 5xx 做有界重试；授权轮询的传输重试不得快于 OAuth `interval`/`slow_down`/`Retry-After`。
- 重定向、取消、证书不受信、证书过期、主机名不匹配、OAuth 终止错误与其他 4xx 均不自动重试，也不会关闭证书校验或静默改为直连。
- JSON 无效、缺 model、Anthropic 缺 max_tokens、未知 role/block 或无效 tool_choice 返回本地 400；Anthropic 路由使用 `invalid_request_error` envelope。
- 本地 API key 无效返回 401；Anthropic 路由使用 Anthropic `authentication_error` envelope。
- 请求体过大返回 413。
- 上游 401/403 会使短期 Copilot token 失效并只重试一次。
- 其他上游状态码保持原状态；Anthropic 路由把错误包装为 Anthropic error envelope。
- 已经开始的 SSE 无法改变 HTTP 200；截断或本地转换失败会在流内发送对应协议的 error event。Chat 缺 `[DONE]`、Responses 缺终止事件、原生 Anthropic 缺 `message_stop` 或终态 error 都按失败处理。
- HTTP 日志中的 502 也可能代表已经返回 HTTP 200 的流在中途失败。流式异常会另记来源、固定原因类别、上游协议路径和本地请求 ID，不输出 prompt、工具参数、原始上游错误文本或凭据。
- Chat 与 Responses 永不互相 fallback。
- Anthropic Messages 只按模型目录预选一次原生 Messages、Chat 或 Responses；上游失败后不再串联或降级到另一个协议。
- 不因某模型失败而静默换账号、换 provider、降级协议或绕过限额。

## Gemini / Google API 边界

原生 Gemini `generateContent` / `streamGenerateContent` 使用独立的 Content、Part、candidate 与 SSE 合同，当前为 Unsupported。本应用不把它伪装成 OpenAI 或 Anthropic 成功响应。支持 OpenAI compatibility 的客户端可以把 base URL 指向本应用，并调用 Copilot 目录实际开放的模型；`x-goog-api-key` 仅是本地鉴权头别名。参见 [Google 官方 OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai) 与 [原生 GenerateContent API](https://ai.google.dev/api/generate-content)。

## backend 演进约束

引入官方 Copilot SDK 后，应保持本文件定义的客户端合同，同时满足：

- SDK backend 和 internal-experimental backend 可显式选择，不自动静默切换。
- 固定 SDK/CLI runtime 版本，并对两条 backend 运行相同 golden tests。
- 禁用 SDK 的 Shell、文件、Git、MCP 和其他第一方工具；代理只做模型 I/O。
- 若 SDK 无法忠实实现某字段，保持 Unsupported 或返回清晰错误，不用 agent 文本伪造协议对象。
- 只有 SDK 路线通过模型、取消、超时、SSE 顺序、工具调用和错误映射回归测试后，才可设为默认稳定 backend。

## 发布前必须补齐

- 继续跟踪 Anthropic 新增的顶层字段与 block 扩展，在进入兼容合同前保持显式边界。
- 建立模型级 capability probe 与缓存失效策略。
- 缩小 CORS，并校验 Host。
- 增加按客户端速率限制、连接 idle timeout、慢客户端背压和流式超时测试。
- 添加 direct 路由的协议 golden fixtures，覆盖工具、图片、reasoning、usage、错误和取消。
- 在 UI 与 API discovery 中显示 backend=internal-experimental，避免误认为官方 GitHub Copilot API。
- 保持“协议兼容不等于网页订阅可用”的产品文案。
