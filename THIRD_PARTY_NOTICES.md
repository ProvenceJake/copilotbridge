# Third-party notices

CopilotBridge includes the following Apple Swift packages under the Apache License 2.0. Their full license texts, plus SwiftNIO's NOTICE, are bundled in `CopilotBridge.app/Contents/Resources/Licenses/`:

- SwiftNIO 2.102.0: <https://github.com/apple/swift-nio>
- Swift Atomics 1.3.1: <https://github.com/apple/swift-atomics>
- Swift Collections 1.6.0: <https://github.com/apple/swift-collections>
- Swift System 1.8.1: <https://github.com/apple/swift-system>

The release app may also embed compatibility runtime libraries selected by Apple's `swift-stdlib-tool` for the configured macOS deployment target. Swift runtime code is available under the Apache License 2.0 with Runtime Library Exception: <https://github.com/swiftlang/swift/blob/main/LICENSE.txt>.

The optional drag-to-install disk image uses the built-in arrow background from [dmgbuild 1.6.7](https://github.com/dmgbuild/dmgbuild), under the MIT License. Its full license is included at the disk image root as `.Installer-LICENSE.txt` (source: `Resources/DMG-LICENSE.txt`). The Python build tools are not bundled in the application or required at runtime.

The Anthropic/OpenAI translation design was informed by `copilot-llm-proxy`, available at <https://github.com/justfordev123/copilot-llm-proxy> under the MIT License:

> Copyright (c) 2026 @heartAndRain

Additional architecture and compatibility research referenced these open-source projects without copying their source into this repository:

- GitHub Copilot SDK: <https://github.com/github/copilot-sdk> (MIT)
- Jer-y/copilot-proxy: <https://github.com/Jer-y/copilot-proxy> (MIT)
- whtsky/copilot2api: <https://github.com/whtsky/copilot2api> (MIT)
- messense/copilot-api-proxy: <https://github.com/messense/copilot-api-proxy> (MIT)
- VibeProxy: <https://github.com/automazeio/vibeproxy> (MIT)
- Quotio: <https://github.com/nguyenphutrong/quotio> (MIT)
- AIUsage: <https://github.com/sylearn/AIUsage> (Apache-2.0)
- Microsoft Visual Studio Code Copilot quota adapter: <https://github.com/microsoft/vscode> (MIT)
- OpenCode GitHub Copilot model schema: <https://github.com/anomalyco/opencode> (MIT)

GitHub, GitHub Copilot, OpenAI, ChatGPT, Anthropic and Claude are trademarks of their respective owners. This project is not affiliated with or endorsed by GitHub, OpenAI or Anthropic.
