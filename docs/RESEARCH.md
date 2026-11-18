# GitHub Copilot 反向代理方案调研

> 调研快照：2026-09-10。本文比较公开仓库和官方文档，用于技术选型，不构成法律意见，也不代表 GitHub、OpenAI 或 Anthropic 的认可。

## 结论先行

本项目应把“客户端协议兼容”和“上游账号/提供商”分开设计：

1. 当前 MVP 是原生 Swift 数据面，直接访问 GitHub Copilot 上游，并通过未公开的 internal token exchange 换取短期令牌。它能快速验证 OpenAI/Anthropic 客户端兼容性，但必须标记为**实验兼容层**，不能承诺接口稳定性。
2. 后续稳定路线应采用 [GitHub 官方 Copilot SDK](https://github.com/github/copilot-sdk)，固定 SDK 与 Copilot CLI/runtime 版本，并在代理模式关闭全部本机文件、Shell、MCP 等工具权限。
3. 协议层应采用 [Jer-y/copilot-proxy 的 direct / translated / unsupported 原则](https://github.com/Jer-y/copilot-proxy/blob/main/docs/protocol-compatibility.md)：同族协议尽量直通，跨协议只做有边界的转换，无法保持语义时本地拒绝。
4. macOS 产品形态可借鉴 VibeProxy、Quotio 与 AIUsage 的菜单栏体验、进程监管、签名公证和可回滚更新，但不直接继承它们对第三方订阅 OAuth 的产品声明。
5. 本项目当前只使用 GitHub Copilot 账号作为模型上游。“OpenAI Chat”“OpenAI Responses”“Anthropic Messages”是**客户端协议名称**，并不表示支持 ChatGPT 网页订阅、Claude 网页订阅、浏览器 Cookie 或非公开会话令牌。未来接入 OpenAI/Anthropic 时，应优先使用官方 API key、企业凭据或提供商明确支持的 BYOK 方式。
6. 调研阶段曾评估 [farion1231/cc-switch](https://github.com/farion1231/cc-switch) 作为桌面客户端配置管理器；项目现已取消内置导入和数据库写入，只提供标准 OpenAI/Anthropic 本地端点，由用户在目标客户端中手动配置。

## 当前实现定位

当前仓库使用 Swift 6.2 toolchain（Swift 5 language mode）、SwiftNIO 和 macOS Security.framework：

- HTTP 服务只允许绑定 loopback，并要求本地随机 API key。
- GitHub OAuth 长期凭据保存在 macOS Keychain；短期 Copilot token 只缓存在进程内。
- 设置页通过动态 Copilot endpoint 读取当前可选模型；额度优先解析 token exchange 同批返回的快照，缺失时才 best-effort 查询账户状态，且全部只驻留内存。
- OpenAI Chat Completions 与 Responses 请求直通 GitHub Copilot 对应路径。
- Anthropic Messages 被有界转换为 Chat Completions；具体边界见 [COMPATIBILITY.md](COMPATIBILITY.md)。
- Claude Desktop 所需的 `/v1/models`、`HEAD /api/hello`、Messages SSE 和 Bearer gateway 鉴权由独立 `/anthropic` prefix 提供；Codex 使用独立 `/v1` prefix，避免两种模型列表 schema 冲突。
- 当前使用的 GitHub device-flow client ID 与 https://api.github.com/copilot_internal/v2/token 均不属于 GitHub 面向第三方承诺稳定的公共 API。因此，此数据面不能被描述为“官方 Copilot API”。

当前路线的价值是快速完成原生 ARM MVP 和协议测试；它的缺点是上游端点、请求头、模型能力和令牌交换行为都可能无预告变化。产品界面和日志应持续显示“实验”状态，且不得在失败时静默切换账号或绕过限额。

模型和额度必须使用运行时数据：模型可见性受套餐、计费主体及组织/团队 policy 共同决定；模型的 `supported_endpoints`、上下文限制与计费字段不能硬编码。2026 年 6 月后多数计划转为 AI Credits，仍可能存在过渡期 Premium Requests；新旧额度桶不能相加，`chat`/`completions` 请求数也不能改名为 AI Credits。官方 SDK 提供 `models.list` 和实验性的 `account.getQuota`，但没有 Swift SDK 且需要 Copilot CLI runtime，因此当前原生版本继续使用隔离的 internal adapter。参考 [官方 SDK usage and billing](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/usage-and-billing)、[模型可用性](https://docs.github.com/en/copilot/reference/ai-models/supported-models)与[计费变化](https://docs.github.com/en/copilot/reference/copilot-billing/request-based-billing-legacy/what-changed-with-billing)。

## 公开方案对比

| 方案 | 许可证 | 架构、认证与协议 | 主要风险或限制 | 对本项目的选择理由 |
| --- | --- | --- | --- | --- |
| [GitHub Copilot SDK](https://github.com/github/copilot-sdk) | [SDK 为 MIT](https://github.com/github/copilot-sdk/blob/main/LICENSE)；Copilot CLI/runtime 使用[单独许可证](https://github.com/github/copilot-cli/blob/main/LICENSE.md) | 应用通过多语言 SDK，以 JSON-RPC 驱动 Copilot CLI agent runtime；支持 Node、Python、Go、.NET、Java、Rust。登录可使用 Copilot CLI 的系统 Keychain 凭据、GitHub OAuth token、环境变量或 BYOK，详见[官方认证文档](https://github.com/github/copilot-sdk/blob/main/docs/auth/authenticate.md)。Go/Rust 可管理或捆绑 CLI，存在 darwin-arm64 路线。 | SDK 是 agent runtime，不是透明 LLM HTTP 代理；需要自行维护 OpenAI/Anthropic 适配。CLI 默认暴露第一方工具，若权限处理错误会让远端请求触发本机文件或命令操作。SDK 与 runtime 需锁版本。CLI 再分发必须保持原样、附许可证，并且宿主产品要提供超出 CLI 的实质功能。 | **后续稳定主路径。**官方认证和版本化接口优于 internal token exchange；适合在完成 HTTP 兼容层后替换底层。代理模式必须 deny-all，不让 SDK 执行任何本机工具。 |
| [rakshithbn-proj/copilot-bridge](https://github.com/rakshithbn-proj/copilot-bridge) | [MIT](https://github.com/rakshithbn-proj/copilot-bridge/blob/main/LICENSE) | VS Code 扩展在 `127.0.0.1` 暴露自定义 `/chat`、`/chat/stream` 及文件、Git、终端等大量编辑器能力，Python 客户端管理会话；模型调用经 `vscode.lm.selectChatModels` 与 `sendRequest`。本地 API key 自动生成到权限为 0600 的配置文件，body 限制 10 MB，流式断连会取消模型任务。 | 不是 OpenAI Responses 或 Anthropic Messages 代理，请求类型没有 OpenAI `user` 字段，无法直接解决跨协议字段约束。功能面可让 HTTP 调用执行本机文件、命令和 Git 操作，安全边界明显大于纯推理代理；并发也主要交由 VS Code/Copilot 裁决。 | **只借鉴本地 HTTP 工程细节。**采用 body 上限、常量时间鉴权和断连取消思路，不引入编辑器/终端控制面，也不复制其自定义协议。 |
| [larsbaunwall/vscode-copilot-bridge](https://github.com/larsbaunwall/vscode-copilot-bridge) | [Apache-2.0](https://github.com/larsbaunwall/vscode-copilot-bridge/blob/main/LICENSE) | 基于官方 VS Code Language Model API 的窄桥，只提供 `/v1/chat/completions`、`/v1/models` 与 `/health`；强制 loopback、Bearer token，并用 `maxConcurrent` 做并发拒绝。OpenAI 请求类型虽接受 `user`，但消息归一化只构造 VS Code 的 user/assistant message，不把该字段交给模型。 | 必须保持 VS Code 运行；不支持 Responses、Anthropic Messages、完整 reasoning/usage 语义。system/tool 会被文本标记包装，属于面向编辑器 API 的有损映射，不适合作为 Claude Code 的透明网关。 | **官方 API 后端的轻量参考。**它验证了通过 `vscode.lm` 可以避免 private endpoint 与 provider 字段泄漏，但不能替代本项目的多协议适配；借鉴显式并发上限与 fail-closed token 配置。 |
| [Jer-y/copilot-proxy](https://github.com/Jer-y/copilot-proxy) | [MIT](https://github.com/Jer-y/copilot-proxy/blob/main/LICENSE) | Bun/TypeScript 单进程反代；OpenAI Chat、Responses、Embeddings、Anthropic Messages/count_tokens 及 SSE。GitHub device flow 后换取短期 Copilot token，按到期时间预刷新，并处理失效重试。其[产品边界](https://github.com/Jer-y/copilot-proxy/blob/main/docs/product-support.md)明确为 loopback 单一可信操作者。 | 明确声明是未受 GitHub 支持的逆向代理；长期凭据为权限受限的本地文件而非 Keychain。多账号不等于多租户隔离。Responses 的存储、会话恢复、hosted tools、WebSocket 等只能在模型真实支持时使用，不能伪造兼容。 | **协议设计和测试的首要参考。**其 direct / translated / unsupported 分类、模型能力探测和 fail-closed 思路应被本项目采纳；不照搬凭据存储与未公开上游实现。 |
| [whtsky/copilot2api](https://github.com/whtsky/copilot2api) | [MIT](https://github.com/whtsky/copilot2api/blob/main/LICENSE) | Go 单文件 sidecar，发布 darwin-arm64；支持 OpenAI Chat/Responses/Embeddings、Anthropic Messages、Gemini 与 AmpCode。device flow 后由[内部 token 交换](https://github.com/whtsky/copilot2api/blob/main/auth/token.go)获取短期凭据并刷新。 | README 明确要求本机使用，默认没有下游 API key 校验。凭据目录权限虽有限制，但[凭据内容仍为本地 JSON](https://github.com/whtsky/copilot2api/blob/main/auth/storage.go)。协议面越宽，模型特判和语义损失越多。 | **ARM 发布和 Go sidecar 参考。**若未来把数据面拆为独立进程，可参考其体积与交叉编译；当前原生 Swift 路线在 Keychain 和系统集成上更合适。 |
| [messense/copilot-api-proxy](https://github.com/messense/copilot-api-proxy) | [MIT](https://github.com/messense/copilot-api-proxy/blob/main/LICENSE) | Rust 反代；OpenAI、Anthropic、Gemini、Amp/Droid 路由，支持 SSE、tool/function calling、vision；device flow 与后台短期 token 刷新。 | 仓库明确警告其上游是逆向工程，可能随时失效。默认还可代理 Amp/Factory 控制面，增加请求数据、遥测和凭据的信任边界；长期 GitHub token 存在普通文件。 | **Rust 协议实现参考。**适合评估未来安全 sidecar，但不采用额外控制面代理，也不把内部接口当作稳定契约。 |
| [VibeProxy](https://github.com/automazeio/vibeproxy) | [MIT](https://github.com/automazeio/vibeproxy/blob/main/LICENSE) | 原生 SwiftUI 菜单栏应用，内嵌 CLIProxyAPIPlus，负责 OAuth、账号状态、路由与更新；提供 Apple Silicon 构建、签名公证和 Sparkle 更新。项目 README 声称支持多个订阅型 provider 及 GitHub Copilot。 | 核心数据面依赖外部 sidecar；provider 或 sidecar 更新可导致整套功能回归。项目本身也提示直接使用某些 OAuth token 存在账号风险。其 README 的“订阅可用”属于该项目声明，不是本项目可继承的保证。 | **原生 UX、菜单栏和发布流程参考。**本项目不采用“网页订阅复用”作为卖点，认证能力按每个提供商的公开条款独立评审。 |
| [Quotio](https://github.com/nguyenphutrong/quotio) | [MIT](https://github.com/nguyenphutrong/quotio/blob/master/LICENSE) | 原生 macOS 控制面，管理 CLIProxyAPI；支持账号、配额、故障转移、CLI 自动配置和 Sparkle 更新。README 列出 GitHub Copilot、Claude、OpenAI Codex 等 OAuth/provider。 | 首次运行下载并信任独立代理二进制，供应链校验、版本兼容和回滚至关重要。多账号轮询容易被误用为绕限额机制；provider OAuth 是否允许被第三方代理不能只依据开源项目声明判断。 | **账号 UX、守护与升级参考。**若未来下载 sidecar，应采用版本固定、校验、健康检查、原子切换和自动回滚。 |
| [AIUsage](https://github.com/sylearn/AIUsage) | [Apache-2.0](https://github.com/sylearn/AIUsage/blob/main/LICENSE) | 原生 Xcode 应用，聚合多 provider 的配额与本地代理；使用 Keychain，默认 loopback，并区分普通推理接口与管理接口。其代理管理流程包含下载、校验、试运行、提升与回滚。 | 功能面远大于本项目 MVP；账户聚合、遥测、调用归档和第三方代理都会扩大隐私与供应链审计范围。不同 provider 的“订阅”能力仍需分别核对条款。 | **安全默认值和 sidecar 生命周期的最佳参考。**借鉴 Keychain、最小监听面、管理 key 分离和可回滚更新，不复制其大而全的产品范围。 |
| [CC Switch](https://github.com/farion1231/cc-switch) | [MIT](https://github.com/farion1231/cc-switch/blob/main/LICENSE) | 跨平台桌面配置管理器；分别管理 Claude Code、Claude Desktop、Codex 等配置，也能在需要时做本地协议与模型映射。Claude Desktop 既可直接连接 Anthropic-compatible gateway，也可把固定 Claude 角色映射到非 Claude 模型；Codex 原生 provider 使用 Responses。 | 开启本地路由会多一层代理；重复做 Responses↔Chat↔Messages 转换会扩大语义损失。Desktop 模型选择器还受各客户端自身限制。 | **已评估但不再内置集成。**保留为历史方案对比；CopilotBridge 不读取其凭据或数据库，也不向其中写入 Provider。 |

## 桌面客户端兼容边界

- [Claude Code gateway 配置](https://code.claude.com/docs/en/llm-gateway)要求 Messages 流式、tool use 和相关 beta/version header，并可使用 `GET /v1/models` 与 count_tokens。CopilotBridge 因此给 Anthropic 单独保留 `/anthropic` prefix，而不是让 OpenAI 与 Anthropic 共用一个 `/v1/models` schema。官方客户端只会把 `claude`/`anthropic` 前缀的发现模型加入选择器；GPT 模型需用显式模型变量。
- [Claude Desktop 第三方 gateway](https://claude.com/docs/third-party/claude-desktop/gateway)支持 static API key 与 Bearer。官方路径面向 Claude 模型；通过社区工具把 GPT 等非 Claude 模型伪装成 Sonnet/Opus/Haiku 属于实验兼容，不应包装为官方保证。
- [Codex 自定义 model provider](https://developers.openai.com/codex/config-reference)当前 `wire_api` 使用 Responses。CopilotBridge 直接提供 `/v1/responses`，因此 GPT 模型正常路径不需要中间配置管理器做 Responses→Chat 转换。
- ChatGPT Desktop 的普通 Chat、ChatGPT Web 与 Codex Cloud 没有在本机读取任意 provider base URL 的公开接口。这里所说的桌面接入仅指本地 Codex/Work 工作流；客户端 UI 是否展示自定义模型仍可能受官方登录状态和版本限制。

当前 Claude Desktop、Claude Code 与 Codex 的纯手工配置见 [CLIENT_SETUP.md](CLIENT_SETUP.md)。

## 认证与 token 生命周期

社区 internal 路线普遍采用以下流程：

1. 发起 GitHub OAuth device flow，获得长期 GitHub OAuth token。
2. 调用未公开的 copilot_internal token endpoint，换取短期 Copilot token。
3. 从 expires_at、refresh_in 或本地保守默认值计算预刷新时间。
4. 上游返回 401/403 时使缓存失效，只重试一次，避免无限刷新和请求风暴。
5. 多个并发请求共享一次刷新任务，失败采用有上限的退避。

本项目已经把长期 GitHub token 与本地 API key 存入 Keychain，并将短期 token 保持在内存中。仍需保持以下边界：

- 不提供 token 导出 HTTP 路由，不在 UI、日志、命令行参数或崩溃报告中输出 secret。
- OAuth client ID 应可替换为项目自有、启用 device flow 的 GitHub OAuth App；不能把其他客户端的公开 client ID 当成长期产品契约。
- internal exchange 失败时明确报错，不抓取浏览器 Cookie、不读取 ChatGPT/Claude 网页会话，也不尝试规避上游认证。
- exchange 返回的动态推理 endpoint 只能落在 GitHub Copilot 官方 allowlist 对应的 HTTPS 域名；禁止重定向、userinfo、非 443 端口、非根路径和 host 混淆，防止短期 token、prompt 或 tool data 被导向其他 origin。
- 迁移到 SDK 后优先使用 [Copilot CLI 官方认证和系统 Keychain](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli)，并提供凭据来源、注销和撤销入口。

## 安全、合规与许可证风险

### GitHub 使用边界

- [GitHub Acceptable Use Policies](https://docs.github.com/en/site-policy/acceptable-use-policies/github-acceptable-use-policies)限制未经授权的复制、转售、过量自动化和给基础设施造成不当负载的行为。
- [Copilot usage limits](https://docs.github.com/en/enterprise-cloud@latest/copilot/concepts/usage-limits)说明服务会为公平性和防滥用执行速率限制。产品不得把多账号、重试或故障转移设计成绕过配额。
- [GitHub Copilot 附加条款入口](https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features)会随账号类型而不同；Business/Enterprise 还受组织策略约束。
- 企业环境可能需要配置 [Copilot 网络 allowlist](https://docs.github.com/en/copilot/reference/copilot-allowlist-reference)。代理不应绕过企业管理员的策略或网络控制。

### 本机攻击面

- 只监听 127.0.0.1 或 ::1 仍不足以完全消除风险；本地恶意进程和浏览器页面可能访问 loopback。必须保留随机 bearer key、常量时间比较、请求体上限和速率/并发限制。
- 当前实现限制为 32 个连接、16 个活跃请求与每连接 2 个待处理 pipelined 请求，并在停止服务时 drain 在途任务；正式发行仍应增加按客户端速率限制、idle timeout 与慢客户端背压验证。
- 当前响应允许通配 CORS，但受 bearer key 保护。公开发行前应缩小 Origin/Host 规则，并确认预检接口不会泄漏配置。
- 若采用官方 SDK，必须关闭第一方 Shell、文件、Git、MCP 等工具。HTTP 代理的客户端负责工具循环；代理进程不应以用户权限执行模型提出的操作。
- 日志默认记录方法、路径、状态、耗时与脱敏运行摘要；Authorization、Cookie、请求/响应体、prompt、代码和 tool input/result 不得写入日志。

### 再分发

开源项目的 MIT/Apache-2.0 许可证只覆盖各自仓库代码，并不授予模型服务或账号协议的使用权。特别是 Copilot SDK 为 MIT，而 Copilot CLI/runtime 的[专用许可证](https://github.com/github/copilot-cli/blob/main/LICENSE.md)要求：

- 只分发未修改的 runtime；
- 只能作为具有实质额外功能的应用或服务的一部分；
- 不得把 runtime 作为独立或主要产品；
- 附带许可证及版权、商标和归属说明。

正式捆绑前需要建立第三方 notices、版本清单和法律审核。不能因为某个开源代理能登录 ChatGPT 或 Claude，就推断网页订阅允许被转换为通用 API。

## 推荐演进路线

### 阶段 1：收紧当前实验 MVP

- 保持原生 SwiftUI/SwiftNIO、loopback、Keychain 和本地 bearer key。
- 按 [COMPATIBILITY.md](COMPATIBILITY.md)公开精确协议边界；未测试字段不写“支持”。
- internal backend 在设置、诊断和日志中持续标记 experimental。
- 模型列表只表示账号可见模型，不代表所有协议和字段都可用；对模型/协议组合做真实 capability probe。

### 阶段 2：引入官方 SDK backend

- 建立 backend 接口，使 internal-experimental 与 sdk 两条路径可独立测试，禁止静默互相 fallback。
- 固定 SDK 与 CLI/runtime 版本；升级前跑协议 golden tests、SSE 顺序测试和取消/超时测试。
- SDK 权限默认 deny-all，只暴露生成能力；评估 runtime 再分发许可证、包体、签名与公证。
- SDK 路线验证成熟后设为默认，internal 路线仅保留为用户明确选择的兼容模式。

### 阶段 3：增加正式 provider

- OpenAI、Anthropic 等使用官方 API key、企业凭据或其明确支持的 OAuth/BYOK 流程。
- 每个 provider 独立显示数据去向、计费主体、速率限制和模型能力。
- 不实现浏览器 Cookie 导入，不声明 ChatGPT/Claude 网页订阅可用，不提供账号池绕限额功能。

## 最终选择

最合理的组合是：

- 以 GitHub Copilot SDK 作为长期认证/runtime 基础；
- 以 Jer-y/copilot-proxy 作为严格协议语义与测试参考；
- 以 VibeProxy/Quotio 作为 macOS 产品和进程管理参考；
- 不内置第三方配置管理器或写入其数据库，客户端只通过公开配置入口手动连接；
- 以 AIUsage 作为 Keychain、安全默认值与可回滚更新参考；
- 当前 internal token exchange 仅承担可替换、可关闭、明确标注风险的实验兼容层。
