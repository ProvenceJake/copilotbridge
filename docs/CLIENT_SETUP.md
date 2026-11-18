# 客户端手动配置

CopilotBridge 提供必须分开的 OpenAI 与 Anthropic base URL，并额外接受 Azure OpenAI-compatible 路径。客户端会自行追加协议路径，所以不要把完整的 `/v1/messages` 或 `/v1/responses` 填进 base URL。

| 客户端协议 | Base URL | 最终主要路径 |
| --- | --- | --- |
| OpenAI | `http://127.0.0.1:4141/v1` | `/v1/chat/completions`、`/v1/responses`、`/v1/models` |
| Anthropic | `http://127.0.0.1:4141/anthropic` | `/anthropic/v1/messages`、`/anthropic/v1/messages/count_tokens`、`/anthropic/v1/models` |
| Azure OpenAI-compatible | `http://127.0.0.1:4141` | `/openai/deployments/{deployment}/chat/completions` |

这些入口使用应用内同一个本地 API key。key 保存在 macOS Keychain；复制后只放进目标客户端自己的凭据设置，不要提交到仓库。CopilotBridge 不读取或改写目标客户端的配置、凭据文件或数据库。

OpenAI 路由也接受 `/chat/completions`、`/responses`、`/models` 及尾斜杠形式；鉴权头可用 `Authorization: Bearer`、`x-api-key`、Azure 风格 `api-key` 或 `x-goog-api-key`。这用于减少 SDK 配置差异，不会改变唯一上游仍是 GitHub Copilot 的事实。

## 手动配置

### Claude Desktop on 3P

当前 Claude Desktop 提供正式的第三方推理入口：

1. 打开 Help → Troubleshooting → Enable Developer Mode。
2. 应用重启后打开 Developer → Configure Third-Party Inference。
3. Inference provider 选择 Gateway。
4. Gateway base URL 填 `http://127.0.0.1:4141/anthropic`。
5. Credential kind 选择 Static API key，填入本地 key；auth scheme 选择 Bearer。
6. 保存并重启 Claude Desktop。

这条能力属于 Claude Desktop on 3P。普通 claude.ai 云端会话、Web 和 Remote Control 不走本机 gateway。Anthropic 官方要求第三方推理使用 Claude 模型；请选择 Copilot 账号开放的 Claude 模型。

CopilotBridge 会读取模型目录的 `supported_endpoints` 决定上游协议：原生 Messages 直接转发，Chat 模型做 Chat 转译，Responses-only 模型做 Responses 转译。因此目录里仅支持 `/responses` 的模型也可从这个 Messages gateway 调用；文本和 function call 参数会按上游事件增量转成 Anthropic SSE，不再等待整个响应。

### Claude Code

临时启动：

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:4141/anthropic
export ANTHROPIC_AUTH_TOKEN='从应用复制的本地 key'
export ANTHROPIC_MODEL=gpt-4o
export ANTHROPIC_DEFAULT_HAIKU_MODEL=gpt-4o
export ANTHROPIC_DEFAULT_SONNET_MODEL=gpt-4o
export ANTHROPIC_DEFAULT_OPUS_MODEL=gpt-4o
export ANTHROPIC_DEFAULT_FABLE_MODEL=gpt-4o
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
claude
```

持久化时，把同样的变量手动合并进用户级 `~/.claude/settings.json` 的 `env` 对象。示例把主模型和四个角色都设为 `gpt-4o`；启用前应以应用显示的当前可用模型为准。`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` 只负责发现目录；官方客户端只把 ID 以 `claude` 或 `anthropic` 开头的发现结果加入选择器，所以 GPT ID 必须使用这些显式变量。若新版 Claude Code 发送实验字段而上游拒绝，可额外设置 `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`；这会关闭部分实验能力。

### Codex CLI / ChatGPT Desktop 本地 Codex

把下面内容手动合并到用户级 `~/.codex/config.toml`，不要放进项目级 `.codex/config.toml`：

```toml
model = "从 /v1/models 选择"
model_provider = "copilot_bridge"

[model_providers.copilot_bridge]
name = "CopilotBridge"
base_url = "http://127.0.0.1:4141/v1"
env_key = "COPILOT_BRIDGE_API_KEY"
wire_api = "responses"
```

把凭据手动写到用户级 `~/.codex/.env`，然后完全重启桌面端：

```dotenv
COPILOT_BRIDGE_API_KEY=从应用复制的本地key
```

这会配置 Codex CLI/IDE 与 ChatGPT Desktop 的本地 Codex 工作流。普通 ChatGPT Chat、ChatGPT Web 和 Codex Cloud 没有官方本机自定义 model provider 接口。

### Azure OpenAI-compatible SDK

以 Python SDK 为例，deployment 直接使用应用模型列表中的 ID；请求体可以不再重复传 model：

```python
from openai import AzureOpenAI

client = AzureOpenAI(
    azure_endpoint="http://127.0.0.1:4141",
    azure_deployment="从 /v1/models 选择的模型 ID",
    api_key="从应用复制的本地 key",
    api_version="2024-10-21",
)
```

本应用兼容 Azure 的 deployment Chat 路径和 `api-key` 头；`api-version` 只作为客户端兼容参数接受，不会改变 Copilot 上游版本。本应用不实现 Azure 的资源管理、部署管理、音频或图片 API。

### Gemini / Google 客户端边界

本应用没有实现原生 Gemini `models/{model}:generateContent` 或 `:streamGenerateContent`。若客户端支持 Google 官方的 [OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai) 模式，可改用本应用的 OpenAI base URL；可选模型仍必须来自当前 Copilot 账号目录。原生 `google-genai` 请求格式不能直接接入。

## 快速自检

```bash
export COPILOT_BRIDGE_API_KEY='从应用复制的本地 key'
curl http://127.0.0.1:4141/healthz

curl http://127.0.0.1:4141/anthropic/v1/models \
  -H "Authorization: Bearer $COPILOT_BRIDGE_API_KEY"

curl http://127.0.0.1:4141/v1/models \
  -H "Authorization: Bearer $COPILOT_BRIDGE_API_KEY"
```

路径排错：Claude 最终请求应是 `/anthropic/v1/messages`，Codex 最终请求应是 `/v1/responses`。出现 `/v1/v1/...` 或把请求发到根 `/v1/messages`，说明 base URL 填错。

若健康检查成功而模型列表返回 401，请重新复制本地 key；模型列表返回 GitHub/Copilot 错误时，到应用的 GitHub 页重新验证 Copilot 权限。

## 参考

- [Claude Code 连接 LLM gateway 与模型发现](https://code.claude.com/docs/en/llm-gateway)
- [Claude Desktop on 3P gateway](https://claude.com/docs/third-party/claude-desktop/gateway)
- [Codex 自定义 provider](https://developers.openai.com/codex/config-reference)
- [Azure OpenAI REST 路径与鉴权](https://learn.microsoft.com/en-us/azure/foundry/openai/reference)
- [Google Gemini OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai)
