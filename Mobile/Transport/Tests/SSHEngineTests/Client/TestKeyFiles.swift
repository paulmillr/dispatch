#if os(macOS)
import Foundation
@testable import SSHEngine

/// User key files `ssh-keygen` makes at test time (fictional, never kept: the directory is removed at once), parsed
/// with `KeyFile.parse`. One key per type and size per run.
enum TestKeyFiles {
  struct Made: @unchecked Sendable {
    let key: FileKey
    /// The `authorized_keys` line.
    let publicLine: String
  }

  private static let cache = Locked<[String: Made]>([:])
  private static let counter = Locked(0)

  static func parse(type: String, bits: Int? = nil) throws -> FileKey { try make(type: type, bits: bits).key }

  static func make(type: String, bits: Int? = nil) throws -> Made {
    let name = type + (bits.map { "-\($0)" } ?? "")
    if let made = cache.current[name] { return made }
    let number = counter.update { value -> Int in
      value += 1
      return value
    }
    let directory = URL(fileURLWithPath: "/tmp/sc-\(getpid())-\(number)")
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("key")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-q", "-t", type] + (bits.map { ["-b", String($0)] } ?? []) + ["-N", "", "-C", "", "-f", file.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    while process.isRunning { usleep(5_000) }
    guard process.terminationStatus == 0 else { throw LiveSSHD.Failure("ssh-keygen \(type) failed") }
    let bytes = try Data(contentsOf: file)
    let key = try KeyFile.parse(SecretBytes(copying: bytes))
    let made = Made(key: key, publicLine: key.authorizedKeysLine.trimmingCharacters(in: .whitespaces))
    cache.update { $0[name] = made }
    return made
  }
}
#endif
