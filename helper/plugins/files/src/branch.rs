//! c1654cc SpaceBranchReader: bounded HEAD lookup, including Git directory files.
use super::*;
use std::path::Component;

pub(super) struct State {
    root: PathBuf,
    depth: usize,
    stage: Stage,
    reading: bool,
    done: Done<Option<String>>,
}

enum Stage {
    Head,
    Marker,
    Linked(PathBuf),
}

fn normalize(path: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for part in path.components() {
        match part {
            Component::ParentDir => {
                result.pop();
            }
            Component::CurDir => {}
            _ => result.push(part.as_os_str()),
        }
    }
    result
}

fn whitespace(value: char) -> bool {
    value.is_whitespace() || value == '\u{200b}'
}

fn name(head: &str) -> Option<String> {
    let branch = head
        .trim_matches(whitespace)
        .strip_prefix("ref: refs/heads/")?;
    let invalid = branch
        .chars()
        .any(|c| whitespace(c) || dispatch_helper_core::text::control(c));
    (!branch.is_empty() && branch.len() <= 1024 && !invalid).then(|| branch.to_owned())
}

impl State {
    pub(super) fn start(root: &Path, done: Done<Option<String>>, io: &mut dyn Io, jobs: &Jobs) {
        Self {
            root: normalize(root),
            depth: 0,
            stage: Stage::Head,
            reading: false,
            done,
        }
        .submit(io, jobs);
    }

    fn path(&self) -> PathBuf {
        match &self.stage {
            Stage::Head => self.root.join(".git/HEAD"),
            Stage::Marker => self.root.join(".git"),
            Stage::Linked(path) => path.join("HEAD"),
        }
    }

    fn submit(self, io: &mut dyn Io, jobs: &Jobs) {
        let job = if self.reading {
            Job::Read {
                path: self.path(),
                offset: 0,
                length: 4097,
            }
        } else {
            Job::Stat {
                path: self.path(),
                follow: true,
            }
        };
        // Failed metadata reads mean unavailable, not a user-visible error.
        match io.submit(job) {
            Ok(work) => jobs.borrow_mut().push((work, Pending::Branch(self))),
            Err(_) => self.advance(io, jobs, None),
        }
    }

    pub(super) fn event(self, io: &mut dyn Io, jobs: &Jobs, result: io::Result<Output>) {
        match result {
            Ok(Output::Metadata(metadata)) if metadata.kind == FileKind::Directory => {
                self.advance(io, jobs, Some(String::new()));
            }
            Ok(Output::Metadata(metadata))
                if metadata.kind == FileKind::File && metadata.size <= 4096 =>
            {
                Self {
                    reading: true,
                    ..self
                }
                .submit(io, jobs);
            }
            Ok(Output::Read { bytes, .. }) if bytes.len() <= 4096 => {
                self.advance(io, jobs, String::from_utf8(bytes).ok());
            }
            _ => self.advance(io, jobs, None),
        }
    }

    fn advance(mut self, io: &mut dyn Io, jobs: &Jobs, text: Option<String>) {
        self.reading = false;
        match self.stage {
            Stage::Head => {
                if let Some(text) = text {
                    (self.done)(io, Ok(name(&text)));
                    return;
                }
                self.stage = Stage::Marker;
            }
            Stage::Marker => {
                if let Some(text) = text {
                    let link = text
                        .trim_matches(whitespace)
                        .strip_prefix("gitdir: ")
                        .map(|path| {
                            path.trim_matches(|c| {
                                whitespace(c)
                                    && !matches!(
                                        c,
                                        '\n' | '\r'
                                            | '\u{b}'
                                            | '\u{c}'
                                            | '\u{85}'
                                            | '\u{2028}'
                                            | '\u{2029}'
                                    )
                            })
                        });
                    let Some(link) = link.filter(|path| {
                        !path.is_empty()
                            && !path.contains([
                                '\n', '\r', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
                            ])
                    }) else {
                        (self.done)(io, Ok(None));
                        return;
                    };
                    self.stage = Stage::Linked(normalize(&self.root.join(link)));
                } else {
                    self.depth += 1;
                    if self.depth == 64 || !self.root.pop() {
                        (self.done)(io, Ok(None));
                        return;
                    }
                    self.stage = Stage::Head;
                }
            }
            Stage::Linked(_) => {
                (self.done)(io, Ok(text.as_deref().and_then(name)));
                return;
            }
        }
        self.submit(io, jobs);
    }
}
