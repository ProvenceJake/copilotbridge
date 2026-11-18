import Foundation
import Security
import XCTest

@testable import CopilotBridgeCore

final class KeychainBootstrapTests: XCTestCase {
  func testExistingPersistedKeyIsReturnedWithoutWriting() throws {
    let didWrite = MutableBox(false)
    let result = try KeychainBootstrap.loadOrCreate(
      store: KeychainBootstrapStore(
        readLocalAPIKey: { "persisted-local-key" },
        writeLocalAPIKey: { _ in didWrite.value = true },
        readGitHubCredential: { "github-token" }),
      generateLocalAPIKey: { "unused-generated-key" })

    XCTAssertEqual(result.localAPIKey, "persisted-local-key")
    XCTAssertTrue(result.hasGitHubCredential)
    XCTAssertFalse(didWrite.value)
  }

  func testGeneratedKeyIsReturnedOnlyAfterPersistenceSucceeds() throws {
    let persisted = MutableBox<String?>(nil)
    let result = try KeychainBootstrap.loadOrCreate(
      store: KeychainBootstrapStore(
        readLocalAPIKey: { nil },
        writeLocalAPIKey: { persisted.value = $0 },
        readGitHubCredential: { nil }),
      generateLocalAPIKey: { "generated-local-key" })

    XCTAssertEqual(persisted.value, "generated-local-key")
    XCTAssertEqual(result.localAPIKey, "generated-local-key")
    XCTAssertFalse(result.hasGitHubCredential)
  }

  func testPersistenceFailureNeverReturnsTemporaryGeneratedKey() {
    let githubReadAttempted = MutableBox(false)
    var returnedKey: String?

    do {
      let result = try KeychainBootstrap.loadOrCreate(
        store: KeychainBootstrapStore(
          readLocalAPIKey: { nil },
          writeLocalAPIKey: { _ in throw KeychainError(errSecInteractionNotAllowed) },
          readGitHubCredential: {
            githubReadAttempted.value = true
            return nil
          }),
        generateLocalAPIKey: { "temporary-unpersisted-key" })
      returnedKey = result.localAPIKey
      XCTFail("Expected persistence failure")
    } catch {
      XCTAssertEqual((error as? KeychainError)?.status, errSecInteractionNotAllowed)
    }

    XCTAssertNil(returnedKey)
    XCTAssertFalse(githubReadAttempted.value)
  }

  func testWriteRetriesUpdateWhenConcurrentAddWinsRace() throws {
    let addCalls = MutableBox(0)
    let retryCalls = MutableBox(0)

    try KeychainStore.finishWrite(
      initialUpdateStatus: errSecItemNotFound,
      add: {
        addCalls.value += 1
        return errSecDuplicateItem
      },
      retryUpdate: {
        retryCalls.value += 1
        return errSecSuccess
      })

    XCTAssertEqual(addCalls.value, 1)
    XCTAssertEqual(retryCalls.value, 1)
  }

  func testWriteSurfacesFailedRetryAfterConcurrentAdd() {
    XCTAssertThrowsError(
      try KeychainStore.finishWrite(
        initialUpdateStatus: errSecItemNotFound,
        add: { errSecDuplicateItem },
        retryUpdate: { errSecAuthFailed })
    ) {
      XCTAssertEqual(($0 as? KeychainError)?.status, errSecAuthFailed)
    }
  }
}

private final class MutableBox<Value>: @unchecked Sendable {
  var value: Value

  init(_ value: Value) {
    self.value = value
  }
}
