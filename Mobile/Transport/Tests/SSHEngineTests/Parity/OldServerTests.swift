import Foundation
import MobileTransport
import XCTest
@testable import SSHEngine

/// A server without strict key exchange (OpenSSH before 9.6, Dropbear before 2024.84) through the public API, on each
/// engine (`SSHTransportEngine.preferred`, restored after): with ChaCha20-Poly1305 and AES-CTR offered, the Swift
/// engine's order settles on AES-CTR with hmac-sha2-256 and logs in; a server with nothing but truncatable modes is
/// refused with one sentence the user can act on, naming the mode (`incompatibleServer`, final for the host). russh
/// connects to that server (checked in a `DISPATCH_RUSSH` build). A server with no algorithm in common is
/// `incompatibleServer` on every engine, with the same sentence.
final class OldServerTests: XCTestCase {
  private func on<T>(_ engine: SSHTransportEngine, _ body: () async throws -> T) async rethrows -> T {
    let saved = SSHTransportEngine.preferred
    SSHTransportEngine.preferred = engine
    defer { SSHTransportEngine.preferred = saved }
    return try await body()
  }

  private func oldServer(ciphers: [CipherAlgorithm], macs: [MACAlgorithm]) throws -> ParityServer {
    try ParityServer.start(self, clean: false) {
      $0.strict = false
      $0.ciphers = ciphers.map(\.rawValue)
      $0.macs = macs.map(\.rawValue)
    }
  }

  func testDropbearLikeOffersLogInOverAESCTRWithAPlainMAC() async throws {
    for engine in SSHTransportEngine.allCases {
      let server = try oldServer(ciphers: [.chacha20Poly1305, .aes128CTR, .aes256CTR], macs: [.hmacSHA256])
      try await on(engine) {
        let connection = try await server.loggedIn()
        let echo = try await connection.run("echo")
        XCTAssertEqual(echo.text, "hello", "\(engine)")
        await connection.close()
      }
    }
  }

  func testOnlyTruncatableModesAreRefusedInPlainWords() async throws {
    let cases: [([CipherAlgorithm], [MACAlgorithm], String)] = [
      ([.chacha20Poly1305], [.hmacSHA256], "chacha20-poly1305@openssh.com"),
      ([.aes128CTR], [.hmacSHA256ETM], "aes128-ctr with hmac-sha2-256-etm@openssh.com"),
    ]
    for (ciphers, macs, mode) in cases {
      let server = try oldServer(ciphers: ciphers, macs: macs)
      await on(.swift) {
        do {
          let connection = try await server.loggedIn()
          await connection.close()
          XCTFail("\(mode): connected")
        } catch {
          let sentence = "The server's SSH is too old for a safe connection (it offers \(mode) without strict key "
            + "exchange); update the SSH server."
          XCTAssertEqual(error as? SSHTransportError, .incompatibleServer(sentence), mode)
          XCTAssertEqual((error as? SSHTransportError)?.errorDescription, sentence)
          XCTAssertTrue(HostConnectionPolicy.refused(error), "\(mode): retried")
        }
      }
      #if DISPATCH_RUSSH
      // The same server on russh (no such rule): it connects.
      let russh = try oldServer(ciphers: ciphers, macs: macs)
      try await on(.russh) {
        let connection = try await russh.loggedIn()
        await connection.close()
      }
      #endif
      XCTAssertEqual(server.trust.asked.value, [], "\(mode): refused before the host key question")
    }
  }

  /// No common algorithm in a category: the same final error and sentence on both engines (russh's "No common Cipher
  /// algorithm - ours: …" text mapped by `RusshEngine.error`).
  func testNoCommonAlgorithmIsTheSameFinalRefusalOnBothEngines() async throws {
    let cases: [((inout ScriptedServer.Configuration) -> Void, String)] = [
      ({ $0.ciphers = ["fictional-cipher@example.invalid"] }, "cipher"),
      ({ $0.keyExchange = ["fictional-kex@example.invalid"] }, "key exchange"),
    ]
    for (configure, category) in cases {
      for engine in SSHTransportEngine.allCases {
        let server = try ParityServer.start(self, clean: false, transport: configure)
        await on(engine) {
          do {
            let connection = try await server.loggedIn()
            await connection.close()
            XCTFail("\(engine) \(category): connected")
          } catch {
            let sentence = "The server offers no \(category) algorithm this app accepts; update the SSH server or enable a "
              + "current \(category) algorithm on it."
            XCTAssertEqual(error as? SSHTransportError, .incompatibleServer(sentence), "\(engine) \(category)")
            XCTAssertTrue(HostConnectionPolicy.refused(error), "\(engine) \(category): retried")
          }
        }
      }
    }
  }
}
