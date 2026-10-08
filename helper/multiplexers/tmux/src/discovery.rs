use crate::mux::Tmux;
use dispatch_helper_core::{
    api::*,
    json::{self, Data, Value},
};
use std::{
    cell::{Cell, RefCell},
    collections::{BTreeMap, BTreeSet, VecDeque},
    rc::Rc,
};

/// Output-driven rescans run at most this often: each scan inspects every pane's process tree,
/// and agents' redraws would otherwise keep a worker scanning continuously.
pub(crate) const OUTPUT_RESCAN: std::time::Duration = std::time::Duration::from_secs(2);

#[derive(Default)]
pub(crate) struct Discovery {
    /// Topology changed: rescan now.
    pub dirty: bool,
    /// A pane wrote output: rescan within OUTPUT_RESCAN.
    pub output: bool,
    /// The earliest output-driven rescan, and whether a timer waits for it.
    next: Option<std::time::Instant>,
    armed: bool,
    pub rescans: BTreeSet<Id>,
    pending: BTreeSet<Id>,
    /// Pane PTY devices verified like c1654cc TmuxCoordinator.swift:671-681.
    pub ttys: BTreeMap<Id, u64>,
    observed: Rc<RefCell<VecDeque<(Id, Vec<(usize, Binding)>)>>>,
}

// Shared by discovery and the final mutation guard: the native foreground group is one observation.
pub(crate) fn foreground(bytes: &[u8], shell: &Process) -> Option<Vec<Process>> {
    let document = Json::parse(bytes).ok()?;
    let root = document.root();
    if shell.foreground <= 1 || root.get("group")?.signed()? != i64::from(shell.foreground) {
        return None;
    }
    let members = root
        .get("processes")?
        .array()?
        .map(|value| {
            let integer = |key| value.get(key)?.signed();
            let text = |key| {
                value
                    .get(key)?
                    .array()?
                    .map(|v| v.string().map(str::to_owned))
                    .collect::<Option<Vec<_>>>()
            };
            Some(Process {
                pid: integer("pid")?.try_into().ok()?,
                parent: integer("parent")?.try_into().ok()?,
                group: integer("group")?.try_into().ok()?,
                foreground: integer("foreground")?.try_into().ok()?,
                tty: value.get("tty")?.unsigned()?,
                start: value
                    .get("start")?
                    .array()?
                    .map(Value::unsigned)
                    .collect::<Option<Vec<_>>>()?
                    .try_into()
                    .ok()?,
                executable: value.get("executable")?.string()?.into(),
                arguments: text("arguments")?,
                files: value
                    .get("files")?
                    .array()?
                    .map(OpenFile::parse)
                    .collect::<Option<Vec<_>>>()?,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    members
        .iter()
        .all(|p| {
            p.tty == shell.tty && p.group == shell.foreground && p.foreground == shell.foreground
        })
        .then_some(members)
}

pub(crate) fn tty(bytes: &[u8], device: u64) -> bool {
    Json::parse(bytes).ok().is_some_and(|doc| {
        doc.root().get("kind").and_then(Value::string) == Some("character")
            && doc.root().get("tty").and_then(Value::unsigned) == Some(device)
    })
}

impl Tmux {
    pub(crate) fn discover(&mut self, io: &mut dyn Io) {
        let now = io.now();
        if self.discovery.output && !self.discovery.dirty {
            match self.discovery.next {
                // (a timer may wake marginally early: that wake rescans)
                Some(at) if now + std::time::Duration::from_millis(10) < at => {
                    if !self.discovery.armed {
                        self.discovery.armed = true;
                        io.timer(at);
                    }
                }
                _ => self.discovery.dirty = true,
            }
        }
        let dirty = std::mem::take(&mut self.discovery.dirty);
        if dirty {
            self.discovery.output = false;
            self.discovery.armed = false;
            self.discovery.next = Some(now + OUTPUT_RESCAN);
        }
        if !dirty && self.discovery.rescans.is_empty() { return; }
        let nodes: Vec<_> = self
            .nodes
            .iter()
            .filter_map(|node| (node.kind == Kind::Terminal && !node.detached).then_some(node.id))
            .collect();
        self.agents.retain(|id, _| nodes.contains(id));
        self.discovery.ttys.retain(|id, _| nodes.contains(id));
        self.discovery.rescans.retain(|id| nodes.contains(id));
        for id in nodes {
            if !dirty && !self.discovery.rescans.contains(&id) { continue; }
            let Ok(loc) = self.location(id) else {
                continue;
            };
            if self.backends[&loc.backend].remote || !self.discovery.pending.insert(id) {
                continue;
            }
            self.discovery.rescans.remove(&id);
            if let Some((_, binding)) = self.agents.get(&id) {
                let previous = binding.process.clone();
                self.job(
                    io,
                    Job::Process { pid: previous.pid },
                    Box::new(move |mux, _, result| {
                        let alive = matches!(result, Ok(Output::Process(ref p))
                        if p.pid == previous.pid && p.start == previous.start);
                        if !alive
                            && mux.agents.get(&id).is_some_and(|(_, b)| {
                                b.process.pid == previous.pid && b.process.start == previous.start
                            })
                        {
                            mux.agents.remove(&id);
                            mux.changed = true;
                        }
                    }),
                );
            }
            let snapshot = self.backends[&loc.backend].clients[loc.client]
                .snapshot
                .as_ref()
                .unwrap();
            let pane = snapshot.panes[&loc.pane].clone();
            let server = snapshot.server;
            self.job(
                io,
                Job::Process {
                    pid: pane.pid as u32,
                },
                Box::new(move |mux, io, result| {
                    let shell = match result {
                        Ok(Output::Process(p))
                            if p.pid == pane.pid as u32
                                && p.parent == server as u32
                                && p.tty != 0
                                && p.foreground > 1 =>
                        {
                            p
                        }
                        _ => {
                            mux.discovery.pending.remove(&id);
                            return;
                        }
                    };
                    let input = json::write(&Data::Object(vec![("path", Data::String(&pane.tty))]))
                        .unwrap();
                    mux.job(
                        io,
                        Job::Native {
                            name: "file.lstat",
                            input,
                        },
                        Box::new(move |mux, io, result| {
                            let matches = match result {
                                Ok(Output::Bytes(bytes)) => tty(&bytes, shell.tty),
                                _ => false,
                            };
                            if !matches {
                                mux.discovery.pending.remove(&id);
                                return;
                            }
                            mux.changed |=
                                mux.discovery.ttys.insert(id, shell.tty) != Some(shell.tty);
                            if mux.harnesses.is_empty() {
                                mux.discovery.pending.remove(&id);
                                return;
                            }
                            let input = json::write(&Data::Object(vec![(
                                "tty",
                                Data::Unsigned(shell.tty),
                            )]))
                            .unwrap();
                            mux.job(
                                io,
                                Job::Native {
                                    name: "foreground",
                                    input,
                                },
                                Box::new(move |mux, io, result| {
                                    mux.candidates(io, id, shell, result);
                                }),
                            );
                        }),
                    );
                }),
            );
        }
    }

    fn candidates(
        &mut self,
        io: &mut dyn Io,
        id: Id,
        shell: Process,
        result: std::io::Result<Output>,
    ) {
        let members = match result {
            Ok(Output::Bytes(bytes)) => foreground(&bytes, &shell),
            _ => None,
        };
        let members: Vec<_> = members
            .unwrap_or_default()
            .into_iter()
            .filter(|p| self.harnesses.iter().any(|h| h.borrow().matches(p)))
            .collect();
        self.updates.push(Update::Candidate { terminal: id, process: match members.as_slice() {
            [process] if self.location(id).is_ok() => Some(process.clone()),
            _ => None,
        }});
        if members.len() != 1 || self.location(id).is_err() {
            self.discovery.pending.remove(&id);
            return;
        }
        let process = &members[0];
        let harnesses: Vec<_> = self
            .harnesses
            .iter()
            .enumerate()
            .filter_map(|(index, h)| h.borrow().matches(process).then_some((index, h.clone())))
            .collect();
        let remaining = Rc::new(Cell::new(harnesses.len()));
        let bindings = Rc::new(RefCell::new(Vec::new()));
        for (index, harness) in harnesses {
            let remaining = remaining.clone();
            let bindings = bindings.clone();
            let observed = self.discovery.observed.clone();
            harness.borrow_mut().identify(
                io,
                process,
                None,
                deferred(Box::new(move |io, result| {
                    if let Ok(Some(binding)) = result {
                        bindings.borrow_mut().push((index, binding));
                    }
                    remaining.set(remaining.get() - 1);
                    if remaining.get() == 0 {
                        observed
                            .borrow_mut()
                            .push_back((id, std::mem::take(&mut *bindings.borrow_mut())));
                        io.timer(io.now());
                    }
                })),
            );
        }
    }

    pub(crate) fn observations(&mut self, io: &mut dyn Io) {
        let observations: Vec<_> = self.discovery.observed.borrow_mut().drain(..).collect();
        for (id, mut bindings) in observations {
            if bindings.len() != 1 || self.location(id).is_err() {
                self.discovery.pending.remove(&id);
                continue;
            }
            let (harness, binding) = bindings.pop().unwrap();
            self.ownership(
                io,
                id,
                binding.process.clone(),
                Box::new(move |mux, _, result| {
                    mux.discovery.pending.remove(&id);
                    if result.is_err()
                        || mux.agents.iter().any(|(other, (_, b))| {
                            *other != id
                                && b.process.pid == binding.process.pid
                                && b.process.start == binding.process.start
                        })
                    {
                        return;
                    }
                    let changed = mux.agents.get(&id).is_none_or(|(old, b)| {
                        *old != harness
                            || b.session != binding.session
                            || b.transcript != binding.transcript
                            || b.process.pid != binding.process.pid
                            || b.process.start != binding.process.start
                    });
                    mux.agents.insert(id, (harness, binding));
                    if changed {
                        mux.changed = true;
                        mux.updates.push(Update::Agent {
                            terminal: id,
                            summary: Summary::default(),
                        });
                    }
                }),
            );
        }
    }
}
