import Foundation
import Security

struct KeychainRevision: Sendable, Equatable {
  let marker: Data

  static func fresh() -> KeychainRevision {
    KeychainRevision(marker: Data(UUID().uuidString.utf8))
  }
}

public enum KeychainStore {
  public static let service = "app.copilotbridge.credentials"
  public static let githubOAuthAccount = "github-oauth-token"
  public static let localAPIKeyAccount = "local-api-key"

  // Security.framework calls are synchronous. A recursive process-local lock lets
  // multi-step credential operations exclude other app writes
  // while still using the regular read/write helpers inside the transaction.
  private static let credentialLock = NSRecursiveLock()

  public static func read(account: String) throws -> String? {
    credentialLock.lock()
    defer { credentialLock.unlock() }
    return try readUnlocked(account: account)
  }

  private static func readUnlocked(account: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status) }
    guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
      throw KeychainError(errSecDecode)
    }
    return value
  }

  public static func write(_ value: String, account: String) throws {
    try write(value, account: account, revision: .fresh())
  }

  static func write(_ value: String, account: String, revision: KeychainRevision) throws {
    credentialLock.lock()
    defer { credentialLock.unlock() }
    try writeUnlocked(value, account: account, revision: revision)
  }

  private static func writeUnlocked(
    _ value: String,
    account: String,
    revision: KeychainRevision
  ) throws {
    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let updates: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrGeneric as String: revision.marker,
    ]

    let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
    try finishWrite(
      initialUpdateStatus: status,
      add: {
        var add = query
        add.merge(updates) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil)
      },
      retryUpdate: {
        SecItemUpdate(query as CFDictionary, updates as CFDictionary)
      }
    )
  }

  static func finishWrite(
    initialUpdateStatus: OSStatus,
    add: () -> OSStatus,
    retryUpdate: () -> OSStatus
  ) throws {
    if initialUpdateStatus == errSecItemNotFound {
      let addStatus = add()
      if addStatus == errSecDuplicateItem {
        // Another writer can create the item between our update and add. Retry
        // the update instead of surfacing a spurious duplicate-item failure.
        let retryStatus = retryUpdate()
        guard retryStatus == errSecSuccess else { throw KeychainError(retryStatus) }
      } else if addStatus != errSecSuccess {
        throw KeychainError(addStatus)
      }
    } else if initialUpdateStatus != errSecSuccess {
      throw KeychainError(initialUpdateStatus)
    }
  }

  public static func delete(account: String) throws {
    credentialLock.lock()
    defer { credentialLock.unlock() }
    try deleteUnlocked(account: account)
  }

  private static func deleteUnlocked(account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status)
    }
  }

  static func beginExclusiveCredentialAccess() {
    credentialLock.lock()
  }

  static func endExclusiveCredentialAccess() {
    credentialLock.unlock()
  }

  /// Restores a previous value only while the item still carries this operation's
  /// revision marker. The Keychain performs the match and update/delete atomically,
  /// so compensation cannot overwrite a newer writer from another process.
  static func restoreCredential(
    account: String,
    previousValue: String?,
    ifCurrentRevisionIs expectedRevision: KeychainRevision
  ) throws -> Bool {
    credentialLock.lock()
    defer { credentialLock.unlock() }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrGeneric as String: expectedRevision.marker,
    ]
    let status: OSStatus
    if let previousValue {
      let updates: [String: Any] = [
        kSecValueData as String: Data(previousValue.utf8),
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecAttrGeneric as String: KeychainRevision.fresh().marker,
      ]
      status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
    } else {
      status = SecItemDelete(query as CFDictionary)
    }
    if status == errSecItemNotFound { return false }
    guard status == errSecSuccess else { throw KeychainError(status) }
    return true
  }

  public static func generateLocalAPIKey() -> String {
    var bytes = [UInt8](repeating: 0, count: 24)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
      return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}

public struct KeychainBootstrapResult: Sendable, Equatable {
  public let localAPIKey: String
  public let hasGitHubCredential: Bool

  public init(localAPIKey: String, hasGitHubCredential: Bool) {
    self.localAPIKey = localAPIKey
    self.hasGitHubCredential = hasGitHubCredential
  }
}

public enum KeychainBootstrap {
  public static func loadOrCreate() throws -> KeychainBootstrapResult {
    try loadOrCreate(
      store: .keychain,
      generateLocalAPIKey: KeychainStore.generateLocalAPIKey
    )
  }

  static func loadOrCreate(
    store: KeychainBootstrapStore,
    generateLocalAPIKey: () -> String
  ) throws -> KeychainBootstrapResult {
    let localAPIKey: String
    if let saved = try store.readLocalAPIKey(), !saved.isEmpty {
      localAPIKey = saved
    } else {
      let generated = generateLocalAPIKey()
      guard !generated.isEmpty else { throw KeychainError(errSecParam) }
      // Do not return or publish a generated key until persistence succeeds.
      try store.writeLocalAPIKey(generated)
      localAPIKey = generated
    }

    let githubCredential = try store.readGitHubCredential()
    return KeychainBootstrapResult(
      localAPIKey: localAPIKey,
      hasGitHubCredential: githubCredential?.isEmpty == false
    )
  }
}

struct KeychainBootstrapStore: Sendable {
  let readLocalAPIKey: @Sendable () throws -> String?
  let writeLocalAPIKey: @Sendable (String) throws -> Void
  let readGitHubCredential: @Sendable () throws -> String?

  static let keychain = KeychainBootstrapStore(
    readLocalAPIKey: { try KeychainStore.read(account: KeychainStore.localAPIKeyAccount) },
    writeLocalAPIKey: { value in
      try KeychainStore.write(value, account: KeychainStore.localAPIKeyAccount)
    },
    readGitHubCredential: { try KeychainStore.read(account: KeychainStore.githubOAuthAccount) }
  )
}

public struct KeychainError: LocalizedError {
  public let status: OSStatus

  public init(_ status: OSStatus) {
    self.status = status
  }

  public var errorDescription: String? {
    (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain 错误 \(status)"
  }
}
