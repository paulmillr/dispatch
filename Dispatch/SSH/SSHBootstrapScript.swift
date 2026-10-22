import Foundation

/// The shell side of the helper install, shared by the Mac's `SSHBootstrap` (commands over `ssh -S`)
/// and the iPhone's transport (`Mobile/Transport`, an exec channel; compiled in through a symlink).
/// Foundation only: no app types.
enum SSHBootstrapScript {
    /// Prints one `DISPATCH_PLATFORM=<uname -s>:<uname -m>` line.
    static let probe = "printf 'DISPATCH_PLATFORM=%s:%s\\n' \"$(uname -s)\" \"$(uname -m)\""

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

    /// Run after `cachePreamble`: succeeds when the cached helper is the expected file.
    static func verify(size: Int, digest: String) -> String {
        "safe_file dispatch-helper && test -x dispatch-helper && test \"$(wc -c < dispatch-helper | tr -d ' ')\" = '\(size)' && test \"$(checksum dispatch-helper)\" = '\(digest)'"
    }

    /// Reads the helper from stdin into an exclusive private staging directory, checks its size and
    /// SHA-256 on the host, then renames it into place. The exclusive private staging directory prevents
    /// following a planted temporary link. Concurrent uploads publish whole files. Existing cache
    /// permissions are verified, never repaired by chmod.
    static func upload(digest: String, size: Int, staging: String) -> String {
        precondition(staging.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 })
        return """
        \(cachePreamble(digest: digest))
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
        """
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
    static let privateDirectoryScript = """
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
    cd -P "$HOME" || fail "no home folder"
    set -- $(metadata .)
    test "$#" = 3 && test "$1" = "$owner" && test "$((0$2 & 022))" = 0 || fail "home folder writable by others"
    enter_private .dispatch
    """

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

    static func cachePreamble(digest: String) -> String {
        precondition(digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        return privateDirectoryScript + """

        enter_private bin && enter_private versions && enter_private '\(digest)'
        command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || fail "no sha256sum or shasum"
        checksum() {
          if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
          elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d ' ' -f 1
          else return 1; fi
        }
        """
    }
}
