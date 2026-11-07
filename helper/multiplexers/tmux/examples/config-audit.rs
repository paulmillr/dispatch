//! Live custom-config audit driver. The Python runner owns the private tmux server.
use dispatch_helper_core::{api::*, system::System};
use dispatch_helper_tmux::Tmux;
use std::{
    cell::RefCell,
    path::PathBuf,
    process::{Command, Stdio},
    rc::Rc,
    time::Duration,
};
#[path = "../../../core/src/system/startup.rs"]
mod startup;

#[derive(Default)]
struct View {
    nodes: Vec<Node>,
}
impl Ui for View {
    fn update(&mut self, update: Update) {
        if let Update::Topology { nodes, .. } = update {
            self.nodes = nodes;
        }
    }
}

struct Audit {
    io: System,
    mux: Tmux,
    ui: View,
    relay: Option<(Id, i32)>,
}
impl Audit {
    fn call<T: 'static>(
        &mut self,
        start: impl FnOnce(&mut Tmux, &mut System, Done<T>),
    ) -> Result<T, Error> {
        let result = Rc::new(RefCell::new(None));
        let saved = result.clone();
        let deadline = self.io.now() + Duration::from_secs(5);
        self.io.timer(deadline);
        start(
            &mut self.mux,
            &mut self.io,
            Box::new(move |_, value| *saved.borrow_mut() = Some(value)),
        );
        loop {
            self.io.callbacks();
            if let Some(result) = result.borrow_mut().take() {
                return result;
            }
            let (_, event) = self.io.next().unwrap();
            if matches!(event, Event::Timer { at } if at >= deadline) {
                return Err(Error {
                    code: "timeout",
                    message: "audit operation exceeded five seconds".into(),
                });
            }
            self.feed(event)?;
        }
    }
    /// The relayed stream's bytes go to the mux before the event loop sees the event.
    fn feed(&mut self, event: Event) -> Result<(), Error> {
        if let (Some((id, output)), Event::Ready { fd, read: true, .. }) = (self.relay, &event) {
            if *fd == output {
                let mut bytes = [0; 65536];
                let count = self.io.read(output, &mut bytes).unwrap();
                if count == 0 {
                    return Err(Error {
                        code: "closed",
                        message: "relay ended".into(),
                    });
                }
                self.mux
                    .stream(&mut self.io, id, Control::Data(bytes[..count].to_vec()))?;
            }
        }
        self.mux.event(&mut self.io, &mut self.ui, event);
        Ok(())
    }
    /// Run the event loop until `done` holds for the published topology, or `within` passed.
    fn settle(&mut self, within: Duration, done: impl Fn(&[Node]) -> bool) {
        let deadline = self.io.now() + within;
        self.io.timer(deadline);
        while !done(&self.ui.nodes) {
            self.io.callbacks();
            let (_, event) = self.io.next().unwrap();
            if matches!(event, Event::Timer { at } if at >= deadline) {
                return;
            }
            self.feed(event).unwrap();
        }
    }
}

fn main() {
    let args: Vec<_> = std::env::args().collect();
    let mut audit = Audit {
        io: System::new(2, 128).unwrap(),
        mux: Tmux::new(PathBuf::from(&args[1])),
        ui: View::default(),
        relay: None,
    };
    audit.io.section("mux/tmux-config-audit");
    let opened = if std::env::var_os("AUDIT_RELAY").is_some() {
        let mut command = Command::new(&args[1]);
        command
            .args(["-S", &args[2], "-C", "attach-session", "-t", "audit"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let child = audit.io.spawn(command, None).unwrap();
        let input = child.input.unwrap();
        let output = child.output.unwrap();
        audit.io.interest(output, true, false).unwrap();
        let process = Process {
            pid: child.pid,
            parent: 0,
            group: 0,
            foreground: 0,
            tty: 0,
            start: [0, 0],
            executable: "/fixture/ssh".into(),
            arguments: vec![],
            files: vec![],
        };
        let writer: ControlWrite = Rc::new(move |io, bytes, done| {
            let result = io
                .write(input, bytes)
                .map_err(|e| Error {
                    code: "write",
                    message: e.to_string(),
                })
                .and_then(|n| {
                    if n == bytes.len() {
                        Ok(())
                    } else {
                        Err(Error {
                            code: "write",
                            message: "short write".into(),
                        })
                    }
                });
            done(io, result);
        });
        let target = audit
            .call(|mux, io, done| mux.claim(io, &process, writer, done))
            .unwrap()
            .unwrap();
        audit.relay = Some((target.id, output));
        // open coalesces with the adopted client's first snapshot and waits for its topology.
        audit.call(|mux, io, done| mux.open(io, &target.key, done))
    } else {
        audit.call(|mux, io, done| mux.open(io, &args[2], done))
    };
    let backend = match opened {
        Ok(id) => {
            println!("OPEN=OK");
            id
        }
        Err(error) => {
            println!("OPEN=ERR {error:?}");
            return;
        }
    };
    for node in &audit.ui.nodes {
        println!(
            "NODE={:?}|{}|{}|{}",
            node.kind, node.id, node.key, node.name
        );
    }
    let terminal = audit
        .ui
        .nodes
        .iter()
        .find(|n| n.kind == Kind::Terminal)
        .unwrap()
        .id;
    match args[3].as_str() {
        "prefix" => {
            // The first terminal's table, then every terminal's own session's (T4).
            let terminals: Vec<_> = audit
                .ui
                .nodes
                .iter()
                .filter(|n| n.kind == Kind::Terminal)
                .map(|n| (n.id, n.key.clone()))
                .collect();
            for (index, (node, key)) in terminals.into_iter().enumerate() {
                match audit.call(|mux, io, done| mux.prefix(io, node, done)) {
                    Ok(prefix) => {
                        println!(
                            "PREFIX_KEY={:?} REPEAT={:?} PREFIX2={:?} TERMINAL={key}",
                            prefix.key, prefix.repeat_ms, prefix.prefix2
                        );
                        if index > 0 {
                            continue;
                        }
                        for binding in prefix.bindings.into_iter().filter(|b| {
                            ["c", "h", "X"].contains(&b.key.as_str()) || b.key.contains('%')
                        }) {
                            println!("BINDING={binding:?}");
                        }
                    }
                    Err(error) => println!("PREFIX=ERR {error:?}"),
                }
            }
        }
        "create" | "split" | "create-command" | "create-shell" => {
            let parent = if args[3] == "split" {
                terminal
            } else {
                backend
            };
            let command = if args[3] == "create-shell" {
                Some(
                    startup::prepare(
                        std::path::Path::new("/bin/sh"),
                        std::path::Path::new(&std::env::var("HOME").unwrap()),
                        None,
                        std::path::Path::new("/fixture/helper"),
                        None,
                        None,
                        &|key| std::env::var_os(key),
                    )
                    .0,
                )
            } else {
                (args[3] == "create-command").then(|| {
                    let mut command = Command::new("/bin/sh");
                    command.args(["-c", "exec /bin/cat"]);
                    command
                })
            };
            // An ordinary terminal reaches the mux as create_shell (core's Request::create).
            let shell = args[3] == "create-shell";
            println!(
                "CREATE={:?}",
                audit.call(|mux, io, done| match command {
                    Some(command) if shell => mux.create_shell(io, parent, None, command, None, done),
                    command => mux.create(io, parent, None, command, None, done),
                })
            );
            println!(
                "FOCUS={:?}",
                audit.call(|mux, io, done| mux.focus(io, terminal, done))
            );
        }
        // The first terminal's backends.prefix reply with its wire names, for the app's own decoder.
        "prefix-json" => {
            let prefix = audit
                .call(|mux, io, done| mux.prefix(io, terminal, done))
                .unwrap();
            let text = |value: &str| {
                let mut out = String::from("\"");
                for c in value.chars() {
                    match c {
                        '"' => out.push_str("\\\""),
                        '\\' => out.push_str("\\\\"),
                        c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
                        c => out.push(c),
                    }
                }
                out + "\""
            };
            let optional = |value: &Option<String>| value.as_deref().map_or("null".into(), text);
            let bindings: Vec<_> = prefix
                .bindings
                .iter()
                .map(|b| {
                    format!(
                        "{{\"key\":{},\"command\":{},\"repeat\":{}}}",
                        text(&b.key),
                        text(&b.command),
                        b.repeat
                    )
                })
                .collect();
            println!(
                "{{\"key\":{},\"repeat_ms\":{},\"bindings\":[{}],\"prefix2\":{}}}",
                optional(&prefix.key),
                prefix.repeat_ms.map_or("null".into(), |ms| ms.to_string()),
                bindings.join(","),
                optional(&prefix.prefix2)
            );
        }
        // A session started outside Dispatch after the open (open.rs `sessions_changed`): a space of a server
        // opened by its socket; never one of a relayed stream, which shows its own session only.
        "later" => {
            let started = Command::new(&args[1])
                .args(["-S", &args[2], "new-session", "-d", "-s", "later"])
                .env_remove("TMUX")
                .status()
                .unwrap();
            println!("LATER={}", started.success());
            let spaces = |nodes: &[Node]| nodes.iter().filter(|n| n.kind == Kind::Workspace).count();
            let before = spaces(&audit.ui.nodes);
            audit.settle(Duration::from_secs(3), |nodes| spaces(nodes) > before);
            for node in audit.ui.nodes.iter().filter(|n| n.kind != Kind::Terminal) {
                println!("LATER_NODE={:?}|{}", node.kind, node.key.rsplit(':').next().unwrap_or(""));
            }
        }
        // Space names (affinity.rs `display`): the session's own space takes a chosen session name, read live;
        // another space of the session follows its folder, as does the own one under tmux's numeric default.
        "names" => {
            let tmux = |extra: &[&str]| {
                let output = Command::new(&args[1])
                    .args(["-S", &args[2]])
                    .args(extra)
                    .env_remove("TMUX")
                    .output()
                    .unwrap();
                String::from_utf8_lossy(&output.stdout).trim().to_owned()
            };
            let session = tmux(&["display-message", "-p", "-t", "audit:", "#{session_id}"]);
            let own = |nodes: &[Node]| {
                nodes
                    .iter()
                    .find(|n| n.kind == Kind::Workspace && n.key.ends_with(&format!(":{session}")))
                    .map(|n| n.name.clone())
            };
            println!("NAME_OPEN={:?}", own(&audit.ui.nodes));
            tmux(&["rename-session", "-t", "audit", "renamed"]);
            audit.settle(Duration::from_secs(3), |nodes| own(nodes).as_deref() == Some("renamed"));
            println!("NAME_RENAMED={:?}", own(&audit.ui.nodes));
            let window = tmux(&["new-window", "-d", "-t", "renamed:", "-P", "-F", "#{window_id}"]);
            let value = r#"{"version":1,"group":"0F0F0F0F-0000-4000-8000-000000000001","name":"extra","order":0,"usesDirectoryName":true}"#;
            tmux(&["set-option", "-w", "-t", &window, "@dispatch-window", value]);
            let extra = |nodes: &[Node]| {
                nodes
                    .iter()
                    .find(|n| n.kind == Kind::Workspace && n.key.contains(":group:"))
                    .map(|n| n.name.clone())
            };
            audit.settle(Duration::from_secs(3), |nodes| extra(nodes).is_some());
            println!("NAME_EXTRA={:?}", extra(&audit.ui.nodes));
            tmux(&["rename-session", "-t", "renamed", "42"]);
            audit.settle(Duration::from_secs(3), |nodes| own(nodes).as_deref() != Some("renamed"));
            println!("NAME_NUMBERED={:?}", own(&audit.ui.nodes));
        }
        "command" => println!(
            "COMMAND={:?}",
            audit.call(|mux, io, done| mux.command(io, terminal, &args[4], done))
        ),
        _ => {}
    }
}
