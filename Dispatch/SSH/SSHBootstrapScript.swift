import Foundation

/// The shell side of the helper install, shared by the Mac's `SSHBootstrap` (commands over `ssh -S`)
/// and the iPhone's transport (`Mobile/Transport`, an exec channel; compiled in through a symlink).
/// Foundation only: no app types.
enum SSHBootstrapScript {
    /// Prints one `DISPATCH_PLATFORM=<uname -s>:<uname -m>` line.
    static let probe = "printf 'DISPATCH_PLATFORM=%s:%s\\n' \"$(uname -s)\" \"$(uname -m)\""

    /// The runtime-folder probe (the iPhone's on every connection, the Mac's only once `~/.dispatch` proved unable to
    /// run programs; the Mac's other connections send `probe` alone): `probe`, then a `DISPATCH_RUNTIME=<$XDG_RUNTIME_DIR>` line when the helper could be installed
    /// in the runtime folder instead of `~/.dispatch` (`runtimeDirectory(_:)`): the folder is set, absolute, owned by the
    /// account with mode 0700, and `dispatch` in it, if it exists, is a private folder and not a link. It writes nothing:
    /// `dispatch` is made only by an install there (`runtimeEntry`). Whether the folder may run programs is learnt only by
    /// installing or starting the helper. `platform(_:)` reads the `DISPATCH_PLATFORM=` line only, whatever else the
    /// output holds.
    static let runtimeProbe = probe + """

    if (
    \(privateFunctions)
    case "$XDG_RUNTIME_DIR" in /*) ;; *) fail "no runtime folder (XDG_RUNTIME_DIR)";; esac
    cd -P "$XDG_RUNTIME_DIR" || fail "cannot enter the runtime folder"
    private_directory . || fail "runtime folder not private"
    if test -e dispatch || test -L dispatch; then private_directory dispatch || fail "unsafe folder dispatch"; fi
    ) >/dev/null 2>&1; then printf 'DISPATCH_RUNTIME=%s\\n' "$XDG_RUNTIME_DIR"; fi
    """

    /// The runtime folder a `runtimeProbe` found usable, if any: its one `DISPATCH_RUNTIME=` line, an absolute path.
    static func runtimeDirectory(_ output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("DISPATCH_RUNTIME=") }
        guard lines.count == 1, let line = lines.first else { return nil }
        let path = String(line.dropFirst("DISPATCH_RUNTIME=".count))
        return path.hasPrefix("/") && path.utf8.count <= 4096 && !path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
            ? path : nil
    }

    /// Where the helper cache lives: `~/.dispatch` (`.home`), or `$XDG_RUNTIME_DIR/dispatch` (`.runtimeDirectory`), which
    /// both apps try when the home folder cannot run programs (mounted noexec; the Mac only for grants without agent
    /// hooks). The runtime folder is emptied at logout, so a helper there is uploaded again after that.
    enum Root: Equatable {
        case home
        case runtimeDirectory
    }

    /// The largest helper either app uploads.
    static let maximumSize = 32 * 1024 * 1024

    enum Platform: Equatable {
        case helper(String)
        case unsupported
        case unidentified
    }

    /// The bundled helper name (`darwin-arm64`, `linux-aarch64`, `linux-x86_64`) for a probe's output.
    static func platform(_ output: String) -> Platform {
        let platforms = output.split(separator: "\n").filter { $0.hasPrefix("DISPATCH_PLATFORM=") }
        guard platforms.count == 1, let platform = platforms.first else { return .unidentified }
        switch platform {
        // Apple silicon only: an Intel Mac is unsupported and keeps plain SSH.
        case "DISPATCH_PLATFORM=Darwin:arm64": return .helper("darwin-arm64")
        case "DISPATCH_PLATFORM=Linux:aarch64", "DISPATCH_PLATFORM=Linux:arm64": return .helper("linux-aarch64")
        case "DISPATCH_PLATFORM=Linux:x86_64": return .helper("linux-x86_64")
        default: return .unsupported
        }
    }

    /// The helper's path under `$HOME`.
    static func relativePath(digest: String) -> String {
        ".dispatch/bin/versions/" + digest + "/dispatch-helper"
    }

    /// The helper's path under its root's folder: `$HOME` (`relativePath(digest:)`) or `$XDG_RUNTIME_DIR`.
    static func relativePath(digest: String, root: Root) -> String {
        switch root {
        case .home: relativePath(digest: digest)
        case .runtimeDirectory: "dispatch/bin/versions/" + digest + "/dispatch-helper"
        }
    }

    /// Run after `cachePreamble`: succeeds when the cached helper is the expected file.
    static func verify(size: Int, digest: String) -> String {
        "safe_file dispatch-helper && test -x dispatch-helper && test \"$(wc -c < dispatch-helper | tr -d ' ')\" = '\(size)' && test \"$(checksum dispatch-helper)\" = '\(digest)'"
    }

    /// Run after `cachePreamble` when `verify` failed: prints `DISPATCH_NOEXEC` when the cached helper is the expected file,
    /// owned by the account with mode 0700, and only `test -x` refuses it. That is a folder that cannot run programs:
    /// mounted noexec (the kernel's `access(X_OK)` says so where `/bin/sh` asks it, as bash and current dash do; a shell
    /// that reads only the mode bits lets the exec itself fail, status 126) or blocked by policy. It also dates the file
    /// (`touch -c`): no helper runs from this folder to mark the version used, and the helper's cleanup removes a version
    /// folder nothing changed for a day, which would cost an upload to learn the same again.
    static func blocked(size: Int, digest: String) -> String {
        "safe_file dispatch-helper && set -- $(metadata dispatch-helper) && test \"$2\" = 700 && test \"$(wc -c < dispatch-helper | tr -d ' ')\" = '\(size)' && test \"$(checksum dispatch-helper)\" = '\(digest)' && ! test -x dispatch-helper && touch -c dispatch-helper && printf 'DISPATCH_NOEXEC\\n'"
    }

    /// The cache check both apps send: succeeds when the cached helper under `root` is the expected file; otherwise
    /// prints `DISPATCH_NOEXEC` when it is but the folder cannot run it (`blocked`), and fails (status 1, or a preamble
    /// failure's reason).
    static func cacheCheck(size: Int, digest: String, root: Root = .home) -> String {
        cachePreamble(digest: digest, root: root) + "\n" + verify(size: size, digest: digest)
            + " && exit 0\n" + blocked(size: size, digest: digest) + "\nexit 1"
    }

    /// Whether a cache check's output names a folder that cannot run programs.
    static func blocked(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains("DISPATCH_NOEXEC")
    }

    /// Reads the helper from stdin into an exclusive private staging directory, checks its size and
    /// SHA-256 on the host, then renames it into place. The exclusive private staging directory prevents
    /// following a planted temporary link. Concurrent uploads publish whole files. Existing cache
    /// permissions are verified, never repaired by chmod.
    static func upload(digest: String, size: Int, staging: String, root: Root = .home) -> String {
        precondition(staging.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 })
        return """
        \(cachePreamble(digest: digest, root: root))
        test ! -e dispatch-helper && test ! -L dispatch-helper || safe_file dispatch-helper || fail "unsafe cached helper"
        mkdir '\(staging)' || fail "cannot create the upload folder"
        trap 'rm -f \(staging)/dispatch-helper; rmdir \(staging) 2>/dev/null' EXIT HUP INT TERM
        (set -C; cat > '\(staging)/dispatch-helper') || fail "upload interrupted"
        test "$(wc -c < '\(staging)/dispatch-helper' | tr -d ' ')" = '\(size)' || fail "upload incomplete"
        test "$(checksum '\(staging)/dispatch-helper')" = '\(digest)' || fail "upload checksum mismatch"
        chmod 700 '\(staging)/dispatch-helper' || fail "cannot make the helper executable"
        test ! -e dispatch-helper && test ! -L dispatch-helper || safe_file dispatch-helper || fail "unsafe cached helper"
        mv -f '\(staging)/dispatch-helper' dispatch-helper || fail "cannot install the helper"
        \(verify(size: size, digest: digest)) || fail "installed helper does not verify"
        """ + (root == .home ? "" : "\n" + pruneRuntimeVersions(keeping: digest))
    }

    /// After an upload into the runtime folder (which no helper's cleanup visits): other versions' folders there that
    /// nothing changed for a day. A helper still running from one keeps running; the next start of that version uploads
    /// it again. Never follows links; a folder it cannot remove stays.
    static func pruneRuntimeVersions(keeping digest: String) -> String {
        "find .. -mindepth 1 -maxdepth 1 -type d -name '" + String(repeating: "?", count: 64) + "' ! -name '" + digest
            + "' -mtime +0 -exec rm -rf {} + 2>/dev/null || :"
    }

    /// Every child is reached from an already checked working directory. Keeping
    /// cwd inside it prevents replacement of an ancestor redirecting an upload.
    /// Same-account processes are outside the helper's security boundary.
    ///
    /// Folders are created, then checked: other Dispatch commands create the same ones at the same moment (a login and
    /// the publish step releasing it, two first connections to a host, the Mac and the iPhone), so a folder that
    /// already exists is not a failure, and whatever is there must pass the same owner and mode check. Never "check,
    /// then create": that loses those races (`SSHBootstrapScriptTests` keeps the pattern out).
    ///
    /// Every failure says why with `fail`: one `dispatch-setup: <reason>` line on stdout, which the app and the login
    /// read, and on stderr, which the iPhone and a person read.
    static let privateDirectoryScript = privateFunctions + "\n" + """
    cd -P "$HOME" || fail "no home folder"
    set -- $(metadata .)
    test "$#" = 3 && test "$1" = "$owner" && test "$((0$2 & 022))" = 0 || fail "home folder writable by others"
    enter_private .dispatch
    """

    /// `privateDirectoryScript`'s checks and functions, without entering a folder.
    static let privateFunctions = """
    umask 077
    fail() {
      printf 'dispatch-setup: %s\\n' "$*"
      printf 'dispatch-setup: %s\\n' "$*" >&2
      exit 1
    }
    owner=$(id -u) || fail "cannot read the account id"
    if test "$(uname -s)" = Darwin; then
      metadata() { stat -f '%u %Lp %l' "$1"; }
    else
      metadata() { stat -c '%u %a %h' "$1"; }
    fi
    private_directory() {
      test ! -L "$1" && test -d "$1" || return 1
      set -- $(metadata "$1")
      test "$#" = 3 && test "$1" = "$owner" && test "$2" = 700
    }
    safe_file() {
      test ! -L "$1" && test -f "$1" || return 1
      set -- $(metadata "$1")
      test "$#" = 3 && test "$1" = "$owner" && test "$3" = 1 || return 1
      case "$2" in 600|700) return 0;; *) return 1;; esac
    }
    enter_private() {
      mkdir "$1" 2>/dev/null
      if ! private_directory "$1"; then
        if test -e "$1" || test -L "$1"; then fail "unsafe folder $1"; else fail "cannot create folder $1"; fi
      fi
      cd -P "$1" || fail "cannot enter folder $1"
    }
    """

    /// Enters `$XDG_RUNTIME_DIR/dispatch`: the runtime folder must be absolute, owned by the account and 0700 (as the XDG
    /// base directory specification and systemd make it), and `dispatch` in it passes `enter_private`.
    static let runtimeEntry = """
    case "$XDG_RUNTIME_DIR" in /*) ;; *) fail "no runtime folder (XDG_RUNTIME_DIR)";; esac
    cd -P "$XDG_RUNTIME_DIR" || fail "cannot enter the runtime folder"
    private_directory . || fail "runtime folder not private"
    enter_private dispatch
    """

    /// The private-folder checks, then the root's folder (`~/.dispatch` or `$XDG_RUNTIME_DIR/dispatch`) entered.
    static func privateDirectoryScript(root: Root) -> String {
        switch root {
        case .home: privateDirectoryScript
        case .runtimeDirectory: privateFunctions + "\n" + runtimeEntry
        }
    }

    /// The reason a setup command gave (`dispatch-setup: <reason>`, its last such line), if it gave one.
    static func reason(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).last { $0.hasPrefix("dispatch-setup: ") }
            .map { String($0.dropFirst("dispatch-setup: ".count)) }
    }

    /// Reasons another attempt can fix: the upload broke off or the file changed under it. Everything else (an unsafe
    /// or uncreatable folder, no checksum tool) fails the same way again. A failure that gave no reason (the SSH
    /// channel dropped, a signal) is worth one more attempt too.
    static func transient(_ reason: String?) -> Bool {
        guard let reason else { return true }
        return ["upload interrupted", "upload incomplete", "upload checksum mismatch", "cannot install the helper",
                "installed helper does not verify", "cannot create the upload folder"].contains(reason)
    }

    /// A reason as it may travel to the login and onto the terminal: letters, digits and plain punctuation, bounded.
    static func printable(_ reason: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,:;_/()-")
        let kept = String(reason.filter { allowed.contains($0) }.prefix(160)).trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? "unknown reason" : kept
    }

    static func cachePreamble(digest: String, root: Root = .home) -> String {
        precondition(digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        return privateDirectoryScript(root: root) + """

        enter_private bin && enter_private versions && enter_private '\(digest)'
        command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || fail "no sha256sum or shasum"
        checksum() {
          if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
          elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d ' ' -f 1
          else return 1; fi
        }
        """
    }

    // MARK: A helper that exited before it greeted

    /// Text for a helper that exited before it answered `hello`, the same on the Mac and the iPhone, from its exit
    /// status (nil: a signal or a lost connection) and stderr. 126 is a folder that cannot run programs (for `.home`
    /// without a usable runtime folder, `runtimeDirectory` nil, it says so), 127 a helper that could not be started;
    /// otherwise the setup's `dispatch-setup:` reason, else the first lines of stderr, else a line with the status. Never
    /// empty; letters and plain punctuation only, so `printable` keeps it whole (at most 160 characters but stderr).
    static func launchFailure(status: Int32?, stderr: String, root: Root, runtimeDirectory: String?) -> String {
        let said = firstLines(stderr)
        switch status {
        case 126?:
            return folderCannotRunPrograms(root)
                + (root == .home && runtimeDirectory == nil ? " No private runtime folder (XDG_RUNTIME_DIR) to use instead." : "")
        case 127?:
            return "The helper could not be started" + (said.map { ": " + $0 } ?? ".")
        default:
            if let reason = reason(stderr) { return "Could not start the helper: " + printable(reason) + "." }
            if let said { return "The helper stopped before it answered: " + said }
            if let status { return "The helper stopped before it answered (exit status \(status))." }
            return "The helper stopped before it answered (no exit status: it was killed or the connection closed)."
        }
    }

    /// "The home folder cannot run programs …" (or the runtime folder's).
    static func folderCannotRunPrograms(_ root: Root) -> String {
        (root == .home ? "The home folder" : "The runtime folder (XDG_RUNTIME_DIR)")
            + " cannot run programs (noexec mount or policy), so the helper cannot start there."
    }

    /// Up to three non-empty lines of `text`, control characters dropped, at most 300 characters; nil when nothing is left.
    static func firstLines(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { String($0.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(3)
        let joined = lines.joined(separator: " / ")
        guard !joined.isEmpty else { return nil }
        return joined.count > 300 ? String(joined.prefix(297)) + "..." : joined
    }
}
