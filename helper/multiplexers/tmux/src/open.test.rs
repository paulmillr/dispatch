//! `%sessions-changed` on a backend opened by its server: sessions made since are attached, once.
use super::*;
use crate::{backend::Backend, endpoint::Endpoint, snapshot::Snapshot};
use std::{
    os::fd::RawFd,
    path::{Path, PathBuf},
    process::Command,
    rc::Rc,
    time::Instant,
};

/// Records submitted jobs and spawned clients; job completions are delivered by the test.
#[derive(Default)]
struct Recorder {
    jobs: Vec<(Work, Vec<String>)>,
    spawned: Vec<Vec<String>>,
}
fn arguments(command: &Command) -> Vec<String> {
    command.get_args().map(|arg| arg.to_string_lossy().into_owned()).collect()
}
#[rustfmt::skip]
impl Io for Recorder {
    fn now(&self) -> Instant { Instant::now() }
    fn timer(&mut self, _: Instant) {}
    fn defer(&mut self, _: Box<dyn FnOnce(&mut dyn Io)>) {}
    fn interest(&mut self, _: RawFd, _: bool, _: bool) -> io::Result<()> { Ok(()) }
    fn read(&mut self, _: RawFd, _: &mut [u8]) -> io::Result<usize> { unreachable!() }
    fn write(&mut self, _: RawFd, _: &[u8]) -> io::Result<usize> { unreachable!() }
    fn close(&mut self, _: RawFd) {}
    fn accept(&mut self, _: RawFd) -> io::Result<RawFd> { unreachable!() }
    fn child(&mut self, _: u32) -> io::Result<()> { unreachable!() }
    fn submit(&mut self, job: Job) -> io::Result<Work> {
        let Job::Run { command, .. } = job else { unreachable!() };
        let work = self.jobs.len() as Work + 1;
        self.jobs.push((work, arguments(&command)));
        Ok(work)
    }
    fn cancel(&mut self, _: Work) -> bool { true }
    fn watch(&mut self, _: &Path, _: bool) -> io::Result<u64> { unreachable!() }
    fn unwatch(&mut self, _: u64) {}
    fn spawn(&mut self, command: Command, _: Option<Grid>) -> io::Result<Spawned> {
        self.spawned.push(arguments(&command));
        Ok(Spawned { pid: 900 + self.spawned.len() as u32, input: None, output: None, stderr: None, tty: None })
    }
    fn resize(&mut self, _: RawFd, _: Grid) -> io::Result<()> { unreachable!() }
    fn hangup(&mut self, _: RawFd) -> io::Result<()> { unreachable!() }
    fn connect(&mut self, _: &Address) -> io::Result<RawFd> { unreachable!() }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> { unreachable!() }
    fn reply(&mut self, _: u64, _: &[u8]) -> io::Result<()> { unreachable!() }
}

fn snapshot(session: u64) -> Snapshot {
    Snapshot {
        windows: Vec::new(),
        panes: Default::default(),
        session,
        client: 0,
        server: 4242,
        socket: "/tmp/fixture/tmux".into(),
        name: String::new(),
    }
}

/// Backend 1, opened by its server's socket: a live client of $1, and an ended one of $2 (detached by the app, or
/// a session killed meanwhile). `claimed`: the live client is a claimed stream instead.
fn opened(remote: bool, claimed: bool) -> Tmux {
    let mut tmux = Tmux::new("tmux".into());
    let mut live = if claimed {
        Client::adopt(Rc::new(|io: &mut dyn Io, _: &[u8], done: Done<()>| done(io, Ok(()))))
    } else {
        Client::default()
    };
    live.session = Some(1);
    live.snapshot = Some(snapshot(1));
    let mut ended = Client::default();
    ended.session = Some(2);
    ended.snapshot = Some(snapshot(2));
    ended.ended = true;
    tmux.backends.insert(1, Backend {
        key: "/tmp/fixture/tmux".into(),
        endpoint: (!remote && !claimed).then(|| Endpoint::fixture("/tmp/fixture/tmux")),
        clients: vec![live, ended],
        ids: Default::default(),
        done: Vec::new(),
        opening: 0,
        views: Default::default(),
        selection: Default::default(),
        remote,
        identity: None,
        pending: Default::default(),
        order: Default::default(),
    });
    tmux
}

fn changed(tmux: &mut Tmux, io: &mut Recorder) {
    tmux.notification(io, Location { backend: 1, client: 0, pane: 0 }, "%sessions-changed");
}

fn listed(tmux: &mut Tmux, io: &mut Recorder, work: Work, stdout: &str) {
    let done = tmux.jobs.remove(&work).unwrap();
    done(tmux, io, Ok(Output::Exit { status: Some(0), stdout: stdout.as_bytes().to_vec() }));
}

#[test]
fn a_session_made_later_is_attached_once_and_known_ones_never_again() {
    let mut tmux = opened(false, false);
    let mut io = Recorder::default();
    changed(&mut tmux, &mut io);
    assert_eq!(io.jobs.len(), 1);
    assert_eq!(io.jobs[0].1, ["-u", "-N", "-S", "/tmp/fixture/tmux", "list-sessions", "-F", "#{session_id}"]);
    // Notifications while the list is read coalesce into one more read.
    changed(&mut tmux, &mut io);
    changed(&mut tmux, &mut io);
    assert_eq!(io.jobs.len(), 1);
    listed(&mut tmux, &mut io, 1, "$1\n$2\n$3\n");
    assert_eq!(
        io.spawned,
        [["-u", "-N", "-S", "/tmp/fixture/tmux", "-C", "attach-session", "-t", "$3"]],
        "$1 is shown, $2 ended or was detached: only the new $3 gets a client"
    );
    assert_eq!(tmux.backends[&1].clients[2].session, Some(3));
    assert!(tmux.changed);
    assert_eq!(io.jobs.len(), 2, "the coalesced notification reads the list again");
    listed(&mut tmux, &mut io, 2, "$1\n$3\n");
    assert_eq!(io.spawned.len(), 1, "a client started for $3 is not started twice, snapshot or not");
    assert_eq!(io.jobs.len(), 2);
}

#[test]
fn a_failed_listing_adds_nothing_and_the_next_notification_reads_again() {
    let mut tmux = opened(false, false);
    let mut io = Recorder::default();
    changed(&mut tmux, &mut io);
    let done = tmux.jobs.remove(&1).unwrap();
    done(&mut tmux, &mut io, Ok(Output::Exit { status: Some(1), stdout: b"no server running".to_vec() }));
    assert!(io.spawned.is_empty());
    changed(&mut tmux, &mut io);
    assert_eq!(io.jobs.len(), 2);
}

#[test]
fn claimed_and_relayed_streams_show_their_own_session_only() {
    for (remote, claimed) in [(true, false), (false, true)] {
        let mut tmux = opened(remote, claimed);
        let mut io = Recorder::default();
        changed(&mut tmux, &mut io);
        assert!(io.jobs.is_empty(), "remote={remote} claimed={claimed}");
    }
}
