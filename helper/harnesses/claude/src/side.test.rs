//! What a Claude side takes from its parent's environment (docs/security.md, Side conversations).
use super::*;
use std::{cell::RefCell, collections::VecDeque, io, rc::Rc, time::Instant};

fn environment(values: &[(&str, &str)]) -> BTreeMap<String, Vec<u8>> {
    values.iter().map(|(name, value)| ((*name).to_owned(), value.as_bytes().to_vec())).collect()
}

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

/// The native job's answer for these settings files, as the side asks for it.
fn scanned(files: &[&[u8]]) -> References {
    let root = std::env::temp_dir().join(format!("dispatch-claude-references-{}-{}", std::process::id(), files.len()));
    std::fs::create_dir_all(&root).unwrap();
    let paths: Vec<PathBuf> = files.iter().enumerate().map(|(n, bytes)| {
        let path = root.join(format!("settings-{n}.json"));
        std::fs::write(&path, bytes).unwrap();
        path
    }).chain([root.join("missing.json")]).collect();
    let input = dispatch_helper_core::wire::body::encode_plain(&Data::Object(vec![
        ("paths", Data::Array(paths.iter().map(|path| Data::from(path.as_path())).collect())),
        ("keys", Data::Array(HELPERS.iter().map(|key| Data::String(key)).collect())),
        ("env", Data::Array(PROVIDERS.iter().map(|(selector, _)| Data::String(selector)).collect())),
    ])).unwrap();
    let answer = dispatch_helper_core::system::native("file.json.references", &input).unwrap();
    std::fs::remove_dir_all(&root).unwrap();
    references(&answer).unwrap()
}

#[test]
fn credential_commands_in_settings_name_the_variables_a_side_takes() {
    let references = scanned(&[
        br#"{"apiKeyHelper":"printf %s \"$SAM_EXAMPLE_KEY\" ${SAM_EXAMPLE_VAULT:-none} $1 $HOME $$","env":{"X":"$NOT_A_HELPER","SAM_SECRET":"synthetic"}}"#,
        br#"{"awsAuthRefresh":"sam-login --profile ${SAM_EXAMPLE_PROFILE}","otelHeadersHelper":"echo $SAM_EXAMPLE_OTEL"}"#,
        b"not json $SAM_EXAMPLE_IGNORED",
    ]);
    // Only names come back: never the settings' env values or other contents.
    assert!(references.env.is_empty());
    // HOME is already among ENVIRONMENT; positional and special parameters are no names.
    assert_eq!(referenced(&BTreeMap::new(), &references),
               strings(&["SAM_EXAMPLE_KEY", "SAM_EXAMPLE_VAULT", "SAM_EXAMPLE_PROFILE", "SAM_EXAMPLE_OTEL"]));
}

#[test]
fn a_cloud_provider_the_parent_selects_adds_its_variables() {
    let none = References::default();
    assert!(referenced(&environment(&[("CLAUDE_CODE_USE_BEDROCK", "0"), ("CLAUDE_CODE_USE_VERTEX", "")]), &none).is_empty());
    let bedrock = referenced(&environment(&[("CLAUDE_CODE_USE_BEDROCK", "1")]), &none);
    assert!(bedrock.iter().any(|name| name == "AWS_SECRET_ACCESS_KEY"));
    assert!(bedrock.iter().any(|name| name == "CLAUDE_CODE_SKIP_BEDROCK_AUTH"));
    assert!(!bedrock.iter().any(|name| name.starts_with("GOOGLE_") || name.starts_with("AZURE_")));
    let vertex = referenced(&environment(&[("CLAUDE_CODE_USE_VERTEX", "true")]), &none);
    assert!(vertex.contains(&"GOOGLE_APPLICATION_CREDENTIALS".to_owned()) && vertex.contains(&"ANTHROPIC_VERTEX_PROJECT_ID".to_owned()));
    assert!(!vertex.iter().any(|name| name.starts_with("AWS_")));
    let foundry = referenced(&environment(&[("CLAUDE_CODE_USE_FOUNDRY", "1")]), &none);
    assert!(foundry.contains(&"ANTHROPIC_FOUNDRY_API_KEY".to_owned()) && foundry.contains(&"AZURE_CLIENT_SECRET".to_owned()));
}

#[test]
fn a_cloud_provider_selected_in_settings_env_adds_its_variables_too() {
    let references = scanned(&[
        br#"{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","CLAUDE_CODE_USE_VERTEX":"0"}}"#,
        br#"{"env":{"CLAUDE_CODE_USE_FOUNDRY":true}}"#,
    ]);
    assert_eq!(references.env.get("CLAUDE_CODE_USE_BEDROCK").map(String::as_str), Some("1"));
    let names = referenced(&BTreeMap::new(), &references);
    assert!(names.contains(&"AWS_ACCESS_KEY_ID".to_owned()) && names.contains(&"AZURE_TENANT_ID".to_owned()));
    assert!(!names.iter().any(|name| name.starts_with("GOOGLE_")));
}

#[test]
fn declared_names_are_taken_once_and_never_loader_or_dispatch_variables() {
    let names = referenced(&environment(&[(DECLARED, "SAM_A,SAM_B:SAM_A LD_PRELOAD DYLD_INSERT_LIBRARIES DISPATCH_HELPER_ENDPOINT PATH 1BAD bad-name")]), &References::default());
    assert_eq!(names, strings(&["SAM_A", "SAM_B"]));
    // The cap counts names that pass, not what was filtered out.
    let many = format!("{} SAM_LAST", "LD_X ".repeat(100));
    assert_eq!(referenced(&environment(&[(DECLARED, &many)]), &References::default()), strings(&["SAM_LAST"]));
    for name in ENVIRONMENT {
        assert!(forwardable(name) || name == DECLARED, "{name}");
    }
}

#[test]
fn settings_are_read_where_the_side_loads_them() {
    let directory = Path::new("/work/project");
    let paths = |values: &[(&str, &str)], os| settings(&environment(values), directory, os);
    assert_eq!(paths(&[("HOME", "/home/sam"), ("CLAUDE_CONFIG_DIR", "/srv/claude")], "macos"), vec![
        PathBuf::from("/srv/claude/settings.json"),
        PathBuf::from("/work/project/.claude/settings.json"),
        PathBuf::from("/work/project/.claude/settings.local.json"),
        PathBuf::from("/Library/Application Support/ClaudeCode/managed-settings.json"),
    ]);
    assert_eq!(paths(&[("HOME", "/home/sam"), ("CLAUDE_CONFIG_DIR", "relative")], "linux")[..1], [PathBuf::from("/home/sam/.claude/settings.json")]);
    assert_eq!(paths(&[], "linux"), vec![
        PathBuf::from("/work/project/.claude/settings.json"),
        PathBuf::from("/work/project/.claude/settings.local.json"),
        PathBuf::from("/etc/claude-code/managed-settings.json"),
    ]);
}

#[derive(Default)]
struct Fake {
    next: u64,
    jobs: VecDeque<(Work, Job)>,
    deferred: VecDeque<Box<dyn FnOnce(&mut dyn Io)>>,
    spawned: Vec<Command>,
}
fn unsupported<T>() -> io::Result<T> {
    Err(io::ErrorKind::Unsupported.into())
}
impl Io for Fake {
    fn os(&self) -> &str {
        "linux"
    }
    fn defer(&mut self, callback: Box<dyn FnOnce(&mut dyn Io)>) {
        self.deferred.push_back(callback)
    }
    fn interest(&mut self, _: i32, _: bool, _: bool) -> io::Result<()> {
        Ok(())
    }
    fn read(&mut self, _: i32, _: &mut [u8]) -> io::Result<usize> {
        unsupported()
    }
    fn write(&mut self, _: i32, _: &[u8]) -> io::Result<usize> {
        unsupported()
    }
    fn close(&mut self, _: i32) {}
    fn accept(&mut self, _: i32) -> io::Result<i32> {
        unsupported()
    }
    fn child(&mut self, _: u32) -> io::Result<()> {
        Ok(())
    }
    fn timer(&mut self, _: Instant) {}
    fn now(&self) -> Instant {
        Instant::now()
    }
    fn random(&mut self, bytes: &mut [u8]) -> io::Result<()> {
        bytes.fill(7);
        Ok(())
    }
    fn submit(&mut self, job: Job) -> io::Result<Work> {
        self.next += 1;
        self.jobs.push_back((self.next, job));
        Ok(self.next)
    }
    fn cancel(&mut self, _: Work) -> bool {
        false
    }
    fn watch(&mut self, _: &Path, _: bool) -> io::Result<u64> {
        unsupported()
    }
    fn unwatch(&mut self, _: u64) {}
    fn spawn(&mut self, command: Command, _: Option<Grid>) -> io::Result<Spawned> {
        // Recorded, then refused: the launch ends with that error.
        self.spawned.push(command);
        unsupported()
    }
    fn resize(&mut self, _: i32, _: Grid) -> io::Result<()> {
        unsupported()
    }
    fn hangup(&mut self, _: i32) -> io::Result<()> {
        unsupported()
    }
    fn connect(&mut self, _: &Address) -> io::Result<i32> {
        unsupported()
    }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> {
        unsupported()
    }
    fn reply(&mut self, _: u64, _: &[u8]) -> io::Result<()> {
        unsupported()
    }
}
struct Quiet;
impl Ui for Quiet {
    fn update(&mut self, _: Update) {}
}

/// The names an environment job asks for, after checking it names the parent's exact process.
fn asked(job: &Job, parent: &Process) -> Vec<String> {
    let Job::Native { name: "environment", value } = job else { panic!("unexpected job") };
    let input = dispatch_helper_core::wire::body::decode_plain(value).unwrap();
    assert_eq!(input.get("pid").and_then(|v| v.unsigned()), Some(parent.pid.into()));
    let start: Vec<u64> = input.get("start").unwrap().array().unwrap().map(|n| n.unsigned().unwrap()).collect();
    assert_eq!(start, parent.start);
    assert_eq!(input.get("executable").and_then(|v| v.path()), Some(parent.executable.as_path()));
    input.get("names").unwrap().array().unwrap().map(|name| name.string().unwrap().to_owned()).collect()
}

fn answer(values: &[(&str, &[u8])]) -> io::Result<Output> {
    let value = Data::Object(values.iter().map(|(name, value)| (*name, Data::Bytes(value))).collect());
    Ok(Output::Value(dispatch_helper_core::wire::body::encode_plain(&value).unwrap()))
}

#[test]
fn an_api_key_helper_reading_a_custom_variable_gets_it_in_the_side() {
    let root = std::env::temp_dir().join(format!("dispatch-claude-side-{}", std::process::id()));
    let config = root.join("claude-home");
    std::fs::create_dir_all(&config).unwrap();
    std::fs::write(config.join("settings.json"), br#"{"apiKeyHelper":"printf %s \"$SAM_EXAMPLE_KEY\""}"#).unwrap();
    let parent = Process {
        pid: 4242,
        parent: 1,
        group: 4242,
        foreground: 4242,
        tty: 0,
        start: [1_800_000_000, 5],
        executable: PathBuf::from("/opt/claude/bin/claude"),
        arguments: Vec::new(),
        files: Vec::new(),
    };
    let binding = Binding { session: "0b9f6c1e-3a52-4d7e-9c41-5e2f8a7b6c10".into(), transcript: None, process: parent.clone() };
    let result: Rc<RefCell<Option<Result<Binding, Error>>>> = Rc::default();
    let saved = result.clone();
    let mut io = Fake::default();
    let mut sides = Sides::default();
    sides.open(&mut io, Launch {
        parent: binding,
        directory: root.join("work"),
        question: "what changed?".into(),
        model: Some("dispatch-fixture".into()),
        effort: None,
        read_only: true,
        done: Box::new(move |_, value| *saved.borrow_mut() = Some(value)),
    });
    let (mut further, mut environments) = (None, 0);
    while let Some((work, job)) = io.jobs.pop_front() {
        let asks = matches!(job, Job::Native { name: "environment", .. });
        let first = asks && environments == 0;
        environments += usize::from(asks);
        let output = match &job {
            Job::Native { name: "environment", .. } if first => {
                assert_eq!(asked(&job, &parent), strings(&ENVIRONMENT));
                let config = config.to_string_lossy().into_owned();
                answer(&[
                    ("HOME", b"/home/sam"),
                    ("PATH", b"/usr/bin:/bin"),
                    ("CLAUDE_CONFIG_DIR", config.as_bytes()),
                    (DECLARED, b"SAM_EXAMPLE_SCRIPT_TOKEN"),
                ])
            }
            Job::Native { name: "environment", .. } => {
                // The settings named one variable, the parent declared another.
                further = Some(asked(&job, &parent));
                answer(&[("SAM_EXAMPLE_KEY", b"synthetic-key"), ("SAM_EXAMPLE_SCRIPT_TOKEN", b"synthetic-token")])
            }
            Job::Native { name: "file.json.references", value } => {
                Ok(Output::Value(dispatch_helper_core::system::native("file.json.references", value).unwrap()))
            }
            _ => panic!("unexpected job"),
        };
        sides.event(&mut io, &mut Quiet, Event::Done { work, result: output });
        while let Some(callback) = io.deferred.pop_front() {
            callback(&mut io);
        }
    }
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(further, Some(strings(&["SAM_EXAMPLE_KEY", "SAM_EXAMPLE_SCRIPT_TOKEN"])));
    let command = io.spawned.pop().expect("the side was started");
    let mut variables: Vec<(String, Option<String>)> = command
        .get_envs()
        .map(|(name, value)| (name.to_string_lossy().into_owned(), value.map(|v| v.to_string_lossy().into_owned())))
        .collect();
    variables.sort();
    let config = config.to_string_lossy().into_owned();
    // Only these, from the parent: the declaration itself is not passed on.
    assert_eq!(variables, vec![
        ("CLAUDE_CONFIG_DIR".to_owned(), Some(config)),
        ("HOME".to_owned(), Some("/home/sam".to_owned())),
        ("PATH".to_owned(), Some("/usr/bin:/bin".to_owned())),
        ("SAM_EXAMPLE_KEY".to_owned(), Some("synthetic-key".to_owned())),
        ("SAM_EXAMPLE_SCRIPT_TOKEN".to_owned(), Some("synthetic-token".to_owned())),
    ]);
    // The refused spawn ends the launch with its error, once.
    assert!(matches!(result.borrow_mut().take(), Some(Err(_))));
}

#[test]
fn the_fork_runs_on_the_parents_model_and_effort() {
    assert_eq!(pinned(Some("claude-fable-5-2"), Some("xhigh")), strings(&["--model", "claude-fable-5-2", "--effort", "xhigh"]));
    assert_eq!(pinned(Some("claude-fable-5-2"), Some("High")), strings(&["--model", "claude-fable-5-2", "--effort", "high"]));
    // No effort, or one the command line would refuse: Claude's own default, never a failed fork.
    assert_eq!(pinned(Some("claude-fable-5-2"), None), strings(&["--model", "claude-fable-5-2"]));
    assert_eq!(pinned(Some("claude-fable-5-2"), Some("ultra")), strings(&["--model", "claude-fable-5-2"]));
    assert_eq!(pinned(None, Some("low")), strings(&["--effort", "low"]));
}
