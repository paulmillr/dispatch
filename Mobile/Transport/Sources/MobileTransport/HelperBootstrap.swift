import CryptoKit
import Foundation

/// Installs the Dispatch helper on a host over an exec channel: `SSHBootstrap.install` of the Mac app,
/// with the same shell (Dispatch/SSH/SSHBootstrapScript.swift, shared through a symlink) but streaming
/// the binary into a channel's stdin instead of an `ssh -S` process.
public enum HelperBootstrap: Sendable {
  public struct Installed: Sendable, Equatable {
    /// Bundled helper name: `darwin-arm64`, `linux-aarch64` or `linux-x86_64`.
    public let platform: String
    public let digest: String
    public let size: Int
    /// `~`-relative path of the installed helper.
    public let relativePath: String
    /// False when an identical helper was already cached on the host.
    public let uploaded: Bool
  }

  /// Probes the platform, then uploads `<binaries>/<platform>` unless the digest-named cache already
  /// holds it. The host checks size and SHA-256 before the rename. `environment` is set for every script
  /// (`env NAME=value`; a private `HOME` moves the install, as the test fixtures do).
  public static func install(on connection: SSHConnection, binaries: URL, environment: [String: String] = [:]) async throws -> Installed {
    let shell = { (script: String) in posixShell(script, environment: environment) }
    let probe = try await connection.run(shell(SSHBootstrapScript.probe))
    guard probe.status == 0 else { throw SSHTransportError.bootstrap("Could not use the authenticated SSH connection.") }
    let platform: String
    switch SSHBootstrapScript.platform(probe.text) {
    case .helper(let name): platform = name
    case .unidentified: throw SSHTransportError.bootstrap("Could not identify the SSH host platform.")
    case .unsupported: throw SSHTransportError.bootstrap("SSH integration requires Linux on ARM64 or x86-64, or macOS on Apple silicon.")
    }
    let binary = try Data(contentsOf: binaries.appendingPathComponent(platform))
    guard !binary.isEmpty, binary.count <= SSHBootstrapScript.maximumSize else {
      throw SSHTransportError.bootstrap("SSH helper is missing or invalid.")
    }
    let digest = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
    let installed = { (uploaded: Bool) in
      Installed(platform: platform, digest: digest, size: binary.count,
                relativePath: SSHBootstrapScript.relativePath(digest: digest), uploaded: uploaded)
    }
    let verify = SSHBootstrapScript.verify(size: binary.count, digest: digest)
    if try await connection.run(shell(SSHBootstrapScript.cachePreamble(digest: digest) + "\n" + verify)).status == 0 {
      return installed(false)
    }
    // An upload that broke off (or a cache the Mac was filling at the same moment) is tried once more; a failure the
    // script calls permanent (an unsafe folder, no checksum tool) is not.
    do {
      try await upload(binary, digest: digest, on: connection, shell: shell)
    } catch SSHTransportError.bootstrap(let message) where SSHBootstrapScript.transient(SSHBootstrapScript.reason(message)) {
      try await upload(binary, digest: digest, on: connection, shell: shell)
    }
    return installed(true)
  }

  /// One upload into a fresh staging folder; its failure carries the script's `dispatch-setup:` reason.
  private static func upload(_ binary: Data, digest: String, on connection: SSHConnection,
                             shell: (String) -> String) async throws {
    let staging = "upload-" + UUID().uuidString.lowercased()
    let exec = try await connection.exec(shell(SSHBootstrapScript.upload(digest: digest, size: binary.count, staging: staging)))
    async let output = collect(exec)
    var offset = 0
    do {
      while offset < binary.count {
        let end = min(offset + (1 << 20), binary.count)
        try await exec.write(binary.subdata(in: offset..<end))
        offset = end
      }
      try await exec.finishInput()
    } catch {
      // The script exits early on a check failure; its status explains more than the write error.
      _ = try? await output
      throw error
    }
    let stderr = try await output
    let status = try await exec.exitStatus()
    guard status == 0 else {
      throw SSHTransportError.bootstrap("Could not install the SSH helper in the remote cache (\(status)):\n" + stderr)
    }
  }

  /// The helper's stdio command: re-verifies the cached file, then execs it from its directory, with
  /// `environment` set (`env NAME=value` before the shell).
  public static func launchCommand(_ installed: Installed, capabilities: String = "", environment: [String: String] = [:]) -> String {
    posixShell(
      SSHBootstrapScript.cachePreamble(digest: installed.digest) + "\n"
        + SSHBootstrapScript.verify(size: installed.size, digest: installed.digest) + " || exit 1\n"
        + "exec ./dispatch-helper --remote --capabilities " + shellQuote(capabilities) + " --stdio",
      environment: environment)
  }

  private static func collect(_ exec: SSHExec) async throws -> String {
    var stderr = Data()
    for try await output in exec {
      if case .stderr(let data) = output, stderr.count < 65_536 { stderr.append(data) }
    }
    return String(decoding: stderr, as: UTF8.self)
  }
}

/// The scripts are POSIX sh: the account's login shell (zsh on macOS: no octal `0700` in arithmetic)
/// only execs /bin/sh, as the Mac's `SSHMaster.arguments(command:)` does. The helper stays a direct
/// child of sshd.
/// `environment` goes in front through `env` (names are `[A-Za-z_][A-Za-z0-9_]*`; others are dropped).
func posixShell(_ script: String, environment: [String: String] = [:]) -> String {
  let assignments = environment.sorted { $0.key < $1.key }.filter { isEnvironmentName($0.key) }
    .map { $0.key + "=" + shellQuote($0.value) }
  let prefix = assignments.isEmpty ? "exec " : "exec env " + assignments.joined(separator: " ") + " "
  return prefix + "/bin/sh -c " + shellQuote(script)
}

func isEnvironmentName(_ name: String) -> Bool {
  guard let first = name.utf8.first, first == 95 || (65...90).contains(first) || (97...122).contains(first) else { return false }
  return name.utf8.allSatisfy { $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
}

func shellQuote(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
