# 1.0.0 验证记录

验证日期：2026-09-10。范围：当前 Apple Silicon Mac、当前 Copilot 账号、当前模型目录。

## 已完成的针对性验证

- 全量自动测试：214 项，211 项通过、3 项可选联网测试默认跳过，零失败；严格并发检查、warnings-as-errors、Swift 格式检查和 shell/plist 语法检查通过。
- 先复现旧版 Responses `item_id` / `response.id` 误判，再验证稳定索引关联；并行工具参数不会混合，改写 call_id / name / 参数仍失败。
- 真实工具结果回传复现 `reasoning.encrypted_content` 拒绝后，补齐无 status 的加密 reasoning、不同快照密文及下一轮恢复。
- `gpt-5.6-sol`：新编译 Core 经已登录本地代理的 raw Responses 数据通道完成 9 个真实请求，涵盖 3 次文本、150 字符 user_id、中途 system、强制工具、工具结果、历史回传、算术推理及推理状态回传。每次验证 HTTP 200、唯一 message_start、无流内 error 和 message_stop；工具 ID/参数、stop reason 与合成答案另做断言。工具结果及算术响应均实际出现了 redacted_thinking，下一轮回传成功。
- `gpt-5-mini`：通过 Chat Completions 转译通道完成同样的 9 个真实请求，全部正常结束；该轮没有加密推理 block，不据此宣称已验证 Chat 路径的 opaque thinking。
- 模型目录性能：18 个合成模型，每项约 2 KiB 元数据，1,000 次缓存端点查询，Debug 构建基线约 130 ms，优化后约 1.9 ms。该结果衡量本地重复解析开销，不代表上游推理吞吐或端到端速度提升。
- URL 尾斜杠：base 根路径与 `/v1` 前缀、有无尾斜杠，均覆盖 data / stream 请求。
- 发布包：`dist/CopilotBridge-1.0.0-arm64.zip`，Info.plist 版本 1.0.0、arm64-only；app 与 zip 解包后均通过 `codesign --verify --deep --strict`。zip 的 SHA-256 为 `101e768880a2a330c0a110e960ce7e0674c191be327f0bfde9b0a2f2bac98b3a`，旁置 `.sha256` 文件可校验。

## 拖拽安装 DMG

- 产物：`dist/CopilotBridge-1.0.0-arm64.dmg`，6,268,693 字节；SHA-256：`fbb25c0a4030be5c51b8dde8d1a658baa2deec7f5f4325ab6236f613fe50a8f6`，旁置 `.sha256` 文件可校验。
- 使用 APFS / UDZO 压缩镜像，适用于应用要求的 Apple Silicon、macOS 14+。HFS+ 试包会给许可证资源生成 FinderInfo，导致 strict 签名校验失败；该试包未作为发布产物。
- Finder 实际打开后自动展示双图标安装窗口，左侧应用、右侧指向 `/Applications` 的快捷入口，中间是方向箭头，沿用现有生图图标。
- `hdiutil verify`、只读挂载、镜像内 `codesign --verify --deep --strict`、复制至临时安装目录后的相同签名校验及 `diff -qr` 均通过。DMG 中的 app 与已验证的 1.0.0 app 文件内容完全一致，没有重新编译或重新签名。
- 未覆盖实际安装目录、启动另一个代理或修改凭据。此轮只验证安装包，不重复消耗额度执行推理测试；现有 ad-hoc / 未公证边界仍适用。
- 可重复打包命令见[构建指南中的 DMG 拖拽安装](BUILD.md#dmg-拖拽安装)；脚本要求匹配的 app 版本，并拒绝覆盖已有 DMG。

## 可重复执行

```sh
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
xcrun swift-format lint --strict --recursive Sources Tests
bash -n scripts/build-app.sh scripts/build-dmg.sh scripts/notarize.sh
```

可选真实验证：先在非共享终端以安全方式设置 `COPILOT_BRIDGE_LOCAL_TEST_KEY`（本地代理 key，不是 GitHub token），再执行：

```sh
COPILOT_BRIDGE_RUN_LOCAL_LIVE_TESTS=1 \
COPILOT_BRIDGE_LOCAL_TEST_URL=http://127.0.0.1:4141 \
COPILOT_BRIDGE_LOCAL_TEST_MODEL=gpt-5.6-sol \
swift test --filter LiveLocalProxyTests
```

此测试启动临时 loopback 代理来执行当前 Core，通过运行中的应用鉴权，不读取 GitHub Keychain 凭据；结束或抛错都会停止临时服务。真实请求会使用账号额度。普通 `swift test` 默认跳过联网测试。

## 边界

- 当前账号目录有 18 个可选模型，没有原生 Claude 模型，因此不把 mock 的原生 Messages 验证宣称为真实 Claude 上游验证。
- 不承诺全部模型、图片、可见 reasoning summary、所有第三方客户端及所有协议扩展均已实测。现有协议边界见 [COMPATIBILITY.md](COMPATIBILITY.md)。
- 本机签名通过不等于 Gatekeeper 公证通过；重新签名后系统可能再次要求钥匙串授权。没有修改客户端配置、登录项或鉴权策略。
