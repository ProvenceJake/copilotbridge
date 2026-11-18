import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

struct BridgeHTTPRequest: @unchecked Sendable {
  let method: HTTPMethod
  let uri: String
  let headers: HTTPHeaders
  let body: Data
  let path: String
  let hasValidRequestTarget: Bool

  init(method: HTTPMethod, uri: String, headers: HTTPHeaders, body: Data) {
    self.method = method
    self.uri = uri
    self.headers = headers
    self.body = body

    let encodedPath =
      uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? uri
    let lowercasedPath = encodedPath.lowercased()
    hasValidRequestTarget =
      (method == .OPTIONS && encodedPath == "*")
      || (encodedPath.hasPrefix("/") && !encodedPath.hasPrefix("//")
        && !lowercasedPath.contains("%2f") && !lowercasedPath.contains("%5c")
        && !encodedPath.contains("#"))
    if encodedPath.count > 1 {
      path = String(encodedPath.dropLastTrailingSlashes())
    } else {
      path = encodedPath
    }
  }
}

extension String {
  fileprivate func dropLastTrailingSlashes() -> Substring {
    var end = endIndex
    while end > startIndex, self[index(before: end)] == "/" { end = index(before: end) }
    return self[..<end]
  }
}

actor HTTPResponder {
  nonisolated let requestID: String
  private let channel: Channel
  private let responseVersion: HTTPVersion
  private let keepsConnectionAlive: Bool
  private var started = false
  private var finished = false

  init(channel: Channel, requestVersion: HTTPVersion, requestWantsKeepAlive: Bool) {
    requestID = UUID().uuidString.lowercased()
    self.channel = channel
    responseVersion = requestVersion
    keepsConnectionAlive = requestWantsKeepAlive && requestVersion == .http1_1
  }

  func sendJSON(status: Int, object: Any, extraHeaders: [(String, String)] = []) async {
    do {
      guard JSONSerialization.isValidJSONObject(object) else {
        throw BridgeError.protocolFailure("本地响应包含无法编码的 JSON 值。")
      }
      let data = try JSONSerialization.data(withJSONObject: object)
      try await send(
        status: status, data: data, contentType: "application/json; charset=utf-8",
        extraHeaders: extraHeaders)
    } catch {
      await sendFallbackError(error.localizedDescription)
    }
  }

  func send(status: Int, data: Data, contentType: String, extraHeaders: [(String, String)] = [])
    async throws
  {
    guard !started else { return }
    started = true
    var headers = baseHeaders()
    headers.add(name: "Content-Type", value: contentType)
    headers.add(name: "Content-Length", value: String(data.count))
    for (name, value) in extraHeaders { headers.replaceOrAdd(name: name, value: value) }
    let head = HTTPResponseHead(
      version: responseVersion,
      status: HTTPResponseStatus(statusCode: status),
      headers: headers
    )
    writeWithoutFlushing(.head(head))
    if !data.isEmpty {
      var buffer = channel.allocator.buffer(capacity: data.count)
      buffer.writeBytes(data)
      writeWithoutFlushing(.body(.byteBuffer(buffer)))
    }
    try await finish()
  }

  func startStream(
    status: Int = 200, contentType: String = "text/event-stream; charset=utf-8",
    extraHeaders: [(String, String)] = []
  ) async throws {
    guard !started else { return }
    started = true
    var headers = baseHeaders()
    headers.add(name: "Content-Type", value: contentType)
    headers.add(name: "Cache-Control", value: "no-cache, no-transform")
    headers.add(name: "X-Accel-Buffering", value: "no")
    if keepsConnectionAlive { headers.add(name: "Transfer-Encoding", value: "chunked") }
    for (name, value) in extraHeaders { headers.replaceOrAdd(name: name, value: value) }
    let head = HTTPResponseHead(
      version: responseVersion,
      status: HTTPResponseStatus(statusCode: status),
      headers: headers
    )
    try await write(.head(head))
  }

  func writeStream(_ data: Data) async throws {
    guard started, !finished, !data.isEmpty else { return }
    var buffer = channel.allocator.buffer(capacity: data.count)
    buffer.writeBytes(data)
    try await write(.body(.byteBuffer(buffer)))
  }

  func finish() async throws {
    guard !finished else { return }
    finished = true
    try await write(.end(nil))
    if !keepsConnectionAlive { try await channel.close().get() }
  }

  private func write(_ part: HTTPServerResponsePart) async throws {
    try await channel.writeAndFlush(part).get()
  }

  private func writeWithoutFlushing(_ part: HTTPServerResponsePart) {
    channel.write(part, promise: nil)
  }

  private func baseHeaders() -> HTTPHeaders {
    var headers = HTTPHeaders()
    headers.add(name: "Server", value: BridgeVersion.userAgent)
    headers.add(name: "Connection", value: keepsConnectionAlive ? "keep-alive" : "close")
    headers.add(name: "Access-Control-Allow-Origin", value: "*")
    headers.add(
      name: "Access-Control-Allow-Headers",
      value:
        "authorization, content-type, x-api-key, api-key, x-goog-api-key, anthropic-version, anthropic-beta, anthropic-dangerous-direct-browser-access, openai-beta, openai-organization, openai-project, idempotency-key, x-stainless-arch, x-stainless-async, x-stainless-lang, x-stainless-os, x-stainless-package-version, x-stainless-read-timeout, x-stainless-retry-count, x-stainless-runtime, x-stainless-runtime-version"
    )
    headers.add(name: "Access-Control-Allow-Methods", value: "GET, HEAD, POST, OPTIONS")
    headers.add(name: "Access-Control-Max-Age", value: "86400")
    headers.add(name: "Access-Control-Allow-Private-Network", value: "true")
    headers.add(
      name: "Access-Control-Expose-Headers",
      value:
        "request-id, x-request-id, x-upstream-request-id, retry-after, x-ratelimit-limit, x-ratelimit-remaining, x-ratelimit-reset"
    )
    headers.add(
      name: "Vary", value: "Origin, Access-Control-Request-Headers, Access-Control-Request-Method")
    headers.add(name: "X-Content-Type-Options", value: "nosniff")
    headers.add(name: "X-Request-ID", value: requestID)
    headers.add(name: "request-id", value: requestID)
    return headers
  }

  private func sendFallbackError(_: String) async {
    guard !started else {
      try? await finish()
      return
    }
    try? await send(
      status: 500,
      data: Data(
        "{\"error\":{\"type\":\"gateway_error\",\"message\":\"本地响应编码失败。\"}}".utf8),
      contentType: "application/json")
  }
}

final class HTTPRequestHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias RequestHandler = @Sendable (BridgeHTTPRequest, HTTPResponder) async -> Void

  private let maximumRequestBytes: Int
  private let maximumQueuedRequests = 2
  private let handler: RequestHandler
  private let admission: RequestAdmissionController
  private var requestHead: HTTPRequestHead?
  private var body = ByteBufferAllocator().buffer(capacity: 0)
  private var rejectedForSize = false
  private var task: Task<Void, Never>?
  private var pendingRequests: [(BridgeHTTPRequest, HTTPVersion, Bool, Bool)] = []

  fileprivate init(
    maximumRequestBytes: Int,
    admission: RequestAdmissionController,
    handler: @escaping RequestHandler
  ) {
    self.maximumRequestBytes = maximumRequestBytes
    self.admission = admission
    self.handler = handler
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      requestHead = head
      body = ByteBufferAllocator().buffer(capacity: 0)
      rejectedForSize = false
      if let length = head.headers.first(name: "Content-Length").flatMap(Int.init),
        length > maximumRequestBytes
      {
        rejectedForSize = true
      }
      if !rejectedForSize,
        head.headers[canonicalForm: "Expect"].contains(where: {
          $0.caseInsensitiveCompare("100-continue") == .orderedSame
        })
      {
        let response = HTTPResponseHead(version: head.version, status: .continue)
        context.channel.writeAndFlush(HTTPServerResponsePart.head(response), promise: nil)
      }
    case .body(var buffer):
      guard !rejectedForSize else { return }
      if body.readableBytes + buffer.readableBytes > maximumRequestBytes {
        rejectedForSize = true
        body = ByteBufferAllocator().buffer(capacity: 0)
      } else {
        body.writeBuffer(&buffer)
      }
    case .end:
      guard let head = requestHead else {
        let responder = HTTPResponder(
          channel: context.channel, requestVersion: .http1_1, requestWantsKeepAlive: false)
        task = Task {
          await responder.sendJSON(
            status: 400,
            object: Self.openAIError("缺少 HTTP request head。", type: "invalid_request_error"))
        }
        return
      }
      if rejectedForSize {
        body = ByteBufferAllocator().buffer(capacity: 0)
        let request = BridgeHTTPRequest(
          method: head.method, uri: head.uri, headers: head.headers, body: Data())
        guard enqueue((request, head.version, head.isKeepAlive, true), context: context) else {
          return
        }
        requestHead = nil
        processNext(channel: context.channel)
        return
      }
      let requestBody = Data(body.readableBytesView)
      body = ByteBufferAllocator().buffer(capacity: 0)
      let request = BridgeHTTPRequest(
        method: head.method, uri: head.uri, headers: head.headers, body: requestBody)
      guard enqueue((request, head.version, head.isKeepAlive, false), context: context) else {
        return
      }
      requestHead = nil
      processNext(channel: context.channel)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    task?.cancel()
    pendingRequests.removeAll(keepingCapacity: false)
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    task?.cancel()
    context.close(promise: nil)
  }

  private static func openAIError(_ message: String, type: String) -> [String: Any] {
    ["error": ["message": message, "type": type, "param": NSNull(), "code": NSNull()]]
  }

  private func enqueue(
    _ request: (BridgeHTTPRequest, HTTPVersion, Bool, Bool), context: ChannelHandlerContext
  ) -> Bool {
    guard pendingRequests.count < maximumQueuedRequests else {
      task?.cancel()
      pendingRequests.removeAll(keepingCapacity: false)
      context.close(promise: nil)
      return false
    }
    pendingRequests.append(request)
    return true
  }

  private func processNext(channel: Channel) {
    guard task == nil, !pendingRequests.isEmpty, channel.isActive else { return }
    let (request, version, keepAlive, oversized) = pendingRequests.removeFirst()
    let responder = HTTPResponder(
      channel: channel, requestVersion: version, requestWantsKeepAlive: keepAlive)
    let handler = self.handler
    let bypassesAdmission = Self.bypassesAdmission(request)
    let admitted = oversized || bypassesAdmission || admission.tryAcquire()
    let start = channel.eventLoop.makePromise(of: Void.self)
    let newTask = Task { [weak self, admission] in
      try? await start.futureResult.get()
      defer {
        if admitted && !oversized && !bypassesAdmission { admission.release() }
      }
      guard !Task.isCancelled else { return }
      if oversized {
        await responder.sendJSON(
          status: 413,
          object: Self.errorObject(
            for: request.path,
            message: "请求体超过本地限制。",
            type: "request_too_large",
            requestID: responder.requestID))
      } else if !admitted {
        await responder.sendJSON(
          status: 503,
          object: Self.errorObject(
            for: request.path,
            message: "本地并发请求已达到上限。",
            type: "overloaded_error",
            requestID: responder.requestID))
      } else {
        await handler(request, responder)
      }
      guard !Task.isCancelled else { return }
      do {
        try await channel.eventLoop.submit { [weak self] in
          guard let self else { return }
          self.task = nil
          self.processNext(channel: channel)
        }.get()
      } catch {
        // The server drains request tasks before shutting down event loops.
      }
    }
    task = newTask
    start.succeed(())
  }

  fileprivate func cancelAndReturnTask() -> Task<Void, Never>? {
    task?.cancel()
    pendingRequests.removeAll(keepingCapacity: false)
    return task
  }

  private static func bypassesAdmission(_ request: BridgeHTTPRequest) -> Bool {
    request.method == .OPTIONS
      || (request.method == .GET && (request.path == "/health" || request.path == "/healthz"))
      || (request.method == .HEAD
        && (request.path == "/api/hello" || request.path == "/anthropic/api/hello"))
  }

  private static func errorObject(
    for path: String, message: String, type: String, requestID: String
  ) -> [String: Any] {
    if path == "/v1/messages" || path.hasPrefix("/v1/messages/")
      || path == "/anthropic" || path.hasPrefix("/anthropic/")
    {
      return [
        "type": "error",
        "error": ["type": type, "message": message],
        "request_id": requestID,
      ]
    }
    return [
      "error": [
        "message": message,
        "type": type,
        "param": NSNull(),
        "code": type,
      ]
    ]
  }
}

private final class RequestAdmissionController: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumConcurrentRequests: Int
  private var activeRequests = 0

  init(maximumConcurrentRequests: Int) {
    self.maximumConcurrentRequests = maximumConcurrentRequests
  }

  func tryAcquire() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard activeRequests < maximumConcurrentRequests else { return false }
    activeRequests += 1
    return true
  }

  func release() {
    lock.lock()
    activeRequests = max(0, activeRequests - 1)
    lock.unlock()
  }
}

private final class ChildChannelRegistry: @unchecked Sendable {
  private struct Entry {
    let channel: Channel
    let handler: HTTPRequestHandler
  }

  private let lock = NSLock()
  private let maximumConnections: Int
  private var entries: [ObjectIdentifier: Entry] = [:]

  init(maximumConnections: Int) {
    self.maximumConnections = maximumConnections
  }

  func register(channel: Channel, handler: HTTPRequestHandler) -> Bool {
    let id = ObjectIdentifier(channel)
    lock.lock()
    guard entries.count < maximumConnections else {
      lock.unlock()
      return false
    }
    entries[id] = Entry(channel: channel, handler: handler)
    lock.unlock()
    channel.closeFuture.whenComplete { [weak self] _ in self?.remove(id) }
    return true
  }

  func closeAllAndDrain() async {
    let snapshot = currentEntries()

    await withTaskGroup(of: Void.self) { group in
      for entry in snapshot {
        group.addTask { _ = try? await entry.channel.close().get() }
      }
    }
    for entry in snapshot {
      do {
        let currentTask = try await entry.channel.eventLoop.submit {
          entry.handler.cancelAndReturnTask()
        }.get()
        if let currentTask { await currentTask.value }
      } catch {
        // The child already closed and has no work left to drain.
      }
    }
  }

  private func remove(_ id: ObjectIdentifier) {
    lock.lock()
    entries.removeValue(forKey: id)
    lock.unlock()
  }

  private func currentEntries() -> [Entry] {
    lock.lock()
    defer { lock.unlock() }
    return Array(entries.values)
  }
}

actor LocalHTTPServer {
  private let configuration: BridgeConfiguration
  private let handler: HTTPRequestHandler.RequestHandler
  private let admission = RequestAdmissionController(maximumConcurrentRequests: 16)
  private let children = ChildChannelRegistry(maximumConnections: 32)
  private var group: MultiThreadedEventLoopGroup?
  private var channel: Channel?

  init(configuration: BridgeConfiguration, handler: @escaping HTTPRequestHandler.RequestHandler) {
    self.configuration = configuration
    self.handler = handler
  }

  func start() async throws {
    guard channel == nil else { return }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    self.group = group
    let maximumRequestBytes = configuration.maximumRequestBytes
    let handler = self.handler
    let admission = self.admission
    let children = self.children
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 128)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        let requestHandler = HTTPRequestHandler(
          maximumRequestBytes: maximumRequestBytes,
          admission: admission,
          handler: handler)
        guard children.register(channel: channel, handler: requestHandler) else {
          return channel.eventLoop.makeFailedFuture(
            BridgeError.invalidConfiguration("本地连接数已达到上限。"))
        }
        return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
          channel.pipeline.addHandler(requestHandler)
        }
      }
      .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
      .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

    do {
      channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
    } catch {
      try? await shutdownGroup(group)
      self.group = nil
      throw error
    }
  }

  func stop() async {
    if let channel {
      try? await channel.close().get()
      self.channel = nil
    }
    await children.closeAllAndDrain()
    if let group {
      try? await shutdownGroup(group)
      self.group = nil
    }
  }

  private func shutdownGroup(_ group: MultiThreadedEventLoopGroup) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      group.shutdownGracefully { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }
}
