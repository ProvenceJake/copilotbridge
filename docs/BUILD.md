# 构建、打包与分发

从项目根目录执行以下命令。

产物最低运行要求是 Apple Silicon Mac 与 macOS 14。构建要求是 Swift 6.1+；例如 Xcode 16.3 自带 Swift 6.1，而按 [Apple 的版本表](https://developer.apple.com/xcode/system-requirements/)该版 Xcode 的构建机系统要求是 macOS 15.2+。当前已用 macOS 15.7.9、Swift 6.2 / Xcode 26.3 验证。

开发运行：

```bash
swift run CopilotBridge
```

测试：

```bash
swift test
```

生成 arm64 `.app` 与 zip（默认 ad-hoc 签名）：

```bash
scripts/build-app.sh
```

脚本总会生成 `dist/CopilotBridge-arm64.zip`，zip 内包含项目与依赖许可证。构建过程会使用 Apple 的部署扫描器嵌入所需 Swift 兼容运行库，裁成 arm64，并移除指向构建机 Xcode 的绝对运行路径。普通本地目录也会生成 `dist/CopilotBridge.app`；某些 iCloud/File Provider 同步目录可能给 `.app` 附加破坏签名的 FinderInfo，此时脚本会恢复原有 app（如有）并保留已在系统临时目录解包复验的新 zip。也可直接构建到非同步目录：

```bash
mkdir -p "$HOME/Applications"
OUTPUT_DIR="$HOME/Applications" scripts/build-app.sh
open "$HOME/Applications/CopilotBridge.app"
```

### DMG 拖拽安装

打开 `dist/CopilotBridge-1.0.0-arm64.dmg`，将左侧 CopilotBridge 拖到右侧 `Applications`（应用程序）文件夹。复制完成后推出安装盘，再从“应用程序”启动。如果旧版正在运行，先从菜单栏退出旧版，避免同时启动两个代理实例；复制应用不会删除钥匙串中的登录信息或应用设置。

DMG 打包只需 macOS、Python 3.10+ 和已有的签名 `.app`，不会重新编译、重新签名或安装应用：

```bash
python3 -m venv /tmp/copilotbridge-dmg-tools
/tmp/copilotbridge-dmg-tools/bin/python -m pip install -r scripts/dmg-requirements.txt
DMGBUILD=/tmp/copilotbridge-dmg-tools/bin/dmgbuild \
  scripts/build-dmg.sh "$HOME/Applications/CopilotBridge.app"
```

脚本生成带版本号的压缩 DMG 和 `.sha256`，配置左右图标、方向箭头及 `/Applications` 快捷入口；自动校验镜像、只读挂载、签名，以及复制到临时目录后的完整性，不覆盖实际安装的应用。版本号取自传入 app，并要求与 `Resources/Info.plist` 一致；已有同名 DMG 时拒绝覆盖，可用 `OUTPUT_DIR` 选择新目录。依赖仅用于打包，安装和运行不需要 Python。

### 对外分发签名

ad-hoc 产物只用于本机开发测试；它不会通过另一台 Mac 的 Gatekeeper 分发校验。DMG 不会改变这一限制。要对外分发，请使用 Developer ID 签名并完成公证。

Developer ID 签名（建议直接输出到非同步目录）：

```bash
OUTPUT_DIR="$HOME/Applications" \
  SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
  scripts/build-app.sh
```

公证凭据先保存到系统 Keychain，再提交非同步目录中的 app。成功后脚本会重新生成并复验已 staple 的 `CopilotBridge-arm64.zip`：

```bash
xcrun notarytool store-credentials CopilotBridgeNotary
NOTARY_KEYCHAIN_PROFILE=CopilotBridgeNotary \
  scripts/notarize.sh "$HOME/Applications/CopilotBridge.app"
```

需要 DMG 时，在上述签名、公证和 staple 完成后，再将同一个 app 交给 `scripts/build-dmg.sh`；打包过程保留其签名和公证票据。
