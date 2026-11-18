import AppKit
import CopilotBridgeCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: BridgeAppModel

  var body: some View {
    TabView {
      GeneralSettings(model: model)
        .tabItem { Label("服务", systemImage: "switch.2") }
      AuthenticationSettings(model: model)
        .tabItem { Label("GitHub", systemImage: "person.badge.key") }
      ModelQuotaSettings(model: model)
        .tabItem { Label("模型与额度", systemImage: "chart.bar.doc.horizontal") }
      LogSettings(model: model)
        .tabItem { Label("日志", systemImage: "text.alignleft") }
      AboutSettings()
        .tabItem { Label("关于", systemImage: "info.circle") }
    }
    .padding(18)
    .alert(
      "CopilotBridge",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.dismissError() } }
      )
    ) {
      Button("好", role: .cancel) { model.dismissError() }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }
}

private struct GeneralSettings: View {
  @ObservedObject var model: BridgeAppModel
  @State private var revealsAPIKey = false

  var body: some View {
    Form {
      Section("本地服务") {
        LabeledContent("状态") {
          HStack(spacing: 7) {
            Circle().fill(model.isRunning ? .green : .secondary).frame(width: 8, height: 8)
            Text(model.isRunning ? "运行中" : "已停止")
          }
        }
        TextField("端口", value: $model.port, format: .number)
          .disabled(model.isRunning || model.isBusy)
        LabeledContent("监听地址", value: "127.0.0.1（仅本机）")
        Button(model.isRunning ? "停止" : "启动") { model.toggleServer() }
          .buttonStyle(.borderedProminent)
          .disabled(model.isBusy || (!model.isRunning && !model.isCredentialStoreReady))
      }

      Section("启动") {
        Toggle("应用启动后自动开启代理", isOn: $model.autoStart)
        Toggle(
          "登录 Mac 时启动应用",
          isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
          ))
        if let message = model.launchAtLoginMessage {
          Text(message).font(.caption).foregroundStyle(.secondary)
        }
      }

      Section("本地鉴权") {
        HStack {
          Text(
            !model.isCredentialStoreReady
              ? "Keychain 未就绪"
              : (revealsAPIKey ? model.localAPIKey : String(repeating: "•", count: 24))
          )
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          Spacer()
          Button(revealsAPIKey ? "隐藏" : "显示") { revealsAPIKey.toggle() }
            .disabled(!model.isCredentialStoreReady)
          Button("复制") { BridgeAppModel.copy(model.localAPIKey) }
            .disabled(!model.isCredentialStoreReady)
          Button("轮换…") {
            Task { await model.regenerateLocalAPIKey() }
          }
          .disabled(model.isBusy)
        }
        Text("除健康检查、OPTIONS 和 HEAD 预热外，请求都必须使用 Bearer 或 X-API-Key。轮换会停止服务。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct AuthenticationSettings: View {
  @ObservedObject var model: BridgeAppModel
  @State private var manualToken = ""

  var body: some View {
    Form {
      Section("Copilot 权限") {
        LabeledContent("状态", value: model.credentialStatus)
        if let expiry = model.copilotTokenExpiry {
          LabeledContent(
            "短期 token 到期", value: expiry.formatted(date: .abbreviated, time: .standard))
        }

        if let authorization = model.deviceAuthorization {
          VStack(alignment: .leading, spacing: 10) {
            Text("浏览器已打开。输入下面的设备码：")
            Text(authorization.userCode)
              .font(.system(size: 26, weight: .semibold, design: .monospaced))
              .textSelection(.enabled)
            HStack {
              Button("复制设备码") { BridgeAppModel.copy(authorization.userCode) }
              Button("重新打开 GitHub") { NSWorkspace.shared.open(authorization.verificationURL) }
              Button("取消", role: .cancel) { model.cancelGitHubLogin() }
            }
          }
        } else {
          HStack {
            Button("登录 GitHub") { model.beginGitHubLogin() }
              .buttonStyle(.borderedProminent)
              .disabled(model.isBusy)
            if model.isGitHubConnected {
              Button("验证 Copilot") { Task { await model.verifyCopilot() } }
                .disabled(model.isBusy)
              Button("退出登录", role: .destructive) { Task { await model.signOut() } }
                .disabled(model.isBusy)
            }
          }
        }
      }

      Section("手动导入（高级）") {
        SecureField("GitHub OAuth token", text: $manualToken)
        Button("保存到 Keychain 并验证") {
          let token = manualToken
          manualToken = ""
          Task { await model.saveManualGitHubToken(token) }
        }
        .disabled(
          manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
      }

      Section("实验接口说明") {
        Text(
          "当前版本使用 Copilot Chat device flow 与未公开的 copilot_internal token exchange。它要求你自己的有效 Copilot 权限，可能随 GitHub 更新而失效；不要用于共享账号、转售、绕过配额或组织策略。"
        )
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct ModelQuotaSettings: View {
  @ObservedObject var model: BridgeAppModel

  var body: some View {
    Form {
      Section("账户概览") {
        HStack {
          LabeledContent("状态", value: model.accountOverviewStatus)
          Spacer()
          if model.isRefreshingAccountOverview {
            ProgressView().controlSize(.small)
          }
          Button("刷新") { model.refreshModelsAndQuota() }
            .disabled(
              !model.isGitHubConnected || model.isRefreshingAccountOverview || model.isBusy)
        }
        if let quota = model.copilotQuota {
          if let account = quota.accountName {
            LabeledContent("GitHub 账户", value: account)
          }
          if let plan = quota.planName ?? quota.sku {
            LabeledContent("Copilot 计划", value: plan)
          }
        }
        if !model.isGitHubConnected {
          Label("请先在“GitHub”页登录。", systemImage: "person.badge.key")
            .foregroundStyle(.secondary)
        }
      }

      Section("实验额度快照") {
        if let quota = model.copilotQuota {
          if quota.entries.isEmpty {
            Text("GitHub 已返回账户信息，但没有提供可展示的额度数值。")
              .foregroundStyle(.secondary)
          } else {
            ForEach(quota.entries) { entry in
              QuotaRow(entry: entry)
            }
          }
          if let resetAt = quota.resetAt {
            LabeledContent(
              "重置时间",
              value: resetAt.formatted(date: .abbreviated, time: .standard))
          }
          if !quota.hasExactAICreditData {
            Text("GitHub 没有返回明确的 AI Credits 数值；上面只显示原始请求额度或未注明单位的数值，不做换算。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let updatedAt = model.quotaUpdatedAt {
            LabeledContent(
              "额度读取时间",
              value: updatedAt.formatted(date: .abbreviated, time: .standard))
          }
          if let message = model.quotaMessage {
            Label("本次刷新失败，当前保留上次结果：\(message)", systemImage: "clock.arrow.circlepath")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else if let message = model.quotaMessage {
          Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        } else {
          Text(model.isGitHubConnected ? "等待刷新。" : "登录后显示当前账户额度。")
            .foregroundStyle(.secondary)
        }
        Link(
          "在 GitHub 查看官方用量",
          destination: URL(string: "https://github.com/settings/billing")!)
      }

      Section("可用模型（\(model.availableModels.count)）") {
        if let message = model.modelCatalogMessage, model.availableModels.isEmpty {
          Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        } else if model.availableModels.isEmpty {
          Text(model.isGitHubConnected ? "当前账户没有返回可选对话模型。" : "登录后显示当前账户的模型目录。")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.availableModels) { availableModel in
            AvailableModelRow(
              model: availableModel,
              showsLegacyMultiplier: showsLegacyMultiplier)
          }
          if let updatedAt = model.modelCatalogUpdatedAt {
            LabeledContent(
              "模型读取时间",
              value: updatedAt.formatted(date: .abbreviated, time: .standard))
          }
          if let message = model.modelCatalogMessage {
            Label("本次刷新失败，当前保留上次结果：\(message)", systemImage: "clock.arrow.circlepath")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Section {
        Text("模型和计费信息按刷新时 GitHub 返回的目录展示，不写死型号、倍率或额度。模型最大输入限制不是账户剩余额度；不同额度分类也不会相加。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear {
      guard model.modelCatalogUpdatedAt == nil || model.quotaUpdatedAt == nil else { return }
      model.refreshModelsAndQuota()
    }
  }

  private var showsLegacyMultiplier: Bool {
    model.copilotQuota?.entries.contains {
      $0.id.lowercased().replacingOccurrences(of: "-", with: "_") == "premium_interactions"
        && $0.unit == .requests
    } == true
  }
}

private struct QuotaRow: View {
  let entry: CopilotQuotaEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
        Spacer()
        Text(summary).foregroundStyle(.secondary)
      }
      if let percent = entry.percentRemaining, !entry.unlimited, entry.hasQuota != false {
        ProgressView(value: percent, total: 100)
          .accessibilityLabel("\(title)剩余百分比")
          .accessibilityValue("\(format(percent))%")
      }
      if entry.overagePermitted == true {
        Text("允许超额使用").font(.caption).foregroundStyle(.secondary)
      }
      if let resetAt = entry.resetAt {
        Text("该项重置：\(resetAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
  }

  private var title: String {
    switch entry.id.lowercased().replacingOccurrences(of: "-", with: "_") {
    case "ai_credits": return entry.unit == .aiCredits ? "AI Credits" : "AI Credits（单位异常）"
    case "premium_models":
      switch entry.unit {
      case .aiCredits: return "AI Credits"
      case .requests: return "Premium Requests"
      case .unspecified: return "premium_models（单位未知）"
      }
    case "premium_interactions":
      return entry.unit == .aiCredits ? "AI Credits（兼容桶）" : "Premium Requests（旧制）"
    case "chat": return "聊天"
    case "completions", "code_completions": return "代码补全"
    default: return entry.id
    }
  }

  private var summary: String {
    if entry.hasQuota == false { return "当前不可用" }
    if entry.unlimited { return "不限量" }
    let suffix: String
    switch entry.unit {
    case .aiCredits: suffix = " Credits"
    case .requests: suffix = " 次"
    case .unspecified: suffix = ""
    }
    if let remaining = entry.remaining, let entitlement = entry.entitlement {
      return "\(format(remaining)) / \(format(entitlement))\(suffix) 剩余"
    }
    if let used = entry.used, let entitlement = entry.entitlement {
      return "\(format(used)) / \(format(entitlement))\(suffix) 已用"
    }
    if let remaining = entry.remaining { return "剩余 \(format(remaining))\(suffix)" }
    if let used = entry.used { return "已用 \(format(used))\(suffix)" }
    if let percent = entry.percentRemaining { return "剩余 \(format(percent))%" }
    return "GitHub 未提供数值"
  }

  private func format(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
  }
}

private struct AvailableModelRow: View {
  let model: CopilotAvailableModel
  let showsLegacyMultiplier: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(model.displayName).fontWeight(.medium)
          if model.displayName != model.id {
            Text(model.id)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        Spacer()
        if let multiplier = model.billingMultiplier, showsLegacyMultiplier {
          Text("PR ×\(multiplier.formatted(.number.precision(.fractionLength(0...2))))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .help("GitHub 当前返回的旧 Premium Request 倍率")
        }
      }
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 64), spacing: 6)],
        alignment: .leading,
        spacing: 4
      ) {
        ForEach(badges, id: \.self) { badge in
          ModelBadge(badge)
        }
      }
      if !model.supportedEndpoints.isEmpty {
        Text("协议：\(model.supportedEndpoints.joined(separator: " · "))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  private var badges: [String] {
    var values: [String] = []
    if model.isPremium == true { values.append("Premium") }
    if model.isPreview == true { values.append("Preview") }
    if model.capabilities.contains(.vision) { values.append("视觉") }
    if model.capabilities.contains(.tools) { values.append("工具") }
    if model.capabilities.contains(.reasoning) { values.append("推理") }
    if let maximum = model.maximumPromptTokens {
      values.append("最大输入 \(compactTokenCount(maximum))")
    }
    if let maximum = model.maximumOutputTokens {
      values.append("输出 \(compactTokenCount(maximum))")
    }
    return values
  }

  private func compactTokenCount(_ value: Int) -> String {
    if value >= 1_000_000, value.isMultiple(of: 1_000_000) {
      return "\(value / 1_000_000)M"
    }
    if value >= 1_000, value.isMultiple(of: 1_000) {
      return "\(value / 1_000)K"
    }
    return value.formatted()
  }
}

private struct ModelBadge: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.caption2)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(.quaternary, in: Capsule())
  }
}

private struct LogSettings: View {
  @ObservedObject var model: BridgeAppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("记录路径、状态、耗时和脱敏运行摘要；不记录请求/响应体或凭据。").foregroundStyle(.secondary)
        Spacer()
        Button("清空") { model.clearLogs() }
      }
      ScrollView {
        Text(model.logs.isEmpty ? "暂无日志" : model.logs.joined(separator: "\n"))
          .font(.system(.caption, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .textSelection(.enabled)
          .padding(10)
      }
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
    .padding(12)
  }
}

private struct AboutSettings: View {
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .font(.system(size: 54)).foregroundStyle(.tint)
      Text("CopilotBridge").font(.title.bold())
      Text("\(BridgeVersion.current) · Apple Silicon · macOS 14+")
      Text("原生 SwiftUI 菜单栏应用，将你自己的 GitHub Copilot 权限桥接为 OpenAI 与 Anthropic 兼容的本地 API。")
        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
      Link("GitHub Copilot SDK", destination: URL(string: "https://github.com/github/copilot-sdk")!)
      Text("MIT License · 非 GitHub/OpenAI/Anthropic 官方产品")
        .font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}
