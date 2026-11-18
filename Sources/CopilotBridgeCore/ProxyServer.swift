import Foundation
import NIOHTTP1

public final class ProxyServer: @unchecked Sendable {
  private let configuration: BridgeConfiguration
  private let lifecycle = AsyncMutex()
  private let onEvent: @Sendable (BridgeEvent) -> Void
  private let tokenManager: CopilotTokenManager
  private var server: LocalHTTPServer?

  public init(
    configuration: BridgeConfiguration,
    tokenManager: CopilotTokenManager? = nil,
    onEvent: @escaping @Sendable (BridgeEvent) -> Void = { _ in }
  ) {
    self.configuration = configuration
    self.tokenManager =
      tokenManager
      ?? CopilotTokenManager(
        userAgent: configuration.userAgent,
        editorVersion: configuration.editorVersion,
        editorPluginVersion: configuration.editorPluginVersion
      )
    self.onEvent = onEvent
  }

  public func start() async throws {
    await lifecycle.acquire()
    do {
      try Task.checkCancellation()
      guard server == nil else {
        await lifecycle.release()
        return
      }
      guard
        configuration.host == "127.0.0.1" || configuration.host == "::1"
          || configuration.host == "localhost"
      else {
        throw BridgeError.invalidConfiguration("当前版本为安全起见只允许监听 loopback 地址。")
      }
      guard (1...65_535).contains(configuration.port) else {
        throw BridgeError.invalidConfiguration("端口必须在 1...65535 之间。")
      }
      guard !configuration.localAPIKey.isEmpty else {
        throw BridgeError.invalidConfiguration("本地 API key 不能为空。")
      }
      guard configuration.maximumRequestBytes > 0,
        configuration.maximumUpstreamResponseBytes > 0,
        configuration.maximumSSELineBytes > 0,
        configuration.maximumSSEEventBytes > 0
      else {
        throw BridgeError.invalidConfiguration("所有请求与响应读取限额都必须大于 0。")
      }

      let client = CopilotClient(configuration: configuration, tokens: tokenManager)
      let modelCatalog = ModelCatalogStore(client: client)
      let resolver = ModelResolver(aliases: configuration.modelAliases) {
        try await modelCatalog.modelIDs()
      }
      let router = ProxyRouter(
        configuration: configuration,
        client: client,
        modelCatalog: modelCatalog,
        resolver: resolver,
        onEvent: onEvent
      )
      let candidate = LocalHTTPServer(configuration: configuration) { request, responder in
        await router.route(request, responder: responder)
      }
      do {
        try await candidate.start()
        try Task.checkCancellation()
      } catch {
        await candidate.stop()
        throw error
      }
      server = candidate
      onEvent(.info("本地代理已启动：\(configuration.endpoint.absoluteString)"))
      await lifecycle.release()
    } catch {
      await lifecycle.release()
      throw error
    }
  }

  public func stop() async {
    await lifecycle.acquire()
    let runningServer = server
    if let runningServer {
      await runningServer.stop()
      server = nil
    }
    await lifecycle.release()
    if runningServer != nil { onEvent(.info("本地代理已停止。")) }
  }

  public func verifyCopilotAccess() async throws -> Date {
    try await tokenManager.verify()
  }
}

private actor AsyncMutex {
  private var isLocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !isLocked {
      isLocked = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      isLocked = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

private struct UpstreamStreamFailure: LocalizedError {
  let message: String
  let type: String?

  var errorDescription: String? { message }
}

private final class ProxyRouter: @unchecked Sendable {
  private let configuration: BridgeConfiguration
  private let client: CopilotClient
  private let modelCatalog: ModelCatalogStore
  private let resolver: ModelResolver
  private let onEvent: @Sendable (BridgeEvent) -> Void

  init(
    configuration: BridgeConfiguration,
    client: CopilotClient,
    modelCatalog: ModelCatalogStore,
    resolver: ModelResolver,
    onEvent: @escaping @Sendable (BridgeEvent) -> Void
  ) {
    self.configuration = configuration
    self.client = client
    self.modelCatalog = modelCatalog
    self.resolver = resolver
    self.onEvent = onEvent
  }

  func route(_ request: BridgeHTTPRequest, responder: HTTPResponder) async {
    let started = ContinuousClock.now
    var status = 500
    defer {
      let duration = started.duration(to: .now)
      let milliseconds =
        Int(duration.components.seconds * 1_000)
        + Int(duration.components.attoseconds / 1_000_000_000_000_000)
      onEvent(
        .request(
          method: request.method.rawValue, path: request.path, status: status,
          milliseconds: milliseconds))
    }

    guard request.hasValidRequestTarget else {
      status = 400
      let error =
        isAnthropicRoute(request.path)
        ? anthropicError(
          "HTTP 请求目标无效。", type: "invalid_request_error", requestID: responder.requestID)
        : openAIError("HTTP 请求目标无效。", type: "invalid_request_error")
      await responder.sendJSON(status: status, object: error)
      return
    }

    if request.method == .OPTIONS {
      status = 204
      try? await responder.send(status: 204, data: Data(), contentType: "text/plain")
      return
    }
    if request.method == .HEAD,
      request.path == "/api/hello" || request.path == "/anthropic/api/hello"
    {
      status = 204
      try? await responder.send(status: 204, data: Data(), contentType: "text/plain")
      return
    }
    if request.method == .GET && (request.path == "/healthz" || request.path == "/health") {
      status = 200
      await responder.sendJSON(
        status: 200,
        object: [
          "ok": true,
          "service": "CopilotBridge",
          "version": BridgeVersion.current,
          "listen": "loopback",
        ])
      return
    }
    guard isAuthorized(request.headers) else {
      status = 401
      let error =
        isAnthropicRoute(request.path)
        ? anthropicError(
          "本地 API key 无效。", type: "authentication_error", requestID: responder.requestID)
        : openAIError("本地 API key 无效。", type: "authentication_error")
      await responder.sendJSON(
        status: 401, object: error
      )
      return
    }

    do {
      switch (request.method, request.path) {
      case (.GET, "/"), (.GET, "/v1"):
        status = 200
        await responder.sendJSON(
          status: 200,
          object: [
            "name": "CopilotBridge",
            "protocols": ["openai-chat", "openai-responses", "anthropic-messages"],
            "docs": "https://github.com/github/copilot-sdk",
          ])
      case (.GET, "/models"), (.GET, "/v1/models"), (.GET, "/openai/v1/models"):
        status = try await relayModels(
          responder: responder,
          format: isCodexModelCatalogRequest(request) ? .codex : .openAI)
      case (.GET, "/anthropic/v1/models"):
        status = try await relayModels(responder: responder, format: .anthropic)
      case (.POST, "/chat/completions"), (.POST, "/v1/chat/completions"),
        (.POST, "/openai/v1/chat/completions"):
        status = try await relayOpenAI(
          request, upstreamPath: "chat/completions", responder: responder)
      case (.POST, "/responses"), (.POST, "/v1/responses"), (.POST, "/openai/v1/responses"):
        status = try await relayOpenAI(request, upstreamPath: "responses", responder: responder)
      case (.POST, "/v1/messages"), (.POST, "/anthropic/v1/messages"):
        status = try await relayAnthropic(request, responder: responder)
      case (.POST, "/v1/messages/count_tokens"), (.POST, "/anthropic/v1/messages/count_tokens"):
        let json = try parseObject(request.body)
        status = 200
        await responder.sendJSON(
          status: 200, object: ["input_tokens": try AnthropicCodec.estimatedInputTokens(json)])
      default:
        if request.method == .GET,
          let model = modelLookupRoute(request.path)
        {
          status = try await relayModel(
            id: model.id, format: model.format, responder: responder)
          return
        }
        if request.method == .POST,
          let azure = azureDeploymentRoute(request.path)
        {
          status = try await relayOpenAI(
            request,
            upstreamPath: azure.upstreamPath,
            routeModel: azure.deployment,
            responder: responder)
          return
        }
        status = 404
        let missingPath = boundedUTF8(request.path, maximumBytes: 512)
        let error =
          isAnthropicRoute(request.path)
          ? anthropicError(
            "未找到接口 \(missingPath)。", type: "not_found_error",
            requestID: responder.requestID)
          : openAIError("未找到接口 \(missingPath)。", type: "not_found_error")
        await responder.sendJSON(status: 404, object: error)
      }
    } catch is CancellationError {
      status = 499
      try? await responder.finish()
    } catch let error as BridgeError {
      status = statusCode(for: error)
      let clientMessage = boundedUTF8(error.localizedDescription, maximumBytes: 1_024)
      if isAnthropicRoute(request.path) {
        await responder.sendJSON(
          status: status,
          object: anthropicError(
            clientMessage, type: errorType(for: status), requestID: responder.requestID))
      } else {
        await responder.sendJSON(
          status: status,
          object: openAIError(clientMessage, type: errorType(for: status)))
      }
      onEvent(.warning(eventSummary(for: error, status: status)))
    } catch {
      status = 502
      if isAnthropicRoute(request.path) {
        await responder.sendJSON(
          status: 502,
          object: anthropicError("代理处理请求失败。", requestID: responder.requestID))
      } else {
        await responder.sendJSON(
          status: 502, object: openAIError("代理处理请求失败。", type: "api_error"))
      }
      onEvent(.error("代理处理请求时发生未分类错误。"))
    }
  }

  private enum ModelCatalogFormat {
    case openAI
    case anthropic
    case codex
  }

  private func relayModels(responder: HTTPResponder, format: ModelCatalogFormat) async throws -> Int
  {
    let upstream = try await modelCatalog.response()
    guard (200..<300).contains(upstream.status) else {
      try await sendUpstreamError(
        upstream, responder: responder, anthropic: format == .anthropic)
      return upstream.status
    }
    if format == .openAI {
      let translated = try OpenAIModelCodec.translate(try parseObject(upstream.data))
      await responder.sendJSON(
        status: 200, object: translated, extraHeaders: forwardedHeaders(upstream.headers))
      return 200
    }

    let source = try parseObject(upstream.data)
    let translated: [String: Any]
    switch format {
    case .openAI:
      preconditionFailure("OpenAI model catalogs are relayed before translation")
    case .anthropic:
      translated = try AnthropicModelCodec.translate(source)
    case .codex:
      translated = try CodexModelCodec.translate(source)
    }
    await responder.sendJSON(status: 200, object: translated)
    return 200
  }

  private func relayModel(
    id: String, format: ModelCatalogFormat, responder: HTTPResponder
  ) async throws -> Int {
    let upstream = try await modelCatalog.response()
    guard (200..<300).contains(upstream.status) else {
      try await sendUpstreamError(
        upstream, responder: responder, anthropic: format == .anthropic)
      return upstream.status
    }

    let source = try parseObject(upstream.data)
    let translated =
      format == .anthropic
      ? try AnthropicModelCodec.translate(source)
      : try OpenAIModelCodec.translate(source)
    let models = translated["data"] as? [[String: Any]] ?? []
    guard let model = models.first(where: { $0["id"] as? String == id }) else {
      if format == .anthropic {
        await responder.sendJSON(
          status: 404,
          object: anthropicError(
            "未找到模型 \(boundedUTF8(id, maximumBytes: 256))。", type: "not_found_error",
            requestID: responder.requestID))
      } else {
        await responder.sendJSON(
          status: 404,
          object: openAIError(
            "未找到模型 \(boundedUTF8(id, maximumBytes: 256))。", type: "not_found_error"))
      }
      return 404
    }
    await responder.sendJSON(
      status: 200, object: model, extraHeaders: forwardedHeaders(upstream.headers))
    return 200
  }

  private func isCodexModelCatalogRequest(_ request: BridgeHTTPRequest) -> Bool {
    guard let components = URLComponents(string: request.uri) else { return false }
    return components.queryItems?.contains(where: {
      $0.name == "client_version" && !($0.value ?? "").isEmpty
    }) == true
  }

  private func relayOpenAI(
    _ request: BridgeHTTPRequest,
    upstreamPath: String,
    routeModel: String? = nil,
    responder: HTTPResponder
  ) async throws -> Int {
    var json = try parseObject(request.body)
    let bodyModel = json["model"] as? String
    guard let requestedModel = routeModel ?? bodyModel, !requestedModel.isEmpty else {
      throw BridgeError.invalidRequest("请求缺少 model。")
    }
    json["model"] = await resolver.resolve(requestedModel)
    let wantsStream = json["stream"] as? Bool ?? false
    if wantsStream, upstreamPath == "chat/completions" {
      var streamOptions = json["stream_options"] as? [String: Any] ?? [:]
      streamOptions["include_usage"] = true
      json["stream_options"] = streamOptions
    }

    if wantsStream {
      return try await relayRawStream(path: upstreamPath, json: json, responder: responder)
    }
    let upstream = try await client.data(path: upstreamPath, json: json)
    if !(200..<300).contains(upstream.status) {
      recordUpstreamFailure(upstream, responder: responder)
    }
    try await responder.send(
      status: upstream.status,
      data: upstream.data,
      contentType: contentType(upstream.headers),
      extraHeaders: forwardedHeaders(upstream.headers)
    )
    return upstream.status
  }

  private func relayRawStream(path: String, json: [String: Any], responder: HTTPResponder)
    async throws -> Int
  {
    let upstream = try await client.stream(path: path, json: json)
    guard (200..<300).contains(upstream.status) else {
      let data = try await readAll(
        upstream.bytes, limit: configuration.maximumUpstreamResponseBytes)
      recordUpstreamFailure(
        status: upstream.status, data: data, headers: upstream.headers, responder: responder)
      try await responder.send(
        status: upstream.status,
        data: data,
        contentType: contentType(upstream.headers),
        extraHeaders: forwardedHeaders(upstream.headers)
      )
      return upstream.status
    }

    try await responder.startStream(extraHeaders: forwardedHeaders(upstream.headers))
    var frames = SSEFrameBuffer(
      maximumEventBytes: configuration.maximumSSEEventBytes,
      maximumLineBytes: configuration.maximumSSELineBytes
    )
    var validator = OpenAIStreamValidator(
      kind: path == "responses" ? .responses : .chatCompletions)
    do {
      for try await line in SSELineSequence(
        upstream.bytes, maximumLineBytes: configuration.maximumSSELineBytes)
      {
        try Task.checkCancellation()
        if let frame = try frames.feed(line: line) {
          if let event = frame.event { try validator.observe(event) }
          try await responder.writeStream(frame.bytes)
        }
      }
      try frames.finish()
      try validator.validateEndOfStream()
      try await responder.finish()
      return validator.sawFailure ? 502 : upstream.status
    } catch is CancellationError {
      try? await responder.finish()
      throw CancellationError()
    } catch {
      recordStreamFailure(error, path: path, responder: responder)
      try? await responder.writeStream(
        openAIStreamError(
          boundedUTF8(error.localizedDescription, maximumBytes: 1_024),
          responses: path == "responses"))
      try? await responder.finish()
      return 502
    }
  }

  private func relayAnthropic(_ request: BridgeHTTPRequest, responder: HTTPResponder) async throws
    -> Int
  {
    let source = try parseObject(request.body)
    guard let requestedModel = source["model"] as? String, !requestedModel.isEmpty else {
      throw BridgeError.invalidRequest("Anthropic Messages 请求缺少 model。")
    }
    try validateAnthropicEnvelope(source)
    let resolvedModel = await resolver.resolve(requestedModel)
    let endpoint = try await anthropicEndpoint(for: resolvedModel)
    if endpoint == .messages {
      return try await relayNativeAnthropic(
        source,
        requestedModel: requestedModel,
        resolvedModel: resolvedModel,
        requestHeaders: request.headers,
        responder: responder)
    }
    if endpoint == .responses {
      return try await relayAnthropicViaResponses(
        source,
        requestedModel: requestedModel,
        resolvedModel: resolvedModel,
        responder: responder)
    }
    var openAI = try AnthropicCodec.toOpenAI(source, resolvedModel: resolvedModel)
    openAI["model"] = resolvedModel
    let wantsStream = source["stream"] as? Bool ?? false

    if !wantsStream {
      let upstream = try await client.data(path: "chat/completions", json: openAI)
      guard (200..<300).contains(upstream.status) else {
        try await sendUpstreamError(upstream, responder: responder, anthropic: true)
        return upstream.status
      }
      let translated = try AnthropicCodec.fromOpenAI(
        try parseObject(upstream.data), requestedModel: requestedModel)
      await responder.sendJSON(
        status: 200, object: translated, extraHeaders: forwardedHeaders(upstream.headers))
      return 200
    }

    var streamOptions = openAI["stream_options"] as? [String: Any] ?? [:]
    streamOptions["include_usage"] = true
    openAI["stream_options"] = streamOptions
    let upstream = try await client.stream(path: "chat/completions", json: openAI)
    guard (200..<300).contains(upstream.status) else {
      let data = try await readAll(
        upstream.bytes, limit: configuration.maximumUpstreamResponseBytes)
      recordUpstreamFailure(
        status: upstream.status, data: data, headers: upstream.headers, responder: responder)
      let wrapped = anthropicUpstreamError(
        status: upstream.status, data: data, requestID: responder.requestID)
      await responder.sendJSON(
        status: upstream.status, object: wrapped, extraHeaders: forwardedHeaders(upstream.headers))
      return upstream.status
    }

    let translator = AnthropicStreamTranslator(
      requestedModel: requestedModel,
      maximumAccumulatedFieldBytes: configuration.maximumSSEEventBytes
    )
    try await responder.startStream(extraHeaders: forwardedHeaders(upstream.headers))
    try await responder.writeStream(translator.start())
    let keepalivePayload = translator.ping()
    let keepaliveTask = Task {
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(20))
          try Task.checkCancellation()
          try await responder.writeStream(keepalivePayload)
        } catch {
          return
        }
      }
    }
    var decoder = SSEDecoder(maximumEventBytes: configuration.maximumSSEEventBytes)
    do {
      var sawDone = false
      for try await line in SSELineSequence(
        upstream.bytes, maximumLineBytes: configuration.maximumSSELineBytes)
      {
        try Task.checkCancellation()
        if line.text.hasPrefix(":") {
          try await responder.writeStream(translator.ping())
          continue
        }
        if let event = try decoder.feed(line: line.text) {
          if event.data == "[DONE]" {
            sawDone = true
            break
          }
          if event.name == "ping" {
            try await responder.writeStream(translator.ping())
            continue
          }
          let chunk = try parseStreamChunk(event)
          let translated = try translator.consume(chunk)
          if !translated.isEmpty { try await responder.writeStream(translated) }
        }
      }
      if !sawDone, let event = decoder.finish() {
        if event.data == "[DONE]" {
          sawDone = true
        } else if event.name == "ping" {
          try await responder.writeStream(translator.ping())
        } else {
          let chunk = try parseStreamChunk(event)
          let translated = try translator.consume(chunk)
          if !translated.isEmpty { try await responder.writeStream(translated) }
        }
      }
      guard sawDone else {
        throw BridgeError.protocolFailure("Copilot 上游流在 [DONE] 前结束。")
      }
      keepaliveTask.cancel()
      await keepaliveTask.value
      try await responder.writeStream(try translator.end())
    } catch is CancellationError {
      keepaliveTask.cancel()
      await keepaliveTask.value
      try? await responder.finish()
      throw CancellationError()
    } catch {
      keepaliveTask.cancel()
      await keepaliveTask.value
      recordStreamFailure(error, path: "chat/completions", responder: responder)
      let upstreamType = (error as? UpstreamStreamFailure)?.type
      try? await responder.writeStream(
        translator.error(
          boundedUTF8(error.localizedDescription, maximumBytes: 1_024),
          type: anthropicStreamErrorType(upstreamType)))
      try? await responder.finish()
      return 502
    }
    try await responder.finish()
    return 200
  }

  private func anthropicEndpoint(for model: String) async throws -> CopilotInferenceEndpoint {
    do {
      guard let endpoints = try await modelCatalog.supportedEndpoints(for: model) else {
        return .chatCompletions
      }
      if endpoints.contains(.messages) { return .messages }
      if endpoints.contains(.chatCompletions) { return .chatCompletions }
      if endpoints.contains(.responses) { return .responses }
      throw BridgeError.invalidRequest(
        "模型 \(boundedUTF8(model, maximumBytes: 256)) 没有可用的 HTTP 推理端点。")
    } catch let error as BridgeError {
      switch error {
      case .upstream, .protocolFailure:
        onEvent(.warning("无法读取模型端点能力，暂按旧版 Chat Completions 路由。"))
        return .chatCompletions
      default:
        throw error
      }
    }
  }

  /// Rejects malformed protocol envelopes before the model catalog lookup. Besides returning
  /// client errors promptly, this prevents invalid local input from triggering an upstream request.
  /// Endpoint-specific codecs still perform the detailed validation needed for translation.
  private func validateAnthropicEnvelope(_ source: [String: Any]) throws {
    _ = try strictAnthropicStreamValue(source["stream"])
    guard AnthropicCodec.exactPositiveInteger(source["max_tokens"]) != nil else {
      throw BridgeError.invalidRequest("Anthropic Messages 请求必须提供正整数 max_tokens。")
    }
    guard let messages = source["messages"] as? [[String: Any]] else {
      throw BridgeError.invalidRequest("Anthropic Messages 请求缺少 messages 数组。")
    }
    for message in messages {
      guard let role = message["role"] as? String,
        role == "user" || role == "assistant" || role == "system"
      else {
        throw BridgeError.invalidRequest("Anthropic message.role 必须是 user、assistant 或 system。")
      }
      if message["content"] is String { continue }
      guard let blocks = message["content"] as? [[String: Any]] else {
        throw BridgeError.invalidRequest("Anthropic message.content 必须是字符串或 block 数组。")
      }
      for block in blocks {
        guard let type = block["type"] as? String, !type.isEmpty else {
          throw BridgeError.invalidRequest("Anthropic content block 缺少 type。")
        }
        if type == "tool_use", let input = block["input"], !(input is NSNull) {
          guard let object = input as? [String: Any], JSONSerialization.isValidJSONObject(object)
          else {
            throw BridgeError.invalidRequest("tool_use.input 必须是 JSON 对象。")
          }
        }
      }
    }
  }

  private func relayAnthropicViaResponses(
    _ source: [String: Any],
    requestedModel: String,
    resolvedModel: String,
    responder: HTTPResponder
  ) async throws -> Int {
    let wantsStream = try strictAnthropicStreamValue(source["stream"])
    var openAI = try AnthropicResponsesCodec.toOpenAI(source, resolvedModel: resolvedModel)

    if !wantsStream {
      openAI["stream"] = false
      let upstream = try await client.data(path: "responses", json: openAI)
      guard (200..<300).contains(upstream.status) else {
        try await sendUpstreamError(upstream, responder: responder, anthropic: true)
        return upstream.status
      }
      let translated = try AnthropicResponsesCodec.fromOpenAI(
        try parseObject(upstream.data), requestedModel: requestedModel)
      await responder.sendJSON(
        status: 200,
        object: translated,
        extraHeaders: forwardedHeaders(upstream.headers))
      return 200
    }

    openAI["stream"] = true
    let upstream = try await client.stream(path: "responses", json: openAI)
    guard (200..<300).contains(upstream.status) else {
      let data = try await readAll(
        upstream.bytes, limit: configuration.maximumUpstreamResponseBytes)
      recordUpstreamFailure(
        status: upstream.status, data: data, headers: upstream.headers, responder: responder)
      await responder.sendJSON(
        status: upstream.status,
        object: anthropicUpstreamError(
          status: upstream.status, data: data, requestID: responder.requestID),
        extraHeaders: forwardedHeaders(upstream.headers))
      return upstream.status
    }

    let translator = AnthropicResponsesStreamTranslator(
      requestedModel: requestedModel,
      maximumAccumulatedFieldBytes: configuration.maximumSSEEventBytes)
    try await responder.startStream(extraHeaders: forwardedHeaders(upstream.headers))
    let keepalivePayload = translator.ping()
    let keepaliveTask = Task {
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(20))
          try Task.checkCancellation()
          try await responder.writeStream(keepalivePayload)
        } catch {
          return
        }
      }
    }
    var decoder = SSEDecoder(maximumEventBytes: configuration.maximumSSEEventBytes)
    do {
      var sawDoneSentinel = false
      for try await line in SSELineSequence(
        upstream.bytes, maximumLineBytes: configuration.maximumSSELineBytes)
      {
        try Task.checkCancellation()
        if line.text.hasPrefix(":") {
          try await responder.writeStream(translator.ping())
          continue
        }
        guard let event = try decoder.feed(line: line.text) else { continue }
        if event.data == "[DONE]" {
          sawDoneSentinel = true
          break
        }
        if event.name == "ping", event.data.isEmpty {
          try await responder.writeStream(translator.ping())
          continue
        }
        let translated = try translator.consume(
          eventName: event.name, object: try parseStreamChunk(event))
        if !translated.isEmpty { try await responder.writeStream(translated) }
      }
      if !sawDoneSentinel, let event = decoder.finish(), event.data != "[DONE]" {
        if event.name == "ping", event.data.isEmpty {
          try await responder.writeStream(translator.ping())
        } else {
          let translated = try translator.consume(
            eventName: event.name, object: try parseStreamChunk(event))
          if !translated.isEmpty { try await responder.writeStream(translated) }
        }
      }
      try translator.finish()
      keepaliveTask.cancel()
      await keepaliveTask.value
      try await responder.finish()
      return translator.sawFailure ? 502 : upstream.status
    } catch is CancellationError {
      keepaliveTask.cancel()
      await keepaliveTask.value
      try? await responder.finish()
      throw CancellationError()
    } catch {
      keepaliveTask.cancel()
      await keepaliveTask.value
      recordStreamFailure(error, path: "responses", responder: responder)
      let upstreamType = (error as? UpstreamStreamFailure)?.type
      try? await responder.writeStream(
        translator.error(
          boundedUTF8(error.localizedDescription, maximumBytes: 1_024),
          type: anthropicStreamErrorType(upstreamType)))
      try? await responder.finish()
      return 502
    }
  }

  private func relayNativeAnthropic(
    _ source: [String: Any],
    requestedModel: String,
    resolvedModel: String,
    requestHeaders: HTTPHeaders,
    responder: HTTPResponder
  ) async throws -> Int {
    var body = source
    body["model"] = resolvedModel
    let headers = nativeAnthropicHeaders(requestHeaders)
    let wantsStream = try strictAnthropicStreamValue(source["stream"])

    if !wantsStream {
      let upstream = try await client.data(
        path: "v1/messages", json: body, additionalHeaders: headers)
      guard (200..<300).contains(upstream.status) else {
        try await sendUpstreamError(upstream, responder: responder, anthropic: true)
        return upstream.status
      }
      try await responder.send(
        status: upstream.status,
        data: upstream.data,
        contentType: contentType(upstream.headers),
        extraHeaders: forwardedHeaders(upstream.headers))
      return upstream.status
    }

    let upstream = try await client.stream(
      path: "v1/messages", json: body, additionalHeaders: headers)
    guard (200..<300).contains(upstream.status) else {
      let data = try await readAll(
        upstream.bytes, limit: configuration.maximumUpstreamResponseBytes)
      recordUpstreamFailure(
        status: upstream.status, data: data, headers: upstream.headers, responder: responder)
      await responder.sendJSON(
        status: upstream.status,
        object: anthropicUpstreamError(
          status: upstream.status, data: data, requestID: responder.requestID),
        extraHeaders: forwardedHeaders(upstream.headers))
      return upstream.status
    }

    try await responder.startStream(extraHeaders: forwardedHeaders(upstream.headers))
    let eventEncoder = AnthropicStreamTranslator(requestedModel: requestedModel)
    let keepalivePayload = eventEncoder.ping()
    let keepaliveTask = Task {
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(20))
          try Task.checkCancellation()
          try await responder.writeStream(keepalivePayload)
        } catch {
          return
        }
      }
    }
    var frames = SSEFrameBuffer(
      maximumEventBytes: configuration.maximumSSEEventBytes,
      maximumLineBytes: configuration.maximumSSELineBytes)
    var validator = AnthropicNativeStreamValidator()
    do {
      for try await line in SSELineSequence(
        upstream.bytes, maximumLineBytes: configuration.maximumSSELineBytes)
      {
        try Task.checkCancellation()
        if let frame = try frames.feed(line: line),
          try validator.observe(frame.event) == .forward
        {
          try await responder.writeStream(frame.bytes)
        }
      }
      try frames.finish()
      try validator.validateEndOfStream()
      keepaliveTask.cancel()
      await keepaliveTask.value
      try await responder.finish()
      return validator.sawFailure ? 502 : upstream.status
    } catch is CancellationError {
      keepaliveTask.cancel()
      await keepaliveTask.value
      try? await responder.finish()
      throw CancellationError()
    } catch {
      keepaliveTask.cancel()
      await keepaliveTask.value
      recordStreamFailure(error, path: "v1/messages", responder: responder)
      try? await responder.writeStream(
        eventEncoder.error(
          boundedUTF8(error.localizedDescription, maximumBytes: 1_024), type: "api_error"))
      try? await responder.finish()
      return 502
    }
  }

  private func recordStreamFailure(_ error: any Error, path: String, responder: HTTPResponder) {
    onEvent(
      .warning(
        SafeUpstreamErrorDiagnostic.streamFailureSummary(
          error: error, upstreamPath: path, localRequestID: responder.requestID)))
  }

  private func nativeAnthropicHeaders(_ headers: HTTPHeaders) -> [String: String] {
    var result = [
      "Anthropic-Version": headers.first(name: "Anthropic-Version") ?? "2023-06-01",
      "X-Initiator": "user",
    ]
    if let beta = headers.first(name: "Anthropic-Beta"), !beta.isEmpty {
      result["Anthropic-Beta"] = beta
    }
    return result
  }

  private func strictAnthropicStreamValue(_ value: Any?) throws -> Bool {
    guard let value, !(value is NSNull) else { return false }
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else {
      throw BridgeError.invalidRequest("Anthropic stream 必须是布尔值。")
    }
    return number.boolValue
  }

  private func sendUpstreamError(
    _ upstream: CopilotDataResponse, responder: HTTPResponder, anthropic: Bool
  ) async throws {
    recordUpstreamFailure(upstream, responder: responder)
    if anthropic {
      await responder.sendJSON(
        status: upstream.status,
        object: anthropicUpstreamError(
          status: upstream.status, data: upstream.data, requestID: responder.requestID),
        extraHeaders: forwardedHeaders(upstream.headers)
      )
    } else {
      try await responder.send(
        status: upstream.status,
        data: upstream.data,
        contentType: contentType(upstream.headers),
        extraHeaders: forwardedHeaders(upstream.headers)
      )
    }
  }

  private func parseObject(_ data: Data) throws -> [String: Any] {
    guard !data.isEmpty else { throw BridgeError.invalidRequest("请求体不能为空。") }
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BridgeError.invalidRequest("请求体必须是 JSON 对象。")
      }
      return object
    } catch let error as BridgeError {
      throw error
    } catch {
      throw BridgeError.invalidRequest("JSON 解析失败：\(error.localizedDescription)")
    }
  }

  private func isAuthorized(_ headers: HTTPHeaders) -> Bool {
    let bearer = headers.first(name: "Authorization").flatMap { value -> String? in
      guard value.count > 7, value.prefix(7).lowercased() == "bearer " else { return nil }
      return String(value.dropFirst(7))
    }
    let candidate =
      bearer
      ?? headers.first(name: "X-API-Key")
      ?? headers.first(name: "api-key")
      ?? headers.first(name: "X-Goog-API-Key")
    guard let candidate else { return false }
    return constantTimeEqual(candidate, configuration.localAPIKey)
  }

  private func isAnthropicRoute(_ path: String) -> Bool {
    path == "/anthropic" || path.hasPrefix("/anthropic/") || path == "/v1/messages"
      || path.hasPrefix("/v1/messages/")
  }

  private func azureDeploymentRoute(_ path: String) -> (deployment: String, upstreamPath: String)? {
    let prefix = "/openai/deployments/"
    guard path.hasPrefix(prefix) else { return nil }
    let remainder = path.dropFirst(prefix.count)
    guard let separator = remainder.firstIndex(of: "/") else { return nil }
    let deployment = String(remainder[..<separator]).removingPercentEncoding ?? ""
    guard !deployment.isEmpty, !deployment.contains("/") else { return nil }
    switch remainder[separator...] {
    case "/chat/completions": return (deployment, "chat/completions")
    case "/responses": return (deployment, "responses")
    default: return nil
    }
  }

  private func modelLookupRoute(_ path: String) -> (id: String, format: ModelCatalogFormat)? {
    let candidates: [(prefix: String, format: ModelCatalogFormat)] = [
      ("/anthropic/v1/models/", .anthropic),
      ("/openai/v1/models/", .openAI),
      ("/v1/models/", .openAI),
      ("/models/", .openAI),
    ]
    for candidate in candidates where path.hasPrefix(candidate.prefix) {
      let encodedID = String(path.dropFirst(candidate.prefix.count))
      guard !encodedID.isEmpty,
        let id = encodedID.removingPercentEncoding,
        !id.isEmpty,
        !id.contains("/")
      else { return nil }
      return (id, candidate.format)
    }
    return nil
  }

  private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
    let lhs = Array(left.utf8)
    let rhs = Array(right.utf8)
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  private func forwardedHeaders(_ headers: [String: String]) -> [(String, String)] {
    let allowed = [
      "x-request-id", "request-id", "retry-after", "x-ratelimit-limit",
      "x-ratelimit-remaining", "x-ratelimit-reset",
    ]
    var result: [(String, String)] = []
    for name in allowed {
      guard let value = headers[name] else { continue }
      let targetName =
        name == "x-request-id" || name == "request-id"
        ? "X-Upstream-Request-ID" : name
      if targetName == "X-Upstream-Request-ID",
        result.contains(where: { $0.0 == targetName })
      {
        continue
      }
      result.append((targetName, value))
    }
    return result
  }

  private func contentType(_ headers: [String: String]) -> String {
    headers["content-type"] ?? "application/json; charset=utf-8"
  }

  private func recordUpstreamFailure(
    _ upstream: CopilotDataResponse, responder: HTTPResponder
  ) {
    recordUpstreamFailure(
      status: upstream.status, data: upstream.data, headers: upstream.headers,
      responder: responder)
  }

  private func recordUpstreamFailure(
    status: Int, data: Data, headers: [String: String], responder: HTTPResponder
  ) {
    onEvent(
      .warning(
        SafeUpstreamErrorDiagnostic.summary(
          status: status,
          data: data,
          headers: headers,
          localRequestID: responder.requestID)))
  }

  private func openAIError(_ message: String, type: String) -> [String: Any] {
    ["error": ["message": message, "type": type, "param": NSNull(), "code": NSNull()]]
  }

  private func anthropicError(
    _ message: String, type: String = "api_error", requestID: String
  ) -> [String: Any] {
    [
      "type": "error",
      "error": ["type": type, "message": message],
      "request_id": requestID,
    ]
  }

  private func anthropicUpstreamError(status: Int, data: Data, requestID: String) -> [String: Any] {
    let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let nested = parsed?["error"] as? [String: Any]
    let message =
      nested?["message"] as? String
      ?? parsed?["message"] as? String
      ?? String(data: data.prefix(512), encoding: .utf8)
      ?? "Copilot upstream HTTP \(status)"
    return anthropicError(
      boundedUTF8(message, maximumBytes: 1_024), type: errorType(for: status),
      requestID: requestID)
  }

  private func statusCode(for error: BridgeError) -> Int {
    switch error {
    case .missingGitHubToken: return 401
    case .invalidConfiguration, .invalidRequest: return 400
    case .upstream(let status, _): return status == 0 ? 502 : status
    case .protocolFailure: return 502
    }
  }

  private func eventSummary(for error: BridgeError, status: Int) -> String {
    switch error {
    case .missingGitHubToken:
      return "请求失败：GitHub 凭据不可用。"
    case .invalidConfiguration:
      return "请求失败：本地代理配置无效。"
    case .invalidRequest:
      return "请求被拒绝：格式或参数无效。"
    case .upstream(let upstreamStatus, _):
      return "Copilot 上游请求失败（HTTP \(upstreamStatus == 0 ? status : upstreamStatus)）。"
    case .protocolFailure:
      return "Copilot 上游响应未通过协议校验。"
    }
  }

  private func errorType(for status: Int) -> String {
    switch status {
    case 400: return "invalid_request_error"
    case 401: return "authentication_error"
    case 402: return "billing_error"
    case 403: return "permission_error"
    case 404: return "not_found_error"
    case 409: return "conflict_error"
    case 413: return "request_too_large"
    case 429: return "rate_limit_error"
    case 504: return "timeout_error"
    case 503, 529: return "overloaded_error"
    case 400..<500: return "invalid_request_error"
    default: return "api_error"
    }
  }

  private func readAll(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
    var data = Data()
    let chunkSize = min(64 * 1_024, limit)
    var chunk: [UInt8] = []
    chunk.reserveCapacity(chunkSize)
    var receivedBytes = 0
    for try await byte in bytes {
      guard receivedBytes < limit else {
        throw BridgeError.protocolFailure("上游错误响应超过读取限制。")
      }
      receivedBytes += 1
      chunk.append(byte)
      if chunk.count == chunkSize {
        data.append(contentsOf: chunk)
        chunk.removeAll(keepingCapacity: true)
      }
    }
    if !chunk.isEmpty { data.append(contentsOf: chunk) }
    return data
  }

  private func parseStreamChunk(_ event: SSEDecoder.Event) throws -> [String: Any] {
    guard !event.data.isEmpty, let data = event.data.data(using: .utf8),
      let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      let eventName = event.name?.prefix(64) ?? "unnamed"
      throw BridgeError.protocolFailure(
        "Copilot 上游返回了无效的 SSE 数据（event=\(eventName)，bytes=\(event.data.utf8.count)）。")
    }
    if event.name == "error" || chunk["type"] as? String == "error" || chunk["error"] != nil {
      let nested = chunk["error"] as? [String: Any]
      let message =
        nested?["message"] as? String ?? chunk["message"] as? String ?? "Copilot 上游流返回错误。"
      let outerType = chunk["type"] as? String
      let type = nested?["type"] as? String ?? (outerType == "error" ? nil : outerType)
      throw UpstreamStreamFailure(
        message: boundedUTF8(message, maximumBytes: 1_024), type: type)
    }
    return chunk
  }

  private func anthropicStreamErrorType(_ type: String?) -> String {
    let knownTypes: Set<String> = [
      "api_error",
      "authentication_error",
      "billing_error",
      "conflict_error",
      "invalid_request_error",
      "not_found_error",
      "overloaded_error",
      "permission_error",
      "rate_limit_error",
      "request_too_large",
      "timeout_error",
    ]
    guard let type, knownTypes.contains(type) else { return "api_error" }
    return type
  }

  private func openAIStreamError(_ message: String, responses: Bool) -> Data {
    let object: [String: Any]
    if responses {
      object = [
        "type": "error",
        "code": "server_error",
        "message": boundedUTF8(message, maximumBytes: 1_024),
        "param": NSNull(),
        "sequence_number": 0,
      ]
    } else {
      object = [
        "type": "error",
        "error": [
          "message": boundedUTF8(message, maximumBytes: 1_024),
          "type": "api_error",
          "param": NSNull(),
          "code": NSNull(),
        ],
      ]
    }
    let payload =
      JSONSerialization.isValidJSONObject(object)
      ? ((try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
      : Data("{}".utf8)
    var result = Data("event: error\ndata: ".utf8)
    result.append(payload)
    result.append(Data("\n\n".utf8))
    return result
  }
}

private func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
  guard maximumBytes > 0 else { return "" }
  guard value.utf8.count > maximumBytes else { return value }

  let ellipsis = "…"
  let ellipsisBytes = ellipsis.utf8.count
  guard maximumBytes > ellipsisBytes else {
    return String(repeating: ".", count: maximumBytes)
  }

  let contentLimit = maximumBytes - ellipsisBytes
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

struct SSELine: Equatable {
  let text: String
  let bytes: Data
}

struct SSELineParser {
  private static let carriageReturn: UInt8 = 0x0D
  private static let lineFeed: UInt8 = 0x0A

  private let maximumLineBytes: Int
  private var textBytes: [UInt8] = []
  private var rawBytes: [UInt8] = []
  private var hasPendingCarriageReturn = false

  init(maximumLineBytes: Int = 4 * 1_024 * 1_024) {
    self.maximumLineBytes = max(1, maximumLineBytes)
  }

  mutating func feed(_ byte: UInt8) throws -> SSELine? {
    if hasPendingCarriageReturn {
      hasPendingCarriageReturn = false
      if byte == Self.lineFeed {
        rawBytes.append(byte)
        return takeLine()
      }

      let line = takeLine()
      try appendToNextLine(byte)
      return line
    }

    if byte == Self.carriageReturn {
      rawBytes.append(byte)
      hasPendingCarriageReturn = true
      return nil
    }
    if byte == Self.lineFeed {
      rawBytes.append(byte)
      return takeLine()
    }

    try appendContentByte(byte)
    return nil
  }

  mutating func feed(_ bytes: Data) throws -> [SSELine] {
    var lines: [SSELine] = []
    for byte in bytes {
      if let line = try feed(byte) { lines.append(line) }
    }
    return lines
  }

  mutating func finish() -> SSELine? {
    if hasPendingCarriageReturn {
      hasPendingCarriageReturn = false
      return takeLine()
    }
    guard !rawBytes.isEmpty else { return nil }
    return takeLine()
  }

  private mutating func appendToNextLine(_ byte: UInt8) throws {
    if byte == Self.carriageReturn {
      rawBytes.append(byte)
      hasPendingCarriageReturn = true
    } else {
      try appendContentByte(byte)
    }
  }

  private mutating func appendContentByte(_ byte: UInt8) throws {
    guard textBytes.count < maximumLineBytes else {
      throw BridgeError.protocolFailure("Copilot 上游 SSE 单行超过读取限制。")
    }
    rawBytes.append(byte)
    textBytes.append(byte)
  }

  private mutating func takeLine() -> SSELine {
    defer {
      textBytes.removeAll(keepingCapacity: true)
      rawBytes.removeAll(keepingCapacity: true)
    }
    return SSELine(
      text: String(decoding: textBytes, as: UTF8.self),
      bytes: Data(rawBytes)
    )
  }
}

struct SSELineSequence: AsyncSequence {
  typealias Element = SSELine

  struct AsyncIterator: AsyncIteratorProtocol {
    private var iterator: URLSession.AsyncBytes.Iterator
    private var parser = SSELineParser()
    private var reachedEnd = false

    init(iterator: URLSession.AsyncBytes.Iterator, maximumLineBytes: Int) {
      self.iterator = iterator
      parser = SSELineParser(maximumLineBytes: maximumLineBytes)
    }

    mutating func next() async throws -> SSELine? {
      while let byte = try await iterator.next() {
        if let line = try parser.feed(byte) { return line }
      }
      guard !reachedEnd else { return nil }
      reachedEnd = true
      return parser.finish()
    }
  }

  private let bytes: URLSession.AsyncBytes
  private let maximumLineBytes: Int

  init(_ bytes: URLSession.AsyncBytes, maximumLineBytes: Int = 4 * 1_024 * 1_024) {
    self.bytes = bytes
    self.maximumLineBytes = maximumLineBytes
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(iterator: bytes.makeAsyncIterator(), maximumLineBytes: maximumLineBytes)
  }
}

/// Holds one raw SSE frame until its terminating blank line has been validated.
/// This prevents a locally generated error event from being appended to a partial
/// upstream event and keeps valid streams byte-for-byte identical.
struct SSEFrameBuffer {
  struct Frame {
    let bytes: Data
    let event: SSEDecoder.Event?
  }

  private var decoder: SSEDecoder
  private var bufferedBytes = Data()
  private let maximumBufferedBytes: Int

  init(maximumEventBytes: Int, maximumLineBytes: Int) {
    let eventLimit = max(1, maximumEventBytes)
    let lineLimit = max(1, maximumLineBytes)
    decoder = SSEDecoder(maximumEventBytes: eventLimit)
    maximumBufferedBytes =
      eventLimit > Int.max - lineLimit ? Int.max : eventLimit + lineLimit
  }

  mutating func feed(line: SSELine) throws -> Frame? {
    // Standalone comments are keep-alives rather than events. Forward complete
    // comment lines immediately so buffering does not turn them into timeouts.
    if bufferedBytes.isEmpty, line.text.hasPrefix(":"), lineHasDelimiter(line.bytes) {
      _ = try decoder.feed(line: line.text)
      return Frame(bytes: line.bytes, event: nil)
    }

    guard line.bytes.count <= maximumBufferedBytes - bufferedBytes.count else {
      throw BridgeError.protocolFailure("Copilot 上游 SSE 单事件原始帧超过读取限制。")
    }
    bufferedBytes.append(line.bytes)
    let event = try decoder.feed(line: line.text)
    guard line.text.isEmpty else { return nil }

    let bytes = bufferedBytes
    bufferedBytes = Data()
    return Frame(bytes: bytes, event: event)
  }

  mutating func finish() throws {
    guard bufferedBytes.isEmpty else {
      throw BridgeError.protocolFailure("Copilot 上游 SSE 事件在分隔空行前结束。")
    }
  }

  private func lineHasDelimiter(_ bytes: Data) -> Bool {
    bytes.last == UInt8(ascii: "\n") || bytes.last == UInt8(ascii: "\r")
  }
}

struct SSEDecoder {
  struct Event {
    let name: String?
    let data: String
  }

  private var name: String?
  private var dataLines: [String] = []
  private let maximumEventBytes: Int
  private var dataBytes = 0

  init(maximumEventBytes: Int = 8 * 1_024 * 1_024) {
    self.maximumEventBytes = max(1, maximumEventBytes)
  }

  mutating func feed(line: String) throws -> Event? {
    if line.isEmpty {
      guard !dataLines.isEmpty || name != nil else { return nil }
      defer {
        name = nil
        dataLines.removeAll(keepingCapacity: true)
        dataBytes = 0
      }
      return Event(name: name, data: dataLines.joined(separator: "\n"))
    }
    if line.hasPrefix(":") { return nil }
    if line.hasPrefix("event:") {
      name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
    } else if line.hasPrefix("data:") {
      var value = String(line.dropFirst(5))
      if value.first == " " { value.removeFirst() }
      let separatorBytes = dataLines.isEmpty ? 0 : 1
      let appendedBytes = value.utf8.count + separatorBytes
      guard appendedBytes <= maximumEventBytes - dataBytes else {
        throw BridgeError.protocolFailure("Copilot 上游 SSE 单事件超过读取限制。")
      }
      dataLines.append(value)
      dataBytes += appendedBytes
    }
    return nil
  }

  mutating func finish() -> Event? {
    guard !dataLines.isEmpty || name != nil else { return nil }
    defer {
      name = nil
      dataLines.removeAll(keepingCapacity: true)
      dataBytes = 0
    }
    return Event(name: name, data: dataLines.joined(separator: "\n"))
  }
}
