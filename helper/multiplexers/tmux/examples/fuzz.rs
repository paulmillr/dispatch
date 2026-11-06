//! Randomized tmux driver for `test/tmux-fuzz.py`, which owns the private tmux server.
//!
//! `fuzz TMUX SOCKET SEED STEPS` interleaves Dispatch's operations (the Multiplexer API) with commands a user types
//! into tmux, and after each step waits up to 3 s for the published topology to match the server: its sessions,
//! windows, panes and window names. `FUZZ_MODE` picks how the backend is reached: `socket` (backends.open: every
//! reconnect and the iPhone), `local` (a tab's own `tmux -CC` on a PTY, claimed as a verified local client) or
//! `relay` (a control stream claim cannot verify, as through ssh). Lines the runner checks: `DONE`, `MISMATCH`,
//! `STALE`, `BADKEY`, `STREAM_ERR`, a Dispatch step (`STEP n D`) that timed out; a panic exits non-zero.
//! `FUZZ_SCENARIO="cmd; cmd"` runs those tmux commands instead and prints the topology (a repro); `FUZZ_RAW` prints
//! the relayed bytes; `FUZZ_DUMP_AT=n` prints the nodes after step n.
use dispatch_helper_core::{api::*, system::System};
use dispatch_helper_tmux::Tmux;
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
    process::{Command, Stdio},
    rc::Rc,
    time::Duration,
};

/// xorshift64: the same seed makes the same choices.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: usize) -> usize {
        if n == 0 { 0 } else { (self.next() % n as u64) as usize }
    }
    fn pick<'a, T>(&mut self, items: &'a [T]) -> Option<&'a T> {
        if items.is_empty() { None } else { Some(&items[self.below(items.len())]) }
    }
    fn chance(&mut self, percent: u64) -> bool {
        self.next() % 100 < percent
    }
}

#[derive(Default)]
struct View {
    nodes: Vec<Node>,
}
impl Ui for View {
    fn update(&mut self, update: Update) {
        if let Update::Topology { nodes, backend, .. } = update {
            if std::env::var_os("FUZZ_SCENARIO").is_some() {
                println!("  TOPOLOGY backend={backend} nodes={}", nodes.len());
            }
            self.nodes = nodes;
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Socket,
    Local,
    Relay,
}

/// Names for sessions, windows, panes and spaces: tmux's format and target syntax, the helper's `|` field separator,
/// control characters, wide and invisible characters.
const NAMES: &[&str] = &[
    "", " ", "work", "#{session_id}", "a|b", "a|b|c|d|e|f|g", "a;b", "a \\; b", "-t", "--", "\"q\"", "'s'",
    "é ñ 日本 🙂", "a\tb", "a\nb", "\u{1}ctl", "a:b", "a.b", "$1", "@2", "%3", "#[fg=red]x", "##", "~", "../..",
    "{}", "\\", "x.exe", "trailing ", " leading", "#(echo hi)", "\u{7f}del", "\u{200b}zw", "名前", "a=b",
];

/// What the helper publishes for a window name: control characters as spaces (query.tmux), `.exe` dropped
/// (affinity.rs `label`).
fn published(name: &str) -> String {
    let name: String = name.chars().map(|c| if (c as u32) < 0x20 || c as u32 == 0x7f { ' ' } else { c }).collect();
    if name.chars().count() > 4 && name.to_lowercase().ends_with(".exe") && !name.contains(' ') {
        name[..name.len() - 4].into()
    } else {
        name
    }
}

/// (session, `@` or `%`, window or pane) of a node key `tmux:<namespace>:$S[:@W|:%P|:group:G]`.
fn parse_key(key: &str) -> (Option<u64>, Option<char>, Option<u64>) {
    if key.contains(":retained:") {
        return (None, None, None);
    }
    let Some(at) = key.rfind(":$") else { return (None, None, None) };
    let mut parts = key[at + 2..].split(':');
    let session = parts.next().and_then(|s| s.parse().ok());
    match parts.next() {
        Some(p) if p.starts_with('@') || p.starts_with('%') => (session, p.chars().next(), p[1..].parse().ok()),
        _ => (session, None, None),
    }
}

fn short(key: &str) -> &str {
    key.rfind(":$").map_or(key, |at| &key[at + 1..])
}

type Triples = BTreeSet<(u64, u64, u64)>;

struct Fuzz {
    io: System,
    mux: Tmux,
    ui: View,
    tmux: String,
    socket: String,
    rng: Rng,
    mode: Mode,
    backend: Id,
    /// Terminals attached by a step: input and screen reads go to these (others hold input until attached).
    attached: BTreeSet<Id>,
    /// Panes Dispatch detached: they stay hidden wherever tmux moves them (dismissal is per pane).
    detached: BTreeSet<(u64, u64)>,
    /// The claimed control client's pid: its stream shows the session that client is on (tmux moves it to another
    /// when its session ends under `detach-on-destroy off`). None for a server opened by its socket.
    claimed: Option<u32>,
    /// The relayed stream and how far its DCS frame is read (0 before, 1 inside, 2 after; a PTY only).
    relay: Option<(Id, i32)>,
    dcs: u8,
    ended: bool,
    reported: String,
    dumped: bool,
}

impl Fuzz {
    /// The relayed client's bytes, as the Mac forwards them: on a PTY (`-CC`), only what is inside the DCS 1000p
    /// frame (Start at its opener, End at its ST), as the renderer's control detection does.
    fn relay_event(&mut self, event: &Event) {
        let (Some((id, output)), Event::Ready { fd, read: true, .. }) = (self.relay, event) else { return };
        if *fd != output {
            return;
        }
        let mut bytes = [0; 65536];
        let count = self.io.read(output, &mut bytes).unwrap_or(0);
        if count == 0 {
            println!("RELAY_ENDED");
            self.relay = None;
            self.ended = true;
            self.io.close(output);
            if self.dcs != 2 {
                let _ = self.mux.stream(&mut self.io, id, Control::End);
            }
            let _ = self.mux.stream(&mut self.io, id, Control::Exit(None));
            return;
        }
        let mut data = &bytes[..count];
        if std::env::var_os("FUZZ_RAW").is_some() {
            println!("RAW {}", String::from_utf8_lossy(data).escape_debug());
        }
        let stream = |mux: &mut Tmux, io: &mut System, control: Control| {
            if let Err(error) = mux.stream(io, id, control) {
                println!("STREAM_ERR {error:?}");
            }
        };
        if self.mode != Mode::Local {
            stream(&mut self.mux, &mut self.io, Control::Data(data.to_vec()));
            return;
        }
        if self.dcs == 0 {
            let Some(at) = data.windows(7).position(|w| w == b"\x1bP1000p") else { return };
            data = &data[at + 7..];
            self.dcs = 1;
            stream(&mut self.mux, &mut self.io, Control::Start);
        }
        if self.dcs == 1 {
            let end = data.windows(2).position(|w| w == b"\x1b\\");
            let inside = &data[..end.unwrap_or(data.len())];
            if !inside.is_empty() {
                stream(&mut self.mux, &mut self.io, Control::Data(inside.to_vec()));
            }
            if end.is_some() {
                self.dcs = 2;
                stream(&mut self.mux, &mut self.io, Control::End);
            }
        }
    }
    fn call<T: 'static>(&mut self, start: impl FnOnce(&mut Tmux, &mut System, Done<T>)) -> Result<T, Error> {
        let result = Rc::new(RefCell::new(None));
        let saved = result.clone();
        let deadline = self.io.now() + Duration::from_secs(5);
        self.io.timer(deadline);
        start(&mut self.mux, &mut self.io, Box::new(move |_, value| *saved.borrow_mut() = Some(value)));
        loop {
            self.io.callbacks();
            if let Some(result) = result.borrow_mut().take() {
                return result;
            }
            let (_, event) = self.io.next().unwrap();
            if matches!(event, Event::Timer { at } if at >= deadline) {
                return Err(Error { code: "timeout", message: "operation exceeded five seconds".into() });
            }
            self.relay_event(&event);
            self.mux.event(&mut self.io, &mut self.ui, event);
        }
    }
    fn pump(&mut self, ms: u64) {
        let deadline = self.io.now() + Duration::from_millis(ms);
        self.io.timer(deadline);
        loop {
            self.io.callbacks();
            let (_, event) = self.io.next().unwrap();
            if matches!(event, Event::Timer { at } if at >= deadline) {
                return;
            }
            self.relay_event(&event);
            self.mux.event(&mut self.io, &mut self.ui, event);
        }
    }
    fn native(&self, args: &[&str]) -> (bool, String, String) {
        let out = Command::new(&self.tmux).arg("-S").arg(&self.socket).args(args).env_remove("TMUX").output().unwrap();
        (out.status.success(), String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
    }
    /// The server's (session, window, pane) triples and window names; None once the server is gone.
    fn truth(&self) -> Option<(Triples, BTreeMap<u64, String>)> {
        let (ok, out, _) = self.native(&["list-panes", "-a", "-F", "#{session_id}|#{window_id}|#{pane_id}|#{window_name}"]);
        if !ok {
            return None;
        }
        let scope: Option<BTreeSet<u64>> = self.claimed.map(|pid| {
            let clients = self.native(&["list-clients", "-F", "#{client_pid}|#{session_id}"]).1;
            clients.lines().filter_map(|line| line.split_once('|'))
                .filter(|(client, _)| client.parse() == Ok(pid))
                .filter_map(|(_, session)| session[1..].parse().ok()).collect()
        });
        let mut set = BTreeSet::new();
        let mut names = BTreeMap::new();
        for line in out.lines() {
            let f: Vec<_> = line.splitn(4, '|').collect();
            let [s, w, p, name] = f[..] else { continue };
            let (Ok(s), Ok(w), Ok(p)) = (s[1..].parse(), w[1..].parse(), p[1..].parse()) else { continue };
            if scope.as_ref().is_some_and(|scope| !scope.contains(&s)) || self.detached.contains(&(s, p)) {
                continue;
            }
            set.insert((s, w, p));
            names.insert(w, name.to_owned());
        }
        Some((set, names))
    }
    fn topology(&self) -> (Triples, BTreeMap<u64, String>) {
        let by_id: BTreeMap<Id, &Node> = self.ui.nodes.iter().map(|n| (n.id, n)).collect();
        let mut set = BTreeSet::new();
        let mut names = BTreeMap::new();
        for node in self.ui.nodes.iter().filter(|n| !n.key.contains(":retained:")) {
            match node.kind {
                Kind::Terminal => {
                    let (s, _, p) = parse_key(&node.key);
                    let w = node.parent.and_then(|p| by_id.get(&p)).and_then(|t| parse_key(&t.key).2);
                    match (s, w, p) {
                        (Some(s), Some(w), Some(p)) => {
                            set.insert((s, w, p));
                        }
                        _ => println!("BADKEY {} parent={:?}", node.key, node.parent),
                    }
                }
                Kind::Tab => {
                    if let (_, Some('@'), Some(w)) = parse_key(&node.key) {
                        names.insert(w, node.name.clone());
                    }
                }
                Kind::Workspace => {}
            }
        }
        (set, names)
    }
    /// Wait up to 3 s for the topology to match the server; report the difference otherwise. False once there is
    /// nothing more to compare (the server or the relayed stream ended).
    fn converge(&mut self, step: usize) -> bool {
        let mut last = String::new();
        for _ in 0..30 {
            self.pump(100);
            if self.ended {
                return false;
            }
            let Some((mut truth, names)) = self.truth() else {
                println!("SERVER_GONE step={step}");
                return false;
            };
            let (topology, shown) = self.topology();
            // With every session detached no control client is left to hear of new ones: nothing more follows the
            // server until the app restores one (docs/integrations.md, Sessions and space names).
            if topology.is_empty() && !self.detached.is_empty() {
                println!("ALL_DETACHED step={step}");
                return false;
            }
            let terminals: BTreeSet<Id> = self.ui.nodes.iter().filter(|n| n.kind == Kind::Terminal).map(|n| n.id).collect();
            // A terminal shown again after it was gone needs a new attach before it takes input.
            self.attached.retain(|id| terminals.contains(id));
            // A session whose every pane Dispatch detached stays quiet: windows started there later stay hidden
            // until the app restores it (docs/integrations.md, Sessions and space names).
            let quiet: BTreeSet<u64> = self.detached.iter().map(|(s, _)| *s)
                .filter(|s| !topology.iter().any(|t| t.0 == *s)).collect();
            truth.retain(|t| !quiet.contains(&t.0));
            let windows: BTreeSet<u64> = truth.iter().map(|t| t.1).collect();
            let expected: BTreeMap<u64, String> = names.iter().filter(|(w, _)| windows.contains(w))
                .map(|(w, n)| (*w, published(n))).collect();
            if truth == topology && expected == shown {
                return true;
            }
            last = format!(
                "missing={:?} extra={:?} names_expected={:?} names_published={:?}",
                truth.difference(&topology).collect::<Vec<_>>(),
                topology.difference(&truth).collect::<Vec<_>>(),
                expected.iter().filter(|(w, n)| shown.get(w) != Some(n)).collect::<Vec<_>>(),
                shown.iter().filter(|(w, n)| expected.get(w) != Some(n)).collect::<Vec<_>>(),
            );
        }
        if last != self.reported {
            println!("MISMATCH step={step} {last}");
            if !self.dumped {
                self.dumped = true;
                self.dump();
                println!("  TRUTH {}", self.native(&["list-panes", "-a", "-F", "#{session_id}|#{window_id}|#{pane_id}|#{@dispatch-window}"]).1.replace('\n', " ; "));
            }
            self.reported = last;
        }
        true
    }
    fn dump(&self) {
        for n in &self.ui.nodes {
            println!("  NODE {:?} id={} parent={:?} key={} attached={}", n.kind, n.id, n.parent, short(&n.key), self.attached.contains(&n.id));
        }
    }
    /// A close that answered Ok: what it detached and the server kept stays hidden.
    fn forget(&mut self, before: &[Node], node: Id) {
        let mut stack = vec![node];
        while let Some(id) = stack.pop() {
            stack.extend(before.iter().filter(|n| n.parent == Some(id)).map(|n| n.id));
            if let Some(n) = before.iter().find(|n| n.id == id)
                && let (Some(s), Some('%'), Some(p)) = parse_key(&n.key)
            {
                self.detached.insert((s, p));
            }
        }
    }
    fn nodes(&self, kind: Kind) -> Vec<Id> {
        self.ui.nodes.iter().filter(|n| n.kind == kind && !n.key.contains(":retained:")).map(|n| n.id).collect()
    }
    fn name(&mut self) -> String {
        if self.rng.chance(15) {
            let len = 1 + self.rng.below(600);
            (0..len).map(|_| char::from_u32(0x20 + self.rng.below(0x2fe0) as u32).unwrap_or('?')).collect()
        } else {
            self.rng.pick(NAMES).unwrap().to_string()
        }
    }
    /// A random id of `list`'s rows (`$`, `@` or `%` ids), or an empty string.
    fn target(&mut self, list: &[&str]) -> String {
        let (_, out, _) = self.native(list);
        let items: Vec<String> = out.lines().map(str::to_owned).collect();
        self.rng.pick(&items).cloned().unwrap_or_default()
    }

    fn dispatch_op(&mut self, step: usize) {
        let terminals = self.nodes(Kind::Terminal);
        let tabs = self.nodes(Kind::Tab);
        let workspaces = self.nodes(Kind::Workspace);
        let all: Vec<Id> = self.ui.nodes.iter().map(|n| n.id).collect();
        let attached: Vec<Id> = terminals.iter().copied().filter(|t| self.attached.contains(t)).collect();
        let text = match self.rng.below(14) {
            0 => {
                // A new window in a space, or (the backend) a new space; beside a terminal: a split.
                let mut parents = workspaces.clone();
                parents.push(self.backend);
                let Some(&parent) = self.rng.pick(&parents) else { return };
                let beside = if self.rng.chance(30) { self.rng.pick(&terminals).copied() } else { None };
                format!("create parent={parent} beside={beside:?} => {:?}", self.call(|m, io, d| m.create(io, parent, beside, None, None, d)))
            }
            1 => {
                let Some(&parent) = self.rng.pick(&terminals) else { return };
                format!("split terminal={parent} => {:?}", self.call(|m, io, d| m.create(io, parent, None, None, None, d)))
            }
            2 => {
                let Some(&node) = self.rng.pick(&all) else { return };
                let name = self.name();
                let result = self.call(|m, io, d| m.rename(io, node, &name, d));
                format!("rename node={node} name={name:?} => {result:?}")
            }
            3 => {
                let Some(&node) = self.rng.pick(&all) else { return };
                format!("focus node={node} => {:?}", self.call(|m, io, d| m.focus(io, node, d)))
            }
            4 => {
                let Some(&node) = self.rng.pick(&all) else { return };
                let how = match self.rng.below(3) { 0 => Close::Prompt, 1 => Close::Detach, _ => Close::Terminate };
                let label = format!("{how:?} {}", self.ui.nodes.iter().find(|n| n.id == node).map_or("", |n| short(&n.key)));
                let before = self.ui.nodes.clone();
                let result = self.call(|m, io, d| m.close(io, node, how, d));
                if result.is_ok() {
                    self.forget(&before, node);
                }
                format!("close node={node} {label} => {result:?}")
            }
            5 => {
                let (Some(&node), Some(&parent)) = (self.rng.pick(&tabs), self.rng.pick(&workspaces)) else { return };
                let before = if self.rng.chance(50) { self.rng.pick(&tabs).copied() } else { None };
                format!("move tab={node} parent={parent} before={before:?} => {:?}", self.call(|m, io, d| m.r#move(io, node, parent, before, d)))
            }
            6 => {
                let Some(&t) = self.rng.pick(&terminals) else { return };
                let zoomed = self.rng.chance(50);
                format!("zoom terminal={t} {zoomed} => {:?}", self.call(|m, io, d| m.zoom(io, t, zoomed, d)))
            }
            7 => {
                let Some(&t) = self.rng.pick(&terminals) else { return };
                let grid = Grid {
                    columns: if self.rng.chance(5) { 0 } else { 1 + self.rng.below(400) as u16 },
                    rows: if self.rng.chance(5) { 0 } else { 1 + self.rng.below(150) as u16 },
                    pixels: None,
                };
                format!("resize terminal={t} {}x{} => {:?}", grid.columns, grid.rows, self.call(|m, io, d| m.resize(io, t, grid, d)))
            }
            8 => {
                // Panes run cat; ^C, ^D, ^Z and ^\ would end or stop it.
                let Some(&t) = self.rng.pick(&attached) else { return };
                let len = self.rng.below(64);
                let bytes: Vec<u8> = (0..len).map(|_| self.rng.next() as u8).filter(|b| ![3, 4, 26, 28].contains(b)).collect();
                format!("input terminal={t} {} bytes => {:?}", bytes.len(), self.call(|m, io, d| m.input(io, t, &bytes, d)))
            }
            9 => {
                let Some(&t) = self.rng.pick(&terminals) else { return };
                let commands = ["select-window -t :=0", "select-window -t :=5", "resize-pane -U 5", "send-prefix",
                    "select-layout tiled", "swap-pane -D", "select-pane -L", "next-layout", "rotate-window",
                    "resize-pane -Z", "last-window", "select-window -t :=999999999999"];
                let command = self.rng.pick(&commands).unwrap().to_string();
                format!("command terminal={t} {command:?} => {:?}", self.call(|m, io, d| m.command(io, t, &command, d)))
            }
            10 => {
                let Some(&node) = self.rng.pick(&all) else { return };
                format!("prefix node={node} => {:?}", self.call(|m, io, d| m.prefix(io, node, d)).map(|p| p.key))
            }
            11 => {
                let Some(&t) = self.rng.pick(&terminals) else { return };
                let grid = Grid { columns: 20 + self.rng.below(200) as u16, rows: 5 + self.rng.below(60) as u16, pixels: None };
                let (takeover, publishes) = (self.rng.chance(50), self.rng.chance(50));
                let result = self.call(|m, io, d| m.attach(io, t, grid, takeover, publishes, d));
                if result.is_ok() {
                    self.attached.insert(t);
                }
                format!("attach terminal={t} takeover={takeover} publishes={publishes} => {result:?}")
            }
            12 => {
                // The screen now (host_screens is on): a read waiting for a change would wait for output.
                let Some(&t) = self.rng.pick(&attached) else { return };
                format!("screen terminal={t} => {:?}", self.call(|m, io, d| m.screen(io, t, false, d)).map(|_| "screen"))
            }
            _ => {
                let Some(&node) = self.rng.pick(&all) else { return };
                format!("idle node={node} => {:?}", self.call(|m, io, d| m.idle(io, node, d)))
            }
        };
        println!("STEP {step} D {text}");
        let dump_at = std::env::var("FUZZ_DUMP_AT").ok().and_then(|v| v.parse::<usize>().ok());
        if text.contains("\"timeout\"") || dump_at == Some(step) {
            self.dump();
        }
    }

    fn user_op(&mut self, step: usize) {
        const PANES: [&str; 4] = ["list-panes", "-a", "-F", "#{pane_id}"];
        const WINDOWS: [&str; 4] = ["list-windows", "-a", "-F", "#{window_id}"];
        const SESSIONS: [&str; 3] = ["list-sessions", "-F", "#{session_id}"];
        let count = |f: &Fuzz, list: &[&str]| f.native(list).1.lines().count();
        let name = self.name();
        let words: Vec<String> = match self.rng.below(22) {
            0 => vec!["new-window".into(), "-d".into(), "-n".into(), name, "-t".into(), format!("{}:", self.target(&SESSIONS))],
            1 => vec!["split-window".into(), "-d".into(), "-t".into(), self.target(&PANES)],
            // Never the last pane, window or session: the server would exit with it.
            2 if count(self, &PANES) > 2 => vec!["kill-pane".into(), "-t".into(), self.target(&PANES)],
            3 if count(self, &WINDOWS) > 2 => vec!["kill-window".into(), "-t".into(), self.target(&WINDOWS)],
            4 if count(self, &SESSIONS) > 1 => vec!["kill-session".into(), "-t".into(), self.target(&SESSIONS)],
            5 => vec!["rename-window".into(), "-t".into(), self.target(&WINDOWS), name],
            6 => vec!["rename-session".into(), "-t".into(), self.target(&SESSIONS), name],
            7 => vec!["new-session".into(), "-d".into(), "-s".into(), name],
            8 => vec!["swap-window".into(), "-s".into(), self.target(&WINDOWS), "-t".into(), self.target(&WINDOWS)],
            9 => vec!["move-window".into(), "-s".into(), self.target(&WINDOWS), "-t".into(), format!("{}:", self.target(&SESSIONS))],
            10 => vec!["link-window".into(), "-d".into(), "-s".into(), self.target(&WINDOWS), "-t".into(), format!("{}:", self.target(&SESSIONS))],
            11 => vec!["unlink-window".into(), "-t".into(), self.target(&WINDOWS)],
            12 => vec!["break-pane".into(), "-d".into(), "-s".into(), self.target(&PANES)],
            13 => vec!["join-pane".into(), "-d".into(), "-s".into(), self.target(&PANES), "-t".into(), self.target(&PANES)],
            14 => vec!["respawn-pane".into(), "-k".into(), "-t".into(), self.target(&PANES)],
            15 => {
                let layouts = ["tiled", "even-horizontal", "even-vertical", "main-vertical", "main-horizontal"];
                vec!["select-layout".into(), "-t".into(), self.target(&WINDOWS), self.rng.pick(&layouts).unwrap().to_string()]
            }
            16 => vec!["resize-window".into(), "-t".into(), self.target(&WINDOWS), "-x".into(), (1 + self.rng.below(300)).to_string(), "-y".into(), (1 + self.rng.below(100)).to_string()],
            17 => vec!["select-pane".into(), "-t".into(), self.target(&PANES), "-T".into(), name],
            18 => {
                let options = [("renumber-windows", "on"), ("renumber-windows", "off"), ("base-index", "3"), ("automatic-rename", "off"),
                    ("automatic-rename", "on"), ("remain-on-exit", "on"), ("remain-on-exit", "off"), ("pane-border-status", "top"),
                    ("pane-border-status", "off"), ("status", "off"), ("status", "4"), ("window-size", "smallest"), ("window-size", "manual"),
                    ("allow-rename", "off"), ("synchronize-panes", "on"), ("history-limit", "0")];
                let (option, value) = self.rng.pick(&options).unwrap();
                vec!["set-option".into(), "-g".into(), option.to_string(), value.to_string()]
            }
            // cat ends on ^D (remain-on-exit keeps the pane, dead).
            19 if count(self, &PANES) > 1 => vec!["send-keys".into(), "-t".into(), self.target(&PANES), "C-d".into()],
            20 => {
                // The grouping option is raw: anything a pane's program sets.
                let values = ["", "{", "null", "[]", "{\"group\":1}", "{\"group\":\"g\",\"name\":\"n\",\"order\":-1}",
                    "{\"group\":\"g\",\"name\":\"\\u0000x\",\"order\":18446744073709551615}", "{\"group\":\"g\"}\n@0|x",
                    "{\"group\":\"\",\"name\":\"\",\"order\":0}", "|||", "{\"group\":\"g\",\"name\":\"n\",\"order\":1e400}"];
                let value = if self.rng.chance(20) { "[".repeat(5000) } else { self.rng.pick(&values).unwrap().to_string() };
                vec!["set-option".into(), "-w".into(), "-t".into(), self.target(&WINDOWS), "@dispatch-window".into(), value]
            }
            _ => vec!["swap-pane".into(), "-d".into(), "-s".into(), self.target(&PANES), "-t".into(), self.target(&PANES)],
        };
        let args: Vec<&str> = words.iter().map(String::as_str).collect();
        let (ok, _, err) = self.native(&args);
        let shown: Vec<String> = args.iter().map(|a| a.chars().take(40).collect()).collect();
        println!("STEP {step} U {shown:?} => {}", if ok { "ok".into() } else { format!("err {}", err.trim()) });
    }

    /// Claim a control client of session $0 as the Mac would hand it over; the claimed stream's open id.
    fn claim(&mut self) -> Result<Id, Error> {
        let local = self.mode == Mode::Local;
        let mut command = Command::new(&self.tmux);
        let child = if local {
            command.args(["-S", &self.socket, "-CC", "attach-session", "-t", "$0"]);
            self.io.spawn(command, Some(Grid { columns: 120, rows: 40, pixels: None })).unwrap()
        } else {
            command.args(["-S", &self.socket, "-C", "attach-session", "-t", "$0"])
                .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
            self.io.spawn(command, None).unwrap()
        };
        let (input, output) = (child.input.unwrap(), child.output.unwrap());
        let process = if local {
            // The process as the mux reads it again: verified as a local `tmux -CC` in its terminal's foreground.
            std::thread::sleep(Duration::from_millis(300));
            let work = self.io.submit(Job::Process { pid: child.pid }).unwrap();
            loop {
                self.io.callbacks();
                match self.io.next().unwrap().1 {
                    Event::Done { work: done, result } if done == work => match result {
                        Ok(Output::Process(process)) => break process,
                        other => return Err(Error { code: "process", message: format!("{:?}", other.map(|_| ())) }),
                    },
                    event => self.mux.event(&mut self.io, &mut self.ui, event),
                }
            }
        } else {
            Process { pid: child.pid, parent: 0, group: 0, foreground: 0, tty: 0, start: [0, 0],
                executable: "/fixture/ssh".into(), arguments: vec![], files: vec![] }
        };
        // Everything is written, however the PTY splits it (an attach writes over a kilobyte at once).
        let writer: ControlWrite = Rc::new(move |io, bytes, done| {
            let mut rest = bytes;
            let started = std::time::Instant::now();
            let mut result = Ok(());
            while !rest.is_empty() {
                match io.write(input, rest) {
                    Ok(n) => rest = &rest[n..],
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock && started.elapsed() < Duration::from_secs(2) => {
                        std::thread::sleep(Duration::from_millis(2));
                    }
                    Err(e) => {
                        result = Err(Error { code: "write", message: e.to_string() });
                        break;
                    }
                }
            }
            done(io, result);
        });
        let target = self.call(|m, io, d| m.claim(io, &process, writer, d))?
            .ok_or_else(|| Error { code: "claim", message: "not claimed".into() })?;
        self.relay = Some((target.id, output));
        self.claimed = Some(child.pid);
        // Read only now: bytes before the claim wait in the pipe or PTY.
        self.io.interest(output, true, false).unwrap();
        self.call(|m, io, d| m.open(io, &target.key, d))
    }
}

fn main() {
    let args: Vec<_> = std::env::args().collect();
    let seed: u64 = args[3].parse().unwrap();
    let steps: usize = args[4].parse().unwrap();
    let mode = match std::env::var("FUZZ_MODE").as_deref() {
        Ok("local") => Mode::Local,
        Ok("relay") => Mode::Relay,
        _ => Mode::Socket,
    };
    let mut fuzz = Fuzz {
        io: System::new(2, 128).unwrap(),
        mux: Tmux::new(PathBuf::from(&args[1])),
        ui: View::default(),
        tmux: args[1].clone(),
        socket: args[2].clone(),
        rng: Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1),
        mode,
        backend: 0,
        attached: BTreeSet::new(),
        detached: BTreeSet::new(),
        claimed: None,
        relay: None,
        dcs: 0,
        ended: false,
        reported: String::new(),
        dumped: false,
    };
    fuzz.io.section("mux/tmux-fuzz");
    // Screens come from tmux, as for the queue drainer: no client publishes them here.
    fuzz.mux.host_screens(true);
    let socket = fuzz.socket.clone();
    let opened = if mode == Mode::Socket { fuzz.call(|m, io, d| m.open(io, &socket, d)) } else { fuzz.claim() };
    match opened {
        Ok(id) => {
            println!("OPEN=OK");
            fuzz.backend = id;
        }
        Err(error) => {
            println!("OPEN=ERR {error:?}");
            return;
        }
    }
    if let Ok(scenario) = std::env::var("FUZZ_SCENARIO") {
        for command in scenario.split(';') {
            let args: Vec<&str> = command.split_whitespace().collect();
            println!("RUN {args:?} => {:?}", fuzz.native(&args));
            fuzz.pump(500);
        }
        fuzz.pump(3000);
        fuzz.dump();
        println!("TRUTH {}", fuzz.native(&["list-panes", "-a", "-F", "#{session_id}|#{window_id}|#{pane_id}"]).1);
        return;
    }
    if fuzz.converge(0) {
        for step in 1..=steps {
            if fuzz.rng.chance(55) { fuzz.dispatch_op(step) } else { fuzz.user_op(step) }
            if !fuzz.converge(step) {
                break;
            }
        }
    }
    if fuzz.ended && mode == Mode::Local {
        // A tab's own client ended (its session killed or detached): its spaces leave.
        fuzz.pump(3000);
        let live = fuzz.ui.nodes.iter().filter(|n| !n.key.contains(":retained:")).count();
        if live > 0 {
            println!("STALE {live} nodes after the claimed client ended");
            fuzz.dump();
        }
    }
    // A relayed stream that ends keeps its last view for a reconnect (backend.rs `suspended`), even after tmux's
    // %exit: nothing to compare after it.
    println!("DONE");
}
