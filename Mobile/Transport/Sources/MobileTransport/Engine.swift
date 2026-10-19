import DispatchMobileSSHCore
import Foundation

/// Glue to the Rust engine (Core/include/dispatch_mobile_ssh.h): context boxes and result codes.
enum Engine {
  static var version: String { String(cString: dms_version()) }

  /// Passes `box` to C retained; the callback that ends the operation takes it back with `release`.
  static func retain(_ box: AnyObject) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(box).toOpaque()
  }

  static func borrow<T: AnyObject>(_ context: UnsafeMutableRawPointer?, as type: T.Type) -> T {
    Unmanaged<T>.fromOpaque(context!).takeUnretainedValue()
  }

  static func release<T: AnyObject>(_ context: UnsafeMutableRawPointer?, as type: T.Type) -> T {
    Unmanaged<T>.fromOpaque(context!).takeRetainedValue()
  }

  static func error(_ code: Int32, _ message: UnsafePointer<CChar>?) -> SSHTransportError {
    let text = message.map { String(cString: $0) } ?? ""
    switch code {
    case DMS_TIMEOUT: return .timedOut(text.isEmpty ? "SSH" : text)
    case DMS_INVALID_KEY: return .invalidKey(text)
    case DMS_WRONG_PASSPHRASE: return .wrongPassphrase
    case DMS_CANCELLED: return .cancelled
    case DMS_UNSUPPORTED: return .unsupportedAuthentication(text)
    case DMS_CLOSED: return .channelClosed
    case DMS_REFUSED: return .commandFailed(status: -1, stderr: text)
    case DMS_NETWORK: return .network(text)
    default: return .protocolError(text)
    }
  }

  /// Overwrites `count` bytes at `pointer` with zeros in a way the optimizer keeps (`memset_s`): for copies of
  /// secrets (keyboard-interactive answers, passphrases) before their memory is freed.
  static func wipe(_ pointer: UnsafeMutableRawPointer?, count: Int) {
    guard let pointer, count > 0 else { return }
    _ = memset_s(pointer, count, 0, count)
  }

  static func methods(_ bits: UInt32) -> [String] {
    [(DMS_METHOD_PUBLICKEY, "publickey"), (DMS_METHOD_PASSWORD, "password"),
     (DMS_METHOD_KEYBOARD_INTERACTIVE, "keyboard-interactive"), (DMS_METHOD_HOSTBASED, "hostbased")]
      .filter { bits & $0.0 != 0 }.map(\.1)
  }
}

/// A `dms_reply *` answered later from Swift concurrency. Each is answered exactly once.
struct EngineReply: @unchecked Sendable {
  let pointer: OpaquePointer?

  func bool(_ value: Bool) { dms_reply_bool(pointer, value) }
  func cancel() { dms_reply_cancel(pointer) }
  func bytes(_ data: Data) {
    data.withUnsafeBytes { dms_reply_bytes(pointer, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
  }
  /// Keyboard-interactive answers: the C copies are wiped before they are freed (the engine wipes its own).
  func strings(_ values: [String]) {
    var copies = values.map { strdup($0) }
    defer {
      for copy in copies {
        if let copy { Engine.wipe(copy, count: strlen(copy)) }
        free(copy)
      }
    }
    copies.withUnsafeMutableBufferPointer { buffer in
      buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
        dms_reply_strings(pointer, $0, values.count)
      }
    }
  }
}

/// One-shot result slot for an operation's final callback.
final class Completion<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?
  private var result: Result<Value, any Error>?

  func finish(_ result: Result<Value, any Error>) {
    let continuation = lock.withLock { () -> CheckedContinuation<Value, any Error>? in
      guard self.result == nil else { return nil }
      self.result = result
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume(with: result)
  }

  var value: Value {
    get async throws {
      try await withCheckedThrowingContinuation { continuation in
        let ready = lock.withLock { () -> Result<Value, any Error>? in
          if result == nil { self.continuation = continuation }
          return result
        }
        if let ready { continuation.resume(with: ready) }
      }
    }
  }
}

func withCStrings<R>(_ a: String, _ b: String, _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> R) -> R {
  a.withCString { a in b.withCString { b in body(a, b) } }
}

extension Data {
  /// SSH wire string: u32 length then bytes.
  mutating func appendSSHString(_ bytes: Data) {
    var length = UInt32(bytes.count).bigEndian
    Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
    append(bytes)
  }
}
