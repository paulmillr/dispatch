//! The list read against real files, its jobs run in the order a test chooses.
use super::*;
use std::{
    collections::VecDeque,
    io::Write,
    os::unix::fs::MetadataExt,
    time::Instant,
};

type Callback = Box<dyn FnOnce(&mut dyn Io, io::Result<Output>)>;

#[derive(Default)]
struct Fake {
    next: u64,
    jobs: VecDeque<(Work, Job)>,
    callbacks: BTreeMap<Work, Callback>,
    deferred: VecDeque<Box<dyn FnOnce(&mut dyn Io)>>,
    /// (offset, length) of every read run.
    reads: Vec<(u64, u64)>,
    stats: usize,
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
    fn submit(&mut self, job: Job) -> io::Result<Work> {
        self.next += 1;
        self.jobs.push_back((self.next, job));
        Ok(self.next)
    }
    fn cancel(&mut self, _: Work) -> bool {
        false
    }
    fn then(&mut self, work: Work, callback: Callback) {
        self.callbacks.insert(work, callback);
    }
    fn watch(&mut self, _: &Path, _: bool) -> io::Result<u64> {
        unsupported()
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

fn metadata(m: std::fs::Metadata) -> Metadata {
    Metadata {
        kind: if m.is_file() { FileKind::File } else { FileKind::Other },
        size: m.size(),
        device: m.dev(),
        inode: m.ino(),
        modified_ns: m.mtime() as i128 * 1_000_000_000 + m.mtime_nsec() as i128,
        changed_ns: m.ctime() as i128 * 1_000_000_000 + m.ctime_nsec() as i128,
    }
}
fn run(job: &Job) -> io::Result<Output> {
    use std::io::{Read, Seek, SeekFrom};
    match job {
        Job::Stat { path, .. } => Ok(Output::Metadata(metadata(std::fs::metadata(path)?))),
        Job::Read { path, offset, length } => {
            let mut file = std::fs::File::open(path)?;
            let before = metadata(file.metadata()?);
            file.seek(SeekFrom::Start(*offset))?;
            let mut bytes = Vec::new();
            (&mut file).take(*length).read_to_end(&mut bytes)?;
            Ok(Output::Read { before, after: metadata(file.metadata()?), bytes })
        }
        _ => panic!("unexpected job"),
    }
}

/// Test lines: `a <ms> <text>` an answer, `e <ms>` a turn end, `s <ms>` a turn start, `r <ms>`
/// another record, `t <title>` a title; anything else yields nothing.
fn classify(_: &str) -> Classify {
    Box::new(|line: &[u8]| {
        let line = String::from_utf8_lossy(line).into_owned();
        let mut words = line.splitn(3, ' ');
        let (kind, first, rest) = (words.next().unwrap_or(""), words.next().unwrap_or(""), words.next().unwrap_or(""));
        let time = first.parse::<i64>().ok();
        let mut out = Line::default();
        match kind {
            "a" => (out.time_ms, out.answer) = (time, Some((rest.into(), time))),
            "e" => (out.time_ms, out.ended) = (time, time),
            "s" => (out.time_ms, out.started) = (time, time),
            "r" => out.time_ms = time,
            "t" => out.title = Some(format!("{first} {rest}").trim().into()),
            _ => {}
        }
        out
    })
}

struct World {
    io: Fake,
    tails: Shared,
    path: PathBuf,
    dir: PathBuf,
}
impl World {
    fn new(name: &str, text: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("dispatch-tail-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("transcript.jsonl");
        std::fs::write(&path, text).unwrap();
        Self { io: Fake::default(), tails: Shared::default(), path, dir }
    }
    fn ask(&mut self) -> Rc<RefCell<Option<Result<Overview, Error>>>> {
        let answer = Rc::new(RefCell::new(None));
        let saved = answer.clone();
        listing(&self.tails, &mut self.io, &self.path.clone(), "s", true, classify, Box::new(move |_, result| {
            *saved.borrow_mut() = Some(result);
        }));
        answer
    }
    /// Run jobs and callbacks; `before(index)` runs ahead of job `index`.
    fn pump(&mut self, mut before: impl FnMut(&mut Self, usize)) {
        let mut index = 0;
        loop {
            while let Some(callback) = self.io.deferred.pop_front() {
                callback(&mut self.io);
            }
            let Some((work, job)) = self.io.jobs.pop_front() else { break };
            before(self, index);
            match &job {
                Job::Read { offset, length, .. } => self.io.reads.push((*offset, *length)),
                Job::Stat { .. } => self.io.stats += 1,
                _ => {}
            }
            let result = run(&job);
            let callback = self.io.callbacks.remove(&work).expect("every job is chained");
            callback(&mut self.io, result);
            index += 1;
        }
    }
    fn get(&mut self) -> Overview {
        let answer = self.ask();
        self.pump(|_, _| {});
        answer.take().expect("answered").expect("read")
    }
    fn append(&self, text: &str) {
        std::fs::OpenOptions::new().append(true).open(&self.path).unwrap().write_all(text.as_bytes()).unwrap();
    }
    fn counts(&mut self) -> (usize, Vec<(u64, u64)>) {
        let counts = (self.io.stats, std::mem::take(&mut self.io.reads));
        self.io.stats = 0;
        counts
    }
}
impl Drop for World {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// `count` other records of `size` bytes each, times from `from`.
fn filler(count: usize, size: usize, from: i64) -> String {
    (0..count).map(|n| format!("r {} {}\n", from + n as i64, "x".repeat(size))).collect()
}

#[test]
fn a_large_transcript_is_read_only_at_its_end() {
    // 8 MiB of records, then the title, an answer and some tool records.
    let text = filler(8 * 1024, 1024, 1) + "t Fix the login form\n" + "a 50000 The form posts again.\n" + &filler(20, 100, 50001);
    let mut world = World::new("large", &text);
    let overview = world.get();
    assert_eq!(overview.preview.as_deref(), Some("The form posts again."));
    assert_eq!(overview.title.as_deref(), Some("Fix the login form"));
    assert_eq!(overview.time_ms, Some(50020));
    assert_eq!(overview.reply_ms, Some(50000));
    let (stats, reads) = world.counts();
    assert_eq!(stats, 1);
    let size = text.len() as u64;
    assert_eq!(reads, [(size - TAIL, TAIL)], "one read of the last {TAIL} bytes");
}

#[test]
fn no_answer_near_the_end_reads_back_to_the_cap() {
    // An answer 6 MiB from the end lies past the cap: no preview, and no more than CAP read.
    let text = "a 1 Too far back.\n".to_owned() + &filler(6 * 1024, 1024, 2);
    let mut world = World::new("cap", &text);
    let overview = world.get();
    assert_eq!(overview.preview, None);
    let (_, reads) = world.counts();
    let read: u64 = reads.iter().map(|(_, length)| length).sum();
    assert_eq!(read, CAP);
    assert_eq!(reads.iter().map(|(_, length)| *length / 1024).collect::<Vec<_>>(), [256, 256, 512, 1024, 2048]);

    // Within it: found by reading back, each read as long as all before it.
    let text = "t Title\n".to_owned() + "a 1 Found it.\n" + &filler(600, 1024, 2);
    let mut world = World::new("back", &text);
    let overview = world.get();
    assert_eq!((overview.preview.as_deref(), overview.title.as_deref()), (Some("Found it."), Some("Title")));
    let (_, reads) = world.counts();
    assert_eq!(reads.len(), 3);
    assert_eq!(reads.last().map(|(offset, _)| *offset), Some(0));
}

#[test]
fn a_line_split_across_two_reads_is_read_whole() {
    // The answer line straddles the first read's start.
    let answer = format!("a 7 {}\n", "y".repeat(1000));
    let tail = filler(1, (TAIL as usize) - 500, 8);
    let text = filler(10, 100, 1) + &answer + &tail;
    let mut world = World::new("split", &text);
    let overview = world.get();
    assert_eq!(overview.preview.map(|text| text.chars().count()), Some(Overview::PREVIEW + 1));
    assert_eq!(overview.reply_ms, Some(7));
}

#[test]
fn an_unchanged_transcript_costs_a_stat() {
    let mut world = World::new("unchanged", &("a 1 Hello.\n".to_owned() + &filler(10, 100, 2)));
    let first = world.get();
    let _ = world.counts();
    let second = world.get();
    assert_eq!(first, second);
    assert_eq!(world.counts(), (1, Vec::new()));
}

#[test]
fn an_append_is_read_from_the_last_complete_line() {
    let text = "a 1 Hello.\n".to_owned() + &filler(10, 100, 2);
    let mut world = World::new("append", &text);
    let _ = world.get();
    let _ = world.counts();
    // An unfinished line: not taken yet, and the row stays as it was.
    world.append("a 20 The new ans");
    let overview = world.get();
    assert_eq!(overview.preview.as_deref(), Some("Hello."));
    // From where the last complete line ended, with the 64 bytes before it (an append, not a file
    // written again).
    let end = text.len() as u64;
    let (_, reads) = world.counts();
    assert_eq!(reads, [(end - 64, 64 + 16)]);
    world.append("wer.\ne 21\n");
    let overview = world.get();
    assert_eq!(overview.preview.as_deref(), Some("The new answer."));
    assert_eq!((overview.time_ms, overview.reply_ms), (Some(21), Some(21)));
    let (_, reads) = world.counts();
    assert_eq!(reads, [(end - 64, 64 + 26)]);
    // The next one starts after these lines.
    world.append("r 22\n");
    let _ = world.get();
    let (_, reads) = world.counts();
    assert_eq!(reads, [(end + 26 - 64, 64 + 5)]);
}

#[test]
fn appends_during_a_read_wait_for_the_next() {
    let text = "a 1 Hello.\n".to_owned() + &filler(10, 100, 2);
    let mut world = World::new("during", &text);
    // Claude writes between the stat and the read: no error, the row is the file the stat found.
    let answer = world.ask();
    world.pump(|world, index| if index == 1 { world.append("a 30 Later.\n") });
    let overview = answer.take().unwrap().unwrap();
    assert_eq!(overview.preview.as_deref(), Some("Hello."));
    assert_eq!(world.get().preview.as_deref(), Some("Later."));

    // A call while a read runs gets one more read after it, which sees what was written meanwhile.
    world.append("r 35\n");
    let first = world.ask();
    let second = Rc::new(RefCell::new(None));
    let saved = second.clone();
    world.pump(|world, index| {
        if index == 1 {
            world.append("a 40 Newest.\n");
            *saved.borrow_mut() = Some(world.ask());
        }
    });
    assert_eq!(first.take().unwrap().unwrap().preview.as_deref(), Some("Later."));
    let second = second.take().unwrap().take().unwrap().unwrap();
    assert_eq!(second.preview.as_deref(), Some("Newest."));
}

#[test]
fn a_replaced_or_shortened_transcript_is_read_again() {
    let mut world = World::new("replaced", &("a 1 Old.\n".to_owned() + &filler(10, 100, 2)));
    let _ = world.get();
    let next = world.dir.join("next.jsonl");
    std::fs::write(&next, "a 5 New.\n").unwrap();
    std::fs::rename(&next, &world.path).unwrap();
    assert_eq!(world.get().preview.as_deref(), Some("New."));
    std::fs::write(&world.path, "a 6 Short.\n").unwrap();
    assert_eq!(world.get().preview.as_deref(), Some("Short."));
    std::fs::remove_file(&world.path).unwrap();
    assert_eq!(world.get(), Overview::default());
}

#[test]
fn the_reply_is_the_answer_or_a_later_turn_end() {
    // A turn end after the answer (an interrupt) moves the reply; records after it do not.
    let mut world = World::new("reply", "a 10 Done.\ne 12\nr 15\nr 16\n");
    let overview = world.get();
    assert_eq!((overview.time_ms, overview.reply_ms), (Some(16), Some(12)));
    // An older turn end does not.
    let mut world = World::new("older", "e 5\na 10 Done.\nr 15\n");
    assert_eq!(world.get().reply_ms, Some(10));
}
