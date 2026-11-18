import AppKit
import CopilotBridgeCore
import Foundation
import ServiceManagement

@MainActor
final class BridgeAppModel: ObservableObject {
  private enum AccountLoadResult: Sendable {
    case models([CopilotAvailableModel])
    case quota(CopilotQuotaSnapshot)
    case modelsFailed(String)
    case quotaFailed(String)
  }

  private enum GitHubLoginPhase {
    case requestingCode
    case pollingAuthorization
    case committing
    case verifying

    var failureStatus: String {
      switch self {
      case .requestingCode: "获取 GitHub 登录码失败"
      case .pollingAuthorization: "GitHub 授权失败"
      case .committing: "GitHub 凭据保存失败"
      case .verifying: "Copilot 验证失败"
      }
    }

    var failureEvent: BridgeEvent {
      switch self {
      case .requestingCode: .error("GitHub 登录码请求失败。")
      case .pollingAuthorization: .error("GitHub 设备授权失败。")
      case .committing: .error("GitHub 凭据保存失败。")
      case .verifying: .warning("Copilot 权限验证失败。")
      }
    }
  }

  @Published var port: Int {
    didSet { UserDefaults.standard.set(port, forKey: "server.port") }
  }
  @Published private(set) var isRunning = false
  @Published private(set) var isBusy = true
  @Published private(set) var isCredentialStoreReady = false
  @Published private(set) var isGitHubConnected = false
  @Published private(set) var credentialStatus = "正在后台读取 Keychain…"
  @Published private(set) var copilotTokenExpiry: Date?
  @Published private(set) var deviceAuthorization: DeviceAuthorization?
  @Published private(set) var errorMessage: String?
  @Published private(set) var logs: [String] = []
  @Published private(set) var localAPIKey = ""
  @Published private(set) var launchAtLogin = false
  @Published private(set) var launchAtLoginMessage: String?
  @Published private(set) var availableModels: [CopilotAvailableModel] = []
  @Published private(set) var copilotQuota: CopilotQuotaSnapshot?
  @Published private(set) var modelCatalogMessage: String?
  @Published private(set) var quotaMessage: String?
  @Published private(set) var accountOverviewStatus = "登录 GitHub 后可读取"
  @Published private(set) var modelCatalogUpdatedAt: Date?
  @Published private(set) var quotaUpdatedAt: Date?
  @Published private(set) var isRefreshingAccountOverview = false
  @Published var autoStart: Bool {
    didSet { UserDefaults.standard.set(autoStart, forKey: "server.autoStart") }
  }

  private var server: ProxyServer?
  private var serviceGeneration = UUID()
  private var activityGenerations: Set<UUID> = []
  private var activityWaiters: [CheckedContinuation<Void, Never>] = []
  private var isBootstrapping = true
  private var bootstrapTask: Task<Void, Never>?
  private var loginTask: Task<Void, Never>?
  private var loginGeneration: UUID?
  private var loginActivityGeneration: UUID?
  private var loginPhase: GitHubLoginPhase?
  private var accountRefreshTask: Task<Void, Never>?
  private var accountRefreshGeneration = UUID()
  private var terminationRequested = false
  private var terminationTask: Task<Void, Never>?
  private var credentialGeneration = UUID()
  private let dependencies: BridgeAppDependencies
  private let tokenManager: CopilotTokenManager
  private let accountDataSource: CopilotAccountDataSource

  init(
    dependencies: BridgeAppDependencies = .live,
    tokenManager: CopilotTokenManager = CopilotTokenManager(),
    accountDataSource: CopilotAccountDataSource? = nil,
    initialPort: Int? = nil,
    initialAutoStart: Bool? = nil
  ) {
    self.dependencies = dependencies
    self.tokenManager = tokenManager
    self.accountDataSource = accountDataSource ?? .live(tokenManager: tokenManager)
    let savedPort = initialPort ?? UserDefaults.standard.integer(forKey: "server.port")
    port = savedPort == 0 ? 4_141 : savedPort
    autoStart = initialAutoStart ?? UserDefaults.standard.bool(forKey: "server.autoStart")

    refreshLaunchAtLoginStatus()
    bootstrapTask = Task { [weak self] in
      await self?.bootstrapCredentials()
    }
  }

  var baseURL: String { "http://127.0.0.1:\(port)" }
  var openAIBaseURL: String { "\(baseURL)/v1" }
  var anthropicBaseURL: String { "\(baseURL)/anthropic" }
  var accountOverviewUpdatedAt: Date? {
    [modelCatalogUpdatedAt, quotaUpdatedAt].compactMap { $0 }.max()
  }

  func startServer() async {
    guard !terminationRequested, !isRunning, server == nil, !isBusy else { return }
    guard isCredentialStoreReady, !localAPIKey.isEmpty else {
      errorMessage = "Keychain 尚未就绪；不会使用未持久化的临时 key 启动代理。"
      return
    }
    let activity = beginActivity()
    defer { finishActivity(activity) }
    await startServerOperation()
  }

  func stopServer() async {
    guard !terminationRequested, !isBusy, isRunning || server != nil else { return }
    let activity = beginActivity()
    defer { finishActivity(activity) }
    await stopServerOperation()
  }

  /// Finishes credential persistence before allowing AppKit to terminate the process.
  /// Device-code requests, authorization polling, and post-commit verification are
  /// safe to cancel. Only a synchronous Keychain transaction already in flight must
  /// be allowed to finish.
  func prepareForTermination() async {
    if let terminationTask {
      await terminationTask.value
      return
    }

    terminationRequested = true
    cancelAccountRefresh(clearData: false)
    let terminationActivity = beginActivity()
    let pendingBootstrap = bootstrapTask
    let pendingLogin = loginTask
    if let loginPhase, loginPhase != .committing {
      cancelGitHubLogin()
    }

    let task = Task { @MainActor [weak self] in
      await pendingBootstrap?.value
      await pendingLogin?.value
      guard let self else { return }
      await self.waitForOtherActivities(except: terminationActivity)
      await self.stopServerOperation()
      self.finishActivity(terminationActivity)
    }
    terminationTask = task
    await task.value
  }

  func toggleServer() {
    Task {
      if isRunning { await stopServer() } else { await startServer() }
    }
  }

  func beginGitHubLogin() {
    guard !terminationRequested, loginTask == nil, !isBusy else { return }
    errorMessage = nil
    deviceAuthorization = nil
    let activity = beginActivity()
    loginActivityGeneration = activity
    credentialStatus = "正在申请设备登录码…"
    let auth = dependencies.makeGitHubDeviceAuth()
    let generation = UUID()
    loginGeneration = generation
    loginPhase = .requestingCode
    loginTask = Task { [weak self] in
      guard let self else { return }
      do {
        let authorization = try await auth.requestCode()
        try Task.checkCancellation()
        guard self.loginGeneration == generation else { return }
        self.loginPhase = .pollingAuthorization
        self.deviceAuthorization = authorization
        self.credentialStatus = "等待你在 GitHub 授权"
        self.dependencies.presentDeviceAuthorization(authorization)
        let token = try await auth.pollForToken(authorization)
        try Task.checkCancellation()
        guard self.loginGeneration == generation else { return }
        // Keychain writes are synchronous Security.framework transactions and cannot be
        // cancelled once dispatched. Keep this login busy and make the commit phase
        // non-cancellable so a stale write cannot race a replacement login.
        self.loginPhase = .committing
        self.deviceAuthorization = nil
        self.credentialStatus = "GitHub 已授权，正在安全保存…"
        try await self.dependencies.writeGitHubToken(token)
        self.isGitHubConnected = true
        self.clearAccountOverview(status: "等待读取新账号的模型与额度")
        self.loginPhase = .verifying
        if self.terminationRequested {
          // Termination that began during the commit only waits for persistence.
          // Verification is network-only and can be deferred until the next launch.
          self.credentialStatus = "已保存 GitHub 凭据，尚未验证"
        } else {
          self.credentialStatus = "GitHub 已授权，正在验证 Copilot…"
          await self.activateChangedGitHubCredential()
        }
      } catch is CancellationError {
        if self.loginGeneration == generation {
          self.credentialStatus = self.isGitHubConnected ? "已保存 GitHub 凭据" : "未登录"
        }
      } catch {
        if self.loginGeneration == generation {
          let phase = self.loginPhase ?? .requestingCode
          self.errorMessage = Self.githubLoginErrorMessage(for: error)
          self.credentialStatus = phase.failureStatus
          self.record(phase.failureEvent)
        }
      }
      if self.loginGeneration == generation {
        self.deviceAuthorization = nil
        self.finishActivity(activity)
        self.loginTask = nil
        self.loginGeneration = nil
        self.loginActivityGeneration = nil
        self.loginPhase = nil
      }
    }
  }

  func cancelGitHubLogin() {
    guard loginPhase != .committing else {
      credentialStatus = "GitHub 已授权，正在安全保存；此阶段不能取消。"
      return
    }
    if loginPhase == .verifying {
      // Fence off a verification result even if its transport ignores cancellation.
      credentialGeneration = UUID()
    }
    loginTask?.cancel()
    loginTask = nil
    loginGeneration = nil
    deviceAuthorization = nil
    if let activity = loginActivityGeneration { finishActivity(activity) }
    loginActivityGeneration = nil
    loginPhase = nil
    credentialStatus = isGitHubConnected ? "已保存 GitHub 凭据" : "未登录"
  }

  private static func githubLoginErrorMessage(for error: any Error) -> String {
    if let urlError = error as? URLError, urlError.code == .secureConnectionFailed {
      return "与 GitHub 建立 TLS 安全连接失败。请检查系统代理/VPN 的 TLS 转发状态与证书信任；应用不会跳过证书校验。"
    }
    return error.localizedDescription
  }

  func saveManualGitHubToken(_ token: String) async {
    guard !terminationRequested, loginTask == nil, !isBusy else { return }
    let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      errorMessage = "GitHub OAuth token 不能为空。"
      return
    }
    let activity = beginActivity()
    defer { finishActivity(activity) }
    do {
      try await dependencies.writeGitHubToken(value)
      isGitHubConnected = true
      credentialStatus = "已保存 GitHub 凭据，正在验证…"
      await activateChangedGitHubCredential()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func verifyCopilot() async {
    guard !terminationRequested, loginTask == nil, !isBusy else { return }
    let activity = beginActivity()
    defer { finishActivity(activity) }
    let generation = credentialGeneration
    await verifyCopilotOperation(generation: generation)
  }

  func refreshModelsAndQuota() {
    startAccountRefresh(allowDuringCredentialActivity: false, forceQuotaRefresh: true)
  }

  private func startAccountRefresh(
    allowDuringCredentialActivity: Bool,
    forceQuotaRefresh: Bool
  ) {
    guard !terminationRequested, accountRefreshTask == nil else { return }
    if !allowDuringCredentialActivity {
      guard !isBusy, loginTask == nil else { return }
    }
    guard isGitHubConnected else {
      accountOverviewStatus = "登录 GitHub 后可读取"
      return
    }

    let generation = UUID()
    accountRefreshGeneration = generation
    isRefreshingAccountOverview = true
    accountOverviewStatus = "正在读取模型与额度…"
    modelCatalogMessage = nil
    quotaMessage = nil
    let dataSource = accountDataSource
    accountRefreshTask = Task { @MainActor [weak self] in
      let results = await withTaskGroup(of: AccountLoadResult.self) { group in
        group.addTask {
          do {
            return .models(try await dataSource.fetchModels())
          } catch {
            return .modelsFailed(error.localizedDescription)
          }
        }
        group.addTask {
          do {
            return .quota(try await dataSource.fetchQuota(forceQuotaRefresh))
          } catch {
            return .quotaFailed(error.localizedDescription)
          }
        }
        var values: [AccountLoadResult] = []
        for await result in group { values.append(result) }
        return values
      }

      guard let self, !Task.isCancelled, self.accountRefreshGeneration == generation else {
        return
      }
      var loadedModels = false
      var loadedQuota = false
      for result in results {
        switch result {
        case .models(let models):
          self.availableModels = models
          self.modelCatalogMessage = nil
          self.modelCatalogUpdatedAt = .now
          loadedModels = true
        case .quota(let quota):
          self.copilotQuota = quota
          self.quotaMessage = nil
          self.quotaUpdatedAt = .now
          loadedQuota = true
        case .modelsFailed(let message):
          self.modelCatalogMessage = message
        case .quotaFailed(let message):
          self.quotaMessage = message
        }
      }
      switch (loadedModels, loadedQuota) {
      case (true, true): self.accountOverviewStatus = "已更新"
      case (true, false), (false, true): self.accountOverviewStatus = "部分信息不可用"
      case (false, false): self.accountOverviewStatus = "读取失败"
      }
      self.isRefreshingAccountOverview = false
      self.accountRefreshTask = nil
      if loadedModels {
        self.record(.info("已刷新 Copilot 模型目录（\(self.availableModels.count) 个可选模型）。"))
      }
      if !loadedQuota {
        self.record(.warning("GitHub 未返回可展示的 Copilot 额度。"))
      }
    }
  }

  func signOut() async {
    guard !terminationRequested, loginTask == nil, !isBusy else { return }
    let activity = beginActivity()
    defer { finishActivity(activity) }
    credentialGeneration = UUID()
    clearAccountOverview(status: "正在退出…")
    await stopServerOperation()
    await tokenManager.invalidate()
    do {
      try await dependencies.deleteGitHubToken()
      isGitHubConnected = false
      copilotTokenExpiry = nil
      credentialStatus = "未登录"
      clearAccountOverview(status: "登录 GitHub 后可读取")
      record(.info("已从 Keychain 删除 GitHub 凭据。"))
    } catch {
      accountOverviewStatus = "退出失败，可重新刷新"
      errorMessage = error.localizedDescription
    }
  }

  func regenerateLocalAPIKey() async {
    guard !terminationRequested, loginTask == nil, !isBusy else { return }
    let activity = beginActivity()
    defer { finishActivity(activity) }
    await stopServerOperation()
    let key = KeychainStore.generateLocalAPIKey()
    do {
      try await dependencies.writeLocalAPIKey(key)
      localAPIKey = key
      isCredentialStoreReady = true
      record(.info("已轮换本地 API key；旧 key 立即失效。"))
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      refreshLaunchAtLoginStatus()
    } catch {
      launchAtLoginMessage = "登录项更新失败：\(error.localizedDescription)。请先从 .app 启动，或在系统设置中允许。"
      refreshLaunchAtLoginStatus(preserveMessage: true)
    }
  }

  func dismissError() { errorMessage = nil }
  func clearLogs() { logs.removeAll() }

  static func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }

  private func refreshLaunchAtLoginStatus(preserveMessage: Bool = false) {
    switch SMAppService.mainApp.status {
    case .enabled:
      launchAtLogin = true
      if !preserveMessage { launchAtLoginMessage = nil }
    case .requiresApproval:
      launchAtLogin = false
      if !preserveMessage { launchAtLoginMessage = "需要在“系统设置 → 通用 → 登录项”中批准。" }
    case .notFound:
      launchAtLogin = false
      if !preserveMessage { launchAtLoginMessage = "请从已打包的 CopilotBridge.app 启动后再开启登录项。" }
    case .notRegistered:
      launchAtLogin = false
      if !preserveMessage { launchAtLoginMessage = nil }
    @unknown default:
      launchAtLogin = false
    }
  }

  private func activateChangedGitHubCredential() async {
    let generation = UUID()
    credentialGeneration = generation
    clearAccountOverview(status: "等待读取模型与额度")
    let shouldRestart = isRunning
    if shouldRestart { await stopServerOperation() }
    guard credentialGeneration == generation else { return }
    await tokenManager.invalidate()
    guard credentialGeneration == generation else { return }
    await verifyCopilotOperation(generation: generation)
    guard credentialGeneration == generation else { return }
    if shouldRestart, copilotTokenExpiry != nil, !terminationRequested {
      await startServerOperation()
    }
  }

  private func bootstrapCredentials() async {
    var shouldAutoStart = false
    do {
      let result = try await dependencies.loadCredentials()
      localAPIKey = result.localAPIKey
      isCredentialStoreReady = true
      isGitHubConnected = result.hasGitHubCredential
      credentialStatus = result.hasGitHubCredential ? "已保存 GitHub 凭据，尚未验证" : "未登录"
      shouldAutoStart = autoStart
    } catch {
      localAPIKey = ""
      isCredentialStoreReady = false
      isGitHubConnected = false
      credentialStatus = "Keychain 不可用"
      errorMessage = "后台读取 Keychain 失败：\(error.localizedDescription)"
    }
    isBootstrapping = false
    bootstrapTask = nil
    updateBusyState()
    if isGitHubConnected, !terminationRequested {
      startAccountRefresh(allowDuringCredentialActivity: false, forceQuotaRefresh: false)
    }
    if shouldAutoStart, !terminationRequested { await startServer() }
  }

  private func startServerOperation() async {
    errorMessage = nil
    guard isCredentialStoreReady, !localAPIKey.isEmpty else {
      errorMessage = "Keychain 中没有已持久化的本地 API key，未启动代理。"
      return
    }
    guard (1...65_535).contains(port) else {
      errorMessage = "端口必须在 1...65535 之间。"
      return
    }

    let generation = UUID()
    serviceGeneration = generation
    let configuration = BridgeConfiguration(port: port, localAPIKey: localAPIKey)
    let candidate = ProxyServer(configuration: configuration, tokenManager: tokenManager) {
      [weak self] event in
      Task { @MainActor [weak self] in self?.record(event) }
    }
    server = candidate
    do {
      try await candidate.start()
      guard serviceGeneration == generation, server === candidate else {
        await candidate.stop()
        return
      }
      isRunning = true
    } catch {
      guard serviceGeneration == generation, server === candidate else { return }
      server = nil
      isRunning = false
      errorMessage = error.localizedDescription
      record(.error("代理启动失败。"))
    }
  }

  private func stopServerOperation() async {
    serviceGeneration = UUID()
    let runningServer = server
    server = nil
    isRunning = false
    await runningServer?.stop()
  }

  private func verifyCopilotOperation(generation: UUID) async {
    do {
      let expiry = try await tokenManager.verify()
      guard credentialGeneration == generation else { return }
      copilotTokenExpiry = expiry
      isGitHubConnected = true
      credentialStatus = "Copilot 可用"
      record(.info("Copilot 权限验证成功。"))
      startAccountRefresh(allowDuringCredentialActivity: true, forceQuotaRefresh: false)
    } catch {
      guard credentialGeneration == generation else { return }
      copilotTokenExpiry = nil
      credentialStatus = "Copilot 验证失败"
      accountOverviewStatus = "Copilot 未验证，结果可能已过期"
      if !availableModels.isEmpty {
        modelCatalogMessage = "Copilot 验证失败；当前保留上次成功的模型目录。"
      }
      if copilotQuota != nil {
        quotaMessage = "Copilot 验证失败；当前保留上次成功的额度快照。"
      }
      errorMessage = error.localizedDescription
      record(.warning("Copilot 权限验证失败。"))
    }
  }

  private func beginActivity() -> UUID {
    let generation = UUID()
    activityGenerations.insert(generation)
    updateBusyState()
    return generation
  }

  private func cancelAccountRefresh(clearData: Bool) {
    accountRefreshGeneration = UUID()
    accountRefreshTask?.cancel()
    accountRefreshTask = nil
    isRefreshingAccountOverview = false
    if clearData {
      availableModels = []
      copilotQuota = nil
      modelCatalogMessage = nil
      quotaMessage = nil
      modelCatalogUpdatedAt = nil
      quotaUpdatedAt = nil
    }
  }

  private func clearAccountOverview(status: String) {
    cancelAccountRefresh(clearData: true)
    accountOverviewStatus = status
  }

  private func finishActivity(_ generation: UUID) {
    guard activityGenerations.remove(generation) != nil else { return }
    updateBusyState()
    let waiters = activityWaiters
    activityWaiters.removeAll(keepingCapacity: true)
    for waiter in waiters { waiter.resume() }
  }

  private func waitForOtherActivities(except generation: UUID) async {
    while activityGenerations.contains(where: { $0 != generation }) {
      await withCheckedContinuation { continuation in
        activityWaiters.append(continuation)
      }
    }
  }

  private func updateBusyState() {
    isBusy = isBootstrapping || !activityGenerations.isEmpty
  }

  private func record(_ event: BridgeEvent) {
    let detail: String
    switch event {
    case .info(let message): detail = "INFO  \(message)"
    case .warning(let message): detail = "WARN  \(message)"
    case .error(let message): detail = "ERROR \(message)"
    case .request(let method, let path, let status, let milliseconds):
      detail = "HTTP  \(method) \(path) → \(status)  \(milliseconds)ms"
    }
    let timestamp = Date.now.formatted(.dateTime.hour().minute().second())
    logs.append(Self.boundedLogEntry("\(timestamp)  \(detail)"))
    if logs.count > 300 { logs.removeFirst(logs.count - 300) }
  }

  private static func boundedLogEntry(_ value: String, maximumBytes: Int = 1_024) -> String {
    guard value.utf8.count > maximumBytes else { return value }
    let ellipsis = "…"
    let contentLimit = maximumBytes - ellipsis.utf8.count
    var result = ""
    result.reserveCapacity(contentLimit)
    var usedBytes = 0
    for scalar in value.unicodeScalars {
      let scalarBytes = scalar.utf8.count
      guard scalarBytes <= contentLimit - usedBytes else { break }
      result.unicodeScalars.append(scalar)
      usedBytes += scalarBytes
    }
    result.append(ellipsis)
    return result
  }
}
