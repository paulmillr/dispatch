//! Native settings installation; every filesystem operation is a System job.
use crate::{
    history::{error, text},
    settings,
};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Json},
};
use std::{io, path::PathBuf};

enum Stage {
    Process,
    Environment,
    Stat,
    Read(u64),
    Check,
    Compare(u64),
    Directory,
    Write,
}
pub(crate) struct Setup {
    stage: Stage,
    home: Option<PathBuf>,
    path: PathBuf,
    command: String,
    pub enabled: Option<bool>,
    remote: bool,
    installed: bool,
    before: Option<Vec<u8>>,
    after: Vec<u8>,
    expected: Expected,
    pub done: Done<Install>,
}
pub(crate) enum Next {
    Job(Job),
    Done(Install),
}
impl Setup {
    pub fn new(
        home: Option<PathBuf>,
        enabled: Option<bool>,
        remote: bool,
        command: String,
        done: Done<Install>,
    ) -> Self {
        Self {
            stage: Stage::Process,
            home,
            path: PathBuf::new(),
            command,
            enabled,
            remote,
            installed: false,
            before: None,
            after: Vec::new(),
            expected: Expected::Absent,
            done,
        }
    }
    fn prepare(&mut self) -> Result<Next, Error> {
        let doc = self
            .before
            .as_deref()
            .map(Json::parse)
            .transpose()
            .map_err(|e| error("settings", e.message))?;
        self.installed = doc.as_ref().is_some_and(|doc| {
            doc.root()
                .get("hooks")
                .and_then(|hooks| hooks.get("PermissionRequest"))
                .and_then(|groups| groups.array())
                .into_iter()
                .flatten()
                .any(|group| {
                    group
                        .get("hooks")
                        .and_then(|handlers| handlers.array())
                        .into_iter()
                        .flatten()
                        .any(|handler| text(handler, "command") == Some(&self.command))
                })
        });
        // Remote setup appends only missing handlers like the old SSH helper
        // (c51466a hooks.rs:85-166; its install_for has no remove, so turning the integration off
        // leaves the remote file as it is); local setup keeps the app's merge
        // (CodexHookSetup.swift:80-141).
        if self.remote && self.enabled == Some(false) {
            return Ok(Next::Done(Install {
                installed: self.installed,
                ..Install::default()
            }));
        }
        self.after = match (self.remote, self.enabled) {
            (true, _) => settings::installation(self.before.as_deref(), &self.command)?
                .unwrap_or_else(|| self.before.clone().unwrap_or_default()),
            _ => settings::merge(doc.as_ref(), &self.command, self.enabled.unwrap_or(true))?,
        };
        // Unchanged settings are never rewritten.
        if self.enabled.is_none() || self.before.as_deref() == Some(self.after.as_slice()) {
            return Ok(Next::Done(self.report()));
        }
        self.stage = Stage::Check;
        Ok(Next::Job(Job::Stat {
            path: self.path.clone(),
            follow: true,
        }))
    }
    fn report(&self) -> Install {
        Install {
            restart: self.enabled.is_some()
                && self.before.as_deref() != Some(self.after.as_slice()),
            installed: self.enabled.unwrap_or(self.installed),
            edits: vec![Edit {
                path: self.path.clone(),
                before: self.before.clone(),
                after: Some(self.after.clone()),
                backup: None,
            }],
            ..Install::default()
        }
    }
    fn compare(&mut self, current: Option<&[u8]>) -> Result<Next, Error> {
        if current != self.before.as_deref() {
            return Err(error(
                "changed",
                "Agent settings changed during setup. Try again.",
            ));
        }
        self.stage = Stage::Directory;
        Ok(Next::Job(Job::MakeDir {
            path: self.path.parent().unwrap().to_owned(),
            mode: 0o700,
        }))
    }
    pub fn complete(&mut self, output: io::Result<Output>) -> Result<Next, Error> {
        if matches!(self.stage, Stage::Write)
            && output.as_ref().is_err_and(|e| {
                matches!(
                    e.kind(),
                    io::ErrorKind::AlreadyExists | io::ErrorKind::StaleNetworkFileHandle
                )
            })
        {
            return Err(error(
                "changed",
                "Agent settings changed during setup. Try again.",
            ));
        }
        if output
            .as_ref()
            .is_err_and(|e| e.kind() == io::ErrorKind::NotFound)
        {
            return match self.stage {
                Stage::Stat => self.prepare(),
                Stage::Check => self.compare(None),
                _ => Err(error(
                    "changed",
                    "Agent settings changed during setup. Try again.",
                )),
            };
        }
        match (&self.stage, output.map_err(|e| error("io", e))?) {
            (Stage::Process, Output::Process(process)) => {
                self.stage = Stage::Environment;
                Ok(Next::Job(Job::Native {
                    name: "environment",
                    input: json::write(&Data::Object(vec![
                        ("pid", Data::Unsigned(process.pid.into())),
                        (
                            "names",
                            Data::Array(vec![
                                Data::String("HOME"),
                                Data::String("CLAUDE_CONFIG_DIR"),
                            ]),
                        ),
                    ]))?,
                }))
            }
            (Stage::Environment, Output::Bytes(bytes)) => {
                let doc = Json::parse(&bytes).map_err(|e| error("settings", e.message))?;
                let home = crate::identity::home(doc.root(), self.home.clone())
                    .ok_or_else(|| error("settings", "Claude home unavailable"))?;
                if !home.is_absolute() {
                    return Err(error("settings", "Claude home is not absolute"));
                }
                self.path = home.join("settings.json");
                self.stage = Stage::Stat;
                Ok(Next::Job(Job::Stat {
                    path: self.path.clone(),
                    follow: true,
                }))
            }
            (Stage::Stat | Stage::Check, Output::Metadata(metadata)) => {
                if metadata.kind != FileKind::File {
                    return Err(error("settings", "Agent settings are not a regular file"));
                }
                self.stage = if matches!(self.stage, Stage::Stat) {
                    Stage::Read(metadata.size)
                } else {
                    Stage::Compare(metadata.size)
                };
                Ok(Next::Job(Job::Read {
                    path: self.path.clone(),
                    offset: 0,
                    length: metadata.size,
                }))
            }
            (
                Stage::Read(size) | Stage::Compare(size),
                Output::Read {
                    before,
                    after,
                    bytes,
                },
            ) => {
                if before != after || before.size != *size || bytes.len() as u64 != *size {
                    return Err(error(
                        "changed",
                        "Agent settings changed during setup. Try again.",
                    ));
                }
                if matches!(self.stage, Stage::Read(_)) {
                    self.expected = Expected::Same(Guard::from(before));
                    self.before = Some(bytes);
                    self.prepare()
                } else {
                    self.compare(Some(&bytes))
                }
            }
            (Stage::Directory, Output::Written) => {
                self.stage = Stage::Write;
                Ok(Next::Job(Job::Write {
                    path: self.path.clone(),
                    bytes: self.after.clone(),
                    mode: 0o600,
                    expected: self.expected,
                }))
            }
            (Stage::Write, Output::Written) => Ok(Next::Done(self.report())),
            _ => Err(error("settings", "Unexpected settings filesystem result")),
        }
    }
}
