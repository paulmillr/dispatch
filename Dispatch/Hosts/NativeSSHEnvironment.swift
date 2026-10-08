import Foundation

/// Private startup files are scoped to this app instance. No user shell files or
/// backend configuration are edited, and unsupported shells still get PATH.
enum NativeSSHEnvironment {
    /// A server started from an ordinary terminal must receive the same private
    /// startup files as panes subsequently created through the native UI.
    static func tmuxFunction(fish: Bool) -> String {
        let variables = """
        "DISPATCH_NATIVE_STARTUP=$DISPATCH_HERDR_DIRECTORY/native" \\
        "ZDOTDIR=$DISPATCH_HERDR_DIRECTORY/native/zsh"
        """
        if fish {
            let definition = """

            function tmux
              set -l user_zdot $HOME
              if set -q ZDOTDIR; set user_zdot $ZDOTDIR; end
              if set -q DISPATCH_NATIVE_ZDOTDIR; set user_zdot $DISPATCH_NATIVE_ZDOTDIR; end
              set -l data_dirs /usr/local/share:/usr/share
              if set -q XDG_DATA_DIRS; set data_dirs $XDG_DATA_DIRS; end
              command env "DISPATCH_NATIVE_ZDOTDIR=$user_zdot" "XDG_DATA_DIRS=$DISPATCH_HERDR_DIRECTORY/native/share:$data_dirs" \\
                \(variables) tmux $argv
            end

            """
            return ShellCommandWrapper.preservingUserCommand("tmux", definition: definition, fish: true)
        }
        let definition = """

        function tmux {
          command env "DISPATCH_NATIVE_ZDOTDIR=${DISPATCH_NATIVE_ZDOTDIR:-${ZDOTDIR:-$HOME}}" \\
            "XDG_DATA_DIRS=$DISPATCH_HERDR_DIRECTORY/native/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" \\
            \(variables) tmux "$@"
        }

        """
        return ShellCommandWrapper.preservingUserCommand("tmux", definition: definition, fish: false)
    }

    static func install(in directory: URL, functions: [ShellCommandWrapper] = [.ssh]) throws {
        let fm = FileManager.default
        let zsh = directory.appendingPathComponent("native/zsh")
        let fish = directory.appendingPathComponent("native/share/fish/vendor_conf.d")
        try fm.createDirectory(at: zsh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: fish, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            var script = """
            ZDOTDIR=${DISPATCH_NATIVE_ZDOTDIR:-$HOME}
            if [[ -r "$ZDOTDIR/\(name)" && "$ZDOTDIR" != "$DISPATCH_NATIVE_STARTUP/zsh" ]]; then
              builtin source "$ZDOTDIR/\(name)"
            fi
            export DISPATCH_NATIVE_ZDOTDIR=$ZDOTDIR

            """
            if name == ".zshrc" || name == ".zlogin" { script += functions.map { $0.definition() }.joined() + tmuxFunction(fish: false) }
            if name == ".zshrc" {
                script += "if [[ -o login ]]; then ZDOTDIR=$DISPATCH_NATIVE_STARTUP/zsh; fi\n"
            } else if name != ".zlogin" { script += "ZDOTDIR=$DISPATCH_NATIVE_STARTUP/zsh\n" }
            try script.write(to: zsh.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try (functions.map { $0.definition(fish: true) }.joined() + tmuxFunction(fish: true)).write(to: fish.appendingPathComponent("dispatch-ssh.fish"), atomically: true, encoding: .utf8)
    }

    static func variables(directory: URL, inheriting environment: [String: String],
                          functions: [ShellCommandWrapper] = [.ssh]) -> [String: String] {
        let root = directory.appendingPathComponent("native").path
        let original = environment["DISPATCH_NATIVE_ZDOTDIR"] ?? environment["GHOSTTY_ZSH_ZDOTDIR"] ?? environment["ZDOTDIR"] ?? environment["HOME"] ?? NSHomeDirectory()
        var variables = ["DISPATCH_NATIVE_STARTUP": root, "DISPATCH_NATIVE_ZDOTDIR": original,
                "ZDOTDIR": root + "/zsh",
                "XDG_DATA_DIRS": root + "/share:" + (environment["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share")]
        variables.merge(bashFunctions(inheriting: environment, functions: functions), uniquingKeysWith: { _, new in new })
        return variables
    }

    static func bashFunctions(inheriting environment: [String: String],
                              functions: [ShellCommandWrapper] = [.ssh]) -> [String: String] {
        Dictionary(functions.map {
            ($0.bashVariable, environment[$0.bashVariable] ?? $0.bashFunction)
        }, uniquingKeysWith: { first, _ in first })
    }
}
