//! backends.create on a host without a running tmux server (the iPhone app has no shell).
use super::*;
use std::{
    io,
    os::fd::RawFd,
    path::{Path, PathBuf},
    process::Command,
    time::Instant,
};

/// Records submitted jobs; completions are delivered by the test.
struct Jobs {
    now: Instant,
    submitted: Vec<(Work, Job)>,
}
#[rustfmt::skip]
impl Io for Jobs {
    fn now(&self) -> Instant { self.now }
    fn timer(&mut self, _: Instant) {}
    fn defer(&mut self, _: Box<dyn FnOnce(&mut dyn Io)>) {}
    fn interest(&mut self, _: RawFd, _: bool, _: bool) -> io::Result<()> { Ok(()) }
    fn read(&mut self, _: RawFd, _: &mut [u8]) -> io::Result<usize> { unreachable!() }
    fn write(&mut self, _: RawFd, _: &[u8]) -> io::Result<usize> { unreachable!() }
    fn close(&mut self, _: RawFd) {}
    fn accept(&mut self, _: RawFd) -> io::Result<RawFd> { unreachable!() }
    fn child(&mut self, _: u32) -> io::Result<()> { unreachable!() }
    fn submit(&mut self, job: Job) -> io::Result<Work> {
        let work = self.submitted.len() as Work + 1;
        self.submitted.push((work, job));
        Ok(work)
    }
    fn cancel(&mut self, _: Work) -> bool { true }
    fn watch(&mut self, _: &Path, _: bool) -> io::Result<u64> { unreachable!() }
    fn unwatch(&mut self, _: u64) {}
    fn spawn(&mut self, _: Command, _: Option<Grid>) -> io::Result<Spawned> { unreachable!() }
    fn resize(&mut self, _: RawFd, _: Grid) -> io::Result<()> { unreachable!() }
    fn hangup(&mut self, _: RawFd) -> io::Result<()> { unreachable!() }
    fn connect(&mut self, _: &Address) -> io::Result<RawFd> { Err(io::ErrorKind::NotFound.into()) }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> { unreachable!() }
    fn reply(&mut self, _: u64, _: &[u8]) -> io::Result<()> { unreachable!() }
}
struct Quiet;
impl Ui for Quiet {
    fn update(&mut self, _: Update) {}
}

fn arguments(job: &Job) -> Option<Vec<String>> {
    match job {
        Job::Run { command, .. } => Some(
            command.get_args().map(|arg| arg.to_string_lossy().into_owned()).collect(),
        ),
        _ => None,
    }
}

fn exit(tmux: &mut Tmux, io: &mut Jobs, work: Work, status: i32) {
    Multiplexer::event(
        tmux,
        io,
        &mut Quiet,
        Event::Done { work, result: Ok(Output::Exit { status: Some(status), stdout: Vec::new() }) },
    );
}

fn start(key: &str) -> (Tmux, Jobs) {
    let mut tmux = Tmux::new("tmux".into());
    let mut io = Jobs { now: Instant::now(), submitted: Vec::new() };
    Multiplexer::start(&mut tmux, &mut io, key, Box::new(|_, _| {}));
    (tmux, io)
}

#[test]
fn without_a_server_create_starts_a_detached_session_then_opens_it() {
    let (mut tmux, mut io) = start("tmux");
    assert_eq!(
        arguments(&io.submitted[0].1).unwrap(),
        ["-u", "-N", "list-sessions", "-F", "#{session_id}"],
        "asks the running server only (-N never starts one)"
    );
    exit(&mut tmux, &mut io, 1, 1);
    assert_eq!(arguments(&io.submitted[1].1).unwrap(), ["-u", "new-session", "-d"]);
    let Job::Run { command, .. } = &io.submitted[1].1 else { unreachable!() };
    assert!(
        command.get_envs().any(|(name, value)| name == "TMUX" && value.is_none()),
        "never a client of an enclosing tmux"
    );
    exit(&mut tmux, &mut io, 2, 0);
    // Then the ordinary open: no further tmux command starts a server.
    assert!(io.submitted[2..].iter().all(|(_, job)| arguments(job)
        .is_none_or(|args| !args.iter().any(|arg| arg == "new-session"))));
}

#[test]
fn a_running_server_is_only_opened_and_a_socket_key_names_its_server() {
    let (mut tmux, mut io) = start("/tmp/hs/tmux.sock");
    assert_eq!(
        arguments(&io.submitted[0].1).unwrap(),
        ["-u", "-N", "-S", "/tmp/hs/tmux.sock", "list-sessions", "-F", "#{session_id}"]
    );
    exit(&mut tmux, &mut io, 1, 0);
    assert!(io.submitted[1..].iter().all(|(_, job)| arguments(job)
        .is_none_or(|args| !args.iter().any(|arg| arg == "new-session"))));
}

#[test]
fn the_server_probe_asks_the_default_server_without_starting_one() {
    let tmux = Tmux::new("tmux".into());
    let probe = tmux.server_probe().unwrap();
    assert_eq!(probe.get_args().collect::<Vec<_>>(), ["-u", "-N", "list-sessions", "-F", "#{session_id}"]);
    assert!(probe.get_envs().any(|(k, v)| k == "TMUX" && v.is_none()));
    assert!(tmux.running(Some(0), b"$0\n"));
    assert!(!tmux.running(Some(1), b"no server running"));
    assert_eq!(tmux.version().unwrap().get_args().collect::<Vec<_>>(), ["-V"]);
}
