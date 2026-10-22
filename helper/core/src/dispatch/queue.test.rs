use super::*;
use std::{collections::BTreeSet, process::Command};

/// One account's files, shared by every helper of a test: checked replaces and removes behave as
/// `Job::Write`/`Job::Remove` do (ESTALE, EEXIST, NotFound), each replace is a new inode.
#[derive(Default)]
struct Disk {
    files: BTreeMap<PathBuf, File>,
    inode: u64,
    clock: i128,
    /// Processes that run, by pid: their start.
    running: BTreeMap<u32, [u64; 2]>,
    /// Pids another account's processes hold now (inspecting them is refused).
    foreign: BTreeSet<u32>,
    /// Every job any helper ran, in order (`name path`).
    log: Vec<String>,
    /// What `attachment.clock` answers (Unix milliseconds).
    wall: i64,
}

#[derive(Clone)]
struct File {
    bytes: Vec<u8>,
    inode: u64,
    stamp: i128,
    mode: u32,
}

impl Disk {
    fn metadata(file: &File) -> Metadata {
        Metadata {
            kind: FileKind::File,
            size: file.bytes.len() as u64,
            device: 1,
            inode: file.inode,
            modified_ns: file.stamp,
            changed_ns: file.stamp,
        }
    }
    fn check(&self, path: &Path, expected: &Expected) -> io::Result<()> {
        let current = self.files.get(path);
        match (expected, current) {
            (Expected::Any, _) => Ok(()),
            (Expected::Absent, None) => Ok(()),
            (Expected::Absent, Some(_)) => Err(io::ErrorKind::AlreadyExists.into()),
            (Expected::Same(guard), Some(file)) if guard.matches(&Self::metadata(file)) => Ok(()),
            (Expected::Same(_), Some(_)) => Err(io::ErrorKind::StaleNetworkFileHandle.into()),
            (Expected::Same(_), None) => Err(io::ErrorKind::NotFound.into()),
        }
    }
    fn run(&mut self, job: Job) -> io::Result<Output> {
        match job {
            Job::MakeDir { path, .. } => {
                self.log.push(format!("mkdir {}", path.display()));
                Ok(Output::Written)
            }
            Job::Process { pid } => {
                self.log.push(format!("process {pid}"));
                if self.foreign.contains(&pid) {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
                let start = *self.running.get(&pid).ok_or(io::ErrorKind::NotFound)?;
                Ok(Output::Process(Process {
                    pid,
                    parent: 1,
                    group: pid as i32,
                    foreground: 0,
                    tty: 0,
                    start,
                    executable: "/bin/helper".into(),
                    arguments: Vec::new(),
                    files: Vec::new(),
                }))
            }
            Job::Native { name: "attachment.clock", .. } => {
                self.log.push("clock".into());
                Ok(Output::Value(wire::body::encode_plain(&Data::Object(vec![("ms", Data::Signed(self.wall))])).unwrap()))
            }
            Job::Native { name: "file.private", value } => {
                let value = wire::body::decode_plain(&value).unwrap();
                let path = value.get("path").and_then(Data::path).unwrap().to_owned();
                self.log.push(format!("read {}", path.display()));
                let file = self.files.get(&path).ok_or(io::ErrorKind::NotFound)?;
                let uid = crate::system::System::account().unwrap().0;
                let metadata = |file: &File| {
                    Data::Object(vec![
                        ("uid", Data::Unsigned(uid.into())),
                        ("mode", Data::Unsigned(file.mode.into())),
                        ("links", Data::Unsigned(1)),
                        ("kind", Data::String("file")),
                        ("size", Data::Unsigned(file.bytes.len() as u64)),
                        ("device", Data::Unsigned(1)),
                        ("inode", Data::Unsigned(file.inode)),
                        ("mtime_ns", Data::Signed(file.stamp as i64)),
                        ("ctime_ns", Data::Signed(file.stamp as i64)),
                    ])
                };
                let bytes = wire::body::encode_plain(&Data::Object(vec![
                    ("before", metadata(file)),
                    ("after", metadata(file)),
                    ("data", Data::Bytes(&file.bytes)),
                ]))
                .unwrap();
                Ok(Output::Value(bytes))
            }
            Job::Write { path, bytes, mode, expected, .. } => {
                self.log.push(format!("write {}", path.display()));
                self.check(&path, &expected)?;
                self.inode += 1;
                self.clock += 1;
                let file = File { bytes, inode: self.inode, stamp: self.clock, mode };
                self.files.insert(path, file);
                Ok(Output::Written)
            }
            Job::Remove { path, expected } => {
                self.log.push(format!("remove {}", path.display()));
                self.check(&path, &expected)?;
                self.files.remove(&path).ok_or(io::ErrorKind::NotFound)?;
                Ok(Output::Written)
            }
            _ => unreachable!(),
        }
    }
}

type Callback = Box<dyn FnOnce(&mut dyn Io, io::Result<Output>)>;

/// One helper's Io: jobs wait until the test runs them, so tests choose the interleaving.
struct Fake {
    disk: Rc<RefCell<Disk>>,
    pid: u32,
    next: Work,
    jobs: BTreeMap<Work, Job>,
    callbacks: BTreeMap<Work, Callback>,
    deferred: VecDeque<Box<dyn FnOnce(&mut dyn Io)>>,
    section: String,
    sections: Vec<String>,
    watches: u64,
}

impl Fake {
    fn new(disk: &Rc<RefCell<Disk>>, pid: u32) -> Self {
        disk.borrow_mut().running.insert(pid, [u64::from(pid), 0]);
        Self {
            disk: disk.clone(),
            pid,
            next: 0,
            jobs: BTreeMap::new(),
            callbacks: BTreeMap::new(),
            deferred: VecDeque::new(),
            section: "ui".into(),
            sections: Vec::new(),
            watches: 0,
        }
    }
    /// Run the oldest job (and the callbacks it defers); false when nothing waits.
    fn step(&mut self) -> bool {
        if let Some(work) = self.deferred.pop_front() {
            work(self);
            return true;
        }
        let Some(work) = self.jobs.keys().next().copied() else { return false };
        let job = self.jobs.remove(&work).unwrap();
        let result = self.disk.borrow_mut().run(job);
        let callback = self.callbacks.remove(&work).expect("a job with a callback");
        callback(self, result);
        true
    }
    fn settle(&mut self) {
        while self.step() {}
    }
}

#[rustfmt::skip]
impl Io for Fake {
    fn now(&self) -> Instant { Instant::now() }
    fn timer(&mut self, _: Instant) {}
    fn after(&mut self, _: Instant, _: Box<dyn FnOnce(&mut dyn Io)>) -> io::Result<()> { Ok(()) }
    fn pid(&self) -> u32 { self.pid }
    fn random(&mut self, bytes: &mut [u8]) -> io::Result<()> {
        self.next += 1;
        for (index, byte) in bytes.iter_mut().enumerate() { *byte = (self.pid as u8) ^ (self.next as u8).wrapping_add(index as u8); }
        Ok(())
    }
    fn section(&mut self, name: &str) -> String { std::mem::replace(&mut self.section, name.into()) }
    fn defer(&mut self, work: Box<dyn FnOnce(&mut dyn Io)>) { self.deferred.push_back(work); }
    fn submit(&mut self, job: Job) -> io::Result<Work> {
        self.next += 1;
        self.sections.push(self.section.clone());
        self.jobs.insert(self.next, job);
        Ok(self.next)
    }
    fn then(&mut self, work: Work, callback: Callback) { self.callbacks.insert(work, callback); }
    fn storage(&mut self) -> io::Result<PathBuf> { Ok("/home/sam/.dispatch/state".into()) }
    fn watch(&mut self, _: &Path, _: bool) -> io::Result<u64> { self.watches += 1; Ok(self.watches) }
    fn unwatch(&mut self, _: u64) {}
    fn interest(&mut self, _: RawFd, _: bool, _: bool) -> io::Result<()> { unreachable!() }
    fn read(&mut self, _: RawFd, _: &mut [u8]) -> io::Result<usize> { unreachable!() }
    fn write(&mut self, _: RawFd, _: &[u8]) -> io::Result<usize> { unreachable!() }
    fn close(&mut self, _: RawFd) { unreachable!() }
    fn accept(&mut self, _: RawFd) -> io::Result<RawFd> { unreachable!() }
    fn child(&mut self, _: u32) -> io::Result<()> { unreachable!() }
    fn cancel(&mut self, _: Work) -> bool { unreachable!() }
    fn spawn(&mut self, _: Command, _: Option<Grid>) -> io::Result<Spawned> { unreachable!() }
    fn resize(&mut self, _: RawFd, _: Grid) -> io::Result<()> { unreachable!() }
    fn hangup(&mut self, _: RawFd) -> io::Result<()> { unreachable!() }
    fn connect(&mut self, _: &Address) -> io::Result<RawFd> { unreachable!() }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> { unreachable!() }
    fn reply(&mut self, _: u64, _: &[u8]) -> io::Result<()> { unreachable!() }
}

const KEY: (Id, &str) = (7, "s-1");

fn key() -> (Id, String) {
    (KEY.0, KEY.1.into())
}

fn binding() -> Binding {
    Binding {
        session: KEY.1.into(),
        transcript: None,
        process: Process {
            pid: 42,
            parent: 1,
            group: 42,
            foreground: 42,
            tty: 0,
            start: [5, 6],
            executable: "/bin/agent".into(),
            arguments: Vec::new(),
            files: Vec::new(),
        },
    }
}

/// A helper's held queues with the test conversation's line pointed at its file (or memory).
fn helper(io: &mut Fake, stored: bool) -> Held {
    let held = Held::new(Rc::new(RefCell::new(VecDeque::new())));
    let path = stored.then(|| store::path(&io.storage().unwrap(), "claude", KEY.1));
    held.queues.borrow_mut().lines.insert(
        key(),
        Line {
            target: Some(Target { harness: "claude".into(), mux: "tmux".into(), terminal: "tmux:s:$1:%3".into(), path }),
            binding: Some(binding()),
            ..Default::default()
        },
    );
    held
}

type Answers = Rc<RefCell<Vec<Result<Answer, Error>>>>;

fn submit(io: &mut Fake, held: &Held, op: Op) -> Answers {
    let answers: Answers = Default::default();
    let sink = answers.clone();
    change(io, held, &key(), op, Some(Box::new(move |_, answer| sink.borrow_mut().push(answer))));
    answers
}

fn add(id: &str, text: &str) -> Op {
    Op::Add { id: id.into(), text: text.into(), mode: Mode::Prompt, command: false, binding: Bound::of(&binding()), attachments: Vec::new() }
}

fn items(held: &Held) -> Vec<String> {
    held.borrow().get(&key()).unwrap().snapshot().into_iter().map(|item| item.id).collect()
}

fn published(held: &Held) -> usize {
    held.updates.borrow().iter().filter(|update| matches!(update, Update::Queue { .. })).count()
}

fn stored(disk: &Rc<RefCell<Disk>>) -> Option<Record> {
    let disk = disk.borrow();
    let file = disk.files.values().next()?;
    Some(Record::decode(&file.bytes).unwrap())
}

#[test]
fn an_add_is_answered_once_the_file_holds_it() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let mut io = Fake::new(&disk, 100);
    let held = helper(&mut io, true);
    let answers = submit(&mut io, &held, add("q-1", "hello"));
    // Prepared once: the directory, this run's identity, the watch; then read and write.
    while answers.borrow().is_empty() {
        assert!(stored(&disk).is_none(), "answered before the write");
        assert!(io.step());
    }
    assert!(matches!(&answers.borrow()[0], Ok(Answer::Added(item)) if item.id == "q-1"));
    let record = stored(&disk).unwrap();
    assert_eq!((record.harness.as_str(), record.session.as_str(), record.items.len()), ("claude", "s-1", 1));
    assert_eq!(disk.borrow().files.values().next().unwrap().mode, 0o600);
    assert_eq!(published(&held), 1);
    // Every store job ran in the store's own section.
    assert!(io.sections.iter().all(|section| section == STORE));
    assert_eq!(
        disk.borrow().log.iter().map(|line| line.split(' ').next().unwrap()).collect::<Vec<_>>(),
        ["mkdir", "process", "read", "write"]
    );
}

#[test]
fn another_helper_sees_what_one_accepted() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let (mut one, mut two) = (Fake::new(&disk, 100), Fake::new(&disk, 200));
    let (first, second) = (helper(&mut one, true), helper(&mut two, true));
    submit(&mut one, &first, add("q-1", "hello"));
    one.settle();
    let listed = submit(&mut two, &second, Op::Read);
    two.settle();
    assert!(listed.borrow()[0].is_ok());
    assert_eq!(items(&second), ["q-1"]);
    // A refresh that changed the snapshot is announced to the second helper's clients.
    assert_eq!(published(&second), 1);
}

#[test]
fn concurrent_adds_from_two_helpers_both_land() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let (mut one, mut two) = (Fake::new(&disk, 100), Fake::new(&disk, 200));
    let (first, second) = (helper(&mut one, true), helper(&mut two, true));
    let a = submit(&mut one, &first, add("q-a", "from one"));
    let b = submit(&mut two, &second, add("q-b", "from two"));
    // Interleave job by job: both read an absent file, one creates it, the other's create fails
    // and is applied again to what the first wrote.
    while one.step() | two.step() {}
    assert!(a.borrow()[0].is_ok() && b.borrow()[0].is_ok());
    let record = stored(&disk).unwrap();
    let mut ids: Vec<_> = record.items.iter().map(|item| item.id.clone()).collect();
    ids.sort();
    assert_eq!(ids, ["q-a", "q-b"]);
    assert_eq!(record.serial, 2);
    // The second create lost (EEXIST) and was written again on a fresh read.
    let log = disk.borrow().log.clone();
    let kinds: Vec<_> = log.iter().map(|line| line.split(' ').next().unwrap()).filter(|kind| ["read", "write"].contains(kind)).collect();
    assert_eq!(kinds, ["read", "read", "write", "write", "read", "write"]);
}

#[test]
fn only_one_of_two_racing_helpers_claims_the_head() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let (mut one, mut two) = (Fake::new(&disk, 100), Fake::new(&disk, 200));
    let (first, second) = (helper(&mut one, true), helper(&mut two, true));
    submit(&mut one, &first, add("q-1", "hello"));
    one.settle();
    // Both prepared, so their claims carry their identities.
    submit(&mut two, &second, Op::Read);
    two.settle();
    let me = |held: &Held| held.borrow().owner.unwrap();
    let a = submit(&mut one, &first, Op::Claim { id: "q-1".into(), owner: me(&first), binding: Bound::of(&binding()) });
    let b = submit(&mut two, &second, Op::Claim { id: "q-1".into(), owner: me(&second), binding: Bound::of(&binding()) });
    while one.step() | two.step() {}
    let wins = [&a, &b].iter().filter(|answers| matches!(answers.borrow()[0], Ok(Answer::Claimed(_)))).count();
    assert_eq!(wins, 1);
    let claim = stored(&disk).unwrap().items[0].claim.unwrap();
    assert!(claim == me(&first) || claim == me(&second));
}

#[test]
fn a_send_result_and_its_acknowledgement() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let mut io = Fake::new(&disk, 100);
    let held = helper(&mut io, true);
    submit(&mut io, &held, add("q-1", "one"));
    submit(&mut io, &held, add("q-2", "two"));
    io.settle();
    let me = held.borrow().owner.unwrap();
    submit(&mut io, &held, Op::Claim { id: "q-1".into(), owner: me, binding: Bound::of(&binding()) });
    submit(&mut io, &held, Op::Finish { id: "q-1".into(), owner: me, outcome: Outcome::Written });
    io.settle();
    let record = stored(&disk).unwrap();
    let sent = Awaiting { owner: me, item: "q-1".into() };
    assert_eq!((record.items.len(), record.awaiting.clone()), (1, Some(sent.clone())));
    submit(&mut io, &held, Op::Acknowledge(sent));
    io.settle();
    assert_eq!(stored(&disk).unwrap().awaiting, None);
}

#[test]
fn the_last_item_takes_its_file_with_it() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let mut io = Fake::new(&disk, 100);
    let held = helper(&mut io, true);
    submit(&mut io, &held, add("q-1", "one"));
    io.settle();
    let removed = submit(&mut io, &held, Op::Remove { id: "q-1".into(), revision: 1 });
    io.settle();
    assert!(removed.borrow()[0].is_ok());
    assert!(disk.borrow().files.is_empty());
    assert!(items(&held).is_empty());
}

#[test]
fn a_refused_change_writes_nothing_and_answers_why() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let mut io = Fake::new(&disk, 100);
    let held = helper(&mut io, true);
    submit(&mut io, &held, add("q-1", "one"));
    io.settle();
    let writes = disk.borrow().log.len();
    let stale = submit(&mut io, &held, Op::Remove { id: "q-1".into(), revision: 99 });
    io.settle();
    assert_eq!(stale.borrow()[0].as_ref().unwrap_err().code, "expired");
    assert!(!disk.borrow().log[writes..].iter().any(|line| line.starts_with("write")));
}

#[test]
fn a_file_that_is_not_private_is_refused() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let mut io = Fake::new(&disk, 100);
    let held = helper(&mut io, true);
    submit(&mut io, &held, add("q-1", "one"));
    io.settle();
    disk.borrow_mut().files.values_mut().next().unwrap().mode = 0o644;
    let read = submit(&mut io, &held, Op::Read);
    io.settle();
    assert_eq!(read.borrow()[0].as_ref().unwrap_err().code, "storage");
}

#[test]
fn a_store_that_keeps_changing_gives_up() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let mut io = Fake::new(&disk, 100);
    let held = helper(&mut io, true);
    submit(&mut io, &held, add("q-1", "one"));
    io.settle();
    let answers = submit(&mut io, &held, add("q-2", "two"));
    let path = disk.borrow().files.keys().next().unwrap().clone();
    // Another writer replaces the file between every read and write.
    while answers.borrow().is_empty() {
        let read = disk.borrow().log.last().is_some_and(|line| line.starts_with("read"));
        if read {
            let mut disk = disk.borrow_mut();
            disk.inode += 1;
            disk.clock += 1;
            let (inode, stamp) = (disk.inode, disk.clock);
            let file = disk.files.get_mut(&path).unwrap();
            (file.inode, file.stamp) = (inode, stamp);
        }
        assert!(io.step());
    }
    assert_eq!(answers.borrow()[0].as_ref().unwrap_err().code, "storage");
    let writes = disk.borrow().log.iter().filter(|line| line.starts_with("write")).count();
    assert_eq!(writes, 1 + usize::from(ATTEMPTS));
}

#[test]
fn a_gone_helpers_claim_becomes_uncertain_and_its_late_result_is_ignored() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let (mut one, mut two) = (Fake::new(&disk, 100), Fake::new(&disk, 200));
    let (first, second) = (helper(&mut one, true), helper(&mut two, true));
    submit(&mut one, &first, add("q-1", "one"));
    one.settle();
    let gone = first.borrow().owner.unwrap();
    submit(&mut one, &first, Op::Claim { id: "q-1".into(), owner: gone, binding: Bound::of(&binding()) });
    one.settle();
    // The first helper's process ends; the second asks and releases it.
    disk.borrow_mut().running.remove(&100);
    submit(&mut two, &second, Op::Read);
    two.settle();
    probe(&mut two, &second, &key(), vec![gone]);
    two.settle();
    let record = stored(&disk).unwrap();
    assert_eq!((record.items[0].pause, record.items[0].claim), (Some(Pause::Uncertain), None));
    // A process with the same pid but another start is someone else: still gone.
    disk.borrow_mut().running.insert(100, [1, 1]);
    assert_eq!(stored(&disk).unwrap().items[0].pause, Some(Pause::Uncertain));
}

#[test]
fn a_running_helpers_marks_are_kept() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let (mut one, mut two) = (Fake::new(&disk, 100), Fake::new(&disk, 200));
    let (first, second) = (helper(&mut one, true), helper(&mut two, true));
    submit(&mut one, &first, add("q-1", "one"));
    one.settle();
    let alive = first.borrow().owner.unwrap();
    submit(&mut one, &first, Op::Claim { id: "q-1".into(), owner: alive, binding: Bound::of(&binding()) });
    one.settle();
    submit(&mut two, &second, Op::Read);
    two.settle();
    probe(&mut two, &second, &key(), vec![alive]);
    two.settle();
    assert_eq!(stored(&disk).unwrap().items[0].claim, Some(alive));
}

#[test]
fn a_provisional_conversation_stays_in_memory() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let mut io = Fake::new(&disk, 100);
    let held = helper(&mut io, false);
    let answers = submit(&mut io, &held, add("q-1", "hello"));
    assert!(matches!(&answers.borrow()[0], Ok(Answer::Added(_))));
    assert!(disk.borrow().log.is_empty());
    assert_eq!(items(&held), ["q-1"]);
    let removed = submit(&mut io, &held, Op::Remove { id: "q-1".into(), revision: 1 });
    assert!(removed.borrow()[0].is_ok());
    assert!(items(&held).is_empty());
}

#[test]
fn operations_of_one_line_run_in_order() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let mut io = Fake::new(&disk, 100);
    let held = helper(&mut io, true);
    let order: Rc<RefCell<Vec<&str>>> = Default::default();
    for (name, op) in [("a", add("q-1", "one")), ("b", add("q-2", "two")), ("c", Op::Hold { held: true, owner: MEMORY })] {
        let order = order.clone();
        change(&mut io, &held, &key(), op, Some(Box::new(move |_, _| order.borrow_mut().push(name))));
    }
    io.settle();
    assert_eq!(*order.borrow(), ["a", "b", "c"]);
    let record = stored(&disk).unwrap();
    assert_eq!(record.hold, held.borrow().owner);
    assert_eq!(record.items.len(), 2);
}

#[test]
fn a_change_in_the_store_is_read_again_once() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let mut io = Fake::new(&disk, 100);
    let held = helper(&mut io, true);
    submit(&mut io, &held, add("q-1", "one"));
    io.settle();
    let watch = held.borrow().watch.unwrap();
    let before = disk.borrow().log.len();
    for _ in 0..3 {
        assert!(changed(&mut io, &held, &Event::Changed { watch, reset: false }));
    }
    io.settle();
    let reads = disk.borrow().log[before..].iter().filter(|line| line.starts_with("read")).count();
    assert_eq!(reads, 1);
    // Another watch is not the store's.
    assert!(!changed(&mut io, &held, &Event::Changed { watch: watch + 1, reset: false }));
}

#[test]
fn a_leaving_client_ends_its_edits() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let mut io = Fake::new(&disk, 100);
    let held = helper(&mut io, true);
    submit(&mut io, &held, add("q-1", "one"));
    io.settle();
    let me = held.borrow().owner.unwrap();
    held.line(&key(), |line| line.edits.insert("q-1".into(), 9));
    submit(&mut io, &held, Op::Edit { id: "q-1".into(), revision: 1, editing: true, owner: me });
    io.settle();
    assert!(stored(&disk).unwrap().items[0].editing.is_some());
    left(&mut io, &held, 8);
    io.settle();
    assert!(stored(&disk).unwrap().items[0].editing.is_some());
    left(&mut io, &held, 9);
    io.settle();
    assert!(stored(&disk).unwrap().items[0].editing.is_none());
}

#[test]
fn revocation_stops_the_line_here_and_in_the_store() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let mut io = Fake::new(&disk, 100);
    let held = helper(&mut io, true);
    submit(&mut io, &held, add("q-1", "one"));
    io.settle();
    revoke(&mut io, &held, &BTreeSet::from([KEY.0]));
    assert!(held.borrow().get(&key()).unwrap().revoked);
    io.settle();
    let record = stored(&disk).unwrap();
    assert!(record.hold.is_none());
    assert_eq!(record.items[0].pause, Some(Pause::Stopped));
}

#[test]
fn another_helpers_claim_makes_this_helpers_direct_sends_wait() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let (mut one, mut two) = (Fake::new(&disk, 100), Fake::new(&disk, 200));
    let (first, second) = (helper(&mut one, true), helper(&mut two, true));
    submit(&mut one, &first, add("q-1", "one"));
    one.settle();
    submit(&mut two, &second, Op::Read);
    two.settle();
    assert!(!claimed_elsewhere(&second, &key()));
    let owner = first.borrow().owner.unwrap();
    submit(&mut one, &first, Op::Claim { id: "q-1".into(), owner, binding: Bound::of(&binding()) });
    one.settle();
    submit(&mut two, &second, Op::Read);
    two.settle();
    assert!(claimed_elsewhere(&second, &key()));
    // Its own claim is not someone else's.
    assert!(!claimed_elsewhere(&first, &key()));
}

#[test]
fn a_holding_client_that_leaves_releases_the_hold() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let mut io = Fake::new(&disk, 100);
    let held = helper(&mut io, true);
    submit(&mut io, &held, add("q-1", "one"));
    held.line(&key(), |line| line.holder = Some(9));
    submit(&mut io, &held, Op::Hold { held: true, owner: MEMORY });
    io.settle();
    // The mark made before the store was ready carries this run's identity.
    assert_eq!(stored(&disk).unwrap().hold, held.borrow().owner);
    left(&mut io, &held, 9);
    io.settle();
    assert_eq!(stored(&disk).unwrap().hold, None);
}

#[test]
fn a_pid_another_account_reused_is_not_the_marks_helper() {
    let disk = Rc::new(RefCell::new(Disk::default()));
    let (mut one, mut two) = (Fake::new(&disk, 100), Fake::new(&disk, 200));
    let (first, second) = (helper(&mut one, true), helper(&mut two, true));
    submit(&mut one, &first, add("q-1", "one"));
    one.settle();
    let gone = first.borrow().owner.unwrap();
    submit(&mut one, &first, Op::Claim { id: "q-1".into(), owner: gone, binding: Bound::of(&binding()) });
    one.settle();
    disk.borrow_mut().running.remove(&100);
    disk.borrow_mut().foreign.insert(100);
    submit(&mut two, &second, Op::Read);
    two.settle();
    probe(&mut two, &second, &key(), vec![gone]);
    two.settle();
    assert_eq!(stored(&disk).unwrap().items[0].pause, Some(Pause::Uncertain));
}

mod attachments {
    use super::*;
    use crate::api::Record;
    use crate::dispatch::attachments::{fill, named_page, remembering, view};

    const ROOT: &str = "/home/sam/.dispatch/attachments";

    fn path(name: &str) -> String {
        format!("{ROOT}/0123456789abcdef0123456789abcdef/{name}")
    }
    fn image(name: &str) -> Attachment {
        Attachment { path: path(name), image: true }
    }
    /// A Claude user record as its harness makes it: the text every client gets (an `[Image]`
    /// line per image) and, on the side, the message text and its images.
    fn user(text: &str, images: usize, time: i64) -> Record {
        let shown = std::iter::once(text.to_owned()).chain(std::iter::repeat_n("[Image]".to_owned(), images)).collect::<Vec<_>>();
        let shown = shown.join("\n");
        Record {
            id: format!("user-{time}"),
            kind: RecordKind::User,
            attached: attachment::attached(&shown, Some(text.into()), vec![None; images]),
            text: shown,
            time_ms: Some(time),
            ..Record::default()
        }
    }
    /// As a chat.attachments client sees records from memory (an update).
    fn shown(held: &Held, mut records: Vec<Record>) -> Vec<Record> {
        view(Some(Path::new(ROOT)), &mut records);
        fill(held, KEY.1, &mut records);
        records
    }
    fn unnamed() -> Block {
        attachment::block(None, None, true)
    }
    fn named(name: &str) -> Block {
        attachment::block(Some(&path(name)), Some(name), true)
    }
    /// A send with these attachments ends with `result` (at the wall time `at`).
    fn send(io: &mut Fake, held: &Held, text: &str, attachments: &[Attachment], result: Result<Sent, Error>, at: i64) {
        io.disk.borrow_mut().wall = at;
        let then = remembering(io, held, "claude", KEY.1, text, attachments).expect("remembered for claude");
        let done = then(Box::new(|_, _| {}));
        done(io, result);
        io.settle();
    }
    fn written() -> Result<Sent, Error> {
        Ok(Sent::Native { written: true, may_have_sent: true, reason: None })
    }
    fn page(io: &mut Fake, held: &Held, enabled: bool, records: Vec<Record>) -> Rc<RefCell<Option<Page>>> {
        let answer = Rc::new(RefCell::new(None));
        let sink = answer.clone();
        let done = named_page(held, enabled, "claude", KEY.1, Box::new(move |_, page| *sink.borrow_mut() = page.ok()));
        done(io, Ok(Page { records, earlier: None }));
        answer
    }

    #[test]
    fn delivered_images_name_the_blocks_of_their_message() {
        let disk = Rc::new(RefCell::new(Disk::default()));
        let mut io = Fake::new(&disk, 100);
        let held = helper(&mut io, true);
        let attachments = [image("a.png"), Attachment { path: path("notes.txt"), image: false }, image("b.png")];
        send(&mut io, &held, " Describe these ", &attachments, written(), 10_000);
        let records = shown(&held, vec![user(&format!("[Image #1] [Image #2]Describe these\n\n{}", path("notes.txt")), 2, 11_000)]);
        assert_eq!(records[0].text, "Describe these");
        assert_eq!(records[0].blocks, [named("a.png"), named("b.png"), attachment::block(Some(&path("notes.txt")), Some("notes.txt"), false)]);
        let file = store::path(&io.storage().unwrap(), "claude", KEY.1).with_extension("idx");
        let file = file.parent().unwrap().parent().unwrap().join("attachments").join(file.file_name().unwrap());
        assert_eq!(disk.borrow().files.get(&file).map(|file| file.mode), Some(0o600), "{:?}", disk.borrow().log);
        assert!(io.sections.iter().all(|section| section == "attachments.index"));

        // Another helper (a reconnect) reads the file once, for a client of chat.attachments.
        let mut other = Fake::new(&disk, 200);
        let fresh = helper(&mut other, true);
        let answer = page(&mut other, &fresh, true, vec![user("Describe these", 2, 11_000)]);
        assert!(answer.borrow().is_none(), "waits for the index");
        other.settle();
        assert_eq!(answer.borrow().as_ref().unwrap().records[0].blocks, [named("a.png"), named("b.png")]);
        let reads = disk.borrow().log.iter().filter(|line| line.ends_with(".idx") && line.starts_with("read")).count();
        page(&mut other, &fresh, true, vec![user("Describe these", 2, 11_000)]);
        other.settle();
        assert_eq!(disk.borrow().log.iter().filter(|line| line.ends_with(".idx") && line.starts_with("read")).count(), reads);
    }

    #[test]
    fn other_clients_get_the_records_as_before_and_cause_no_job() {
        let disk = Rc::new(RefCell::new(Disk::default()));
        let mut io = Fake::new(&disk, 100);
        let held = helper(&mut io, true);
        let records = vec![user("x", 1, 1), user("plain", 0, 2)];
        let answer = page(&mut io, &held, false, records.clone());
        assert_eq!(answer.borrow().as_ref().unwrap().records, records);
        assert_eq!(answer.borrow().as_ref().unwrap().records[0].text, "x\n[Image]");
        // A client of the feature with nothing to name reads no index either.
        let answer = page(&mut io, &held, true, vec![user("plain", 0, 2)]);
        assert_eq!(answer.borrow().as_ref().unwrap().records[0].text, "plain");
        assert!(!io.step(), "no job: {:?}", disk.borrow().log);
    }

    #[test]
    fn only_a_send_that_may_have_reached_the_agent_is_remembered() {
        let disk = Rc::new(RefCell::new(Disk::default()));
        let mut io = Fake::new(&disk, 100);
        let held = helper(&mut io, false);
        let refused = Error { code: "input", message: String::new() };
        send(&mut io, &held, "", &[image("refused.png")], Err(refused), 1_000);
        send(&mut io, &held, "", &[image("unwritten.png")], Ok(Sent::Native { written: false, may_have_sent: false, reason: None }), 1_000);
        assert_eq!(shown(&held, vec![user("", 1, 1_000)])[0].blocks, [unnamed()]);
        let uncertain = Error { code: "uncertain", message: String::new() };
        send(&mut io, &held, "", &[image("typed.png")], Err(uncertain), 1_000);
        assert_eq!(shown(&held, vec![user("", 1, 1_000)])[0].blocks, [named("typed.png")]);
        // Nothing to remember: no image, no session, or a harness whose history names them.
        assert!(remembering(&mut io, &held, "claude", KEY.1, "x", &[Attachment { path: path("a.txt"), image: false }]).is_none());
        assert!(remembering(&mut io, &held, "claude", "", "x", &[image("a.png")]).is_none());
        assert!(remembering(&mut io, &held, "codex", KEY.1, "x", &[image("a.png")]).is_none());
        assert!(!io.step(), "nothing asked: {:?}", disk.borrow().log);
    }

    #[test]
    fn records_of_the_same_text_get_the_send_they_followed() {
        let disk = Rc::new(RefCell::new(Disk::default()));
        let mut io = Fake::new(&disk, 100);
        let held = helper(&mut io, false);
        // Three images sent alone (no text), a minute apart; Claude wrote each record a second
        // after its send started.
        for (name, at) in [("first.png", 60_000), ("second.png", 120_000), ("third.png", 180_000)] {
            send(&mut io, &held, "", &[image(name)], written(), at);
        }
        // Newest first, in two pages, and live: each record gets its own image.
        let newest = shown(&held, vec![user("", 1, 181_000), user("", 1, 121_000)]);
        assert_eq!((newest[0].blocks.clone(), newest[1].blocks.clone()), (vec![named("third.png")], vec![named("second.png")]));
        assert_eq!(shown(&held, vec![user("", 1, 61_000)])[0].blocks, [named("first.png")]);
        // A record before every send, or long after (an image pasted in Terminal), is not named.
        assert_eq!(shown(&held, vec![user("", 1, 1_000)])[0].blocks, [unnamed()]);
        assert_eq!(shown(&held, vec![user("", 1, 10_000_000)])[0].blocks, [unnamed()]);
    }

    #[test]
    fn a_live_record_is_named_while_its_send_runs_and_a_refused_send_is_forgotten() {
        let disk = Rc::new(RefCell::new(Disk::default()));
        let mut io = Fake::new(&disk, 100);
        let held = helper(&mut io, true);
        disk.borrow_mut().wall = 5_000;
        let then = remembering(&mut io, &held, "claude", KEY.1, "Look", &[image("a.png")]).unwrap();
        let done = then(Box::new(|_, _| {}));
        // Claude wrote the record before the walk ended; even before the clock answered.
        assert_eq!(shown(&held, vec![user("Look", 1, 5_100)])[0].blocks, [named("a.png")]);
        io.settle();
        assert_eq!(shown(&held, vec![user("Look", 1, 5_100)])[0].blocks, [named("a.png")]);
        assert!(!disk.borrow().log.iter().any(|line| line.starts_with("write")), "written only once delivered");
        done(&mut io, Err(Error { code: "input", message: String::new() }));
        io.settle();
        assert_eq!(shown(&held, vec![user("Look", 1, 5_100)])[0].blocks, [unnamed()]);
        assert!(!disk.borrow().log.iter().any(|line| line.starts_with("write")), "{:?}", disk.borrow().log);
    }

    #[test]
    fn only_a_client_of_the_feature_may_name_attachments() {
        use crate::dispatch::attachments::named;
        let list = |paths: Vec<Data<'static>>| Data::Object(vec![("text", Data::String("x")), ("attachments", Data::Array(paths))]);
        let plain = Data::Object(vec![("text", Data::String("x"))]);
        for method in ["chat.send", "queue.add"] {
            // Without the field: as before, for every client.
            assert_eq!(named(method, &plain, false), Ok(false));
            assert_eq!(named(method, &plain, true), Ok(false));
            // The field at all, from a client that did not name chat.attachments: refused.
            assert_eq!(named(method, &list(Vec::new()), false).unwrap_err().code, "invalid_input");
            assert_eq!(named(method, &list(vec![Data::String("/a")]), false).unwrap_err().code, "invalid_input");
            assert_eq!(named(method, &list(Vec::new()), true), Ok(false));
            assert_eq!(named(method, &list(vec![Data::String("/a")]), true), Ok(true));
        }
        assert_eq!(named("chat.command", &list(vec![Data::String("/a")]), false), Ok(false));
    }

    #[test]
    fn blocks_are_named_only_when_the_text_and_the_counts_agree() {
        let disk = Rc::new(RefCell::new(Disk::default()));
        let mut io = Fake::new(&disk, 100);
        let held = helper(&mut io, false);
        send(&mut io, &held, "two", &[image("a.png"), image("b.png")], written(), 1_000);
        send(&mut io, &held, "one", &[image("one.png")], written(), 1_000);
        let mut half = user(&format!("{} [Image #1] two", path("b.png")), 1, 1_000);
        half.id = "half".into();
        let records = shown(&held, vec![user("two", 1, 1_000), user("other text", 1, 1_000), user("one", 1, 1_000), half]);
        assert_eq!(records[0].blocks, [unnamed()], "count differs");
        assert_eq!(records[1].blocks, [unnamed()], "text differs");
        assert_eq!(records[2].blocks, [named("one.png")]);
        // One of the two stayed in Claude's composer as its path: the other is named.
        assert_eq!((records[3].text.as_str(), records[3].blocks.clone()), ("two", vec![named("a.png"), named("b.png")]));
        // Another conversation's records are left alone.
        let mut elsewhere = vec![user("one", 1, 1_000)];
        view(None, &mut elsewhere);
        fill(&held, "s-2", &mut elsewhere);
        assert_eq!(elsewhere[0].blocks, [unnamed()]);
    }
}
