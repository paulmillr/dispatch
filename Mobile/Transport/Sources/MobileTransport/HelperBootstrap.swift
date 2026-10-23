import CryptoKit
import Foundation

/// Installs the Dispatch helper on a host over an exec channel: `SSHBootstrap.install` of the Mac app,
/// with the same shell (Dispatch/SSH/SSHBootstrapScript.swift, shared through a symlink) but streaming
/// the binary into a channel's stdin instead of an `ssh -S` process.
public enum HelperBootstrap: Sendable {
  /// Where the helper is installed on the host. `.home` is `~/.dispatch/bin/versions/<sha256>` (the Mac's cache too);
  /// `.runtimeDirectory` is `$XDG_RUNTIME_DIR/dispatch/bin/versions/<sha256>`, tried when the home folder cannot run
  /// programs (mounted noexec, or blocked by policy). Both are entered through the same private-folder checks; the runtime
  /// folder is emptied at logout, so a helper there is uploaded again after that.
  public enum Root: Sendable, Equatable, CaseIterable {
    case home
    case runtimeDirectory

    var script: SSHBootstrapScript.Root {
      switch self {
      case .home: .home
      case .runtimeDirectory: .runtimeDirectory
      }
    }
  }

  public struct Installed: Sendable, Equatable {
    /// Bundled helper name: `darwin-arm64`, `linux-aarch64` or `linux-x86_64`.
    public let platform: String
    public let digest: String
    public let size: Int
    /// The folder the helper is installed under.
    public let root: Root
    /// Path of the installed helper under its root's folder: `$HOME` for `.home`, `$XDG_RUNTIME_DIR` for
    /// `.runtimeDirectory`.
    public let relativePath: String
    /// False when an identical helper was already cached on the host.
    public let uploaded: Bool
    /// `$XDG_RUNTIME_DIR` as the probe saw it, when the helper may be installed there (`fallbackRoot`); nil when the host
    /// has none, or one that fails the private-folder checks.
    public let runtimeDirectory: String?

    /// `digest` is the binary's SHA-256 in 64 lowercase hex digits (the launch command refuses anything else).
    public init(platform: String, digest: String, size: Int, root: Root = .home, uploaded: Bool = true,
                runtimeDirectory: String? = nil) {
      self.platform = platform
      self.digest = digest
      self.size = size
      self.root = root
      relativePath = SSHBootstrapScript.relativePath(digest: digest, root: root.script)
      self.uploaded = uploaded
      self.runtimeDirectory = runtimeDirectory
    }

    /// The host path of the installed helper, for messages: `~/.dispatch/bin/versions/<sha256>/dispatch-helper`, or the
    /// runtime folder's (`$XDG_RUNTIME_DIR` when the probe did not name it).
    public var path: String {
      switch root {
      case .home: "~/" + relativePath
      case .runtimeDirectory: (runtimeDirectory ?? "$XDG_RUNTIME_DIR") + "/" + relativePath
      }
    }

    /// The folder holding the helper (`path` without its file name).
    var folder: String { String(path.dropLast("/dispatch-helper".count)) }
  }

  /// Probes the platform (and whether `$XDG_RUNTIME_DIR` could hold the helper), then uploads `<binaries>/<platform>`
  /// under `root` unless the digest-named cache there already holds it. The host checks size and SHA-256 before the
  /// rename. `environment` is set for every script (`env NAME=value`; a private `HOME` moves the install, as the test
  /// fixtures do, and so does `XDG_RUNTIME_DIR` for the runtime folder).
  ///
  /// A `.home` cache whose file is right but which cannot run programs (`SSHBootstrapScript.blocked`: a `/bin/sh` that
  /// asks the kernel, as bash and current dash do, already sees a noexec mount at `test -x`) moves on to
  /// `.runtimeDirectory` when the probe found it usable, so the result's `root` may differ from `root`; otherwise that is
  /// a bootstrap error with the `launchFailure` text for status 126. A shell that reads only the mode bits, or a policy
  /// that refuses the exec itself, installs at `.home` and learns it when the helper exits with 126 (`fallbackRoot`).
  public static func install(on connection: SSHConnection, binaries: URL, environment: [String: String] = [:],
                             root: Root = .home) async throws -> Installed {
    let shell = { (script: String) in posixShell(script, environment: environment) }
    let probe = try await connection.run(shell(SSHBootstrapScript.runtimeProbe))
    guard probe.status == 0 else { throw SSHTransportError.bootstrap("Could not use the authenticated SSH connection.") }
    let platform: String
    switch SSHBootstrapScript.platform(probe.text) {
    case .helper(let name): platform = name
    case .unidentified: throw SSHTransportError.bootstrap("Could not identify the SSH host platform.")
    case .unsupported: throw SSHTransportError.bootstrap("SSH integration requires Linux on ARM64 or x86-64, or macOS on Apple silicon.")
    }
    let runtimeDirectory = SSHBootstrapScript.runtimeDirectory(probe.text)
    let binary = try Data(contentsOf: binaries.appendingPathComponent(platform))
    guard !binary.isEmpty, binary.count <= SSHBootstrapScript.maximumSize else {
      throw SSHTransportError.bootstrap("SSH helper is missing or invalid.")
    }
    let digest = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
    var root = root
    while true {
      if root == .runtimeDirectory, runtimeDirectory == nil {
        throw SSHTransportError.bootstrap(
          "The host has no private runtime folder ($XDG_RUNTIME_DIR) to install the SSH helper in instead of its home folder.")
      }
      let installed = { (uploaded: Bool) in
        Installed(platform: platform, digest: digest, size: binary.count, root: root, uploaded: uploaded,
                  runtimeDirectory: runtimeDirectory)
      }
      if let uploaded = try await place(binary, digest: digest, root: root, on: connection, shell: shell) {
        return installed(uploaded)
      }
      // The folder cannot run programs: the runtime folder next, once.
      let blocked = installed(true)
      guard let next = fallbackRoot(after: 126, installed: blocked) else {
        throw SSHTransportError.bootstrap(launchFailure(status: 126, stderr: "", installed: blocked))
      }
      root = next
    }
  }

  /// Makes the cache under `root` hold the helper: false when it already did, true after an upload, nil when the file
  /// is there but the folder cannot run it (`SSHBootstrapScript.blocked`). An upload that broke off (or a cache the Mac
  /// was filling at the same moment) is checked and tried once more; a failure the script calls permanent (an unsafe
  /// folder, no checksum tool) is not.
  private static func place(_ binary: Data, digest: String, root: Root, on connection: SSHConnection,
                            shell: (String) -> String) async throws -> Bool? {
    let check = SSHBootstrapScript.cachePreamble(digest: digest, root: root.script) + "\n"
      + SSHBootstrapScript.verify(size: binary.count, digest: digest) + " && exit 0\n"
      + SSHBootstrapScript.blocked(size: binary.count, digest: digest) + "\nexit 1"
    var attempts = 0
    while true {
      let cached = try await connection.run(shell(check))
      if cached.status == 0 { return attempts > 0 }
      if cached.text.split(whereSeparator: \.isNewline).contains("DISPATCH_NOEXEC") { return nil }
      attempts += 1
      do {
        try await upload(binary, digest: digest, root: root, on: connection, shell: shell)
        return true
      } catch SSHTransportError.bootstrap(let message)
        where attempts < 2 && SSHBootstrapScript.transient(SSHBootstrapScript.reason(message)) {
        // "installed helper does not verify" is also how a noexec folder answers once the file is in place: the check
        // above tells the two apart.
      }
    }
  }

  /// One upload into a fresh staging folder; its failure carries the script's `dispatch-setup:` reason.
  private static func upload(_ binary: Data, digest: String, root: Root, on connection: SSHConnection,
                             shell: (String) -> String) async throws {
    let staging = "upload-" + UUID().uuidString.lowercased()
    let exec = try await connection.exec(
      shell(SSHBootstrapScript.upload(digest: digest, size: binary.count, staging: staging, root: root.script)))
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

  /// The helper's stdio command: enters `installed.root`'s folder through the private-folder checks, re-verifies the
  /// cached file, then execs it from its directory, with `environment` set (`env NAME=value` before the shell). Until
  /// that exec, stdout (the helper protocol's stream) is moved to stderr, so a check that fails (`dispatch-setup:
  /// <reason>`, status 1, which `launchFailure` reads) writes nothing where the client expects a frame.
  public static func launchCommand(_ installed: Installed, capabilities: String = "", environment: [String: String] = [:]) -> String {
    posixShell(
      "exec 3>&1 1>&2\n"
        + SSHBootstrapScript.cachePreamble(digest: installed.digest, root: installed.root.script) + "\n"
        + SSHBootstrapScript.verify(size: installed.size, digest: installed.digest)
        + " || { printf 'dispatch-setup: %s\\n' 'installed helper does not verify' >&2; exit 1; }\n"
        + "exec ./dispatch-helper --remote --capabilities " + shellQuote(capabilities) + " --stdio 1>&3 3>&-",
      environment: environment)
  }

  /// Text for a helper that exited before greeting, from its exit status (nil: a signal or a lost channel) and stderr:
  /// 126 is a folder that cannot run programs, 127 a helper that could not be started; otherwise the setup reason or the
  /// first lines of stderr, else a line with the status. Never empty.
  public static func launchFailure(status: Int32?, stderr: String, installed: Installed) -> String {
    let said = firstLines(stderr)
    switch status {
    case 126?:
      let instead = installed.root == .home && installed.runtimeDirectory == nil
        ? " The host has no private runtime folder ($XDG_RUNTIME_DIR) to install it in instead." : ""
      return "\(installed.folder) cannot run programs (the folder is mounted noexec or blocked by policy), so the helper cannot start there." + instead
    case 127?:
      return "The helper at \(installed.path) could not be started" + (said.map { ": " + $0 } ?? ".")
    default:
      if let reason = SSHBootstrapScript.reason(stderr) {
        return "Could not start the helper at \(installed.path): \(SSHBootstrapScript.printable(reason))."
      }
      if let said { return "The helper stopped before it answered: " + said }
      if let status { return "The helper stopped before it answered (exit status \(status))." }
      return "The helper stopped before it answered (no exit status: it was killed or the channel closed)."
    }
  }

  /// The root to try next after a launch failed at `installed.root` with `status`: `.runtimeDirectory` after a 126 (the
  /// folder cannot run programs) at `.home` when the probe saw a usable `$XDG_RUNTIME_DIR`, else nil.
  public static func fallbackRoot(after status: Int32?, installed: Installed) -> Root? {
    status == 126 && installed.root == .home && installed.runtimeDirectory != nil ? .runtimeDirectory : nil
  }

  /// Up to three non-empty lines of `text`, control characters dropped, at most 300 characters; nil when nothing is left.
  private static func firstLines(_ text: String) -> String? {
    let lines = text.split(whereSeparator: \.isNewline)
      .map { String($0.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }).trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }.prefix(3)
    let joined = lines.joined(separator: " / ")
    guard !joined.isEmpty else { return nil }
    return joined.count > 300 ? String(joined.prefix(299)) + "…" : joined
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
