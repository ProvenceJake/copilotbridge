# 更新记录

## 1.0.0 — 2026-09-10

- 修复 Copilot Responses 在响应、内容项 ID 逐事件变化时被误判为 502 的问题，保留索引、终值、工具身份和终止事件校验。
- 支持无 status 的加密 reasoning 项；通过本桥的 opaque envelope 保留和回传推理状态，修复工具结果回传与后续对话错误。没有扩展到可见 reasoning summary。
- 修复上游 base URL 带尾斜杠时产生双斜杠路径的兼容问题。
- 缓存已解析的模型目录索引，减少缓存选路时重复解析 JSON；保持 5 分钟 TTL、合并并发请求和取消行为。
- 保留中途 system 消息、超长 metadata.user_id 规范化、按模型端点选路、模型与额度页面，以及现有生成图标。
- 统一应用“关于”、健康检查、Server header 与构建产物版本；增加版本一致性测试。
- 增加可选真实 Core 联网回归测试，覆盖长用户 ID、文本、工具结果、推理状态和多轮历史；测试仅使用合成内容，不执行模型返回的工具。

此版本仍通过实验性的 Copilot internal adapter 调用上游。macOS arm64 本机包采用 ad-hoc 签名；未进行 Developer ID 公证，不是可直接向其他 Mac 分发的公证版本。
