use dispatch_helper_core::api::Process;
use std::path::Path;

/// Private print forks use their owned channel; discovery matches interactive processes only.
pub fn matches(p: &Process) -> bool {
    let name = p
        .executable
        .file_name()
        .is_some_and(|n| n == "claude" || n == "claude.exe");
    let version = p.executable.parent().is_some_and(|p| {
        p.file_name().is_some_and(|n| n == "versions")
            && p.parent()
                .and_then(Path::file_name)
                .is_some_and(|n| n == "claude")
    });
    (name || version)
        && p.arguments
            .first()
            .is_some_and(|s| !s.is_empty() && !Path::new(s).file_name().is_some_and(|n| n == "rg"))
        && interactive(&p.arguments[1..])
}

/// The typed launcher configures interactive sessions, never service/print invocations.
pub(crate) fn interactive(arguments: &[String]) -> bool {
    let flags = [
        "-p",
        "--print",
        "--version",
        "-v",
        "--help",
        "-h",
        "--background",
        "--bg",
    ];
    let services = [
        "auth",
        "agents",
        "attach",
        "doctor",
        "gateway",
        "import",
        "install",
        "logs",
        "mcp",
        "plugin",
        "plugins",
        "project",
        "respawn",
        "rm",
        "setup-token",
        "stop",
        "kill",
        "ultrareview",
        "update",
        "upgrade",
    ];
    !arguments
        .iter()
        .any(|s| flags.contains(&s.as_str()) || s.starts_with("--print="))
        && arguments
            .first()
            .is_none_or(|s| !services.contains(&s.as_str()))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_interactive_invocations_configure_hooks() {
        for args in [
            vec![],
            vec!["resume", "session"],
            vec!["--model", "opus", "hello"],
        ] {
            assert!(interactive(
                &args.into_iter().map(String::from).collect::<Vec<_>>()
            ));
        }
        for args in [
            vec!["--help"],
            vec!["--version"],
            vec!["-p", "hello"],
            vec!["--print=hello"],
            vec!["mcp", "list"],
            vec!["auth", "login"],
        ] {
            assert!(!interactive(
                &args.into_iter().map(String::from).collect::<Vec<_>>()
            ));
        }
    }
}
