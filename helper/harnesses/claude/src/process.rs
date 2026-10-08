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
    (name || version)
        && p.arguments
            .first()
            .is_some_and(|s| !s.is_empty() && !Path::new(s).file_name().is_some_and(|n| n == "rg"))
        && !p
            .arguments
            .iter()
            .skip(1)
            .any(|s| flags.contains(&s.as_str()) || s.starts_with("--print="))
        && p.arguments
            .get(1)
            .is_none_or(|s| !services.contains(&s.as_str()))
}
