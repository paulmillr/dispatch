//! Ordinary new panes and the server's defaults (docs/integrations.md, tmux and herdr).
use super::*;
use std::ffi::OsStr;

fn words(request: &[(String, bool)]) -> Vec<&str> {
    request.iter().map(|(word, _)| word.as_str()).collect()
}

fn prepared() -> Command {
    let mut command = Command::new("/bin/bash");
    command
        .args(["--noprofile", "--norc", "-p", "-c", "exec \"$SHELL\" --posix -il"])
        .env("SHELL", "/bin/bash")
        .env("TERM", "xterm-256color")
        .env("DISPATCH_SSH_HELPER", "/fixture/helper")
        .env("ZDOTDIR", "/fixture/run/startup-1")
        .env("ENV", "/fixture/run/startup-1/bashrc")
        .env("HISTFILE", "/home/sam/.bash_history")
        .env("DISPATCH_SSH_BASH_HISTORY", "1")
        .env("GHOSTTY_BASH_INJECT", "1")
        .env("BASH_FUNC_codex%%", "() { command codex; }")
        .env(LAUNCH_NAME, "codex")
        .env_remove("DISPATCH_SSH_TOKEN");
    command
}

#[test]
fn the_server_command_starts_unless_it_is_the_prepared_shell() {
    let bash = OsStr::new("/bin/bash");
    assert!(!server_default(bash, "/bin/bash", ""), "the same login shell keeps the prepared one");
    assert!(server_default(bash, "/bin/zsh", ""), "another default-shell starts");
    assert!(server_default(bash, "/bin/bash", "exec /usr/bin/tail -f /dev/null"), "a default-command starts");
    assert!(server_default(bash, "", "reattach-to-user-namespace -l bash"));
}

#[test]
fn a_prepared_shell_keeps_its_command_and_whole_environment() {
    let request = launch(&prepared(), false).unwrap();
    let words = words(&request);
    let tail: Vec<_> = words[words.iter().position(|w| *w == "--").unwrap()..].to_vec();
    assert_eq!(
        tail,
        ["--", "env", "-u", "DISPATCH_SSH_TOKEN", "/bin/bash", "--noprofile", "--norc", "-p", "-c", "exec \"$SHELL\" --posix -il"]
    );
    for pair in ["ENV=/fixture/run/startup-1/bashrc", "SHELL=/bin/bash", "HISTFILE=/home/sam/.bash_history"] {
        assert!(words.contains(&pair), "{pair}");
    }
    assert!(!words.iter().any(|w| w.starts_with(LAUNCH_NAME)));
}

#[test]
fn the_server_command_gets_only_variables_any_shell_may_inherit() {
    let request = launch(&prepared(), true).unwrap();
    let words = words(&request);
    assert!(!words.contains(&"--"), "no command: the server's own starts");
    let pairs: Vec<_> = words.iter().filter(|w| **w != "-e").copied().collect();
    assert_eq!(
        pairs,
        [
            "BASH_FUNC_codex%%=() { command codex; }",
            "DISPATCH_SSH_HELPER=/fixture/helper",
            "DISPATCH_SSH_TOKEN=",
            "TERM=xterm-256color",
            "ZDOTDIR=/fixture/run/startup-1",
        ],
        "ENV, HISTFILE, bash and Ghostty injection and SHELL stay out; a removal is cleared"
    );
    for name in ["SHELL", "ENV", "BASH_ENV", "HISTFILE", "GHOSTTY_BASH_RCFILE", "DISPATCH_SSH_BASH_ENV_SET"] {
        assert!(!shell_neutral(name), "{name}");
    }
    for name in ["ZDOTDIR", "XDG_DATA_DIRS", "DISPATCH_SSH_HELPER", "GHOSTTY_ZSH_ZDOTDIR", "PATH"] {
        assert!(shell_neutral(name), "{name}");
    }
}
