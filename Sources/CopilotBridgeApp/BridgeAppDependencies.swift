import AppKit
import CopilotBridgeCore
import Foundation

protocol GitHubDeviceAuthenticating: Sendable {
  func requestCode() async throws -> DeviceAuthorization
  func pollForToken(_ authorization: DeviceAuthorization) async throws -> String
}

extension GitHubDeviceAuth: GitHubDeviceAuthenticating {}

struct BridgeAppDependencies: Sendable {
  let loadCredentials: @Sendable () async throws -> KeychainBootstrapResult
  let makeGitHubDeviceAuth: @Sendable () -> any GitHubDeviceAuthenticating
  let presentDeviceAuthorization: @MainActor @Sendable (DeviceAuthorization) -> Void
  let writeGitHubToken: @Sendable (String) async throws -> Void
  let deleteGitHubToken: @Sendable () async throws -> Void
  let writeLocalAPIKey: @Sendable (String) async throws -> Void

  static let live = BridgeAppDependencies(
    loadCredentials: {
      try await Task.detached(priority: .userInitiated) {
        try KeychainBootstrap.loadOrCreate()
      }.value
    },
    makeGitHubDeviceAuth: { GitHubDeviceAuth() },
    presentDeviceAuthorization: { authorization in
      BridgeAppModel.copy(authorization.userCode)
      NSWorkspace.shared.open(authorization.verificationURL)
    },
    writeGitHubToken: { token in
      try await Task.detached(priority: .userInitiated) {
        try KeychainStore.write(token, account: KeychainStore.githubOAuthAccount)
      }.value
    },
    deleteGitHubToken: {
      try await Task.detached(priority: .userInitiated) {
        try KeychainStore.delete(account: KeychainStore.githubOAuthAccount)
      }.value
    },
    writeLocalAPIKey: { key in
      try await Task.detached(priority: .userInitiated) {
        try KeychainStore.write(key, account: KeychainStore.localAPIKeyAccount)
      }.value
    }
  )
}
