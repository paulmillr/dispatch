//! A side fork retains reference context and explicitly removes read-only tools.
use dispatch_helper4_core::{
    api::Error,
    json::{self, Data, Value},
};

pub const BOUNDARY: &str = "You are in a separate side conversation. The inherited thread is reference context only. Do not continue its task or goal. Answer only new messages in this side conversation. Do not interact with the main thread or its agents.";

/// Features a read-only side turns off, in the old command-line order;
/// c51466a ssh-helper agent_side.rs:9-13.
pub const FEATURES: [&str; 13] = [
    "multi_agent",
    "multi_agent_v2",
    "shell_tool",
    "unified_exec",
    "apps",
    "hooks",
    "plugins",
    "browser_use",
    "browser_use_external",
    "browser_use_full_cdp_access",
    "computer_use",
    "image_generation",
    "skill_mcp_dependency_install",
];

/// The only variables a side inherits, each from the parent agent's own environment;
/// c51466a ssh-helper agent_side.rs:72-84.
pub const ENVIRONMENT: [&str; 14] = [
    "HOME",
    "PATH",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "CODEX_HOME",
    "OPENAI_BASE_URL",
    "OPENAI_API_KEY",
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "ALL_PROXY",
    "NO_PROXY",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
];

pub fn fork(parent: &str, configuration: Value<'_>, read_only: bool) -> Result<Vec<u8>, Error> {
    let mut fields = vec![
        ("threadId", Data::String(parent)),
        ("ephemeral", Data::Bool(true)),
        ("excludeTurns", Data::Bool(true)),
        ("developerInstructions", Data::String(BOUNDARY)),
        ("deferGoalContinuation", Data::Bool(false)),
    ];
    if read_only {
        let servers = configuration
            .get("mcp_servers")
            .and_then(Value::object)
            .into_iter()
            .flatten()
            .map(|(name, _)| (name, Data::Object(vec![("enabled", Data::Bool(false))])))
            .collect();
        fields.extend([
            ("sandbox", Data::String("read-only")),
            ("approvalPolicy", Data::String("never")),
            (
                "config",
                Data::Object(vec![
                    (
                        "features",
                        Data::Object(
                            FEATURES
                                .into_iter()
                                .map(|name| (name, Data::Bool(false)))
                                .collect(),
                        ),
                    ),
                    (
                        "agents",
                        Data::Object(vec![("max_depth", Data::Unsigned(0))]),
                    ),
                    (
                        "apps",
                        Data::Object(vec![(
                            "_default",
                            Data::Object(vec![("enabled", Data::Bool(false))]),
                        )]),
                    ),
                    ("web_search", Data::String("disabled")),
                    ("mcp_servers", Data::Object(servers)),
                ]),
            ),
        ]);
    }
    json::write(&Data::Object(fields))
}

pub fn permissions() -> Vec<(&'static str, Data<'static>)> {
    vec![
        ("environments", Data::Array(Vec::new())),
        (
            "sandboxPolicy",
            Data::Object(vec![
                ("type", Data::String("readOnly")),
                ("networkAccess", Data::Bool(false)),
            ]),
        ),
        ("approvalPolicy", Data::String("never")),
    ]
}
