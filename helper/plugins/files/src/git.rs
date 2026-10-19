//! files.git: one read-only git command through Job::Collect.
//!
//! The helper is the boundary, not the app: on a remote host the `git.read` grant must mean "read only" whoever
//! asks. So the subcommand and every argument are checked against an allow-list, the repository's configuration
//! that could run a program or write is overridden on the command line, and git sees a reduced environment.
//! Filters are the one kind of program repository configuration names under names of its own: immediately before
//! every command the helper asks git which filters are configured and turns each one off by name. This cannot be
//! cached: included config files and conditional includes selected by the current branch can change without
//! changing the repository's own config file. User and system configuration are ignored entirely.

use super::*;
use dispatch_helper_core::api::{CollectJob, Collected, Git};
use std::{ffi::OsString, os::unix::fs::MetadataExt, process::Command, time::Duration};

/// Long enough for `status` on a large tree on a slow disk; the process group is killed after it.
pub(super) const DEADLINE: Duration = Duration::from_secs(20);
/// Output bytes when the request names no bound, and the most any request gets.
const DEFAULT: u64 = 2 << 20;
const CAP: u64 = 8 << 20;
/// stderr kept for a failure's message; git's own errors are a few lines.
const ERRORS: usize = 64 << 10;
/// The most commits one `log` may ask for: the app pages 200 at a time.
const COMMITS: u64 = 1_000;

/// Before the subcommand, for every run. Repository and user configuration can name programs git runs while
/// reading (an fsmonitor hook, an external diff, gpg) or change the output the app parses; these win over it.
const GLOBAL: [&str; 41] = [
    "--no-pager",
    "-c",
    "core.quotepath=false",
    "-c",
    "color.ui=never",
    "-c",
    "color.diff=never",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "diff.external=",
    // The patch shape the app parses: `a/` and `b/` prefixes, paths from the top, submodules as one line.
    "-c",
    "diff.noprefix=false",
    "-c",
    "diff.mnemonicPrefix=false",
    "-c",
    "diff.srcPrefix=a/",
    "-c",
    "diff.dstPrefix=b/",
    "-c",
    "diff.relative=false",
    "-c",
    "diff.submodule=short",
    // `diff` refreshes the index's stat data on disk after comparing the work tree, whatever
    // GIT_OPTIONAL_LOCKS says (only `status` honours that); without the refresh its output is the same.
    "-c",
    "diff.autoRefreshIndex=false",
    // Signature checks run gpg or ssh-keygen, which write their own state.
    "-c",
    "log.showSignature=false",
    // `%D` names refs as the app reads them (`HEAD -> main, tag: v1`), not `refs/heads/main`.
    "-c",
    "log.decorate=short",
    // A `log` or `show` without a format uses `format.pretty`, which may hold `%G?` (a signature check).
    "-c",
    "format.pretty=medium",
    // Whatever still asks for a signature check finds no program to run.
    "-c",
    "gpg.program=/nonexistent",
    "-c",
    "gpg.openpgp.program=/nonexistent",
    "-c",
    "gpg.x509.program=/nonexistent",
    "-c",
    "gpg.ssh.program=/nonexistent",
    // A partial clone fetches missing objects on demand: no network, no new objects.
    "-c",
    "protocol.allow=never",
];

/// After `diff`, `log` and `show`: an empty `diff.external` alone makes git try to run "", and attribute diff
/// drivers (`diff.<driver>.command`, `textconv`) are programs the repository names.
const DIFFS: [&str; 2] = ["--no-ext-diff", "--no-textconv"];

/// After `status` and `diff`: looking inside a submodule's checkout runs git there, with that submodule's own
/// configuration (`.git/modules/<name>/config`), whose filters the helper does not read. A submodule is compared
/// by its commit alone. The option, not `diff.ignoreSubmodules`: `submodule.<name>.ignore` (even in the tracked
/// `.gitmodules`) wins over the configuration, never over the command line.
const SUBMODULES: &str = "--ignore-submodules=dirty";

/// What a run takes from the helper process. Tests give their own environment and deadline: the process
/// environment is shared by tests running in parallel, and a 20 s wait is too long for one.
#[derive(Clone)]
pub(super) struct Settings {
    /// None: the helper's own (a replay restores the recorded one before anything runs).
    pub environment: Option<Vec<(OsString, OsString)>>,
    pub deadline: Duration,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            environment: None,
            deadline: DEADLINE,
        }
    }
}

fn refused(message: String) -> Error {
    Error {
        code: "invalid_request",
        message,
    }
}

/// The variables git keeps: where programs and the user's own configuration are. Everything else goes,
/// `GIT_DIR`, `GIT_WORK_TREE`, `GIT_CONFIG_PARAMETERS`, `GIT_EXTERNAL_DIFF`, `GIT_SSH*`, `GIT_PROXY*` and the
/// locale among them. `GIT_CONFIG_NOSYSTEM` stays as the helper has it: it only reads less. `GNUPGHOME` is the
/// user's keyring, which a signature check reads.
fn kept(name: &OsString) -> bool {
    matches!(
        name.as_encoded_bytes(),
        b"PATH" | b"HOME" | b"USER" | b"GIT_CONFIG_NOSYSTEM" | b"GNUPGHOME"
    )
}

fn trusted_git(path: &OsString) -> Option<PathBuf> {
    let directories: Vec<PathBuf> = std::env::split_paths(path).collect();
    trusted("git", &directories, false)
}

/// The first `name` in `directories` that no other account can replace: the canonical executable and every directory
/// that names it are owned by root or this account and not writable by group or others. Checking only `bin` is
/// insufficient: another account could replace it through a writable ancestor after the check. `administrators`
/// (macOS) also takes what an administrator owns, and directories writable by the admin or wheel group: those accounts
/// can already replace anything root owns, so trusting them adds nothing. Homebrew's programs are owned that way.
fn trusted(name: &str, directories: &[PathBuf], administrators: bool) -> Option<PathBuf> {
    unsafe extern "C" { fn getuid() -> u32; }
    let uid = unsafe { getuid() };
    let owner = |owner: u32| owner == 0 || owner == uid || (administrators && administrator(owner));
    let unwritable = |mode: u32, group: u32| {
        mode & 0o002 == 0 && (mode & 0o020 == 0 || (administrators && cfg!(target_os = "macos") && matches!(group, 0 | 80)))
    };
    for directory in directories.iter().filter(|part| part.is_absolute()) {
        let Ok(candidate) = std::fs::canonicalize(directory.join(name)) else { continue };
        let Ok(metadata) = std::fs::metadata(&candidate) else { continue };
        let executable = metadata.is_file()
            && owner(metadata.uid())
            && unwritable(metadata.mode(), metadata.gid())
            && metadata.mode() & 0o111 != 0;
        let directories = candidate.parent().into_iter().flat_map(Path::ancestors).all(|path| {
            std::fs::metadata(path).is_ok_and(|metadata| {
                metadata.is_dir() && owner(metadata.uid()) && unwritable(metadata.mode(), metadata.gid())
            })
        });
        if executable && directories {
            return Some(candidate);
        }
    }
    None
}

/// Whether the account `uid` is in macOS's admin group (80), primary or not.
#[cfg(target_os = "macos")]
fn administrator(uid: u32) -> bool {
    use std::ffi::c_char;
    #[repr(C)]
    struct Passwd {
        name: *mut c_char,
        password: *mut c_char,
        uid: u32,
        gid: u32,
        change: i64,
        class: *mut c_char,
        gecos: *mut c_char,
        home: *mut c_char,
        shell: *mut c_char,
        expire: i64,
    }
    unsafe extern "C" {
        fn getpwuid_r(uid: u32, entry: *mut Passwd, bytes: *mut c_char, length: usize, result: *mut *mut Passwd) -> i32;
        fn getgrouplist(name: *const c_char, base: i32, groups: *mut i32, count: *mut i32) -> i32;
    }
    let mut entry = std::mem::MaybeUninit::<Passwd>::zeroed();
    let mut bytes = vec![0 as c_char; 16_384];
    let mut result = std::ptr::null_mut();
    // SAFETY: the record and its strings live in `entry` and `bytes` for the rest of this function.
    let status = unsafe { getpwuid_r(uid, entry.as_mut_ptr(), bytes.as_mut_ptr(), bytes.len(), &mut result) };
    if status != 0 || result.is_null() {
        return false;
    }
    let entry = unsafe { entry.assume_init() };
    if entry.name.is_null() {
        return false;
    }
    let mut groups = vec![0i32; 256];
    let mut count = groups.len() as i32;
    // SAFETY: `name` is the record's terminated string; `groups` holds `count` entries.
    let found = unsafe { getgrouplist(entry.name, entry.gid as i32, groups.as_mut_ptr(), &mut count) };
    found == 0 && groups[..count.clamp(0, 256) as usize].contains(&80)
}

#[cfg(not(target_os = "macos"))]
fn administrator(_: u32) -> bool {
    false
}

/// Where a signature check's programs are looked for after the helper's PATH: Homebrew's, GPG Suite's and the
/// system's.
const SIGNING: [&str; 5] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/MacGPG2/bin", "/usr/bin", "/bin"];

/// What `verify-commit` runs, set after GLOBAL (which points every signing program nowhere), so the repository's own
/// configuration names none of it: gpg and ssh-keygen as `trusted` finds them, never X.509's gpgsm, and the SSH
/// signers the user allows (their own configuration's `gpg.ssh.allowedSignersFile`, else none): a repository naming
/// its own file would vouch for its own key.
fn signing(path: &OsString, signers: Option<&str>) -> Vec<String> {
    let mut directories: Vec<PathBuf> = std::env::split_paths(path).collect();
    directories.extend(SIGNING.iter().map(PathBuf::from));
    let found = |name: &str| {
        trusted(name, &directories, true).map_or_else(|| "/nonexistent".to_owned(), |path| path.display().to_string())
    };
    let gpg = found("gpg");
    [
        format!("gpg.program={gpg}"),
        format!("gpg.openpgp.program={gpg}"),
        format!("gpg.ssh.program={}", found("ssh-keygen")),
        "gpg.x509.program=/nonexistent".to_owned(),
        format!("gpg.ssh.allowedSignersFile={}", signers.unwrap_or("/dev/null")),
        // A repository could otherwise lower the trust a good signature needs.
        "gpg.minTrustLevel=undefined".to_owned(),
    ]
    .into_iter()
    .flat_map(|value| ["-c".to_owned(), value])
    .collect()
}

/// `git -C <path>`, its environment and GLOBAL, then each filter of the repository turned off, then `args`.
fn command(settings: &Settings, path: &Path, filters: &[String], extra: &[String], args: &[&str]) -> Command {
    let environment = match &settings.environment {
        Some(environment) => environment.clone(),
        None => std::env::vars_os().collect(),
    };
    let raw_path = environment.iter().find(|(name, _)| name.as_encoded_bytes() == b"PATH")
        .map(|(_, value)| value.clone()).unwrap_or_else(|| OsString::from("/usr/bin:/bin"));
    let program = trusted_git(&raw_path).unwrap_or_else(|| PathBuf::from("/nonexistent/dispatch-git"));
    let mut child_directories: Vec<&Path> = program.parent().into_iter().collect();
    for directory in [Path::new("/usr/bin"), Path::new("/bin")] {
        if !child_directories.contains(&directory) { child_directories.push(directory); }
    }
    let child_path = std::env::join_paths(child_directories).unwrap_or_else(|_| OsString::from("/usr/bin:/bin"));
    let mut command = Command::new(&program);
    command.env_clear();
    for (name, value) in environment.into_iter().filter(|(name, _)| kept(name)) {
        if name.as_encoded_bytes() == b"PATH" {
            // An empty or relative PATH component means the helper's current directory. A read request must
            // never turn a repository-local `git` executable into code execution.
            command.env(name, &child_path);
        } else if name.as_encoded_bytes() != b"HOME" || Path::new(&value).is_absolute() {
            command.env(name, value);
        }
    }
    // The app matches git's own words (`not a git repository`) and its English dates; a translated git breaks
    // that. File names are unaffected: core.quotepath=false prints them as their bytes in any locale.
    command.env("LC_ALL", "C");
    // Status and diff refresh the index's stat data when they can lock it: a write, and a lock a user's own
    // git would trip over.
    command.env("GIT_OPTIONAL_LOCKS", "0");
    command.env("GIT_TERMINAL_PROMPT", "0");
    command.env("GIT_PAGER", "cat");
    command.env("GIT_NO_LAZY_FETCH", "1");
    // User and system configuration are not needed to read repository state and add independent executable
    // configuration sources. Repository-local configuration is inspected afresh immediately below.
    command.env("GIT_CONFIG_GLOBAL", "/dev/null");
    command.env("GIT_CONFIG_SYSTEM", "/dev/null");
    command.env("GIT_CONFIG_NOSYSTEM", "1");
    command.arg("-C").arg(path).args(GLOBAL);
    for name in filters {
        // Empty commands are no commands (git skips them), and a filter that is not required may then do
        // nothing, so the file is compared as it is on disk.
        for key in ["clean=", "process=", "required=false"] {
            command.arg("-c").arg(format!("filter.{name}.{key}"));
        }
    }
    command.args(extra);
    command.arg(args[0]);
    if matches!(args[0], "diff" | "log" | "show") {
        command.args(DIFFS);
    }
    if matches!(args[0], "status" | "diff") {
        command.arg(SUBMODULES);
    }
    command.args(&args[1..]);
    command
}

/// The configuration keys that name a filter's program: `filter.<name>.<key>`.
const FILTERS: &str = r"^filter\..*\.(clean|process|smudge)$";

/// One request, carried through the probe to its run.
struct Request {
    settings: Settings,
    path: PathBuf,
    args: Vec<String>,
    /// `verify-commit`: the user's allowed SSH signers file, once looked up.
    signers: Option<String>,
    limit: usize,
    end: u8,
    done: Done<Git>,
}

pub(super) fn git(
    access: &transfer::SharedAccess,
    io: &mut dyn Io,
    settings: &Settings,
    path: &Path,
    args: &[String],
    limit: u64,
    done: Done<Git>,
) {
    if !path.is_absolute() || path.as_os_str().as_encoded_bytes().contains(&0) {
        return done(io, Err(error("invalid_request")));
    }
    let end = match allowed(args) {
        Ok(end) => end,
        Err(message) => return done(io, Err(refused(message))),
    };
    if !access.begin_read() {
        return done(io, Err(error("busy")));
    }
    let access = access.clone();
    let done: Done<Git> = Box::new(move |io, result| {
        access.end_read();
        done(io, result);
    });
    let request = Request {
        settings: settings.clone(),
        path: path.to_path_buf(),
        args: args.to_vec(),
        signers: None,
        limit: if limit == 0 { DEFAULT } else { limit.min(CAP) } as usize,
        end,
        done,
    };
    if args[0] == "verify-commit" {
        return signers(io, request, 0);
    }
    list(io, request);
}

/// The user's own configuration files, where `gpg.ssh.allowedSignersFile` usually is (git reads neither while the
/// helper runs it).
fn configurations(settings: &Settings) -> Vec<PathBuf> {
    let environment = match &settings.environment {
        Some(environment) => environment.clone(),
        None => std::env::vars_os().collect(),
    };
    let home = environment.iter().find(|(name, _)| name.as_encoded_bytes() == b"HOME").map(|(_, value)| PathBuf::from(value));
    let Some(home) = home.filter(|home| home.is_absolute()) else { return Vec::new() };
    vec![home.join(".gitconfig"), home.join(".config/git/config")]
}

/// Looks up the allowed SSH signers in the user's configuration files in turn (`config --file … --includes --path`),
/// then runs the check.
fn signers(io: &mut dyn Io, request: Request, index: usize) {
    let files = configurations(&request.settings);
    let Some(file) = files.get(index).filter(|file| file.is_file()).cloned() else {
        return if index + 1 < files.len() { signers(io, request, index + 1) } else { list(io, request) };
    };
    let file = file.display().to_string();
    let args = ["config", "--file", &file, "--includes", "--path", "--get", "gpg.ssh.allowedSignersFile"];
    internal(io, request, &args, move |io, mut request, collected| {
        let value = String::from_utf8_lossy(&collected.stdout).trim().to_owned();
        if collected.status == Some(0) && Path::new(&value).is_absolute() && !value.contains('\n') {
            request.signers = Some(value);
            return list(io, request);
        }
        if index + 1 < configurations(&request.settings).len() { signers(io, request, index + 1) } else { list(io, request) }
    });
}

/// An internal git command, never through the allow-list, with the run's environment and deadline; its
/// failure to run at all answers the request.
fn internal(
    io: &mut dyn Io,
    request: Request,
    args: &[&str],
    then: impl FnOnce(&mut dyn Io, Request, Collected) + 'static,
) {
    let job = Job::Collect(CollectJob {
        command: command(&request.settings, &request.path, &[], &[], args),
        timeout: request.settings.deadline,
        stdout: 64 << 10,
        stderr: ERRORS,
    });
    transfer::job(io, job, move |io, result| match result {
        Ok(Output::Collected(collected)) => then(io, request, collected),
        Ok(_) => (request.done)(io, Err(error("internal"))),
        Err(value) => {
            let answer = failed(value, request.settings.deadline);
            (request.done)(io, answer)
        }
    });
}

/// The filters the configuration names, every scope git reads (the repository's, the user's, includes). This is
/// deliberately a fresh query immediately before the requested command; no single config file identifies all of
/// those scopes or conditional includes.
fn list(io: &mut dyn Io, request: Request) {
    let args = ["config", "-z", "--name-only", "--get-regexp", FILTERS];
    internal(io, request, &args, move |io, request, collected| {
        if collected.truncated {
            let message = "the repository's configuration names more filters than the helper reads".into();
            return (request.done)(io, Err(Error { code: "unsupported", message }));
        }
        // 1: no key matched. Anything else is git's own failure (a broken config file), which the request's
        // command would meet too.
        if !matches!(collected.status, Some(0 | 1)) {
            let answer = answer(collected, request.limit, request.end);
            return (request.done)(io, Ok(answer));
        }
        let mut filters = Vec::new();
        for key in collected.stdout.split(|&b| b == 0).filter(|key| !key.is_empty()) {
            let key = String::from_utf8_lossy(key);
            // The subsection is everything between the section and the last dot (it may hold dots itself).
            let Some(name) = key
                .strip_prefix("filter.")
                .and_then(|rest| rest.rsplit_once('.'))
                .map(|(name, _)| name)
            else {
                continue;
            };
            // `-c` splits its argument at the first `=`: a name holding one cannot be turned off, so the
            // command does not run. A name that is not UTF-8 is not the name git would match either.
            if name.contains(['=', '\u{fffd}']) {
                let message = format!("the repository's filter {name:?} cannot be turned off, so git does not run");
                return (request.done)(io, Err(Error { code: "unsupported", message }));
            }
            if !filters.iter().any(|known| known == name) {
                filters.push(name.to_owned());
            }
        }
        run(io, request, filters);
    });
}

/// The request's own command, with the repository's filters turned off.
fn run(io: &mut dyn Io, request: Request, filters: Vec<String>) {
    let args: Vec<&str> = request.args.iter().map(String::as_str).collect();
    let verify = args[0] == "verify-commit";
    let extra = if verify {
        let environment = match &request.settings.environment {
            Some(environment) => environment.clone(),
            None => std::env::vars_os().collect(),
        };
        let path = environment.into_iter().find(|(name, _)| name.as_encoded_bytes() == b"PATH").map(|(_, value)| value);
        signing(&path.unwrap_or_else(|| OsString::from("/usr/bin:/bin")), request.signers.as_deref())
    } else {
        Vec::new()
    };
    let job = Job::Collect(CollectJob {
        command: command(&request.settings, &request.path, &filters, &extra, &args),
        timeout: request.settings.deadline,
        stdout: request.limit,
        stderr: ERRORS,
    });
    transfer::job(io, job, move |io, result| {
        let answer = match result {
            Ok(Output::Collected(collected)) if verify => Ok(verdict(collected)),
            Ok(Output::Collected(collected)) => Ok(answer(collected, request.limit, request.end)),
            Ok(_) => Err(error("internal")),
            Err(value) => failed(value, request.settings.deadline),
        };
        (request.done)(io, answer);
    });
}

/// A git that did not run to an answer: past the deadline, not installed, or refused for now.
fn failed(value: io::Error, deadline: Duration) -> Result<Git, Error> {
    match value.kind() {
        io::ErrorKind::TimedOut => Ok(Git {
            status: -1,
            output: format!("git took longer than {} s", deadline.as_secs()),
            truncated: false,
        }),
        io::ErrorKind::NotFound => Err(Error {
            code: "unsupported",
            message: "git is not installed on this host".into(),
        }),
        io::ErrorKind::WouldBlock => Err(Error {
            code: "busy",
            message: "too many git commands are waiting on this host".into(),
        }),
        _ => Err(native(value)),
    }
}

/// `verify-commit --raw`: what gpg or ssh-keygen said (git passes it to stderr), whatever the status, which says
/// whether the signature was good.
fn verdict(collected: Collected) -> Git {
    let mut output = String::from_utf8_lossy(&collected.stderr).into_owned();
    output.push_str(&String::from_utf8_lossy(&collected.stdout));
    Git {
        status: collected.status.map_or(-1, Into::into),
        output,
        truncated: false,
    }
}

/// stdout for a run that succeeded or was cut at the bound (stopped by the helper, so its status is 0), stderr
/// for one that failed.
fn answer(collected: Collected, limit: usize, end: u8) -> Git {
    if collected.truncated || collected.status == Some(0) {
        let (output, truncated) = bounded(&collected.stdout, limit, end, collected.truncated);
        return Git {
            status: 0,
            output,
            truncated,
        };
    }
    let mut output = String::from_utf8_lossy(&collected.stderr).into_owned();
    let status = match collected.status {
        Some(status) => status.into(),
        None => {
            if output.is_empty() {
                output = "git was stopped by a signal".into();
            }
            -1
        }
    };
    Git {
        status,
        output,
        truncated: false,
    }
}

/// `bytes` as text of at most `limit` bytes; past it (or already cut) it ends after the last record end.
/// Invalid UTF-8 becomes U+FFFD, three bytes for one, so the bound applies to the text.
fn bounded(bytes: &[u8], limit: usize, end: u8, cut: bool) -> (String, bool) {
    let text = String::from_utf8_lossy(bytes);
    if !cut && text.len() <= limit {
        return (text.into_owned(), false);
    }
    let window = &text.as_bytes()[..text.len().min(limit)];
    // `end` is ASCII, so the byte after it starts a character.
    let length = window.iter().rposition(|&b| b == end).map_or(0, |at| at + 1);
    (text[..length].to_owned(), true)
}

/// Checks `args` against the allow-list; the answer is the byte that ends one record of its output (NUL with
/// `-z` or a format's `%x00`, else the `%x1e` a format asks for, else a newline), where a cut output stops.
fn allowed(args: &[String]) -> Result<u8, String> {
    let Some((name, rest)) = args.split_first() else {
        return Err("no git command".into());
    };
    let check: fn(&str) -> bool = match name.as_str() {
        "rev-parse" => rev_parse,
        "status" => status,
        "diff" => diff,
        "log" => log,
        "show" => show,
        "for-each-ref" => refs,
        "verify-commit" => verify,
        _ => return Err(format!("git {name} is not allowed")),
    };
    let paths = matches!(name.as_str(), "status" | "diff" | "log" | "show");
    let mut end = b'\n';
    let mut arguments = rest.iter();
    while let Some(argument) = arguments.next() {
        let refuse = || format!("git {name} does not allow {argument}");
        if argument.contains('\0') {
            return Err(refuse());
        }
        if argument == "--" && paths {
            // Inside a repository git keeps pathspecs in it, but `diff` outside one (or naming a path outside
            // the work tree) is an implicit `--no-index` that compares any two files. The app names paths
            // relative to the repository's top, so nothing absolute or climbing out is needed.
            for path in arguments.by_ref() {
                let climbs = path.split('/').any(|part| part == "..");
                if path.contains('\0') || path.starts_with('/') || climbs {
                    return Err(format!("git {name} does not allow the path {path}"));
                }
            }
            break;
        }
        // `-n` takes its count as the next argument.
        if name == "log" && argument == "-n" {
            match arguments.next() {
                Some(value) if count(value, COMMITS) => continue,
                Some(value) => return Err(format!("git log does not allow -n {value}")),
                None => return Err(refuse()),
            }
        }
        if !check(argument) {
            return Err(refuse());
        }
        // A format's `%x00` is the record end the app should use: `git commit` refuses a NUL in a message,
        // while a 0x1E in one would forge a record end.
        let asks = |escape: &str| format(argument).is_some_and(|value| value.to_ascii_lowercase().contains(escape));
        if argument == "-z" || asks("%x00") {
            end = 0;
        } else if end != 0 && asks("%x1e") {
            end = 0x1e;
        }
    }
    Ok(end)
}

fn rev_parse(argument: &str) -> bool {
    matches!(argument, "--show-toplevel" | "--abbrev-ref" | "--verify" | "--short") || reference(argument)
}

fn status(argument: &str) -> bool {
    matches!(
        argument,
        "--porcelain=v2"
            | "--branch"
            | "-z"
            | "--untracked-files=normal"
            | "--untracked-files=all"
            | "--untracked-files=no"
            | "--ignored"
            | "--ignored=matching"
            | "--ignored=traditional"
            | "--ignored=no"
            | "--no-renames"
    )
}

/// What `diff` and `show` share: the shape of the change list (counts, or the A/D/M/R letters numstat lacks) and
/// of each patch.
fn patch(argument: &str) -> bool {
    matches!(
        argument,
        "--numstat" | "--name-status" | "--stat" | "-z" | "--no-color" | "--find-renames" | "-M"
    ) || argument
        .strip_prefix("-U")
        .or_else(|| argument.strip_prefix("--unified="))
        .is_some_and(|lines| count(lines, u64::MAX))
}

fn diff(argument: &str) -> bool {
    // `--binary` is not in the list: a patch that carries whole files is a write's worth of output.
    matches!(argument, "--cached" | "--staged" | "HEAD") || patch(argument) || hash(argument)
}

fn log(argument: &str) -> bool {
    if let Some(value) = format(argument) {
        return pretty(value);
    }
    if let Some(value) = argument.strip_prefix("--max-count=").or_else(|| argument.strip_prefix("-n")) {
        return count(value, COMMITS);
    }
    if let Some(value) = argument.strip_prefix("--skip=") {
        return count(value, u64::MAX);
    }
    // Any text: git matches it, nothing runs it.
    if argument.starts_with("--grep=") || argument.starts_with("--author=") {
        return true;
    }
    matches!(
        argument,
        "--date=unix"
            | "--date=iso-strict"
            | "--date=raw"
            | "--all"
            | "--branches"
            | "--remotes"
            | "--tags"
            | "--regexp-ignore-case"
            | "-i"
            | "--fixed-strings"
            | "-F"
            | "--topo-order"
            | "--date-order"
            | "--first-parent"
            | "--no-merges"
            | "--decorate=full"
            | "--decorate=short"
            | "--decorate=no"
    ) || reference(argument)
}

/// `verify-commit --raw <hash>`: the one command that checks a signature, with programs the helper picks (`signing`).
fn verify(argument: &str) -> bool {
    argument == "--raw" || hash(argument)
}

fn show(argument: &str) -> bool {
    if let Some(value) = format(argument) {
        return pretty(value);
    }
    matches!(argument, "-s" | "--no-patch") || patch(argument) || hash(argument)
}

fn refs(argument: &str) -> bool {
    if let Some(value) = argument.strip_prefix("--format=") {
        return placeholders(value);
    }
    if let Some(field) = argument.strip_prefix("--sort=") {
        let field = field.strip_prefix('-').unwrap_or(field);
        return !field.is_empty()
            && !field.starts_with("signature")
            && field
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b':' | b'(' | b')' | b'-' | b'_'));
    }
    if let Some(value) = argument.strip_prefix("--count=") {
        return count(value, u64::MAX);
    }
    if let Some(value) = argument.strip_prefix("--points-at=") {
        return hash(value);
    }
    matches!(argument, "refs/heads" | "refs/remotes" | "refs/tags")
}

/// A `--format=` / `--pretty=` value (log and show).
fn format(argument: &str) -> Option<&str> {
    argument
        .strip_prefix("--format=")
        .or_else(|| argument.strip_prefix("--pretty="))
}

/// A log or show format git takes as one: a value without `%` (and without `format:` or `tformat:`) is the
/// name of a format, `pretty.<name>` in the configuration, which may hold anything, `%G?` included.
fn pretty(value: &str) -> bool {
    // Built in, and git ignores a `pretty.raw` alias: the commit's headers as stored (a signature's among them),
    // nothing checked.
    if value == "raw" {
        return true;
    }
    let named = !value.is_empty()
        && !value.contains('%')
        && !value.starts_with("format:")
        && !value.starts_with("tformat:");
    !named && placeholders(value)
}

/// Placeholders, `%x..` / `%..` escapes and literal text, but none that verifies a signature (`%G…` in log
/// formats, with or without a `+`, `-` or space modifier; `%(signature…)` in ref formats, dereferenced with
/// `*` or not): those run gpg or ssh-keygen. Peeled ref atoms (`%(*objectname)`) only read.
fn placeholders(value: &str) -> bool {
    let mut rest = value;
    while let Some(at) = rest.find('%') {
        rest = &rest[at + 1..];
        if let Some(after) = rest.strip_prefix('%') {
            rest = after;
            continue;
        }
        let placeholder = rest.strip_prefix(['+', '-', ' ']).unwrap_or(rest);
        let atom = placeholder.strip_prefix("(").map(|atom| atom.strip_prefix('*').unwrap_or(atom));
        if placeholder.starts_with('G') || atom.is_some_and(|atom| atom.starts_with("signature")) {
            return false;
        }
    }
    true
}

/// Decimal digits up to `most`.
fn count(value: &str, most: u64) -> bool {
    !value.is_empty()
        && value.len() <= 19
        && value.bytes().all(|b| b.is_ascii_digit())
        && value.parse::<u64>().is_ok_and(|n| n <= most)
}

/// An abbreviated or full object name.
fn hash(value: &str) -> bool {
    (4..=64).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_hexdigit())
}

/// A ref name as `git check-ref-format` allows it, which keeps out options (a leading `-`) and revision
/// syntax (`..`, `@{`, `^`, `~`, `:`).
fn reference(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && !value.starts_with(['-', '/', '.'])
        && !value.ends_with(['/', '.'])
        && !value.ends_with(".lock")
        && !value.contains("..")
        && !value.contains("@{")
        && !value.contains("//")
        && value.chars().all(|c| {
            !c.is_control() && !matches!(c, ' ' | '~' | '^' | ':' | '?' | '*' | '[' | '\\')
        })
}

#[cfg(test)]
#[path = "git.test.rs"]
mod tests;
