//! A side fork retains reference context and explicitly removes read-only tools. It runs on the
//! parent's provider and model, with the parent's own configuration overrides and the
//! credentials that configuration names (docs/security.md, Side conversations).
use crate::channel::failure;
use dispatch_helper_core::{
    api::Error,
    json::{self, Data, Kind, Value},
};
use std::collections::BTreeSet;

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
/// c51466a ssh-helper agent_side.rs:72-84. TZ: a side runs in its parent's time zone, not the
/// machine's (Codex writes the zone into what it sends).
pub const ENVIRONMENT: [&str; 15] = [
    "HOME",
    "PATH",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "TZ",
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

/// Side launches only (the model catalog keeps ENVIRONMENT): Codex's own CA bundle, the
/// lowercase proxy spellings Codex also reads, and the user's own list of names (DECLARED).
pub const SIDE_ENVIRONMENT: [&str; 6] = [
    "CODEX_CA_CERTIFICATE",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "no_proxy",
    DECLARED,
];

/// The parent's list of further variables its sides need (names separated by spaces, commas or
/// colons), e.g. what a provider's `auth` command or an MCP server reads; it is not passed on.
pub const DECLARED: &str = "DISPATCH_SIDE_ENVIRONMENT";

/// Credentials of Codex's built-in providers, by provider id (`amazon-bedrock` and a provider
/// with an `aws` table use the AWS SDK's chain).
const OPENAI: [&str; 4] = ["OPENAI_ORGANIZATION", "OPENAI_PROJECT", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"];
const OSS: [&str; 2] = ["CODEX_OSS_BASE_URL", "CODEX_OSS_PORT"];
pub const AWS: [&str; 18] = [
    "AWS_REGION",
    "AWS_DEFAULT_REGION",
    "AWS_PROFILE",
    "AWS_DEFAULT_PROFILE",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_BEARER_TOKEN_BEDROCK",
    "AWS_CONFIG_FILE",
    "AWS_SHARED_CREDENTIALS_FILE",
    "AWS_WEB_IDENTITY_TOKEN_FILE",
    "AWS_ROLE_ARN",
    "AWS_ROLE_SESSION_NAME",
    "AWS_CA_BUNDLE",
    "AWS_ENDPOINT_URL",
    "AWS_CONTAINER_CREDENTIALS_FULL_URI",
    "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
    "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
];

/// A variable a side may take from its parent: a portable name, never the dynamic loader's
/// (`DYLD_*`, `LD_*`) or Dispatch's own (`DISPATCH_*`).
pub fn forwardable(name: &str) -> bool {
    let mut bytes = name.bytes();
    name.len() <= 128
        && bytes.next().is_some_and(|byte| byte == b'_' || byte.is_ascii_alphabetic())
        && bytes.all(|byte| byte == b'_' || byte.is_ascii_alphanumeric())
        && !["DYLD_", "LD_", "DISPATCH_"]
            .iter()
            .any(|prefix| name.starts_with(prefix))
}

/// The names a DECLARED value lists, in order, each once.
pub fn declared(value: &[u8]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    String::from_utf8_lossy(value)
        .split(|c: char| c.is_whitespace() || c == ',' || c == ':')
        .filter(|name| forwardable(name) && seen.insert(name.to_owned()))
        .take(64)
        .map(str::to_owned)
        .collect()
}

/// The configuration overrides of the parent's command line (its argv, program first), for the
/// side's own `app-server`, in order: each `-c`/`--config` value (as `-c VALUE`, also from the
/// `--config=`, `-c=` and `-cVALUE` spellings), `--enable` and `--disable`. Never what decides
/// what the side may do without asking (PERMISSIONS): a `/side` keeps its configuration's
/// permissions and Dispatch's approvals, as for `-a`/`-s` on the parent's command line.
/// `profile`: a `-p`/`--profile` layer (or `-c profile=…`), which `app-server` cannot load.
#[derive(Debug, Default, PartialEq)]
pub struct Overrides {
    pub arguments: Vec<String>,
    pub profile: bool,
}

/// Configuration keys (their first segment) a side never takes from the parent's command line.
pub const PERMISSIONS: [&str; 9] = [
    "approval_policy",
    "approvals_reviewer",
    "sandbox_mode",
    "sandbox_workspace_write",
    "sandbox_permissions",
    "default_permissions",
    "permissions",
    "permission_profile",
    "projects",
];

/// The first segment of a `-c key=value` override's dotted key (`"quoted"` or bare).
fn key(value: &str) -> &str {
    let value = value.trim_start();
    if let Some(quote) = value.chars().next().filter(|c| *c == '"' || *c == '\'') {
        let rest = &value[1..];
        return rest.split(quote).next().unwrap_or(rest);
    }
    value
        .split(|c: char| c == '.' || c == '=' || c.is_whitespace())
        .next()
        .unwrap_or(value)
}

pub fn overrides(argv: &[String]) -> Overrides {
    // The TUI's options that take a value (`-i` takes several); their values are never options.
    const VALUES: [&str; 14] = [
        "-m",
        "--model",
        "-s",
        "--sandbox",
        "-a",
        "--ask-for-approval",
        "-C",
        "--cd",
        "--add-dir",
        "--local-provider",
        "--remote",
        "--remote-auth-token-env",
        "-i",
        "--image",
    ];
    let mut result = Overrides::default();
    let config = |result: &mut Overrides, value: &str| match key(value) {
        "profile" => result.profile = true,
        key if PERMISSIONS.contains(&key) => {}
        _ => result.arguments.extend(["-c".to_owned(), value.to_owned()]),
    };
    let mut arguments = argv.iter().skip(1).peekable();
    while let Some(argument) = arguments.next() {
        let argument = argument.as_str();
        if argument == "--" {
            break;
        }
        if argument == "-c" || argument == "--config" {
            if let Some(value) = arguments.next() {
                config(&mut result, value);
            }
            continue;
        }
        if argument == "--enable" || argument == "--disable" {
            if let Some(value) = arguments.next() {
                result.arguments.extend([argument.to_owned(), value.clone()]);
            }
            continue;
        }
        if let Some(value) = argument.strip_prefix("--config=") {
            config(&mut result, value);
            continue;
        }
        if argument.starts_with("--enable=") || argument.starts_with("--disable=") {
            result.arguments.push(argument.to_owned());
            continue;
        }
        if let Some(value) = argument.strip_prefix("-c").filter(|value| !value.is_empty() && !argument.starts_with("--")) {
            config(&mut result, value.strip_prefix('=').unwrap_or(value));
            continue;
        }
        if argument == "-p" || argument == "--profile" {
            result.profile = true;
            arguments.next();
            continue;
        }
        if argument.starts_with("--profile=") || (argument.starts_with("-p") && !argument.starts_with("--")) {
            result.profile = true;
            continue;
        }
        if VALUES.contains(&argument) {
            arguments.next();
            if argument == "-i" || argument == "--image" {
                while arguments.next_if(|next| !next.starts_with('-')).is_some() {}
            }
        }
    }
    result
}

/// The parent conversation's provider, model and effort, as Codex itself reports them for the
/// stored thread (`thread/read`): the side runs on them, whatever the configuration's defaults.
#[derive(Debug, PartialEq)]
pub struct Pinned {
    pub model: String,
    pub provider: String,
    pub effort: Option<String>,
}

pub fn pinned(read: Value<'_>) -> Result<Pinned, Error> {
    let thread = read.get("thread");
    let text = |name| {
        thread
            .and_then(|thread| thread.get(name))
            .and_then(Value::string)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    };
    match (text("model"), text("modelProvider")) {
        (Some(model), Some(provider)) => Ok(Pinned {
            model,
            provider,
            effort: text("reasoningEffort"),
        }),
        _ => Err(failure(
            "side",
            "Codex did not report the parent conversation's model and provider (thread/read), so the side conversation cannot run on them. Update Codex: side conversations are verified with Codex 0.164, whose thread/read reports them.",
        )),
    }
}

/// The variables the effective configuration (`config/read`) names for this side, beyond the
/// fixed lists: the provider's `env_key` and `env_http_headers` (and Codex's own variables for a
/// built-in provider); for a full-permission side, each enabled MCP server's `env_vars`,
/// `bearer_token_env_var` and `env_http_headers` (a read-only side runs no MCP server); then the
/// parent's DECLARED names.
pub fn referenced(
    configuration: Value<'_>,
    provider: &str,
    read_only: bool,
    declared: &[String],
) -> Vec<String> {
    let mut names = Vec::new();
    let text = |value: Option<Value<'_>>, key: &str| -> Option<String> {
        value?.get(key).and_then(Value::string).map(str::to_owned)
    };
    let headers = |value: Option<Value<'_>>, names: &mut Vec<String>| {
        let values = value.and_then(|value| value.get("env_http_headers"));
        for (_, name) in values.and_then(Value::object).into_iter().flatten() {
            names.extend(name.string().map(str::to_owned));
        }
    };
    let definition = configuration
        .get("model_providers")
        .and_then(|providers| providers.get(provider));
    names.extend(text(definition, "env_key"));
    headers(definition, &mut names);
    let aws = definition
        .and_then(|definition| definition.get("aws"))
        .is_some_and(|aws| aws.kind() == Kind::Object);
    let builtin: &[&str] = match provider {
        "openai" => &OPENAI,
        "ollama" | "lmstudio" => &OSS,
        "amazon-bedrock" => &AWS,
        _ => &[],
    };
    names.extend(builtin.iter().map(|name| (*name).to_owned()));
    if aws {
        names.extend(AWS.iter().map(|name| (*name).to_owned()));
    }
    if !read_only {
        let servers = configuration.get("mcp_servers").and_then(Value::object);
        for (_, server) in servers.into_iter().flatten() {
            if server.get("enabled").and_then(Value::boolean) == Some(false) {
                continue;
            }
            for entry in server.get("env_vars").and_then(Value::array).into_iter().flatten() {
                names.extend(entry.string().or_else(|| entry.get("name").and_then(Value::string)).map(str::to_owned));
            }
            names.extend(text(Some(server), "bearer_token_env_var"));
            headers(Some(server), &mut names);
        }
    }
    names.extend(declared.iter().cloned());
    let mut seen = BTreeSet::new();
    names.retain(|name| forwardable(name) && seen.insert(name.clone()));
    names.truncate(256);
    names
}

/// `thread/fork` for a side of `parent` on the parent's provider, model and effort (`pinned`).
pub fn fork(
    parent: &str,
    configuration: Value<'_>,
    read_only: bool,
    pinned: &Pinned,
) -> Result<Vec<u8>, Error> {
    let mut fields = vec![
        ("threadId", Data::String(parent)),
        ("ephemeral", Data::Bool(true)),
        ("excludeTurns", Data::Bool(true)),
        ("developerInstructions", Data::String(BOUNDARY)),
        ("deferGoalContinuation", Data::Bool(false)),
        ("model", Data::String(&pinned.model)),
        ("modelProvider", Data::String(&pinned.provider)),
    ];
    let effort = || {
        pinned
            .effort
            .as_deref()
            .map(|effort| ("model_reasoning_effort", Data::String(effort)))
    };
    if !read_only && let Some(effort) = effort() {
        fields.push(("config", Data::Object(vec![effort])));
    }
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
                ]
                .into_iter()
                .chain(effort())
                .collect()),
            ),
        ]);
    }
    json::write(&Data::Object(fields))
}

/// The fork runs on the pinned provider and model, as its reply confirms.
pub fn confirmed(reply: Value<'_>, pinned: &Pinned) -> Result<(), Error> {
    let text = |name| reply.get(name).and_then(Value::string);
    if text("model") == Some(&pinned.model) && text("modelProvider") == Some(&pinned.provider) {
        Ok(())
    } else {
        Err(failure(
            "side",
            "The side conversation could not run on the parent conversation's model and provider (Codex's fork reply named others or none). Update Codex: side conversations are verified with Codex 0.164.",
        ))
    }
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

#[cfg(test)]
#[path = "side.test.rs"]
mod tests;
