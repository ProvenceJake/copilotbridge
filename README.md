<p align="center">
  <img src="docs/assets/app-icon.png" width="120" height="120" alt="CopilotBridge app icon">
</p>
<h1 align="center">CopilotBridge</h1>
<p align="center"><strong>Your GitHub Copilot account, through a local API.</strong><br>A native macOS menu bar app for OpenAI- and Anthropic-compatible clients.</p>
<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.0-0f766e?style=flat-square" alt="Version 1.0.0">
  <img src="https://img.shields.io/badge/platform-Apple%20Silicon-334155?style=flat-square" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/macOS-14%2B-334155?style=flat-square" alt="macOS 14 or later">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2563eb?style=flat-square" alt="MIT License"></a>
</p>
<p align="center"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>
<p align="center">
  <a href="#build-from-source"><strong>Build from source</strong></a> ·
  <a href="#connect-a-client">Client setup</a> ·
  <a href="CHANGELOG.md">Changelog (Chinese)</a> ·
  <a href="https://github.com/ProvenceJake/copilotbridge/issues">Report an issue</a>
</p>

---

CopilotBridge runs a local HTTP server for clients that support **OpenAI Chat Completions**, **OpenAI Responses**, or **Anthropic Messages**. Sign in with your own GitHub Copilot account and choose from the models available to that account.

> [!IMPORTANT]
> CopilotBridge uses an experimental adapter for GitHub Copilot. It depends on internal GitHub interfaces that can change. Model access and quotas follow your account and organization policies. Use an account you are authorized to access.

## Features

| Local API | Menu bar controls | Credential storage |
| --- | --- | --- |
| Chat Completions, Responses, Messages, and model discovery. Streaming, image inputs, and tool calls depend on the model and protocol. | Sign in, start or stop the server, and see the available models and reported quota. | The server listens on loopback. Model requests use a generated local key. The key and long-lived GitHub token are stored in macOS Keychain. |

## Connect a client

1. Launch CopilotBridge and open its settings from the macOS menu bar.
2. Select **登录 GitHub** (Sign in to GitHub) and finish authorization in your browser.
3. Start the local server. Copy the local API key and select a model from the app's model list.
4. Set the base URL and API key in your client.

| Client protocol | Default base URL | Main routes |
| --- | --- | --- |
| OpenAI compatible | `http://127.0.0.1:4141/v1` | Chat Completions, Responses, model discovery |
| Anthropic compatible | `http://127.0.0.1:4141/anthropic` | Messages, estimated token counts, model discovery |
| Azure OpenAI compatible | `http://127.0.0.1:4141` | Deployment-based Chat Completions and Responses |

Check the local server with `curl http://127.0.0.1:4141/healthz`. See the [client setup guide (Chinese)](docs/CLIENT_SETUP.md) for Codex, Claude Code, Claude Desktop third-party inference, and Azure OpenAI-compatible clients.

## Build from source

Use an **Apple Silicon Mac** with **Swift 6.1 or later**. The app targets **macOS 14 or later**. The build and packaging tools require Xcode.

```bash
git clone https://github.com/ProvenceJake/copilotbridge.git
cd copilotbridge
swift test
swift run CopilotBridge
```

Run `./scripts/build-app.sh` to package the app for local testing. Developer ID signing, notarization, and DMG packaging are covered in the [build guide (Chinese)](docs/BUILD.md).

## Compatibility

Available models, image support, context limits, and request limits depend on your GitHub Copilot account. CopilotBridge can forward Anthropic Messages to compatible models directly or translate them through Chat Completions or Responses. Translated routes have protocol-specific limitations. See the [compatibility guide (Chinese)](docs/COMPATIBILITY.md) for supported fields and routes.

## License

CopilotBridge is released under the [MIT License](LICENSE). See the [third-party notices](THIRD_PARTY_NOTICES.md) for dependencies and acknowledgments.
