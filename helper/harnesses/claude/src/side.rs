//! Ephemeral Claude print forks over owned stdio. The helper assigns the fork's session id
//! (--session-id with --fork-session), so identity never comes from output or hooks.
use crate::{
    history::{error, text},
    hooks::Request,
};
use dispatch_helper_core::{
    api::*,
    json::{self, Data, Json, Value},
    rpc::{Lines, Queue},
};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    io,
    os::fd::RawFd,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

/// The parent's variables every side takes (docs/security.md, Side conversations), read from the
/// parent process (e076fd7 CodexProcess.sideEnvironment): the process basics an `apiKeyHelper`
/// or a credential process needs (PATH lookup, home, user, shell, locale, zone), Claude's config
/// folder, Anthropic's API, OAuth and model variables, the cloud providers' selectors, proxies,
/// certificates, and the telemetry opt-outs. A selector set in the parent adds its provider's
/// variables (PROVIDERS); the parent's settings add what their credential commands name.
pub const ENVIRONMENT: [&str; 46] = [
    "HOME",
    "USER",
    "LOGNAME",
    "PATH",
    "SHELL",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TZ",
    "CLAUDE_CONFIG_DIR",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_CUSTOM_HEADERS",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_API_KEY_HELPER_TTL_MS",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_USE_ANTHROPIC_AWS",
    "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD",
    "CLAUDE_CODE_USE_MANTLE",
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "NO_PROXY",
    "https_proxy",
    "http_proxy",
    "no_proxy",
    "NODE_EXTRA_CA_CERTS",
    "NODE_USE_SYSTEM_CA",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "CLAUDE_CODE_CLIENT_CERT",
    "CLAUDE_CODE_CLIENT_KEY",
    "CLAUDE_CODE_CLIENT_KEY_PASSPHRASE",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
    "DISABLE_AUTOUPDATER",
    "DISABLE_TELEMETRY",
    "DISABLE_ERROR_REPORTING",
    DECLARED,
];

/// The parent's list of further variables its sides need (names separated by spaces, commas or
/// colons), e.g. what a credential script reads; it is not passed on.
pub const DECLARED: &str = "DISPATCH_SIDE_ENVIRONMENT";

const AWS: [&str; 18] = [
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
const GOOGLE: [&str; 7] = [
    "GOOGLE_APPLICATION_CREDENTIALS",
    "GOOGLE_CLOUD_PROJECT",
    "GCLOUD_PROJECT",
    "CLOUDSDK_CONFIG",
    "CLOUDSDK_CORE_PROJECT",
    "CLOUDSDK_AUTH_ACCESS_TOKEN",
    "CLOUD_ML_REGION",
];

/// Each cloud provider's own variables, taken when the parent sets its selector.
pub const PROVIDERS: [(&str, &[&str]); 6] = [
    (
        "CLAUDE_CODE_USE_BEDROCK",
        &[
            "ANTHROPIC_BEDROCK_BASE_URL",
            "ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION",
            "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            "CLAUDE_CODE_SKIP_BEDROCK_AUTH",
        ],
    ),
    (
        "CLAUDE_CODE_USE_ANTHROPIC_AWS",
        &["ANTHROPIC_AWS_API_KEY", "ANTHROPIC_AWS_BASE_URL", "ANTHROPIC_AWS_WORKSPACE_ID", "CLAUDE_CODE_SKIP_ANTHROPIC_AWS_AUTH"],
    ),
    (
        "CLAUDE_CODE_USE_MANTLE",
        &["ANTHROPIC_BEDROCK_MANTLE_BASE_URL", "CLAUDE_CODE_SKIP_MANTLE_AUTH"],
    ),
    (
        "CLAUDE_CODE_USE_VERTEX",
        &["ANTHROPIC_VERTEX_PROJECT_ID", "ANTHROPIC_VERTEX_BASE_URL", "CLAUDE_CODE_SKIP_VERTEX_AUTH"],
    ),
    (
        "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD",
        &[
            "ANTHROPIC_GOOGLE_CLOUD_BASE_URL",
            "ANTHROPIC_GOOGLE_CLOUD_LOCATION",
            "ANTHROPIC_GOOGLE_CLOUD_PROJECT",
            "ANTHROPIC_GOOGLE_CLOUD_WORKSPACE_ID",
            "CLAUDE_CODE_SKIP_ANTHROPIC_GOOGLE_CLOUD_AUTH",
        ],
    ),
    (
        "CLAUDE_CODE_USE_FOUNDRY",
        &[
            "ANTHROPIC_FOUNDRY_API_KEY",
            "ANTHROPIC_FOUNDRY_AUTH_TOKEN",
            "ANTHROPIC_FOUNDRY_BASE_URL",
            "ANTHROPIC_FOUNDRY_RESOURCE",
            "CLAUDE_CODE_SKIP_FOUNDRY_AUTH",
            "AZURE_CLIENT_ID",
            "AZURE_TENANT_ID",
            "AZURE_CLIENT_SECRET",
            "AZURE_CLIENT_CERTIFICATE_PATH",
            "AZURE_FEDERATED_TOKEN_FILE",
            "AZURE_AUTHORITY_HOST",
            "AZURE_CONFIG_DIR",
        ],
    ),
];

/// Settings whose shell commands Claude runs for credentials and headers.
const HELPERS: [&str; 6] = [
    "apiKeyHelper",
    "awsAuthRefresh",
    "awsCredentialExport",
    "gcpAuthRefresh",
    "otelHeadersHelper",
    "proxyAuthHelper",
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

/// The settings files a side of a Claude in `directory` loads that can hold credential commands:
/// the user's (`$CLAUDE_CONFIG_DIR`, else `~/.claude`), the project's shared and local ones, and
/// the machine's managed settings.
pub fn settings(environment: &BTreeMap<String, Vec<u8>>, directory: &Path, os: &str) -> Vec<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    let path = |name: &str| {
        environment
            .get(name)
            .map(|value| PathBuf::from(std::ffi::OsStr::from_bytes(value)))
            .filter(|path| path.is_absolute())
    };
    let user = path("CLAUDE_CONFIG_DIR").or_else(|| path("HOME").map(|home| home.join(".claude")));
    let managed = match os {
        "linux" => "/etc/claude-code/managed-settings.json",
        _ => "/Library/Application Support/ClaudeCode/managed-settings.json",
    };
    user.map(|user| user.join("settings.json"))
        .into_iter()
        .chain([
            directory.join(".claude/settings.json"),
            directory.join(".claude/settings.local.json"),
            PathBuf::from(managed),
        ])
        .collect()
}

/// What the side's settings files name (the native "file.json.references" job): the variables
/// their credential commands expand, and the cloud selectors their `env` sets.
#[derive(Debug, Default)]
pub struct References {
    pub names: Vec<String>,
    pub env: BTreeMap<String, String>,
}

/// The variables a side needs beyond ENVIRONMENT: those of each cloud provider whose selector
/// the parent sets, in its environment or its settings' `env` (to anything but empty, `0` or
/// `false`), the names the parent's credential commands use (`references`), and the parent's
/// DECLARED names; each once, never a name ENVIRONMENT has.
pub fn referenced(environment: &BTreeMap<String, Vec<u8>>, references: &References) -> Vec<String> {
    let mut names = Vec::new();
    let truthy = |value: &[u8]| !matches!(value, b"" | b"0" | b"false");
    let set = |name: &str| {
        environment.get(name).is_some_and(|value| truthy(value))
            || references.env.get(name).is_some_and(|value| truthy(value.as_bytes()))
    };
    for (selector, own) in PROVIDERS {
        if set(selector) {
            let cloud: &[&str] = match selector {
                "CLAUDE_CODE_USE_VERTEX" | "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD" => &GOOGLE,
                "CLAUDE_CODE_USE_FOUNDRY" => &[],
                _ => &AWS,
            };
            names.extend(cloud.iter().chain(own).map(|name| (*name).to_owned()));
        }
    }
    names.extend(references.names.iter().cloned());
    let mut seen = BTreeSet::new();
    let mut keep = |name: &str| {
        forwardable(name) && !ENVIRONMENT.contains(&name) && seen.insert(name.to_owned())
    };
    names.retain(|name| keep(name));
    if let Some(value) = environment.get(DECLARED) {
        let declared = String::from_utf8_lossy(value).into_owned();
        names.extend(
            declared
                .split(|c: char| c.is_whitespace() || c == ',' || c == ':')
                .filter(|name| keep(name))
                .take(64)
                .map(str::to_owned),
        );
    }
    names.truncate(256);
    names
}

pub fn arguments(parent: &str, read_only: bool) -> Vec<String> {
    let mut args = vec![
        "--print",
        "--verbose",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--permission-prompt-tool",
        "stdio",
        "--resume",
        parent,
        "--fork-session",
        "--no-session-persistence",
        "--append-system-prompt",
        "You are in a separate side conversation. The inherited thread is reference context only. Do not continue its task or goal. Answer only new messages in this side conversation. Do not interact with the main thread or its agents.",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect::<Vec<_>>();
    if read_only {
        args.extend(
            [
                "--tools",
                "Read,Grep,Glob,AskUserQuestion",
                "--strict-mcp-config",
                "--mcp-config",
                "{\"mcpServers\":{}}",
                "--permission-mode",
                "manual",
                "--settings",
                "{\"disableAllHooks\":true}",
            ]
            .map(str::to_owned),
        );
    }
    args
}

pub struct Stream {
    pub records: Vec<Record>,
    pub busy: bool,
    pub failure: Option<String>,
    pub closed: bool,
}
impl Default for Stream {
    fn default() -> Self {
        Self::new()
    }
}
impl Stream {
    pub fn new() -> Self {
        Self {
            records: Vec::new(),
            busy: true,
            failure: None,
            closed: false,
        }
    }
    pub fn receive(&mut self, message: &Json, fallback: &str) -> Result<(), Error> {
        let root = message.root();
        match text(root, "type") {
            Some("assistant") => {
                if let Some(message) = root.get("message")
                    && let Some(content) = message.get("content").and_then(Value::array)
                {
                    let body = content
                        .filter(|v| text(*v, "type") == Some("text"))
                        .filter_map(|v| text(v, "text"))
                        .collect::<Vec<_>>()
                        .join("\n");
                    if body.is_empty() {
                        return Ok(());
                    }
                    if body.len() > 1_048_576 {
                        self.failure = Some("Side reply exceeded the display limit.".into());
                        self.closed = true;
                        return Err(error("limit", "Side reply exceeded the display limit."));
                    }
                    let id = text(message, "id").unwrap_or(fallback);
                    if let Some(record) = self.records.iter_mut().find(|record| record.id == id) {
                        record.text = body;
                    } else {
                        self.records.push(Record {
                            id: id.into(),
                            kind: RecordKind::Assistant,
                            text: body,
                            ..Record::default()
                        });
                    }
                }
            }
            Some("result") => {
                self.busy = false;
                if root.get("is_error").and_then(Value::boolean) == Some(true) {
                    self.failure = Some(
                        root.get("errors")
                            .and_then(Value::array)
                            .and_then(|values| {
                                values.map(Value::string).collect::<Option<Vec<_>>>()
                            })
                            .map(|values| values.join("\n"))
                            .unwrap_or_else(|| "The side question failed.".into()),
                    );
                }
            }
            _ => {}
        }
        Ok(())
    }
}

pub struct Launch {
    pub parent: Binding,
    pub directory: PathBuf,
    pub question: String,
    pub model: Option<String>,
    /// The parent's effort, passed on only when it is one `claude --effort` takes: an unknown word would fail the fork.
    pub effort: Option<String>,
    pub read_only: bool,
    pub done: Done<Binding>,
}

/// The efforts `claude --effort` accepts.
const EFFORTS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

/// The fork's `--model` and `--effort`: the parent's, so the side answers as the main conversation would.
pub fn pinned(model: Option<&str>, effort: Option<&str>) -> Vec<String> {
    let mut arguments = Vec::new();
    if let Some(model) = model {
        arguments.extend(["--model".to_owned(), model.to_owned()]);
    }
    if let Some(effort) = effort.map(str::to_ascii_lowercase).filter(|effort| EFFORTS.contains(&effort.as_str())) {
        arguments.extend(["--effort".to_owned(), effort]);
    }
    arguments
}
struct Fork {
    parent: Binding,
    read_only: bool,
    process: Option<Process>,
    session: Option<String>,
    binding: Option<Binding>,
    done: Option<Done<Binding>>,
    input: RawFd,
    output: RawFd,
    lines: Lines,
    queue: Queue,
    writes: VecDeque<Option<Done<Sent>>>,
    partial: bool,
    stream: Stream,
    requests: BTreeMap<String, Request>,
    /// Answered requests, retired from the UI at the next event (answer has no UI).
    answered: Vec<String>,
}
/// A launch reading what its side needs: the parent's ENVIRONMENT values, then its settings
/// files, then the further variables they name.
struct Preparing {
    launch: Launch,
    environment: BTreeMap<String, Vec<u8>>,
}
#[derive(Default)]
pub struct Sides {
    /// Process verification job -> fork pid.
    jobs: BTreeMap<Work, u32>,
    /// Parent environment job (ENVIRONMENT) -> the launch waiting for it.
    launches: BTreeMap<Work, Launch>,
    /// Settings references and further environment jobs -> their preparation.
    reads: BTreeMap<Work, u64>,
    further: BTreeMap<Work, u64>,
    preparing: BTreeMap<u64, Preparing>,
    prepared: u64,
    forks: BTreeMap<u32, Fork>,
}

/// The parent's variables `names` (each once), from the parent `launch` names, refused for a
/// reused pid or another executable.
fn environment(io: &mut dyn Io, parent: &Process, names: &[&str]) -> Result<Work, Error> {
    let input = dispatch_helper_core::wire::body::encode_plain(&Data::Object(vec![
        ("pid", Data::Unsigned(parent.pid.into())),
        ("start", Data::Array(parent.start.iter().map(|n| Data::Unsigned(*n)).collect())),
        ("executable", Data::from(parent.executable.as_path())),
        ("names", Data::Array(names.iter().map(|name| Data::String(name)).collect())),
    ]))
    .map_err(|e| error("json", format!("{e:?}")))?;
    io.submit(Job::Native {
        name: "environment",
        value: input,
    })
    .map_err(|e| error("io", e))
}

/// A native "file.json.references" answer.
fn references(bytes: &[u8]) -> Result<References, Error> {
    let value = dispatch_helper_core::wire::body::decode_plain(bytes)?;
    let invalid = || error("side", "Invalid settings references");
    let names = value.get("names").and_then(|v| v.array()).ok_or_else(invalid)?;
    let names = names.map(|name| name.string().map(str::to_owned).ok_or_else(invalid)).collect::<Result<_, _>>()?;
    let env = value.get("env").and_then(|v| v.object()).ok_or_else(invalid)?;
    let env = env
        .map(|(name, value)| Ok((name.to_owned(), value.string().ok_or_else(invalid)?.to_owned())))
        .collect::<Result<_, Error>>()?;
    Ok(References { names, env })
}

/// A native environment answer: names and their values as bytes.
fn variables(bytes: &[u8]) -> Result<BTreeMap<String, Vec<u8>>, Error> {
    let environment = dispatch_helper_core::wire::body::decode_plain(bytes)?;
    let values = environment
        .object()
        .ok_or_else(|| error("side", "Invalid parent environment"))?;
    values
        .map(|(name, value)| {
            let value = value
                .bytes()
                .ok_or_else(|| error("side", "Invalid parent environment"))?;
            Ok((name.to_owned(), value.to_vec()))
        })
        .collect()
}

fn sent(written: bool, partial: bool, reason: Option<String>) -> Sent {
    Sent::Native {
        written,
        may_have_sent: partial,
        reason,
    }
}
fn random(io: &mut dyn Io) -> Result<String, Error> {
    let mut bytes = [0; 16];
    io.random(&mut bytes).map_err(|e| error("io", e))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
impl Fork {
    fn write(
        &mut self,
        io: &mut dyn Io,
        bytes: Vec<u8>,
        done: Option<Done<Sent>>,
    ) -> Result<(), Error> {
        let result = Lines::encode(bytes, 4_194_304)
            .map_err(|e| error("limit", format!("{e:?}")))
            .and_then(|bytes| {
                self.queue
                    .push(bytes)
                    .map_err(|e| error("limit", format!("{e:?}")))
            });
        if let Err(e) = result {
            if let Some(done) = done {
                deferred(done)(io, Ok(sent(false, false, Some(e.message))));
            }
            return Ok(());
        }
        self.writes.push_back(done);
        self.flush(io)
    }
    fn flush(&mut self, io: &mut dyn Io) -> Result<(), Error> {
        if let Some(bytes) = self.queue.front() {
            let size = bytes.len();
            match io.write(self.input, bytes) {
                Ok(0) => return Err(error("io", "Side connection closed")),
                Ok(count) => {
                    self.partial = true;
                    self.queue
                        .consume(count)
                        .map_err(|e| error("io", format!("{e:?}")))?;
                    if count == size {
                        self.partial = false;
                        if let Some(Some(done)) = self.writes.pop_front() {
                            deferred(done)(io, Ok(sent(true, false, None)));
                        }
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(error("io", e)),
            }
        }
        io.interest(self.input, false, self.queue.front().is_some())
            .map_err(|e| error("io", e))
    }
    fn send(
        &mut self,
        io: &mut dyn Io,
        question: &str,
        done: Option<Done<Sent>>,
    ) -> Result<(), Error> {
        let question = question.trim();
        if question.is_empty() || question.len() > 1_048_576 {
            if let Some(done) = done {
                deferred(done)(
                    io,
                    Ok(sent(false, false, Some("Invalid side question".into()))),
                );
            }
            return Ok(());
        }
        let bytes = json::write(&Data::Object(vec![
            ("type", Data::String("user")),
            (
                "message",
                Data::Object(vec![
                    ("role", Data::String("user")),
                    ("content", Data::String(question)),
                ]),
            ),
            ("session_id", Data::String(&self.parent.session)),
            ("parent_tool_use_id", Data::Null),
        ]))?;
        self.stream.busy = true;
        self.stream.failure = None;
        self.write(io, bytes, done)
    }
    fn publish(&self, ui: &mut dyn Ui) {
        if let Some(binding) = self.binding.as_ref().filter(|b| ui.terminal(b).is_some()) {
            ui.update(Update::Records {
                binding: binding.clone(),
                records: self.stream.records.clone(),
            });
            ui.update(Update::State {
                binding: binding.clone(),
                state: State {
                    busy: self.stream.busy,
                    ..State::default()
                },
            });
        }
    }
    fn retire(&mut self, ui: &mut dyn Ui, id: &str) {
        if let Some(request) = self.requests.remove(id)
            && let Some(binding) = self.binding.as_ref().filter(|b| ui.terminal(b).is_some())
        {
            let mut interaction = request.interaction;
            interaction.questions.clear();
            ui.update(Update::Interaction {
                binding: binding.clone(),
                interaction,
            });
        }
    }
    fn receive(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, doc: Json) -> Result<(), Error> {
        let root = doc.root();
        match text(root, "type") {
            Some("control_request") => {
                // c1654cc ChatSideConversation.swift:316-335: questions always reach the user;
                // read-only sides deny every permission, and an undisplayable one is denied.
                let request = match Request::new(Json::parse(&root.write()?)?) {
                    Ok(request) if !(self.read_only && request.interaction.approval) => request,
                    result => {
                        if result.is_err() {
                            self.stream.failure = Some("The side agent requested an operation Dispatch could not display safely, so it was denied.".into());
                        }
                        let id = text(root, "request_id")
                            .ok_or_else(|| error("side", "Missing side request id"))?;
                        // Old sendPermissionDecision(allow: false).
                        let denied = crate::hooks::control(
                            id,
                            Data::Object(vec![
                                ("behavior", Data::String("deny")),
                                ("message", Data::String("Permission denied.")),
                            ]),
                        )?;
                        self.write(io, denied, None)?;
                        self.publish(ui);
                        return Ok(());
                    }
                };
                let id = request.interaction.id.clone();
                if self.requests.contains_key(&id) {
                    return Ok(());
                }
                if request.interaction.approval
                    && self.requests.values().any(|r| r.interaction.approval)
                {
                    let answers = request
                        .interaction
                        .questions
                        .iter()
                        .map(|q| (q.id.clone(), Answer::Options(vec![1])))
                        .collect();
                    self.write(io, request.answer(answers)?, None)?;
                    self.stream.failure = Some(
                        "A second side permission request was denied while another is pending."
                            .into(),
                    );
                } else {
                    if !request.interaction.approval {
                        let ids = self
                            .requests
                            .iter()
                            .filter(|(_, r)| !r.interaction.approval)
                            .map(|(id, _)| id.clone())
                            .collect::<Vec<_>>();
                        for id in ids {
                            self.retire(ui, &id);
                        }
                    }
                    if let Some(binding) =
                        self.binding.as_ref().filter(|b| ui.terminal(b).is_some())
                    {
                        ui.update(Update::Interaction {
                            binding: binding.clone(),
                            interaction: request.interaction.clone(),
                        });
                    }
                    self.requests.insert(id, request);
                }
            }
            Some("control_cancel_request") => {
                if let Some(id) = text(root, "request_id") {
                    self.retire(ui, id);
                }
            }
            Some("result") => {
                for id in self.requests.keys().cloned().collect::<Vec<_>>() {
                    self.retire(ui, &id);
                }
                self.stream.receive(&doc, "")?;
            }
            Some("assistant") => {
                let fallback = if root.get("message").and_then(|v| text(v, "id")).is_none() {
                    random(io)?
                } else {
                    String::new()
                };
                self.stream.receive(&doc, &fallback)?;
            }
            _ => {}
        }
        self.publish(ui);
        Ok(())
    }
}

impl Sides {
    pub fn contains(&self, binding: &Binding) -> bool {
        self.forks
            .get(&binding.process.pid)
            .and_then(|fork| fork.binding.as_ref())
            == Some(binding)
    }
    pub fn open(&mut self, io: &mut dyn Io, launch: Launch) {
        // The side runs with the parent's own values of these names only, read from the parent
        // process (docs/security.md); its settings may name more (prepare).
        match environment(io, &launch.parent.process, &ENVIRONMENT) {
            Ok(work) => {
                self.launches.insert(work, launch);
            }
            Err(e) => deferred(launch.done)(io, Err(e)),
        }
    }
    /// The parent's ENVIRONMENT arrived: ask what the settings files name (only names are
    /// answered, so no file contents are read into the helper or a capture).
    fn prepare(&mut self, io: &mut dyn Io, launch: Launch, environment: BTreeMap<String, Vec<u8>>) -> Result<(), Error> {
        let id = self.prepared;
        self.prepared += 1;
        let paths = settings(&environment, &launch.directory, io.os());
        let input = dispatch_helper_core::wire::body::encode_plain(&Data::Object(vec![
            ("paths", Data::Array(paths.iter().map(|path| Data::from(path.as_path())).collect())),
            ("keys", Data::Array(HELPERS.iter().map(|key| Data::String(key)).collect())),
            ("env", Data::Array(PROVIDERS.iter().map(|(selector, _)| Data::String(selector)).collect())),
        ]))
        .map_err(|e| error("json", format!("{e:?}")))?;
        let work = io
            .submit(Job::Native { name: "file.json.references", value: input })
            .map_err(|e| error("io", e))?;
        self.reads.insert(work, id);
        self.preparing.insert(id, Preparing { launch, environment });
        Ok(())
    }
    /// The settings' references arrived: ask the parent for the further variables, or start.
    fn resolve(&mut self, io: &mut dyn Io, id: u64, references: &References) -> Result<(), Error> {
        let preparing = &self.preparing[&id];
        let names = referenced(&preparing.environment, references);
        if names.is_empty() {
            let preparing = self.preparing.remove(&id).unwrap();
            return self.spawn(io, preparing.launch, preparing.environment);
        }
        let names: Vec<&str> = names.iter().map(String::as_str).collect();
        let work = environment(io, &preparing.launch.parent.process, &names)?;
        self.further.insert(work, id);
        Ok(())
    }
    /// Starts the side; a failure ends the launch with it.
    fn spawn(&mut self, io: &mut dyn Io, launch: Launch, environment: BTreeMap<String, Vec<u8>>) -> Result<(), Error> {
        let completion = std::rc::Rc::new(std::cell::RefCell::new(Some(launch.done)));
        let captured = completion.clone();
        let launch = Launch {
            done: Box::new(move |io, result| {
                if let Some(done) = captured.borrow_mut().take() {
                    done(io, result);
                }
            }),
            ..launch
        };
        if let Err(e) = self.start(io, launch, environment)
            && let Some(done) = completion.borrow_mut().take()
        {
            deferred(done)(io, Err(e));
        }
        Ok(())
    }
    fn start(&mut self, io: &mut dyn Io, launch: Launch, mut environment: BTreeMap<String, Vec<u8>>) -> Result<(), Error> {
        let mut id = [0u8; 16];
        io.random(&mut id).map_err(|e| error("io", e))?;
        id[6] = id[6] & 0x0f | 0x40;
        id[8] = id[8] & 0x3f | 0x80;
        let hex = id.iter().map(|b| format!("{b:02x}")).collect::<String>();
        let session = format!(
            "{}-{}-{}-{}-{}",
            &hex[..8],
            &hex[8..12],
            &hex[12..16],
            &hex[16..20],
            &hex[20..]
        );
        let mut command = Command::new(&launch.parent.process.executable);
        command
            .current_dir(&launch.directory)
            .args(arguments(&launch.parent.session, launch.read_only))
            .args(["--session-id", &session]);
        command.args(pinned(launch.model.as_deref(), launch.effort.as_deref()));
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .env_clear();
        // The parent's environment as bytes: values pass on unchanged (DECLARED only names them).
        environment.remove(DECLARED);
        for (name, value) in &environment {
            use std::os::unix::ffi::OsStrExt;
            command.env(name, std::ffi::OsStr::from_bytes(value));
        }
        let child = io.spawn(command, None).map_err(|e| error("io", e))?;
        let (Some(input), Some(output)) = (child.input, child.output) else {
            if let Some(fd) = child.input {
                io.close(fd);
            }
            if let Some(fd) = child.output {
                io.close(fd);
            }
            let _ = io.terminate(child.pid);
            return Err(error("io", "Missing side pipes"));
        };
        let mut fork = Fork {
            parent: launch.parent,
            read_only: launch.read_only,
            process: None,
            session: Some(session),
            binding: None,
            done: Some(launch.done),
            input,
            output,
            lines: Lines::new(4_194_304),
            queue: Queue::new(8_388_608),
            writes: VecDeque::new(),
            partial: false,
            stream: Stream::new(),
            requests: BTreeMap::new(),
            answered: Vec::new(),
        };
        let result = io
            .child(child.pid)
            .and_then(|_| io.interest(output, true, false))
            .map_err(|e| error("io", e))
            .and_then(|_| fork.send(io, &launch.question, None));
        self.forks.insert(child.pid, fork);
        if let Err(e) = result {
            self.close(io, child.pid, e.message);
            return Ok(());
        }
        match io.submit(Job::Process { pid: child.pid }) {
            Ok(work) => {
                self.jobs.insert(work, child.pid);
            }
            Err(e) => self.close(io, child.pid, e.to_string()),
        }
        Ok(())
    }
    /// Runs a preparation's next step; a failure ends its launch with that error.
    fn settle(&mut self, io: &mut dyn Io, id: u64, step: impl FnOnce(&mut Self, &mut dyn Io) -> Result<(), Error>) {
        if let Err(e) = step(self, io)
            && let Some(preparing) = self.preparing.remove(&id)
        {
            deferred(preparing.launch.done)(io, Err(e));
        }
    }
    fn ready(&mut self, io: &mut dyn Io, pid: u32) {
        if let Some(fork) = self.forks.get_mut(&pid)
            && let (Some(process), Some(session), Some(done)) =
                (&fork.process, &fork.session, fork.done.as_ref())
        {
            let _ = done;
            let binding = Binding {
                process: process.clone(),
                session: session.clone(),
                transcript: None,
            };
            fork.binding = Some(binding.clone());
            deferred(fork.done.take().unwrap())(io, Ok(binding));
        }
    }
    pub fn page(&self, binding: &Binding) -> Page {
        Page {
            records: self.forks[&binding.process.pid].stream.records.clone(),
            earlier: None,
        }
    }
    /// Still-open (unanswered) side requests of `binding`, for a chat that opens.
    pub fn cards(&self, binding: &Binding) -> Vec<Interaction> {
        self.forks
            .get(&binding.process.pid)
            .map(|fork| {
                fork.requests
                    .iter()
                    .filter(|(id, _)| !fork.answered.contains(id))
                    .map(|(_, request)| request.interaction.clone())
                    .collect()
            })
            .unwrap_or_default()
    }
    pub fn state(&self, binding: &Binding) -> State {
        State {
            busy: self.forks[&binding.process.pid].stream.busy,
            ..State::default()
        }
    }
    pub fn send(&mut self, io: &mut dyn Io, binding: &Binding, text: &str, done: Done<Sent>) {
        if let Err(e) = self
            .forks
            .get_mut(&binding.process.pid)
            .unwrap()
            .send(io, text, Some(done))
        {
            self.close(io, binding.process.pid, e.message);
        }
    }
    pub fn answer(
        &mut self,
        io: &mut dyn Io,
        binding: &Binding,
        id: &str,
        answers: Vec<(String, Answer)>,
        done: Done<Sent>,
    ) {
        let fork = self.forks.get_mut(&binding.process.pid).unwrap();
        let bytes = fork
            .requests
            .get(id)
            .filter(|_| !fork.answered.iter().any(|a| a == id))
            .ok_or_else(|| error("expired", "Side question expired"))
            .and_then(|r| r.answer(answers));
        match bytes {
            Ok(bytes) => {
                fork.answered.push(id.into());
                io.timer(io.now());
                if let Err(e) = fork.write(io, bytes, Some(done)) {
                    self.close(io, binding.process.pid, e.message);
                }
            }
            Err(e) => deferred(done)(io, Err(e)),
        }
    }
    pub fn close(&mut self, io: &mut dyn Io, pid: u32, reason: String) {
        if let Some(mut fork) = self.forks.remove(&pid) {
            io.close(fork.input);
            io.close(fork.output);
            let _ = io.terminate(pid);
            if let Some(done) = fork.done.take() {
                deferred(done)(io, Err(error("side", &reason)));
            }
            for done in fork.writes.into_iter().flatten() {
                deferred(done)(io, Ok(sent(false, fork.partial, Some(reason.clone()))));
            }
        }
        let works = self
            .jobs
            .iter()
            .filter_map(|(work, child)| (*child == pid).then_some(*work))
            .collect::<Vec<_>>();
        for work in works {
            self.jobs.remove(&work);
            io.cancel(work);
        }
    }
    pub fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event) -> Option<Event> {
        for fork in self.forks.values_mut() {
            for id in std::mem::take(&mut fork.answered) {
                fork.retire(ui, &id);
            }
        }
        match event {
            Event::Done { work, result } if self.launches.contains_key(&work) => {
                let launch = self.launches.remove(&work).unwrap();
                let done = launch.done;
                let completion = std::rc::Rc::new(std::cell::RefCell::new(Some(done)));
                let captured = completion.clone();
                let launch = Launch {
                    done: Box::new(move |io, result| {
                        if let Some(done) = captured.borrow_mut().take() {
                            done(io, result);
                        }
                    }),
                    ..launch
                };
                let result = match result {
                    Ok(Output::Value(bytes)) => {
                        variables(&bytes).and_then(|environment| self.prepare(io, launch, environment))
                    }
                    Ok(_) => Err(error("side", "Unexpected parent environment")),
                    Err(e) => Err(error("io", e)),
                };
                if let Err(e) = result
                    && let Some(done) = completion.borrow_mut().take()
                {
                    deferred(done)(io, Err(e));
                }
            }
            Event::Done { work, result } if self.reads.contains_key(&work) => {
                let id = self.reads.remove(&work).unwrap();
                // Unreadable settings name nothing; Claude reports its own settings errors.
                let references = match result {
                    Ok(Output::Value(bytes)) => references(&bytes).unwrap_or_default(),
                    _ => References::default(),
                };
                self.settle(io, id, |sides, io| sides.resolve(io, id, &references));
            }
            Event::Done { work, result } if self.further.contains_key(&work) => {
                let id = self.further.remove(&work).unwrap();
                self.settle(io, id, |sides, io| {
                    let further = match result {
                        Ok(Output::Value(bytes)) => variables(&bytes)?,
                        Ok(_) => return Err(error("side", "Unexpected parent environment")),
                        Err(e) => return Err(error("io", e)),
                    };
                    let mut preparing = sides.preparing.remove(&id).unwrap();
                    preparing.environment.extend(further);
                    sides.spawn(io, preparing.launch, preparing.environment)
                });
            }
            Event::Done { work, result } if self.jobs.contains_key(&work) => {
                let pid = self.jobs.remove(&work).unwrap();
                if let Ok(Output::Process(process)) = result
                    && process.pid == pid
                    && let Some(fork) = self.forks.get_mut(&pid)
                    && process.executable == fork.parent.process.executable
                {
                    fork.process = Some(process);
                    self.ready(io, pid);
                } else {
                    self.close(io, pid, "Side process changed".into());
                }
            }
            Event::Ready { fd, read, write }
                if self.forks.values().any(|f| f.input == fd || f.output == fd) =>
            {
                let pid = *self
                    .forks
                    .iter()
                    .find(|(_, f)| f.input == fd || f.output == fd)
                    .unwrap()
                    .0;
                let result = (|| {
                    let fork = self.forks.get_mut(&pid).unwrap();
                    if write && fd == fork.input {
                        fork.flush(io)?;
                    }
                    if read && fd == fork.output {
                        let mut buffer = [0; 65_536];
                        match io.read(fd, &mut buffer) {
                            Ok(0) => return Err(error("side", "Side connection closed")),
                            Ok(count) => {
                                let mut docs = Vec::new();
                                fork.lines
                                    .feed(&buffer[..count], |line| {
                                        if let Ok(doc) = Json::parse(line) {
                                            docs.push(doc);
                                        }
                                        Ok(())
                                    })
                                    .map_err(|e| error("limit", format!("{e:?}")))?;
                                for doc in docs {
                                    fork.receive(io, ui, doc)?;
                                }
                            }
                            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                            Err(e) => return Err(error("io", e)),
                        }
                    }
                    Ok(())
                })();
                if let Err(e) = result {
                    self.close(io, pid, e.message);
                }
            }
            Event::Exit { pid, .. } if self.forks.contains_key(&pid) => {
                self.close(io, pid, "Side process exited".into());
            }
            event => return Some(event),
        }
        None
    }
}

#[cfg(test)]
#[path = "side.test.rs"]
mod tests;
