//! `chat.limits`: the claude.ai plan's usage windows, read only when a client asks. Claude Code gives them to its
//! status line command alone, so a read sets one in the session's own `.claude/settings.local.json` (the file of that
//! folder alone, above the user's and the project's settings), takes the session's one run of it and puts the file
//! back, byte for byte. The command is the installed hook's; Claude's JSON comes in like a hook's and only
//! `rate_limits` is kept. A status line that arrives with no read waiting was left by a helper that died mid-read:
//! it takes its own entry out again (`Repair`). docs/security.md, Agent chat.
//!
//! The session's starting folder on purpose. In a git subfolder or worktree Claude Code keeps its own local file at
//! the repository's root, and one there would reach every session of the repository; it still reads this one, and
//! notices it mid-session and mid-turn (checked with 2.1.321). A `statusLine` in the root's local file wins over it:
//! that read ends `expired`.
use crate::history::{error, text};
use dispatch_helper_core::{
    api::*,
    json::{self, Data, Format, Json, Kind, Value},
};
use std::{
    collections::BTreeMap,
    io,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

/// How long Claude Code gets to run the command it was just given.
const WAIT: Duration = Duration::from_secs(5);
/// More than any settings file a person keeps; a larger one is left alone.
const LARGEST: u64 = 1_048_576;

/// The JSON Claude Code gives a status line: no hook event, and the session's `workspace`.
pub(crate) fn status_line(root: Value<'_>) -> bool {
    root.get("hook_event_name").is_none() && root.get("workspace").is_some_and(|value| value.kind() == Kind::Object)
}

/// The windows of a status line's `rate_limits`; each may be absent, and the object too.
pub(crate) fn windows(root: Value<'_>) -> Vec<LimitWindow> {
    let Some(limits) = root.get("rate_limits") else { return Vec::new() };
    ["five_hour", "seven_day"]
        .into_iter()
        .filter_map(|name| {
            let window = limits.get(name)?;
            let used = window.get("used_percentage")?.number().filter(|n| n.is_finite() && *n >= 0.0 && *n <= 1000.0)?;
            let resets = window.get("resets_at")?.number().filter(|n| n.is_finite() && *n > 0.0 && *n < 1e12)?;
            Some(LimitWindow(name.to_owned(), used.round() as u64, resets as u64))
        })
        .collect()
}

fn invalid() -> Error {
    error("settings", "The folder's Claude settings could not be read")
}

/// `before` with the status line set. A folder with a status line of its own is left alone.
fn with_status_line(before: Option<&[u8]>, command: &str) -> Result<Vec<u8>, Error> {
    let document = before.map(Json::parse).transpose().map_err(|_| invalid())?;
    let root = document.as_ref().map(Json::root);
    if root.is_some_and(|value| value.kind() != Kind::Object) {
        return Err(invalid());
    }
    if root.is_some_and(|value| value.get("statusLine").is_some()) {
        return Err(error("unavailable", "This folder has its own Claude status line"));
    }
    let mut fields =
        root.and_then(Value::object).into_iter().flatten().map(|(key, value)| (key, Data::Value(value))).collect::<Vec<_>>();
    fields.push((
        "statusLine",
        Data::Object(vec![("type", Data::String("command")), ("command", Data::String(command))]),
    ));
    json::write_with(&Data::Object(fields), Format::PrettySortedUnescaped)
}

/// `current` without a status line running `command`: None when it holds no such entry, empty when nothing is left.
fn without_status_line(current: &[u8], command: &str) -> Option<Vec<u8>> {
    let document = Json::parse(current).ok()?;
    let root = document.root();
    if root.kind() != Kind::Object || root.get("statusLine").and_then(|line| text(line, "command")) != Some(command) {
        return None;
    }
    let fields =
        root.object()?.filter(|(key, _)| *key != "statusLine").map(|(key, value)| (key, Data::Value(value))).collect::<Vec<_>>();
    if fields.is_empty() {
        return Some(Vec::new());
    }
    json::write_with(&Data::Object(fields), Format::PrettySortedUnescaped).ok()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Stage {
    Folder,
    Stat,
    Read(u64),
    Write,
    Written,
    Waiting,
    Restore,
    RemoveFolder,
}

/// One read's steps; the jobs are the harness's to run.
pub(crate) struct Reading {
    stage: Stage,
    folder: PathBuf,
    path: PathBuf,
    command: String,
    session: String,
    before: Option<Vec<u8>>,
    expected: Expected,
    written: Option<Guard>,
    made_folder: bool,
    answer: Option<Result<Vec<LimitWindow>, Error>>,
    deadline: Option<Instant>,
    done: Option<Done<Vec<LimitWindow>>>,
}

pub(crate) enum Next {
    Job(Job),
    /// Waiting for Claude Code, until this time.
    Wait(Instant),
    Finished,
}

impl Reading {
    pub fn new(directory: &Path, command: String, session: String, done: Done<Vec<LimitWindow>>) -> (Self, Job) {
        let folder = directory.join(".claude");
        let job = Job::Stat { path: folder.clone(), follow: false };
        let path = folder.join("settings.local.json");
        (
            Self {
                stage: Stage::Folder,
                folder,
                path,
                command,
                session,
                before: None,
                expected: Expected::Absent,
                written: None,
                made_folder: false,
                answer: None,
                deadline: None,
                done: Some(done),
            },
            job,
        )
    }

    fn write(&mut self) -> Result<Next, Error> {
        let bytes = with_status_line(self.before.as_deref(), &self.command)?;
        self.stage = Stage::Write;
        Ok(Next::Job(Job::Write { path: self.path.clone(), bytes, mode: 0o600, expected: self.expected, parent: None }))
    }

    fn fail(&mut self, failure: Error) -> Next {
        self.answer.get_or_insert(Err(failure));
        Next::Finished
    }

    /// The file holds the status line: from here every way out goes through `restore`.
    fn restore(&mut self, now: Instant) -> Next {
        let Some(written) = self.written else {
            // Not yet stated: the Written step comes back here.
            return Next::Wait(self.deadline.unwrap_or(now));
        };
        self.stage = Stage::Restore;
        let expected = Expected::Same(written);
        Next::Job(match self.before.clone() {
            Some(bytes) => Job::Write { path: self.path.clone(), bytes, mode: 0o600, expected, parent: None },
            None => Job::Remove { path: self.path.clone(), expected },
        })
    }

    pub fn complete(&mut self, now: Instant, output: io::Result<Output>) -> Next {
        let missing = output.as_ref().is_err_and(|e| e.kind() == io::ErrorKind::NotFound);
        match (self.stage, output) {
            (Stage::Folder, _) if missing => {
                self.made_folder = true;
                match self.write() {
                    Ok(next) => next,
                    Err(e) => self.fail(e),
                }
            }
            (Stage::Folder, Ok(Output::Metadata(metadata))) if metadata.kind == FileKind::Directory => {
                self.stage = Stage::Stat;
                Next::Job(Job::Stat { path: self.path.clone(), follow: false })
            }
            (Stage::Stat, _) if missing => match self.write() {
                Ok(next) => next,
                Err(e) => self.fail(e),
            },
            (Stage::Stat, Ok(Output::Metadata(metadata))) if metadata.kind == FileKind::File && metadata.size <= LARGEST => {
                self.stage = Stage::Read(metadata.size);
                Next::Job(Job::Read { path: self.path.clone(), offset: 0, length: metadata.size })
            }
            (Stage::Read(size), Ok(Output::Read { before, after, bytes })) => {
                if before != after || before.size != size || bytes.len() as u64 != size {
                    return self.fail(error("changed", "The folder's Claude settings changed"));
                }
                self.expected = Expected::Same(Guard::from(before));
                self.before = Some(bytes);
                match self.write() {
                    Ok(next) => next,
                    Err(e) => self.fail(e),
                }
            }
            (Stage::Write, Ok(Output::Written)) => {
                self.stage = Stage::Written;
                self.deadline = Some(now + WAIT);
                Next::Job(Job::Stat { path: self.path.clone(), follow: false })
            }
            (Stage::Written, Ok(Output::Metadata(metadata))) if metadata.kind == FileKind::File => {
                self.written = Some(Guard::from(metadata));
                self.stage = Stage::Waiting;
                if self.answer.is_some() { self.restore(now) } else { Next::Wait(self.deadline.unwrap_or(now)) }
            }
            // Put back, or changed under us (then the next status line repairs it): the folder either way.
            (Stage::Restore, _) if self.made_folder => {
                self.stage = Stage::RemoveFolder;
                Next::Job(Job::Remove { path: self.folder.clone(), expected: Expected::Any })
            }
            (Stage::Restore | Stage::RemoveFolder, _) => Next::Finished,
            (_, Err(e)) => self.fail(error("io", e)),
            _ => self.fail(invalid()),
        }
    }

    /// Claude Code ran the command for this read's session.
    pub fn answered(&mut self, now: Instant, session: Option<&str>, windows: Vec<LimitWindow>) -> Option<Next> {
        if session != Some(self.session.as_str()) || self.answer.is_some() {
            return None;
        }
        self.answer = Some(Ok(windows));
        (self.stage == Stage::Waiting).then(|| self.restore(now))
    }

    /// Time ran out with no run of the command.
    pub fn expired(&mut self, now: Instant) -> Option<Next> {
        if self.stage != Stage::Waiting || self.deadline.is_none_or(|deadline| now < deadline) {
            return None;
        }
        self.answer.get_or_insert(Err(error("expired", "Claude Code did not run its status line")));
        Some(self.restore(now))
    }

    fn take(&mut self) -> (Option<Done<Vec<LimitWindow>>>, Result<Vec<LimitWindow>, Error>) {
        (self.done.take(), self.answer.take().unwrap_or_else(|| Err(invalid())))
    }
}

#[derive(Clone, Copy)]
enum RepairStage {
    Stat,
    Read(u64),
    Put,
}

/// Takes a dead read's status line out of a folder: only an entry running exactly this helper's command.
struct Repair {
    stage: RepairStage,
    path: PathBuf,
    command: String,
}

impl Repair {
    fn complete(&mut self, output: io::Result<Output>) -> Option<Job> {
        match (self.stage, output.ok()?) {
            (RepairStage::Stat, Output::Metadata(metadata)) if metadata.kind == FileKind::File && metadata.size <= LARGEST => {
                self.stage = RepairStage::Read(metadata.size);
                Some(Job::Read { path: self.path.clone(), offset: 0, length: metadata.size })
            }
            (RepairStage::Read(size), Output::Read { before, after, bytes }) if before == after && before.size == size => {
                let kept = without_status_line(&bytes, &self.command)?;
                self.stage = RepairStage::Put;
                let expected = Expected::Same(Guard::from(before));
                Some(if kept.is_empty() {
                    Job::Remove { path: self.path.clone(), expected }
                } else {
                    Job::Write { path: self.path.clone(), bytes: kept, mode: 0o600, expected, parent: None }
                })
            }
            _ => None,
        }
    }
}

enum Task {
    Reading(PathBuf),
    Repair(Repair),
}

/// Every read and repair under way, one read per folder.
#[derive(Default)]
pub(crate) struct Limits {
    readings: BTreeMap<PathBuf, Reading>,
    tasks: BTreeMap<Work, Task>,
}

/// What the status line runs: the installed hook's command, so nothing new is trusted.
pub(crate) fn command(io: &mut dyn Io) -> Result<String, Error> {
    let executable = io.executable().map_err(|e| error("io", e))?;
    let executable = executable.to_str().ok_or_else(|| error("settings", "Helper executable path is not UTF-8"))?;
    Ok(format!("'{}' hook claude", executable.replace('\'', "'\\''")))
}

impl Limits {
    pub fn read(
        &mut self,
        io: &mut dyn Io,
        directory: &Path,
        command: String,
        session: String,
        done: Done<Vec<LimitWindow>>,
    ) {
        if self.readings.contains_key(directory) {
            deferred(done)(io, Err(error("busy", "Limits are being read")));
            return;
        }
        let (reading, job) = Reading::new(directory, command, session, done);
        self.readings.insert(directory.to_owned(), reading);
        self.submit(io, directory.to_owned(), Next::Job(job));
    }

    fn submit(&mut self, io: &mut dyn Io, directory: PathBuf, next: Next) {
        match next {
            Next::Job(job) => match io.submit(job) {
                Ok(work) => {
                    self.tasks.insert(work, Task::Reading(directory));
                }
                Err(e) => {
                    // Nothing more can run: a status line already written is the next one's to repair.
                    if let Some(reading) = self.readings.get_mut(&directory) {
                        reading.answer.get_or_insert(Err(error("io", e)));
                    }
                    self.finish(io, &directory);
                }
            },
            Next::Wait(at) => io.timer(at),
            Next::Finished => self.finish(io, &directory),
        }
    }

    fn finish(&mut self, io: &mut dyn Io, directory: &Path) {
        if let Some(mut reading) = self.readings.remove(directory) {
            let (done, answer) = reading.take();
            if let Some(done) = done {
                deferred(done)(io, answer);
            }
        }
    }

    /// True when the event was this module's.
    pub fn event(&mut self, io: &mut dyn Io, event: &Event) -> bool {
        match event {
            Event::Hook { message, reply: None, .. } => {
                let Ok(document) = Json::parse(message) else { return false };
                let root = document.root();
                if !status_line(root) {
                    return false;
                }
                let session = text(root, "session_id");
                let folder = root.get("workspace").and_then(|w| text(w, "project_dir")).or_else(|| text(root, "cwd"));
                let now = io.now();
                let found = self.readings.iter_mut().find_map(|(directory, reading)| {
                    (reading.session.as_str() == session.unwrap_or("")).then(|| (directory.clone(), reading.answered(now, session, windows(root))))
                });
                match found {
                    Some((directory, Some(next))) => self.submit(io, directory, next),
                    Some((_, None)) => {}
                    None => {
                        // Never during a read: another session's run must not take out the entry that read is waiting on,
                        // whatever spelling of the folder it reports (/tmp, /private/tmp).
                        if let Some(folder) = folder.map(PathBuf::from).filter(|f| f.is_absolute() && self.readings.is_empty()) {
                            self.repair(io, &folder);
                        }
                    }
                }
                true
            }
            // Every other helper's timers pass here: with no read under way, nothing is asked of the clock.
            Event::Timer { .. } if !self.readings.is_empty() => {
                let now = io.now();
                let expired = self
                    .readings
                    .iter_mut()
                    .filter_map(|(directory, reading)| reading.expired(now).map(|next| (directory.clone(), next)))
                    .collect::<Vec<_>>();
                for (directory, next) in expired {
                    self.submit(io, directory, next);
                }
                false
            }
            _ => false,
        }
    }

    fn repair(&mut self, io: &mut dyn Io, folder: &Path) {
        let Ok(command) = command(io) else { return };
        let path = folder.join(".claude/settings.local.json");
        if let Ok(work) = io.submit(Job::Stat { path: path.clone(), follow: false }) {
            self.tasks.insert(work, Task::Repair(Repair { stage: RepairStage::Stat, path, command }));
        }
    }

    /// A job's answer, when the job was this module's: the result is handed back otherwise.
    pub fn done(&mut self, io: &mut dyn Io, work: Work, result: io::Result<Output>) -> Option<io::Result<Output>> {
        match self.tasks.remove(&work) {
            None => Some(result),
            Some(Task::Reading(directory)) => {
                let now = io.now();
                if let Some(next) = self.readings.get_mut(&directory).map(|reading| reading.complete(now, result)) {
                    self.submit(io, directory, next);
                }
                None
            }
            Some(Task::Repair(mut repair)) => {
                if let Some(job) = repair.complete(result)
                    && let Ok(work) = io.submit(job)
                {
                    self.tasks.insert(work, Task::Repair(repair));
                }
                None
            }
        }
    }
}

#[cfg(test)]
#[path = "limits.test.rs"]
mod tests;
