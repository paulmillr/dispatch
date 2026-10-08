//! Shell startup wrappers that define typed-launch functions without editing any user file:
//! zsh ZDOTDIR wrapper files, a bash ENV rcfile, fish -C init. Port of c1654cc ssh-helper
//! startup.rs:115-238 + shell/bashrc; the caller writes `files` into a private directory
//! (`path`) that outlives the shell, and spawns `command`.
use std::ffi::OsString;
use std::path::Path;
use std::process::Command;

/// Function definitions injected into interactive shells: POSIX (zsh/bash) and fish.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Integration {
    pub posix: String,
    pub fish: String,
}

impl Integration {
    /// `program` typed in a shell runs `dispatch-helper launch <key> args`, unless the user
    /// already defines that name (same guard as the old herdr wrapper).
    pub fn typed(programs: &[(String, String)]) -> Self {
        let mut integration = Self::default();
        for (program, key) in programs {
            integration.posix.push_str(&format!(
                "if ! typeset -f {program} >/dev/null 2>&1 && ! alias {program} >/dev/null 2>&1; then\nfunction {program} {{ command \"$DISPATCH_SSH_HELPER\" launch {key} \"$@\"; }}\nfi\n"
            ));
            integration.fish.push_str(&format!(
                "if not functions -q {program}; function {program}; command $DISPATCH_SSH_HELPER launch {key} $argv; end; end\n"
            ));
        }
        integration
    }
}

const BASHRC: &str = include_str!("startup/bashrc");
const BASH_LAUNCH: &str = "if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then exec -a sh \"$SHELL\" --noprofile -il; else exec \"$SHELL\" --posix -il; fi";

/// The shell command plus the startup files it needs (name, bytes) in `path`. `env` reads the
/// helper's own environment (ZDOTDIR, ENV, HISTFILE, HOME), like the old code's std::env.
pub fn prepare(
    shell: &Path,
    home: &Path,
    path: &Path,
    helper: &Path,
    original: Option<&str>,
    integration: Option<&Integration>,
    env: &dyn Fn(&str) -> Option<OsString>,
) -> (Command, Vec<(String, Vec<u8>)>) {
    let mut files = Vec::new();
    let mut command = Command::new(shell);
    command
        .env("SHELL", shell)
        .env("TERM", "xterm-256color")
        .env_remove("DISPATCH_SSH_TOKEN")
        .env_remove("DISPATCH_SSH_SOCKET");
    let Some(integration) = integration else {
        if let Some(original) = original {
            command.arg("-c").arg(original);
        } else {
            command.arg("-l");
        }
        return (command, files);
    };
    command
        .env("DISPATCH_SSH_HELPER", helper)
        .env("DISPATCH_SSH_STARTUP", path);
    let posix = integration.posix.as_str();
    match shell.file_name().and_then(|name| name.to_str()) {
        Some("zsh") => {
            command.env(
                "DISPATCH_SSH_ZDOTDIR",
                env("ZDOTDIR").unwrap_or_else(|| home.as_os_str().into()),
            );
            for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"] {
                let history = if name == ".zshrc" {
                    "[[ ${HISTFILE-} == $DISPATCH_SSH_STARTUP/.zsh_history ]] && HISTFILE=$ZDOTDIR/.zsh_history\n"
                } else {
                    ""
                };
                let integration = if name == ".zshrc" || name == ".zlogin" {
                    posix
                } else {
                    ""
                };
                // Redirect only while another startup wrapper is needed. A persistent tmux
                // server must inherit the user's ZDOTDIR, not a private directory removed when
                // this shell exits. Leaving the user directory also lets zsh load .zlogout.
                let next = match name {
                    ".zshenv" => {
                        "if [[ -o interactive || -o login ]]; then ZDOTDIR=$DISPATCH_SSH_STARTUP; fi\n"
                    }
                    ".zprofile" => "ZDOTDIR=$DISPATCH_SSH_STARTUP\n",
                    ".zshrc" => "if [[ -o login ]]; then ZDOTDIR=$DISPATCH_SSH_STARTUP; fi\n",
                    _ => "",
                };
                let script = format!(
                    "ZDOTDIR=$DISPATCH_SSH_ZDOTDIR\n{history}[[ -r $ZDOTDIR/{name} ]] && source $ZDOTDIR/{name}\nDISPATCH_SSH_ZDOTDIR=${{ZDOTDIR:-$HOME}}\n{next}{integration}"
                );
                files.push((name.into(), script.into_bytes()));
            }
            command.env("ZDOTDIR", path);
            if let Some(original) = original {
                command.arg("-c").arg(format!("{posix}{original}"));
            } else {
                command.arg("-l");
            }
        }
        Some("bash") => {
            if let Some(original) = original {
                command.arg("-c").arg(format!("{posix}{original}"));
            } else {
                files.push((
                    "bashrc".into(),
                    BASHRC.replace("# DISPATCH_INTEGRATION", posix).into_bytes(),
                ));
                if let Some(original) = env("ENV") {
                    command
                        .env("DISPATCH_SSH_BASH_ENV", original)
                        .env("DISPATCH_SSH_BASH_ENV_SET", "1");
                } else {
                    command
                        .env_remove("DISPATCH_SSH_BASH_ENV")
                        .env_remove("DISPATCH_SSH_BASH_ENV_SET");
                }
                command.env("ENV", path.join("bashrc"));
                if env("HISTFILE").is_none() {
                    let home = env("HOME")
                        .map(std::path::PathBuf::from)
                        .unwrap_or_else(|| home.into());
                    command
                        .env("HISTFILE", home.join(".bash_history"))
                        .env("DISPATCH_SSH_BASH_HISTORY", "1");
                }
                command.args(["--noprofile", "--norc", "-p", "-c", BASH_LAUNCH]);
            }
        }
        Some("fish") => {
            if original.is_none() {
                command.arg("-l");
            }
            command.args(["-C", &integration.fish]);
            if let Some(original) = original {
                command.arg("-c").arg(original);
            }
        }
        _ => {
            if let Some(original) = original {
                command.arg("-c").arg(original);
            } else {
                command.arg("-l");
            }
        }
    }
    (command, files)
}
