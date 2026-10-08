//! Wire operation table. Each entry selects a trait method; no provider policy lives here.
use crate::{
    api::*,
    encode::{Encode, notify},
    helper::{DispatchHelper, Replies},
    json::Value,
    wire,
};
use std::{cell::{Cell, RefCell}, collections::BTreeMap, path::Path, rc::Rc};
mod chat;
pub(crate) use chat::follow;
mod hello;
mod launch;
pub(crate) use launch::write;
mod params;
pub(crate) mod queue;
mod read;

fn checked<T: 'static>(
    done: Done<T>,
    call: impl FnOnce(&mut dyn Io, Done<T>) + 'static,
) -> Done<()> {
    deferred(Box::new(move |io, result| match result {
        Ok(()) => call(io, done),
        Err(error) => done(io, Err(error)),
    }))
}

fn reduced(io: &mut dyn Io, pending: Rc<RefCell<(usize, Option<Error>, Option<Done<()>>)>>, result: Result<(), Error>) {
    let ready = {
        let mut pending = pending.borrow_mut();
        if let Err(error) = result { pending.1.get_or_insert(error); }
        pending.0 -= 1;
        (pending.0 == 0).then(|| (pending.2.take().unwrap(), pending.1.take().map_or(Ok(()), Err)))
    };
    if let Some((done, result)) = ready { deferred(done)(io, result); }
}

struct Closed {
    closed: bool,
    confirmation: bool,
}
impl Encode for Closed {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(
            out,
            &[
                ("closed", &self.closed),
                ("confirmation", &self.confirmation),
            ],
        );
    }
}

pub(crate) type Windows = Rc<RefCell<BTreeMap<(i32, Option<u64>), (Id, Rc<RefCell<wire::Window>>)>>>;
pub(crate) fn window(
    replies: Replies,
    windows: Windows,
    fd: i32,
    id: u64,
    terminal: Id,
    done: Done<()>,
) -> Done<()> {
    let state = Rc::new(RefCell::new(wire::Window::default()));
    windows
        .borrow_mut()
        .insert((fd, Some(id)), (terminal, state.clone()));
    Box::new(move |io, result| {
        let current = windows
            .borrow()
            .get(&(fd, Some(id)))
            .is_some_and(|(key, value)| *key == terminal && Rc::ptr_eq(value, &state));
        if !current {
            return;
        }
        let opened = result.is_ok();
        if opened {
            state.borrow_mut().grant(wire::Window::CAPACITY).unwrap();
        } else {
            windows.borrow_mut().remove(&(fd, Some(id)));
        }
        done(io, result);
        if opened {
            replies.borrow_mut().push_back((
                fd,
                wire::Kind::Notify,
                id,
                notify(
                    "terminal.input_window",
                    &[("terminal", &terminal), ("credit", &wire::Window::CAPACITY)],
                ),
            ));
        }
    })
}
pub(crate) type Nodes = Rc<RefCell<BTreeMap<Id, (usize, Node)>>>;
/// Question ids of native interactions published to the UI, for dismissal.
pub(crate) type Interactions = Rc<RefCell<BTreeMap<(Id, String, String), Vec<String>>>>;
/// Per-harness state that installation.install sets (decisions-1002).
pub(crate) enum Installed {
    /// Explicitly enabled, including optional integrations before their first launch.
    On,
    /// The app disabled hooks: audits report off and hook events get no decision, while the
    /// agent's files keep our hooks (Codex append-only).
    Off,
    /// An optional bridge was removed: the still-running agent must no longer accept Chat input.
    Disabled,
    /// Bindings that were live when the installation changed files; they need a restart.
    Stale(Vec<Binding>),
}
pub(crate) type Installs = Rc<RefCell<BTreeMap<usize, Installed>>>;
/// chat.open {transcript}: one followed archive per request (fd, id); decisions-1002.
pub(crate) struct Followed {
    pub harness: Shared<dyn Harness>,
    /// `later` is the cursor of the last read.
    pub source: Transcript,
    pub watch: u64,
    pub reading: bool,
    pub again: bool,
    /// The State of the last sent read; a read that changes it is sent without new records.
    pub state: Option<State>,
}
pub(crate) type Archives = Rc<RefCell<BTreeMap<(i32, u64), Followed>>>;
/// (client, create request, created terminal or None on failure) awaiting observer adoption.
pub(crate) type Adoptions = Rc<RefCell<Vec<(i32, u64, Option<Id>)>>>;
pub(crate) use queue::Held;
/// Conversations with a composer command in flight (old ChatCommands one-command rule).
pub(crate) type Commands = Rc<RefCell<std::collections::BTreeSet<(Id, String)>>>;
pub(crate) type Sides = Rc<RefCell<BTreeMap<(Id, String), (Binding, Binding)>>>;
pub(crate) fn same(a: &Binding, b: &Binding) -> bool {
    a.session == b.session && a.process.pid == b.process.pid && a.process.start == b.process.start
}

struct Backend {
    mux: u64,
    key: String,
    label: String,
    default: bool,
    /// The mux opens sessions/clients that already exist; c1654cc NewSpaceButton.swift:32.
    external: bool,
}
struct Launch {
    launch: u64,
    key: String,
    label: String,
    /// What users type for this harness; the app wraps it into `dispatch-helper4 launch <key>`.
    program: Option<String>,
}
impl Encode for Launch {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(
            out,
            &[
                ("launch", &self.launch),
                ("key", &self.key),
                ("label", &self.label),
                ("program", &self.program),
            ],
        );
    }
}
/// One registered multiplexer kind, running or not (the app's per-kind toggles and new-space
/// menu; c1654cc NewSpaceButton.swift:14-21, per-mux Settings toggles).
struct Mux {
    mux: u64,
    name: String,
    external: bool,
    claimed: bool,
    program: Option<String>,
}
impl Encode for Mux {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(
            out,
            &[
                ("mux", &self.mux),
                ("name", &self.name),
                ("external", &self.external),
                ("claimed", &self.claimed),
                ("program", &self.program),
            ],
        );
    }
}
impl Encode for Backend {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(
            out,
            &[
                ("mux", &self.mux),
                ("key", &self.key),
                ("label", &self.label),
                ("default", &self.default),
                ("external", &self.external),
            ],
        );
    }
}
pub(crate) type Questions = Rc<RefCell<BTreeMap<(i32, Id, String, String), Question>>>;
pub(crate) struct Question {
    pub request: u64,
    pub done: Done<Sent>,
    binding: Binding,
    interaction: Interaction,
}
#[derive(Default)]
pub(crate) struct Creation {
    pub result: Option<Result<Id, Error>>,
    pub waiting: Vec<Done<Id>>,
}
pub(crate) type Creations = Rc<RefCell<BTreeMap<(i32, usize, u64), Rc<RefCell<Creation>>>>>;
pub(crate) struct Request<'a> {
    pub helper: &'a mut DispatchHelper,
    pub io: &'a mut dyn Io,
    pub replies: Replies,
    pub document: Rc<Json>,
    pub fd: i32,
    pub id: u64,
}
/// Typed sends: input from Sent::Keys goes through the multiplexer's pane check; one path for
/// chat.send, queue.start and held drains.
pub(crate) fn typed(
    active: Option<Rc<Cell<bool>>>,
    mux: Shared<dyn Multiplexer>,
    harness: Shared<dyn Harness>,
    terminal: Id,
    binding: Binding,
    done: Done<Sent>,
) -> Done<Sent> {
    Box::new(move |io, result| match result {
        Ok(Sent::Keys(input)) => crate::menu::keys(
            io,
            active,
            mux,
            harness,
            terminal,
            Rc::new(binding),
            input,
            Box::new(move |io, result| {
                done(
                    io,
                    result.map(|()| Sent::Native {
                        written: true,
                        may_have_sent: true,
                        reason: None,
                    }),
                )
            }),
        ),
        result => done(io, result),
    })
}
/// A terminal-menu harness answers "menu"; the core then walks the menu for the same goal.
#[allow(clippy::too_many_arguments)]
pub(crate) fn walk<T: 'static>(
    active: Option<Rc<Cell<bool>>>,
    mux: Shared<dyn Multiplexer>,
    harness: Shared<dyn Harness>,
    terminal: Id,
    binding: Binding,
    goal: Goal,
    ask: Ask,
    done: Done<T>,
    convert: fn(Menu) -> T,
) -> Done<T> {
    Box::new(move |io, result| match result {
        Err(error) if error.code == "menu" => drive(
            io,
            active,
            mux,
            harness,
            terminal,
            Rc::new(binding),
            Rc::new(goal),
            64,
            false,
            ask,
            Box::new(move |io, result| done(io, result.map(convert))),
        ),
        result => done(io, result),
    })
}
pub(crate) fn reference(mux: usize, id: Id) -> Id {
    (mux as u64) << 48 | id
}
pub(crate) fn local(id: Id) -> Id {
    id & ((1 << 48) - 1)
}

pub(crate) fn invalid(field: &str) -> Error {
    Error {
        code: "invalid_input",
        message: format!("Invalid or missing {field}"),
    }
}
fn text<'a>(p: Value<'a>, name: &str) -> Result<&'a str, Error> {
    p.get(name)
        .and_then(Value::string)
        .ok_or_else(|| invalid(name))
}
pub(crate) fn number(p: Value<'_>, name: &str) -> Result<u64, Error> {
    p.get(name)
        .and_then(Value::unsigned)
        .ok_or_else(|| invalid(name))
}
/// terminals.create environment: K=V entries added to the created command (e.g. the app's
/// typed-launch shell functions, like c1654cc NativeSSHEnvironment.swift:56-77).
fn environment(p: Value<'_>) -> Result<Vec<(String, String)>, Error> {
    let Some(values) = p.get("environment").and_then(Value::array) else {
        return Ok(Vec::new());
    };
    values
        .map(|v| {
            v.string()
                .and_then(|entry| entry.split_once('='))
                .filter(|(key, _)| !key.is_empty() && !key.contains('\0'))
                .map(|(key, value)| (key.to_owned(), value.to_owned()))
                .ok_or_else(|| invalid("environment"))
        })
        .collect()
}
fn optional(p: Value<'_>, name: &str) -> Option<u64> {
    p.get(name).and_then(Value::unsigned)
}
fn flag(p: Value<'_>, name: &str) -> bool {
    p.get(name).and_then(Value::boolean).unwrap_or(false)
}
fn plugin(method: &str) -> &str {
    match method {
        "text" | "read" | "branch" => "files",
        _ => "stats",
    }
}
fn cell(p: Value<'_>, name: &str) -> Result<Option<u16>, Error> {
    optional(p, name)
        .map(|v| u16::try_from(v).map_err(|_| invalid(name)))
        .transpose()
}
fn size(p: Value<'_>) -> Result<Grid, Error> {
    let p = p.get("size").unwrap_or(p);
    Ok(Grid {
        columns: u16::try_from(number(p, "columns")?).map_err(|_| invalid("columns"))?,
        rows: u16::try_from(number(p, "rows")?).map_err(|_| invalid("rows"))?,
        pixels: cell(p, "cell_width")?.zip(cell(p, "cell_height")?),
    })
}
fn scroll(p: Value<'_>) -> Result<Scroll, Error> {
    Ok(Scroll {
        lines: p
            .get("lines")
            .and_then(Value::signed)
            .ok_or_else(|| invalid("lines"))?,
        page: flag(p, "page"),
        at: cell(p, "column")?.zip(cell(p, "row")?),
        modifiers: u8::try_from(optional(p, "modifiers").unwrap_or(0))
            .map_err(|_| invalid("modifiers"))?,
    })
}
/// memberships.place `place`: `kind` names the Place variant; ids are global entity ids.
fn place(p: Value<'_>) -> Result<Place, Error> {
    let p = p.get("place").ok_or_else(|| invalid("place"))?;
    Ok(match text(p, "kind")? {
        "restore" => Place::Restore,
        "extract" => Place::Extract(text(p, "label")?.into()),
        "before" => Place::Before {
            parent: local(number(p, "parent")?),
            before: optional(p, "before").map(local),
        },
        "workspace" => Place::Workspace {
            label: text(p, "label")?.into(),
        },
        "tab" => Place::Tab {
            workspace: local(number(p, "workspace")?),
            label: text(p, "label")?.into(),
        },
        "split" => Place::Split {
            target: local(number(p, "target")?),
            axis: match text(p, "axis")? {
                "rows" => Axis::Rows,
                "columns" => Axis::Columns,
                _ => return Err(invalid("axis")),
            },
            ratio: p
                .get("ratio")
                .and_then(Value::number)
                .ok_or_else(|| invalid("ratio"))?,
        },
        _ => return Err(invalid("kind")),
    })
}
fn mode(p: Value<'_>) -> Result<Mode, Error> {
    match p.get("mode").and_then(Value::string).unwrap_or("prompt") {
        "prompt" => Ok(Mode::Prompt),
        "steer" => Ok(Mode::Steer),
        "follow_up" => Ok(Mode::FollowUp),
        _ => Err(invalid("mode")),
    }
}
fn strings(p: Value<'_>, name: &str) -> Result<Vec<String>, Error> {
    p.get(name)
        .and_then(Value::array)
        .ok_or_else(|| invalid(name))?
        .map(|v| v.string().map(str::to_owned).ok_or_else(|| invalid(name)))
        .collect()
}
pub(crate) fn bytes(p: Value<'_>) -> Result<Vec<u8>, Error> {
    data(p.get("bytes").ok_or_else(|| invalid("bytes"))?)
}
pub fn data(v: Value<'_>) -> Result<Vec<u8>, Error> {
    if let Some(values) = v.array() {
        return values
            .map(|v| {
                v.unsigned()
                    .and_then(|n| u8::try_from(n).ok())
                    .ok_or_else(|| invalid("bytes"))
            })
            .collect();
    }
    let s = v.string().ok_or_else(|| invalid("bytes"))?;
    let mut out = Vec::new();
    let mut bits = 0u32;
    let mut used = 0;
    for c in s.bytes().take_while(|c| *c != b'=') {
        let n = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return Err(invalid("bytes")),
        };
        bits = (bits << 6) | u32::from(n);
        used += 6;
        if used >= 8 {
            used -= 8;
            out.push((bits >> used) as u8);
        }
    }
    Ok(out)
}
fn answers(p: Value<'_>) -> Result<Vec<(String, Answer)>, Error> {
    p.get("answers")
        .and_then(Value::object)
        .ok_or_else(|| invalid("answers"))?
        .map(|(key, v)| {
            let answer = if let Some(s) = v.string() {
                Answer::Text(s.into())
            } else if let Some(a) = v.array() {
                Answer::Options(
                    a.map(|v| {
                        v.unsigned()
                            .and_then(|n| usize::try_from(n).ok())
                            .ok_or_else(|| invalid("answers"))
                    })
                    .collect::<Result<_, _>>()?,
                )
            } else if v.kind() == crate::json::Kind::Null {
                Answer::Skip
            } else {
                return Err(invalid("answers"));
            };
            Ok((key.into(), answer))
        })
        .collect()
}

impl Request<'_> {
    fn closing(&self, p: Value<'_>) -> Done<()> {
        let prompt = p.get("policy").and_then(Value::string) == Some("prompt");
        let check = flag(p, "check");
        let done = self.done(None);
        Box::new(move |io, result| {
            done(
                io,
                match result {
                    Ok(()) => Ok(Closed {
                        closed: !check,
                        confirmation: false,
                    }),
                    Err(error) if (prompt || check) && error.code == "busy" => Ok(Closed {
                        closed: false,
                        confirmation: true,
                    }),
                    Err(error) => Err(error),
                },
            );
        })
    }
    /// Protocol result: Closed
    fn close(&mut self, p: Value<'_>) -> Result<(), Error> {
        let (_, mux) = self.mux(p)?;
        let node = local(number(p, "node")?);
        let how = match text(p, "policy")? {
            "prompt" => Close::Prompt,
            "detach" => Close::Detach,
            "terminate" => Close::Terminate,
            _ => return Err(invalid("policy")),
        };
        let done = self.closing(p);
        if flag(p, "check") && how == Close::Detach {
            if !self.helper.nodes.borrow().contains_key(&number(p, "node")?) {
                return Err(Error {
                    code: "expired",
                    message: "The close destination has ended".into(),
                });
            }
            done(self.io, Ok(()));
        } else if flag(p, "check") {
            mux.borrow_mut().idle(
                self.io,
                node,
                Box::new(move |io, result| {
                    let result = result.and_then(|idle| {
                        if idle {
                            Ok(())
                        } else {
                            Err(Error {
                                code: "busy",
                                message: String::new(),
                            })
                        }
                    });
                    done(io, result);
                }),
            );
        } else {
            mux.borrow_mut().close(self.io, node, how, done);
        }
        Ok(())
    }
    fn attached(&self, p: Value<'_>) -> Result<Done<()>, Error> {
        let terminal = reference(self.helper.route(p), local(number(p, "terminal")?));
        Ok(window(
            self.replies.clone(),
            self.helper.windows.clone(),
            self.fd,
            self.id,
            terminal,
            self.done(Some("terminal.attached")),
        ))
    }
    /// Protocol result: null; input_window renewal follows committed native input
    fn input(&mut self, p: Value<'_>) -> Result<(), Error> {
        let terminal = number(p, "terminal")?;
        let bytes = bytes(p)?;
        let count = u32::try_from(bytes.len()).map_err(|_| invalid("input credit"))?;
        let (index, mux) = self.mux(p)?;
        let terminal = reference(index, local(terminal));
        let windows = self.helper.windows.clone();
        let (stream, state) = {
            let mut windows = windows.borrow_mut();
            let stream = if let Some(stream) = optional(p, "subscription") {
                Some(stream)
            } else {
                let mut matches = windows.iter().filter(|((fd, stream), (id, state))| {
                    *fd == self.fd && stream.is_some() && *id == terminal && state.borrow().active()
                });
                let stream = matches
                    .next()
                    .and_then(|((_, stream), _)| *stream);
                if matches.next().is_some() {
                    return Err(invalid("input subscription"));
                }
                stream
            };
            if stream.is_none() {
                if self.helper.login.as_ref().is_none_or(|login| login.borrow().terminal != Some(terminal)) {
                    return Err(invalid("input window"));
                }
                windows.entry((self.fd, None)).or_insert_with(|| {
                    let mut state = wire::Window::default();
                    state.grant(wire::Window::CAPACITY).unwrap();
                    (terminal, Rc::new(RefCell::new(state)))
                });
            }
            let (id, window) = windows
                .get_mut(&(self.fd, stream))
                .ok_or_else(|| invalid("input window"))?;
            if *id != terminal {
                return Err(invalid("input subscription"));
            }
            window
                .borrow_mut()
                .take(count)
                .map_err(|_| invalid("input credit"))?;
            (stream, window.clone())
        };
        let (fd, replies, done) = (self.fd, self.replies.clone(), self.done(None));
        mux.borrow_mut().input(
            self.io,
            local(terminal),
            &bytes,
            deferred(Box::new(move |io, result| {
                let mut windows = windows.borrow_mut();
                if let Some((id, window)) = windows.get_mut(&(fd, stream))
                    && *id == terminal
                    && Rc::ptr_eq(window, &state)
                {
                    // Completion releases capacity even when the backend discarded the bytes.
                    // Only subscription retirement closes credit; transient failure does not.
                    if count != 0 && window.borrow().active() {
                        let credit = count;
                        if window.borrow_mut().grant(credit).is_ok()
                            && let Some(stream) = stream
                        {
                            replies.borrow_mut().push_back((
                                fd,
                                wire::Kind::Notify,
                                stream,
                                notify(
                                    "terminal.input_window",
                                    &[("terminal", &terminal), ("credit", &credit)],
                                ),
                            ));
                        }
                    }
                }
                drop(windows);
                done(io, result);
            })),
        );
        Ok(())
    }
    fn active(&self) -> Option<Rc<Cell<bool>>> {
        self.helper.admitted.get(&(self.fd, self.id)).map(|(_, active)| active.clone())
    }
    pub(crate) fn done<T: Encode + 'static>(&self, long: Option<&'static str>) -> Done<T> {
        let done = reply(self.replies.clone(), self.fd, self.id, long);
        let active = self.active();
        Box::new(move |io, result| {
            if active.as_ref().is_none_or(|active| active.get()) { done(io, result); }
        })
    }
    /// Protocol result: null
    fn reduce(&mut self, p: Value<'_>) -> Result<(), Error> {
        let requested = p.get("capabilities").and_then(Value::array).ok_or_else(|| invalid("capabilities"))?
            .map(|v| v.string().map(str::to_owned).ok_or_else(|| invalid("capabilities")))
            .collect::<Result<std::collections::BTreeSet<_>, _>>()?;
        let removed = {
            let mut grants = self.helper.permissions.borrow_mut();
            let Some(grants) = grants.as_mut() else {
                return Err(Error { code: "permission_denied", message: "Only an SSH grant can be reduced".into() });
            };
            let removed: std::collections::BTreeSet<_> = grants.difference(&requested).cloned().collect();
            grants.retain(|capability| requested.contains(capability));
            removed
        };
        let modules: Vec<_> = self.helper.multiplexers.iter().enumerate().filter_map(|(index, mux)| {
            let mux = mux.borrow();
            (mux.external() && (removed.contains("backend.register") || match mux.name() {
                "tmux" => removed.contains("tmux.pane"),
                "herdr" => removed.contains("herdr.rpc") || removed.contains("herdr.terminal"),
                _ => false,
            })).then_some(index)
        }).collect();
        let chat = removed.contains("agent.inspect") || removed.contains("agent.submit");
        let terminals: std::collections::BTreeSet<_> = self.helper.nodes.borrow().iter()
            .filter(|(_, (module, _))| chat || modules.contains(module)).map(|(id, _)| *id).collect();
        let mut seen = std::collections::BTreeSet::new();
        let bindings: Vec<_> = self.helper.nodes.borrow().iter()
            .filter(|(id, _)| removed.contains("hooks.configure") || terminals.contains(id))
            .filter_map(|(id, (_, node))| node.agent.clone().map(|(harness, binding)| (harness, binding, terminals.contains(id))))
            .filter(|(harness, binding, _)| seen.insert((*harness, binding.process.pid, binding.process.start))).collect();
        for ((terminal, _), line) in self.helper.held.borrow_mut().iter_mut() {
            if terminals.contains(terminal) { line.revoke(); }
        }
        self.helper.prompts.borrow_mut().retain(|terminal, _| !terminals.contains(terminal));
        self.helper.interactions.borrow_mut().retain(|(terminal, _, _), _| !terminals.contains(terminal));
        self.helper.questions.borrow_mut().retain(|(_, terminal, _, _), _| !terminals.contains(terminal));
        let done = self.done(None);
        let parts = self.helper.multiplexers.clone();
        let resets = self.helper.resets.clone();
        // Native queues need their controller until revocation finishes. Disabling
        // its backend concurrently can close that channel before queued input is removed.
        let finish: Done<()> = Box::new(move |io, result| {
            if modules.is_empty() { deferred(done)(io, result); return; }
            let pending = Rc::new(RefCell::new((modules.len(), result.err(), Some(done))));
            for module in modules {
                let pending = pending.clone();
                let resets = resets.clone();
                parts[module].borrow_mut().enable(io, false, Box::new(move |io, result| {
                    resets.borrow_mut().push_back((module, false, Box::new(|_, _| {})));
                    reduced(io, pending, result);
                }));
            }
        });
        if bindings.is_empty() { deferred(finish)(self.io, Ok(())); return Ok(()); }
        let pending = Rc::new(RefCell::new((bindings.len(), None, Some(finish))));
        for (index, binding, retire) in bindings {
            let harness = self.helper.harnesses[index].clone();
            let retiring = harness.clone();
            let process = binding.process.clone();
            let pending = pending.clone();
            harness.borrow_mut().revoke(self.io, &binding, retire, Box::new(move |io, result| {
                if retire { retiring.borrow_mut().exited(io, &process, None); }
                reduced(io, pending, result);
            }));
        }
        Ok(())
    }
    fn mux(&self, p: Value<'_>) -> Result<(usize, Shared<dyn Multiplexer>), Error> {
        let index = self.helper.route(p);
        self.helper
            .multiplexers
            .get(index)
            .cloned()
            .map(|m| (index, m))
            .ok_or_else(|| Error {
                code: "unsupported",
                message: "Multiplexer unavailable".into(),
            })
    }
    fn agent(
        &self,
        p: Value<'_>,
    ) -> Result<(usize, Shared<dyn Multiplexer>, Shared<dyn Harness>, Binding), Error> {
        let terminal = number(p, "terminal")?;
        let index = self
            .helper
            .nodes
            .borrow()
            .get(&terminal)
            .map(|(index, _)| *index)
            .ok_or_else(|| invalid("terminal"))?;
        let (harness, binding) = self
            .helper
            .binding(terminal, p.get("session").and_then(Value::string))?;
        Ok((
            index,
            self.helper.multiplexers[index].clone(),
            self.helper
                .harnesses
                .get(harness)
                .cloned()
                .ok_or_else(|| invalid("harness"))?,
            binding,
        ))
    }
    fn sent(&self, p: Value<'_>, goal: Option<Goal>) -> Result<Done<Sent>, Error> {
        let (_, mux, harness, binding) = self.agent(p)?;
        let terminal = number(p, "terminal")?;
        let mut reply = self.done(None);
        if goal.is_some() && !harness.borrow().native_queue() {
            let key = (terminal, binding.session.clone());
            if self.helper.held.borrow().get(&key).is_some_and(|line| line.sending) {
                return Err(Error { code: "busy", message: "Input is already being sent".into() });
            }
            reply = queue::sending(self.helper.held.clone(), key, matches!(&goal, Some(Goal::Send { .. })), reply);
        }
        let done = typed(
            self.active(),
            mux.clone(),
            harness.clone(),
            local(terminal),
            binding.clone(),
            reply,
        );
        Ok(match goal {
            Some(goal) => walk(
                self.active(),
                mux,
                harness,
                local(terminal),
                binding.clone(),
                goal,
                self.ask(terminal, binding),
                done,
                |_| Sent::Native {
                    written: true,
                    may_have_sent: true,
                    reason: None,
                },
            ),
            None => done,
        })
    }
    /// One composer command per conversation (c1654cc ChatCommands.swift:302); a harness
    /// without a native result for it gets the same checked send as chat.send.
    /// Protocol result: Outcome
    /// Protocol producers: Harness.command, Harness.send
    fn command(&mut self, p: Value<'_>) -> Result<(), Error> {
        let (_, mux, harness, binding) = self.agent(p)?;
        let terminal = number(p, "terminal")?;
        let key = (terminal, binding.session.clone());
        let text = text(p, "text")?.to_owned();
        if !self.helper.commands.borrow_mut().insert(key.clone()) {
            return Err(Error {
                code: "busy",
                message: "A command is already pending".into(),
            });
        }
        let (pending, reply) = (self.helper.commands.clone(), self.done(None));
        let finish: Done<Outcome> = Box::new(move |io, result| {
            pending.borrow_mut().remove(&key);
            reply(io, result)
        });
        let finish = Rc::new(RefCell::new(Some(finish)));
        let (typed_finish, finish_walked) = (finish.clone(), finish.clone());
        let typing = typed(
            self.active(),
            mux.clone(),
            harness.clone(),
            local(terminal),
            binding.clone(),
            Box::new(move |io, result| {
                if let Some(finish) = typed_finish.borrow_mut().take() {
                    finish(io, result.map(Outcome::Sent));
                }
            }),
        );
        let goal = Goal::Send {
            text: text.clone(),
            mode: Mode::Prompt,
            command: true,
        };
        // A walk may end with the command's result read from the screen.
        let walked = walk(
            self.active(),
            mux,
            harness.clone(),
            local(terminal),
            binding.clone(),
            goal,
            self.ask(terminal, binding.clone()),
            Box::new(move |io, result| match result {
                Ok(Outcome::Sent(sent)) => typing(io, Ok(sent)),
                result => {
                    if let Some(finish) = finish_walked.borrow_mut().take() {
                        finish(io, result);
                    }
                }
            }),
            |menu| match menu.result {
                Some((title, text)) => Outcome::Result { title, text },
                None => Outcome::Sent(Sent::Native {
                    written: true,
                    may_have_sent: true,
                    reason: None,
                }),
            },
        );
        let (sender, current, typed_text) = (harness.clone(), binding.clone(), text.clone());
        harness.borrow_mut().command(
            self.io,
            &binding,
            &text,
            Box::new(move |io, result| match result {
                Err(error) if error.code == "menu" => walked(io, Err(error)),
                Err(error) if error.code == "unsupported" => sender.borrow_mut().send(
                    io,
                    &current,
                    &typed_text,
                    Mode::Prompt,
                    true,
                    Box::new(move |io, result| walked(io, result.map(Outcome::Sent))),
                ),
                result => {
                    if let Some(finish) = finish.borrow_mut().take() {
                        finish(io, result);
                    }
                }
            }),
        );
        Ok(())
    }
    fn ask(&self, terminal: Id, binding: Binding) -> Ask {
        let (questions, replies, fd, request) = (
            self.helper.questions.clone(),
            self.replies.clone(),
            self.fd,
            self.id,
        );
        Rc::new(move |io, interaction, done| {
            let key = (
                fd,
                terminal,
                binding.session.clone(),
                interaction.id.clone(),
            );
            if questions.borrow().contains_key(&key) {
                deferred(done)(
                    io,
                    Err(Error {
                        code: "busy",
                        message: "A confirmation is already pending".into(),
                    }),
                );
                return;
            }
            questions.borrow_mut().insert(
                key,
                Question {
                    request,
                    done,
                    binding: binding.clone(),
                    interaction: interaction.clone(),
                },
            );
            replies.borrow_mut().push_back((
                fd,
                wire::Kind::Notify,
                request,
                notify(
                    "interaction.opened",
                    &[
                        ("terminal", &terminal),
                        ("session", &binding.session),
                        ("interaction", &interaction),
                    ],
                ),
            ));
        })
    }
    fn fallback<T: 'static>(
        &self,
        p: Value<'_>,
        goal: Goal,
        done: Done<T>,
        convert: fn(Menu) -> T,
    ) -> Result<Done<T>, Error> {
        let (_, mux, harness, binding) = self.agent(p)?;
        let terminal = number(p, "terminal")?;
        let ask = self.ask(terminal, binding.clone());
        Ok(walk(
            self.active(),
            mux,
            harness,
            local(terminal),
            binding,
            goal,
            ask,
            done,
            convert,
        ))
    }
    /// Protocol result: Sent
    /// Protocol producers: Multiplexer.keys
    fn answer(&mut self, p: Value<'_>, dismiss: bool) -> Result<(), Error> {
        let (_, _, harness, binding) = self.agent(p)?;
        let terminal = number(p, "terminal")?;
        let interaction = text(p, "interaction")?;
        // A native prompt (prompt.rs) is answered on its screen while it is still shown:
        // the chosen option, or dismiss.
        if let Some(title) = interaction.strip_prefix("prompt:") {
            let shown = self
                .helper
                .prompts
                .borrow()
                .get(&terminal)
                .is_some_and(|(_, _, published, _)| {
                    published
                        .as_ref()
                        .is_some_and(|prompt| prompt.id == interaction)
                });
            if !shown {
                return Err(Error {
                    code: "expired",
                    message: "The prompt has ended".into(),
                });
            }
            let choice = if dismiss {
                None
            } else {
                let chosen = answers(p)?
                    .into_iter()
                    .find_map(|(_, answer)| match answer {
                        Answer::Options(options) => options.first().map(|&option| option as u32),
                        _ => None,
                    });
                Some(chosen.ok_or_else(|| invalid("answers"))?)
            };
            let goal = Goal::Choose {
                title: title.to_owned(),
                choice,
            };
            let walk = self.sent(p, Some(goal))?;
            deferred(walk)(
                self.io,
                Err(Error {
                    code: "menu",
                    message: String::new(),
                }),
            );
            return Ok(());
        }
        let key = (
            self.fd,
            terminal,
            binding.session.clone(),
            interaction.to_owned(),
        );
        let questions = self.helper.questions.clone();
        if interaction.starts_with("menu:") && !questions.borrow().contains_key(&key) {
            return Err(Error {
                code: "expired",
                message: "The confirmation has ended".into(),
            });
        }
        if let Some(question) = questions.borrow().get(&key) {
            if !same(&question.binding, &binding) {
                return Err(Error {
                    code: "expired",
                    message: "The confirmation destination changed".into(),
                });
            }
        }
        let native = (terminal, binding.session.clone(), interaction.to_owned());
        let interactions = self.helper.interactions.clone();
        let values = if dismiss {
            let fields = questions
                .borrow()
                .get(&key)
                .map(|q| q.interaction.questions.iter().map(|q| q.id.clone()).collect())
                .or_else(|| interactions.borrow().get(&native).cloned())
                .ok_or_else(|| Error {
                    code: "expired",
                    message: "The confirmation has ended".into(),
                })?;
            fields.into_iter().map(|id| (id, Answer::Skip)).collect()
        } else {
            answers(p)?
        };
        let (_, mux, _, _) = self.agent(p)?;
        let done = self.done(None);
        let replies = self.replies.clone();
        let fd = self.fd;
        let finish = Box::new(move |io: &mut dyn Io, result: Result<Sent, Error>| {
            if result.is_ok() {
                interactions.borrow_mut().remove(&native);
                let question = questions.borrow_mut().remove(&key);
                if let Some(mut question) = question {
                    question.interaction.questions.clear();
                    replies.borrow_mut().push_back((fd, wire::Kind::Notify, question.request, notify(
                        "interaction.opened", &[("terminal", &terminal), ("session", &question.binding.session),
                            ("interaction", &question.interaction)],
                    )));
                    // The checked effect has already happened. Resume the paused menu
                    // with its native outcome, so its keys cannot be typed twice.
                    deferred(question.done)(io, result.clone());
                }
            }
            done(io, result);
        });
        let done = typed(
            self.active(),
            mux,
            harness.clone(),
            local(terminal),
            binding.clone(),
            finish,
        );
        harness
            .borrow_mut()
            .answer(self.io, &binding, interaction, values, deferred(done));
        Ok(())
    }
    /// The app's command line through the helper's execution prefix; None without one.
    fn script(&self, p: Value<'_>) -> Result<Option<std::process::Command>, Error> {
        let Some(script) = p
            .get("command")
            .and_then(Value::string)
            .filter(|s| !s.is_empty())
        else {
            return Ok(None);
        };
        let prefix = &self.helper.execution;
        let mut command = std::process::Command::new(&prefix[0]);
        command.args(&prefix[1..]);
        if cfg!(target_os = "macos") && prefix[0] == "/usr/bin/login" {
            command.arg(format!("exec -l {script}"));
        } else {
            command.arg(script);
        }
        self.place(p, &mut command)?;
        Ok(Some(command))
    }
    /// The request's environment and cwd (else the parent's cwd) onto a command.
    fn place(&self, p: Value<'_>, command: &mut std::process::Command) -> Result<(), Error> {
        command.envs(environment(p)?);
        let cwd = p
            .get("cwd")
            .and_then(Value::string)
            .filter(|s| !s.is_empty())
            .map(std::path::PathBuf::from)
            .or_else(|| {
                optional(p, "parent").and_then(|id| {
                    self.helper
                        .nodes
                        .borrow()
                        .get(&id)
                        .and_then(|(_, n)| n.cwd.clone())
                })
            });
        if let Some(cwd) = cwd {
            command.current_dir(cwd);
        }
        Ok(())
    }
    fn unit_id(&self, index: usize, method: Option<&'static str>) -> Done<Id> {
        let done = self.done(method);
        let backends = self.helper.backends.clone();
        Box::new(move |io, result| {
            if method == Some("backend.opened")
                && let Ok(id) = &result
            {
                backends.borrow_mut().insert((index, *id));
            }
            done(io, result.map(|id| reference(index, id)));
        })
    }
}

// The single registration table: wire name, parameter schema and trait call.
macro_rules! registered {
    ($r:ident, unavailable, $m:ident) => {
        false
    };
    ($r:ident, core, $m:ident) => {
        true
    };
    ($r:ident, mux, $m:ident) => {
        !$r.helper.multiplexers.is_empty()
    };
    ($r:ident, harness, $m:ident) => {
        !$r.helper.harnesses.is_empty()
    };
    ($r:ident, plugin, $m:ident) => {
        $r.helper
            .plugins
            .iter()
            .any(|part| part.borrow().name() == plugin(stringify!($m)))
    };
}
macro_rules! operations {
    ($r:ident,$p:ident; $($name:literal => $schema:expr, $target:ident $method:ident ($($arg:expr),*) $reply:ident;)*) => {
        pub const OPERATIONS: &[&str] = &[$($name),*];
        pub(crate) fn parameters(root: Value<'_>, allowed: impl FnOnce(&str) -> bool) -> Result<(&str, Value<'_>), Error> {
            params::validate(root, params::Rule::Object(&[
                ("method", params::Rule::Text),
                ("params", params::Rule::Any),
            ]), "request")?;
            let method = text(root, "method")?;
            if !allowed(method) {
                return Err(Error {
                    code: "permission_denied",
                    message: "This SSH feature is disabled".into(),
                });
            }
            let schema = match method {
                $($name => $schema,)*
                _ => return Err(Error {
                    code: "unsupported",
                    message: format!("Unknown operation {method}"),
                }),
            };
            if let Some(value) = root.get("params") {
                params::validate(value, schema, "params")?;
                Ok((method, value))
            } else {
                Ok((method, root))
            }
        }
        impl Request<'_> {
            fn registered(&self, name: &str) -> bool {
                match name {
                    $( $name => registered!(self, $target, $method), )*
                    _ => false,
                }
            }
            pub fn dispatch(&mut $r, name: &str, $p: Value<'_>) -> Result<(), Error> {
                match name {
                    $(
                        $name => operation!($r, $p, $target, $method, [$($arg),*], $reply),
                    )*
                    _ => return Err(Error {
                        code: "unsupported",
                        message: format!("Unknown operation {name}"),
                    }),
                }
                Ok(())
            }
        }
    };
}
macro_rules! operation {
    ($r:ident,$p:ident,mux,$m:ident,[$($a:expr),*],$reply:ident) => {{
        let (index, mux) = $r.mux($p)?;
        let done = reply!($r, $p, index, $reply);
        let _ = index;
        mux.borrow_mut().$m($r.io, $($a,)* done);
    }};
    ($r:ident,$p:ident,harness,$m:ident,[$($a:expr),*],$reply:ident) => {{
        let (index, mux, harness, binding) = $r.agent($p)?;
        let done = reply!($r, $p, index, $reply);
        let _ = index;
        let terminal = number($p, "terminal")?;
        let (_, parent) = $r.helper.binding(terminal, None)?;
        if same(&parent, &binding)
            && matches!(stringify!($m), "send" | "stop" | "select" | "queue_send")
        {
            let document = $r.document.clone();
            let process = binding.process.clone();
            let call = checked(done, move |io, done| {
                let root = document.root();
                let $p = root.get("params").unwrap_or(root);
                let _ = $p;
                let mut done = Some(done);
                let result: Result<(), Error> = (|| {
                    harness.borrow_mut().$m(io, &binding, $($a,)* done.take().unwrap());
                    Ok(())
                })();
                if let Err(error) = result {
                    done.take().unwrap()(io, Err(error));
                }
            });
            mux.borrow_mut().check($r.io, local(terminal), &process, call);
        } else {
            harness.borrow_mut().$m($r.io, &binding, $($a,)* done);
        }
    }};
    ($r:ident,$p:ident,plugin,$m:ident,[$($a:expr),*],$reply:ident) => {{
        let name = $p.get("plugin").and_then(Value::string).unwrap_or(plugin(stringify!($m)));
        let plugin = $r.helper.plugins.iter()
            .find(|v| v.borrow().name() == name)
            .cloned()
            .ok_or_else(|| Error {
                code: "unsupported",
                message: format!("Plugin {name} unavailable"),
            })?;
        let done = $r.done(None);
        plugin.borrow_mut().$m($r.io, $($a,)* done);
    }};
    ($r:ident,$p:ident,core,$m:ident,[$($a:expr),*],$reply:ident) => {{
        $r.$m($p, $($a),*)?;
    }};
    ($r:ident,$p:ident,unavailable,$m:ident,[$($a:expr),*],$reply:ident) => {{
        return Err(Error {
            code: "unsupported",
            message: concat!("No producer for ", stringify!($m)).into(),
        });
    }};
}
macro_rules! reply {
    ($r:ident,$p:ident,$i:ident,value) => {
        $r.done(None)
    };
    ($r:ident,$p:ident,$i:ident,id) => {
        $r.unit_id($i, None)
    };
    ($r:ident,$p:ident,$i:ident,backend) => {
        $r.unit_id($i, Some("backend.opened"))
    };
    ($r:ident,$p:ident,$i:ident,output) => {
        $r.attached($p)?
    };
    ($r:ident,$p:ident,$i:ident,history) => {
        $r.done(Some("chat.history"))
    };
    ($r:ident,$p:ident,$i:ident,send) => {
        $r.sent(
            $p,
            Some(Goal::Send {
                text: text($p, "text")?.into(),
                mode: mode($p)?,
                command: flag($p, "command"),
            }),
        )?
    };
    ($r:ident,$p:ident,$i:ident,sent) => {
        $r.sent($p, None)?
    };
    ($r:ident,$p:ident,$i:ident,models) => {
        $r.fallback($p, Goal::Models, $r.done(None), |menu| menu)?
    };
    ($r:ident,$p:ident,$i:ident,efforts) => {
        $r.fallback(
            $p,
            Goal::Efforts {
                model: text($p, "model")?.into(),
            },
            $r.done(None),
            |menu| menu,
        )?
    };
    ($r:ident,$p:ident,$i:ident,select) => {
        $r.sent(
            $p,
            Some(Goal::Select {
                model: text($p, "model")?.into(),
                effort: $p.get("effort").and_then(Value::string).map(str::to_owned),
            }),
        )?
    };
}
include!("dispatch/table.rs");

impl Request<'_> {
    /// Protocol result: Binding when opening; null when closing
    fn side(&mut self, p: Value<'_>, close: bool) -> Result<(), Error> {
        let (_, _, harness, binding) = self.agent(p)?;
        let terminal = number(p, "terminal")?;
        let sides = self.helper.sides.clone();
        if close {
            let key = (terminal, binding.session.clone());
            if !sides.borrow().contains_key(&key) {
                return Err(invalid("session"));
            }
            let done = self.done(None);
            harness.borrow_mut().side_close(
                self.io,
                &binding,
                Box::new(move |io, result| {
                    if result.is_ok() {
                        sides.borrow_mut().remove(&key);
                    }
                    done(io, result);
                }),
            );
        } else {
            let nodes = self.helper.nodes.clone();
            let done = self.done(None);
            let (_, parent) = self.helper.binding(terminal, None)?;
            harness.borrow_mut().side(
                self.io,
                &binding,
                text(p, "question")?,
                flag(p, "read_only"),
                Box::new(move |io, result| {
                    let result = result.and_then(|side| {
                        if nodes
                            .borrow()
                            .get(&terminal)
                            .and_then(|(_, node)| node.agent.as_ref())
                            .is_none_or(|(_, current)| !same(current, &parent))
                        {
                            return Err(Error {
                                code: "expired",
                                message: "The side conversation destination changed".into(),
                            });
                        }
                        sides
                            .borrow_mut()
                            .insert((terminal, side.session.clone()), (parent, side.clone()));
                        Ok(side)
                    });
                    done(io, result);
                }),
            );
        }
        Ok(())
    }
    /// Protocol result: Vec<Backend> without mux; Vec<String> with mux
    fn backends(&mut self, p: Value<'_>) -> Result<(), Error> {
        if optional(p, "mux").is_some() {
            let (_, mux) = self.mux(p)?;
            let done = self.done(None);
            mux.borrow_mut().backends(self.io, done);
            return Ok(());
        }
        let parts = self.helper.multiplexers.clone();
        let default = self.helper.default.clone();
        let count = parts.len();
        let done = self.done(None);
        if count == 0 {
            done(self.io, Ok(Vec::<Backend>::new()));
            return Ok(());
        }
        let pending = Rc::new(RefCell::new((count, Vec::new(), Some(done))));
        for (index, mux) in parts.into_iter().enumerate() {
            let pending = pending.clone();
            let default = default.clone();
            let external = mux.borrow().external();
            mux.borrow_mut().backends(
                self.io,
                Box::new(move |io, result| {
                    let ready = {
                        let mut pending = pending.borrow_mut();
                        if let Ok(keys) = result {
                            pending.1.extend(keys.into_iter().map(|key| {
                                Backend {
                                    mux: index as u64,
                                    label: key.clone(),
                                    default: default
                                        .as_ref()
                                        .is_some_and(|(i, k)| *i == index && *k == key),
                                    external,
                                    key,
                                }
                            }));
                        }
                        pending.0 -= 1;
                        if pending.0 == 0 {
                            pending
                                .1
                                .sort_by(|a, b| (a.mux, &a.key).cmp(&(b.mux, &b.key)));
                            Some((pending.2.take().unwrap(), std::mem::take(&mut pending.1)))
                        } else {
                            None
                        }
                    };
                    if let Some((done, values)) = ready {
                        done(io, Ok(values));
                    }
                }),
            );
        }
        Ok(())
    }
    /// Protocol result: Id, published as backend.opened
    fn open(&mut self, p: Value<'_>) -> Result<(), Error> {
        let (index, mux) = self.mux(p)?;
        let done = self.unit_id(index, Some("backend.opened"));
        let key = p
            .get("key")
            .and_then(Value::string)
            .or_else(|| {
                self.helper
                    .default
                    .as_ref()
                    .filter(|(i, _)| *i == index)
                    .map(|(_, key)| key.as_str())
            })
            .ok_or_else(|| invalid("key"))?;
        mux.borrow_mut().open(self.io, key, done);
        Ok(())
    }
    /// Protocol result: list of {mux, name, external, claimed, program} for every registered multiplexer
    fn multiplexers(&mut self, _p: Value<'_>) -> Result<(), Error> {
        let kinds: Vec<Mux> = self
            .helper
            .multiplexers
            .iter()
            .enumerate()
            .map(|(index, mux)| {
                let mux_ref = mux.borrow();
                Mux {
                    mux: index as u64,
                    name: mux_ref.name().to_owned(),
                    external: mux_ref.external(),
                    claimed: !self.helper.unclaimed.contains(&index),
                    program: mux_ref.program(),
                }
            })
            .collect();
        self.done(None)(self.io, Ok(kinds));
        Ok(())
    }
    /// Protocol result: notifications until cancellation; only failure ends the request.
    fn observe(&mut self, p: Value<'_>) -> Result<(), Error> {
        number(p, "terminal")?;
        self.mux(p)?;
        Ok(())
    }
    /// Protocol result: null. enabled:false stops claiming that mux's clients in terminals.
    fn claim(&mut self, p: Value<'_>) -> Result<(), Error> {
        let (index, mux) = self.mux(p)?;
        let enabled = flag(p, "enabled");
        let resets = self.helper.resets.clone();
        let done = self.done(None);
        mux.borrow_mut().enable(
            self.io,
            enabled,
            Box::new(move |io, result| {
                if result.is_ok() {
                    resets.borrow_mut().push_back((index, enabled, done));
                } else {
                    done(io, result);
                }
            }),
        );
        Ok(())
    }

    /// Protocol result: null once the client the probe found in `terminal` left
    /// Protocol producers: Multiplexer.release
    fn release(&mut self, p: Value<'_>) -> Result<(), Error> {
        let (index, mux) = self.mux(p)?;
        let terminal = number(p, "terminal")?;
        if self.helper.launching.borrow().contains_key(&terminal) {
            let pending = self.helper.launching.clone();
            let receipts = self.helper.receipts.clone();
            let source = self.helper.multiplexers[(terminal >> 48) as usize].clone();
            let done = self.done(None);
            source.borrow_mut().control(self.io, local(terminal), deferred(Box::new(move |io, current| {
                let result = current.and_then(|current| {
                    pending.borrow().get(&terminal).ok_or_else(|| Error { code: "terminal_unavailable", message: String::new() })?.accept(index, &current)
                }).and_then(|reply| {
                    crate::probe::answer(io, reply, Ok(true)).map_err(|error| Error { code: "launch", message: error.to_string() })?;
                    pending.borrow_mut().remove(&terminal);
                    receipts.borrow_mut().remove(&reply);
                    Ok(())
                });
                done(io, result);
            })));
            return Ok(());
        }
        let client = self
            .helper
            .probes
            .borrow()
            .get(&terminal)
            .map(|(client, _)| client.clone())
            .ok_or_else(|| Error {
                code: "terminal_unavailable",
                message: "No multiplexer client was found in this terminal.".into(),
            })?;
        let done = self.done(None);
        mux.borrow_mut().release(self.io, &client, done);
        Ok(())
    }
    /// Protocol result: the unchanged params JSON value
    fn echo(&mut self, p: Value<'_>) -> Result<(), Error> {
        let body = p.write()?;
        self.replies.borrow_mut().push_back((
            self.fd,
            wire::Kind::Response,
            self.id,
            [b"{\"result\":".as_slice(), &body, b"}"].concat(),
        ));
        Ok(())
    }
    /// Protocol result: Vec<Launch>
    fn launches(&mut self, _p: Value<'_>) -> Result<(), Error> {
        self.done(None)(
            self.io,
            Ok(self
                .helper
                .harnesses
                .iter()
                .enumerate()
                .map(|(index, h)| {
                    let h = h.borrow();
                    Launch {
                        launch: index as u64,
                        key: h.key().to_owned(),
                        label: h.name().to_owned(),
                        program: self.helper.typed.get(&index).cloned(),
                    }
                })
                .collect::<Vec<_>>()),
        );
        Ok(())
    }
    /// Protocol result: null
    fn publish(&mut self, p: Value<'_>) -> Result<(), Error> {
        let (_, mux) = self.mux(p)?;
        let cursor = p.get("cursor").ok_or_else(|| invalid("cursor"))?;
        let cursor = (
            number(cursor, "column")? as u32,
            number(cursor, "row")? as u32,
        );
        mux.borrow_mut().publish(
            self.io,
            local(number(p, "terminal")?),
            Screen {
                text: text(p, "text")?.into(),
                cursor,
                faint_tail: flag(p, "faint_tail"),
            },
        );
        self.done(None)(self.io, Ok(()));
        Ok(())
    }
}

/// The reply (or, with `long`, one notification) of request `id` on `fd`.
pub(crate) fn reply<T: Encode + 'static>(
    replies: Replies,
    fd: i32,
    id: u64,
    long: Option<&'static str>,
) -> Done<T> {
    Box::new(move |_, result| match result {
        Ok(value) => {
            let body = if let Some(method) = long {
                let mut out = b"{\"method\":".to_vec();
                method.encode(&mut out);
                out.extend(b",\"params\":");
                value.encode(&mut out);
                out.push(b'}');
                out
            } else {
                let mut out = b"{\"result\":".to_vec();
                value.encode(&mut out);
                out.push(b'}');
                out
            };
            replies.borrow_mut().push_back((
                fd,
                if long.is_some() {
                    wire::Kind::Notify
                } else {
                    wire::Kind::Response
                },
                id,
                body,
            ));
        }
        Err(error) => crate::helper::failure(&replies, fd, id, error),
    })
}
