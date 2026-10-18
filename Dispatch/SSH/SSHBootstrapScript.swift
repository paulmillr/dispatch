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

    /// The bundled helper name (`darwin-universal`, `linux-aarch64`, `linux-x86_64`) for a probe's output.
    static func platform(_ output: String) -> Platform {
        let platforms = output.split(separator: "\n").filter { $0.hasPrefix("DISPATCH_PLATFORM=") }
        guard platforms.count == 1, let platform = platforms.first else { return .unidentified }
        switch platform {
        case "DISPATCH_PLATFORM=Darwin:arm64", "DISPATCH_PLATFORM=Darwin:x86_64": return .helper("darwin-universal")
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
        test ! -e dispatch-helper && test ! -L dispatch-helper || safe_file dispatch-helper || exit 1
        mkdir '\(staging)' || exit 1
        trap 'rm -f \(staging)/dispatch-helper; rmdir \(staging) 2>/dev/null' EXIT HUP INT TERM
        (set -C; cat > '\(staging)/dispatch-helper') || exit 1
        test "$(wc -c < '\(staging)/dispatch-helper' | tr -d ' ')" = '\(size)' || exit 1
        test "$(checksum '\(staging)/dispatch-helper')" = '\(digest)' || exit 1
        chmod 700 '\(staging)/dispatch-helper' || exit 1
        test ! -e dispatch-helper && test ! -L dispatch-helper || safe_file dispatch-helper || exit 1
        mv -f '\(staging)/dispatch-helper' dispatch-helper || exit 1
        \(verify(size: size, digest: digest))
        """
    }

    /// Every child is reached from an already checked working directory. Keeping
    /// cwd inside it prevents replacement of an ancestor redirecting an upload.
    /// Same-account processes are outside the helper's security boundary.
    static let privateDirectoryScript = """
    umask 077
    owner=$(id -u) || exit 1
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
      test -e "$1" || test -L "$1" || mkdir "$1" || return 1
      private_directory "$1" && cd -P "$1"
    }
    cd -P "$HOME" || exit 1
    set -- $(metadata .)
    test "$#" = 3 && test "$1" = "$owner" && test "$((0$2 & 022))" = 0 || exit 1
    test ! -L .dispatch || exit 1
    enter_private .dispatch || exit 1
    """

    static func cachePreamble(digest: String) -> String {
        precondition(digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        return privateDirectoryScript + """

        enter_private bin && enter_private versions && enter_private '\(digest)' || exit 1
        checksum() {
          if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
          elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d ' ' -f 1
          else return 1; fi
        }
        """
    }
}
