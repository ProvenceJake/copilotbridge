import AppKit
import Foundation

@MainActor
final class ApplicationTerminationCoordinator {
  enum Decision: Equatable {
    case terminateNow
    case terminateLater
  }

  typealias Preparation = @MainActor () async -> Void
  typealias Reply = @MainActor (Bool) -> Void

  private var preparation: Preparation?
  private var pendingReply: Reply?
  private var preparationTask: Task<Void, Never>?
  private(set) var isPrepared = false

  func bind(preparation: @escaping Preparation) {
    guard self.preparation == nil else { return }
    self.preparation = preparation
    startPreparationIfPossible()
  }

  func requestTermination(reply: @escaping Reply) -> Decision {
    guard !isPrepared else { return .terminateNow }
    if pendingReply == nil { pendingReply = reply }
    startPreparationIfPossible()
    return .terminateLater
  }

  private func startPreparationIfPossible() {
    guard preparationTask == nil, let preparation, let pendingReply else { return }
    preparationTask = Task { @MainActor [weak self] in
      await preparation()
      guard let self else {
        pendingReply(true)
        return
      }
      self.isPrepared = true
      self.pendingReply = nil
      self.preparationTask = nil
      pendingReply(true)
    }
  }
}

@MainActor
final class CopilotBridgeApplicationDelegate: NSObject, NSApplicationDelegate {
  private let terminationCoordinator = ApplicationTerminationCoordinator()

  func bind(model: BridgeAppModel) {
    terminationCoordinator.bind { [weak model] in
      await model?.prepareForTermination()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    switch terminationCoordinator.requestTermination(reply: { shouldTerminate in
      sender.reply(toApplicationShouldTerminate: shouldTerminate)
    }) {
    case .terminateNow:
      return .terminateNow
    case .terminateLater:
      return .terminateLater
    }
  }
}
