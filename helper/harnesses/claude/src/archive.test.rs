//! Live transcript reads against a real file, with jobs and watch events run in the order a test
//! chooses: what a watching chat is given when a read races Claude's writes, when a chat reopens,
//! and when the file is replaced.
use crate::Claude;
use dispatch_helper_core::api::*;
use std::{
    cell::RefCell,
    collections::VecDeque,
    io,
    io::Write,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    rc::Rc,
    time::Instant,
};

#[derive(Default)]
struct Fake {
    next: u64,
    jobs: VecDeque<(Work, Job)>,
    deferred: VecDeque<Box<dyn FnOnce(&mut dyn Io)>>,
    watches: Vec<u64>,
}
fn unsupported<T>() -> io::Result<T> {
    Err(io::ErrorKind::Unsupported.into())
}
impl Io for Fake {
    fn defer(&mut self, callback: Box<dyn FnOnce(&mut dyn Io)>) {
        self.deferred.push_back(callback)
    }
    fn interest(&mut self, _: i32, _: bool, _: bool) -> io::Result<()> {
        Ok(())
    }
    fn read(&mut self, _: i32, _: &mut [u8]) -> io::Result<usize> {
        unsupported()
    }
    fn write(&mut self, _: i32, _: &[u8]) -> io::Result<usize> {
        unsupported()
    }
    fn close(&mut self, _: i32) {}
    fn accept(&mut self, _: i32) -> io::Result<i32> {
        unsupported()
    }
    fn child(&mut self, _: u32) -> io::Result<()> {
        Ok(())
    }
    fn timer(&mut self, _: Instant) {}
    fn now(&self) -> Instant {
        Instant::now()
    }
    fn random(&mut self, bytes: &mut [u8]) -> io::Result<()> {
        bytes.iter_mut().enumerate().for_each(|(i, b)| *b = i as u8 ^ 0x5a);
        Ok(())
    }
    fn submit(&mut self, job: Job) -> io::Result<Work> {
        self.next += 1;
        self.jobs.push_back((self.next, job));
        Ok(self.next)
    }
    fn cancel(&mut self, work: Work) -> bool {
        let count = self.jobs.len();
        self.jobs.retain(|(w, _)| *w != work);
        count != self.jobs.len()
    }
    fn watch(&mut self, _: &Path, _: bool) -> io::Result<u64> {
        self.next += 1;
        self.watches.push(self.next);
        Ok(self.next)
    }
    fn unwatch(&mut self, _: u64) {}
    fn spawn(&mut self, _: std::process::Command, _: Option<Grid>) -> io::Result<Spawned> {
        unsupported()
    }
    fn resize(&mut self, _: i32, _: Grid) -> io::Result<()> {
        unsupported()
    }
    fn hangup(&mut self, _: i32) -> io::Result<()> {
        unsupported()
    }
    fn connect(&mut self, _: &Address) -> io::Result<i32> {
        unsupported()
    }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> {
        unsupported()
    }
    fn reply(&mut self, _: u64, _: &[u8]) -> io::Result<()> {
        unsupported()
    }
}

/// What watching chats are given: replace pages and record batches, with their record counts.
#[derive(Default)]
struct Shown(Vec<(&'static str, usize)>);
impl Ui for Shown {
    fn update(&mut self, update: Update) {
        match update {
            Update::History { page, .. } => self.0.push(("history", page.records.len())),
            Update::Records { records, .. } => self.0.push(("records", records.len())),
            _ => {}
        }
    }
    fn watching(&self, _: &Binding) -> bool {
        true
    }
    fn terminal(&self, _: &Binding) -> Option<Id> {
        Some(1)
    }
}

fn metadata(m: std::fs::Metadata) -> Metadata {
    Metadata {
        kind: FileKind::File,
        size: m.size(),
        device: m.dev(),
        inode: m.ino(),
        modified_ns: m.mtime() as i128 * 1_000_000_000 + m.mtime_nsec() as i128,
        changed_ns: m.ctime() as i128 * 1_000_000_000 + m.ctime_nsec() as i128,
    }
}
fn run(job: &Job) -> io::Result<Output> {
    use std::io::{Read, Seek, SeekFrom};
    let Job::Read { path, offset, length } = job else { panic!("unexpected job") };
    let mut file = std::fs::File::open(path)?;
    let before = metadata(file.metadata()?);
    file.seek(SeekFrom::Start(*offset))?;
    let mut bytes = Vec::new();
    (&mut file).take(*length).read_to_end(&mut bytes)?;
    Ok(Output::Read { before, after: metadata(file.metadata()?), bytes })
}

const SESSION: &str = "0b9f6c1e-3a52-4d7e-9c41-5e2f8a7b6c10";
fn uuid(n: usize) -> String {
    format!("00000000-0000-4000-8000-{n:012}")
}
/// A question, its answer and the turn's duration: five records.
fn turn(n: usize) -> String {
    let (u, a, d) = (uuid(3 * n), uuid(3 * n + 1), uuid(3 * n + 2));
    let m = n % 60;
    format!(
        concat!(
            r#"{{"parentUuid":null,"isSidechain":false,"type":"user","message":{{"role":"user","content":"question {n}"}},"uuid":"{u}","timestamp":"2026-10-20T12:{m:02}:00.000Z","sessionId":"{s}","version":"2.1.302"}}"#,
            "\n",
            r#"{{"parentUuid":"{u}","isSidechain":false,"type":"assistant","message":{{"role":"assistant","model":"claude-example","content":[{{"type":"text","text":"answer {n}"}}],"stop_reason":"end_turn"}},"uuid":"{a}","timestamp":"2026-10-20T12:{m:02}:01.000Z","sessionId":"{s}"}}"#,
            "\n",
            r#"{{"parentUuid":"{a}","isSidechain":false,"type":"system","subtype":"turn_duration","uuid":"{d}","timestamp":"2026-10-20T12:{m:02}:02.000Z","sessionId":"{s}"}}"#,
            "\n"
        ),
        n = n, u = u, a = a, d = d, s = SESSION, m = m
    )
}
fn turns(range: std::ops::Range<usize>) -> String {
    range.map(turn).collect()
}
/// Claude ≥ 2.1.300 logs each API request beside the conversation; no record comes from it.
fn blob(n: usize) -> String {
    format!(
        "{{\"type\":\"api-request-blob\",\"sessionId\":\"{SESSION}\",\"hash\":\"h{n}\",\"message\":{{\"role\":\"user\",\"content\":\"{}\"}}}}\n",
        "x".repeat(9_000)
    )
}
fn append(path: &Path, text: &str) {
    std::fs::OpenOptions::new().append(true).open(path).unwrap().write_all(text.as_bytes()).unwrap();
}

struct World {
    claude: Claude,
    io: Fake,
    shown: Shown,
    binding: Binding,
    path: PathBuf,
    dir: PathBuf,
}
impl World {
    fn new(name: &str, transcript: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("dispatch-claude-archive-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("{SESSION}.jsonl"));
        std::fs::write(&path, transcript).unwrap();
        let binding = Binding {
            session: SESSION.into(),
            transcript: Some(path.clone()),
            process: Process {
                pid: 4242, parent: 1, group: 4242, foreground: 4242, tty: 7, start: [1_800_000_000, 0],
                executable: "/opt/example/claude".into(), arguments: vec!["claude".into()], files: vec![],
            },
        };
        Self { claude: Claude::new(dir.clone(), false), io: Fake::default(), shown: Shown::default(), binding, path, dir }
    }
    /// Deferred callbacks, then each job; `before(index)` runs ahead of job `index` (Claude writing
    /// between two reads of one page), `after(index)` once it has run.
    fn pump(&mut self, mut before: impl FnMut(&mut Self, usize), mut after: impl FnMut(&mut Self, usize)) {
        let mut index = 0;
        loop {
            while let Some(callback) = self.io.deferred.pop_front() {
                callback(&mut self.io);
            }
            let Some((work, job)) = self.io.jobs.pop_front() else { break };
            before(self, index);
            let result = run(&job);
            after(self, index);
            self.claude.event(&mut self.io, &mut self.shown, Event::Done { work, result });
            index += 1;
        }
    }
    fn settle(&mut self) {
        self.pump(|_, _| {}, |_, _| {});
    }
    /// chat.open: the page the opening chat is given.
    fn open(&mut self) -> Rc<RefCell<Option<Result<usize, String>>>> {
        let opened = Rc::new(RefCell::new(None));
        let saved = opened.clone();
        self.claude.history(&mut self.io, &self.binding, None, Box::new(move |_, result: Result<Page, Error>| {
            *saved.borrow_mut() = Some(result.map(|page| page.records.len()).map_err(|e| e.message));
        }));
        opened
    }
    /// The transcript's watch fires (Claude wrote, or changed its attributes).
    fn changed(&mut self) {
        let watch = *self.io.watches.first().expect("the transcript is watched");
        self.claude.event(&mut self.io, &mut self.shown, Event::Changed { watch, reset: false });
    }
    fn history(&self) -> bool {
        self.shown.0.iter().any(|(kind, _)| *kind == "history")
    }
}
impl Drop for World {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn a_page_ending_in_request_logs_still_opens_on_the_conversation() {
    // 450 logged requests of 9 KB after the last message: counted, they filled the 400-line,
    // 4 MiB page and the chat opened on no message at all.
    let mut world = World::new("blobs", &(turns(0..40) + &(0..450).map(blob).collect::<String>()));
    let opened = world.open();
    world.settle();
    assert_eq!(*opened.borrow(), Some(Ok(200)));
}

#[test]
fn appends_are_records() {
    let mut world = World::new("append", &turns(0..40));
    let _ = world.open();
    world.settle();
    append(&world.path, &turn(40));
    world.changed();
    world.settle();
    assert_eq!(world.shown.0, [("records", 5)]);
}

#[test]
fn a_read_racing_a_write_adds_records_instead_of_replacing_the_history() {
    let mut world = World::new("race", &turns(0..40));
    let _ = world.open();
    world.settle();
    // The refresh's first read takes the file's start; Claude appends before its guard read, so the
    // cache no longer continues and the page is read again without it.
    append(&world.path, &turn(40));
    world.changed();
    world.pump(|world, index| if index == 1 { append(&world.path, &turn(41)) }, |_, _| {});
    assert!(!world.history(), "{:?}", world.shown.0);
    let added: usize = world.shown.0.iter().map(|(_, count)| count).sum();
    assert!(added >= 10, "both appended turns arrive: {:?}", world.shown.0);
}

#[test]
fn a_reopen_during_a_write_adds_records_for_every_watching_chat() {
    let mut world = World::new("reopen", &turns(0..40));
    let _ = world.open();
    world.settle();
    // A second opening (another view, the iPhone, a reopen on agent.changed) drops the live cache;
    // Claude writes before its read ends.
    let reopened = world.open();
    while let Some(callback) = world.io.deferred.pop_front() {
        callback(&mut world.io);
    }
    append(&world.path, &turn(40));
    world.changed();
    world.settle();
    assert_eq!(*reopened.borrow(), Some(Ok(205)));
    assert!(!world.history(), "{:?}", world.shown.0);
    assert!(world.shown.0.contains(&("records", 205)), "{:?}", world.shown.0);
}

#[test]
fn an_attribute_change_gives_watching_chats_nothing() {
    use std::os::unix::fs::PermissionsExt;
    let mut world = World::new("attribute", &turns(0..40));
    let _ = world.open();
    world.settle();
    std::thread::sleep(std::time::Duration::from_millis(20));
    std::fs::set_permissions(&world.path, std::fs::Permissions::from_mode(0o600)).unwrap();
    world.changed();
    world.settle();
    assert_eq!(world.shown.0, []);
}

#[test]
fn a_replaced_or_shortened_transcript_replaces_the_history() {
    let mut world = World::new("shortened", &turns(0..40));
    let _ = world.open();
    world.settle();
    std::fs::write(&world.path, turns(0..10)).unwrap();
    world.changed();
    world.settle();
    assert_eq!(world.shown.0, [("history", 50)]);

    let mut world = World::new("replaced", &turns(0..40));
    let _ = world.open();
    world.settle();
    let next = world.dir.join("next.jsonl");
    std::fs::write(&next, turns(0..41)).unwrap();
    std::fs::rename(&next, &world.path).unwrap();
    world.changed();
    world.settle();
    assert_eq!(world.shown.0, [("history", 205)]);
}

#[test]
fn an_opening_that_races_a_write_is_read_again_on_its_watch_event() {
    // The opening watches before it reads, so the write that spoils its read also fires the watch:
    // the empty page is followed by the whole history, wherever the event lands.
    for during in [true, false] {
        let mut world = World::new(if during { "open-race-during" } else { "open-race-after" }, &turns(0..40));
        let opened = world.open();
        world.pump(
            |world, index| if index == 1 { append(&world.path, &turn(40)) },
            |world, index| if index == 1 && during { world.changed() },
        );
        assert_eq!(*opened.borrow(), Some(Ok(0)));
        if !during {
            world.changed();
        }
        world.settle();
        assert_eq!(world.shown.0, [("history", 205)], "event during the read: {during}");
    }
}
