import CryptoKit
import Foundation

enum AnthropicMetadataUserIdentifier {
  private static let domainSeparator = Data(
    "CopilotBridge.AnthropicMetadataUserID.v1\0".utf8)

  /// Preserves compatible identifiers and replaces oversized values with a stable opaque value
  /// accepted by upstream APIs whose `user` field is limited to 64 bytes.
  static func upstreamValue(for userID: String) -> String {
    guard userID.utf8.count > 64 else { return userID }

    var hasher = SHA256()
    hasher.update(data: domainSeparator)
    hasher.update(data: Data(userID.utf8))
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
