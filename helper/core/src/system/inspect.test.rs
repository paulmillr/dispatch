use super::*;

fn arguments(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| value.to_string()).collect()
}

#[test]
fn plain_interactive_shells_and_the_helpers_own_bash_startup_count_as_idle_shells() {
    assert!(interactive(Some("zsh"), &arguments(&["-zsh"])));
    assert!(interactive(Some("zsh"), &arguments(&["zsh", "-l"])));
    assert!(interactive(Some("bash"), &arguments(&["bash", "--posix", "-il"])));
    // macOS /bin/bash 3.2 under the helper's startup (BASH_LAUNCH): `exec -a sh bash --noprofile -il`.
    assert!(interactive(Some("bash"), &arguments(&["sh", "--noprofile", "-il"])));
}

#[test]
fn shells_running_a_command_or_other_options_are_not_idle_shells() {
    assert!(!interactive(Some("bash"), &[]));
    assert!(!interactive(Some("bash"), &arguments(&["bash", "-c", "sleep 9"])));
    assert!(!interactive(Some("bash"), &arguments(&["bash", "script.sh"])));
    assert!(!interactive(Some("zsh"), &arguments(&["zsh", "--noprofile", "-il"])));
    assert!(!interactive(Some("bash"), &arguments(&["bash", "--rcfile", "x", "-i"])));
}
