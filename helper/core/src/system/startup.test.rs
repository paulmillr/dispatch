use super::*;
use std::collections::BTreeMap;

fn environment(command: &Command) -> BTreeMap<String, Option<String>> {
    command
        .get_envs()
        .map(|(k, v)| {
            (
                k.to_string_lossy().into_owned(),
                v.map(|v| v.to_string_lossy().into_owned()),
            )
        })
        .collect()
}

fn arguments(command: &Command) -> Vec<String> {
    command
        .get_args()
        .map(|a| a.to_string_lossy().into_owned())
        .collect()
}

fn typed() -> Integration {
    Integration::typed(&[("codex".into(), "codex".into())])
}

#[test]
fn without_a_startup_directory_zsh_gets_the_same_command_and_no_files() {
    let (shell, home, helper) = (Path::new("/bin/zsh"), Path::new("/home/sam"), Path::new("/h"));
    let directory = Path::new("/run/startup-1");
    let env = |_: &str| None;
    let (written, files) = prepare(shell, home, Some(directory), helper, None, Some(&typed()), &env);
    let (skipped, none) = prepare(shell, home, None, helper, None, Some(&typed()), &env);
    assert_eq!(files.len(), 5);
    assert!(none.is_empty());
    assert_eq!(arguments(&written), ["-l"]);
    assert_eq!(arguments(&skipped), ["-l"]);
    let (with, without) = (environment(&written), environment(&skipped));
    assert_eq!(with["ZDOTDIR"].as_deref(), Some("/run/startup-1"));
    assert_eq!(with["DISPATCH_SSH_STARTUP"].as_deref(), Some("/run/startup-1"));
    assert_eq!(with["DISPATCH_SSH_ZDOTDIR"].as_deref(), Some("/home/sam"));
    for name in ["ZDOTDIR", "DISPATCH_SSH_STARTUP", "DISPATCH_SSH_ZDOTDIR"] {
        assert!(!without.contains_key(name), "{name} set without startup files");
    }
    for name in ["SHELL", "TERM", "DISPATCH_SSH_HELPER"] {
        assert_eq!(with[name], without[name], "{name} differs");
    }
}

#[test]
fn without_a_startup_directory_bash_keeps_its_posix_launch_and_fish_its_inline_functions() {
    let (home, helper) = (Path::new("/home/sam"), Path::new("/h"));
    let env = |_: &str| None;
    let (bash, files) = prepare(Path::new("/bin/bash"), home, None, helper, None, Some(&typed()), &env);
    assert!(files.is_empty());
    assert_eq!(arguments(&bash), ["--noprofile", "--norc", "-p", "-c", BASH_LAUNCH]);
    let env_of = environment(&bash);
    assert!(!env_of.contains_key("ENV"));
    assert!(!env_of.contains_key("DISPATCH_SSH_STARTUP"));
    assert_eq!(env_of["HISTFILE"].as_deref(), Some("/home/sam/.bash_history"));
    let (fish, files) = prepare(Path::new("/usr/bin/fish"), home, None, helper, None, Some(&typed()), &env);
    assert!(files.is_empty());
    let args = arguments(&fish);
    assert_eq!(args[0], "-l");
    assert_eq!(args[1], "-C");
    assert!(args[2].contains("function codex"));
    assert_eq!(environment(&fish)["DISPATCH_SSH_HELPER"].as_deref(), Some("/h"));
}
