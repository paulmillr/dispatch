use super::*;

fn shell(script: &str) -> Command {
    let mut command = Command::new("/bin/sh");
    command.args(["-c", script]);
    command
}

fn soon(seconds: u64) -> Instant {
    Instant::now() + Duration::from_secs(seconds)
}

#[test]
fn collect_keeps_stdout_and_stderr_apart_with_the_status() {
    let ran = collect(shell("printf out; printf err >&2; exit 3"), soon(10), 100, 100).unwrap();
    assert_eq!(
        (ran.status.code(), ran.stdout, ran.stderr, ran.truncated),
        (Some(3), b"out".to_vec(), b"err".to_vec(), false)
    );
}

#[test]
fn collect_drops_stderr_past_its_bound_without_blocking_the_child() {
    // Far more than a pipe holds: a child that is not drained would block and miss the deadline.
    let ran = collect(
        shell("head -c 1000000 /dev/zero >&2; printf done"),
        soon(10),
        100,
        10,
    )
    .unwrap();
    assert_eq!((ran.status.code(), ran.stdout, ran.stderr.len()), (Some(0), b"done".to_vec(), 10));
}

#[test]
fn collect_stops_the_group_once_stdout_passes_its_bound() {
    let started = Instant::now();
    // `yes` never ends on its own; the bound ends it, and its group with it.
    let ran = collect(shell("yes line; sleep 30"), soon(20), 4096, 100).unwrap();
    assert!(ran.truncated);
    assert_eq!(ran.stdout.len(), 4096);
    assert!(ran.stdout.starts_with(b"line\nline\n"));
    assert_eq!(ran.status.code(), None);
    assert!(started.elapsed() < Duration::from_secs(10));
    // A child that is already gone when its output passes the bound.
    for _ in 0..20 {
        let ran = collect(shell("printf 12345"), soon(10), 4, 100).unwrap();
        assert_eq!((ran.stdout, ran.truncated), (b"1234".to_vec(), true));
    }
    // Exactly the bound is not past it.
    let ran = collect(shell("printf 1234"), soon(10), 4, 100).unwrap();
    assert_eq!((ran.stdout, ran.truncated, ran.status.code()), (b"1234".to_vec(), false, Some(0)));
}

#[test]
fn collect_kills_the_group_at_the_deadline() {
    let started = Instant::now();
    let error = collect(shell("sleep 30 & wait"), Instant::now() + Duration::from_millis(300), 100, 100)
        .err()
        .unwrap();
    assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    assert!(started.elapsed() < Duration::from_secs(5));
}

#[test]
fn run_still_refuses_stdout_past_its_limit() {
    assert!(run(shell("printf 12345"), Vec::new(), Some(soon(10)), 4).is_err());
}

#[test]
fn collects_wait_on_their_own_workers_and_their_time_starts_when_they_run() {
    use crate::api::{CollectJob, Event, Io, Job, Output};
    let mut system = crate::system::System::new(2, 64).unwrap();
    let collect = |timeout: u64| {
        Job::Collect(CollectJob {
            command: shell("sleep 2"),
            timeout: Duration::from_secs(timeout),
            stdout: 100,
            stderr: 100,
        })
    };
    let started = Instant::now();
    // Two run at once; the third waits for one of them and still gets its whole 3 s once it starts.
    let collects: Vec<u64> = [10, 10, 3].map(|timeout| system.submit(collect(timeout)).unwrap()).into();
    let stat = system
        .submit(Job::Stat {
            path: "/".into(),
            follow: true,
        })
        .unwrap();
    let mut answered = Vec::new();
    while answered.len() < 4 {
        let (_, event) = system.next().unwrap();
        let Event::Done { work, result } = event else {
            continue;
        };
        if work == stat {
            assert!(matches!(result, Ok(Output::Metadata(_))));
            assert!(started.elapsed() < Duration::from_secs(1), "{:?}", started.elapsed());
        } else {
            match result {
                Ok(Output::Collected(collected)) => assert_eq!(collected.status, Some(0)),
                other => panic!("collect {work}: {:?}", other.map(|_| ())),
            }
        }
        answered.push(work);
    }
    assert_eq!(answered[0], stat);
    assert_eq!(answered.last(), collects.last());
    assert!(started.elapsed() >= Duration::from_secs(4), "{:?}", started.elapsed());
}
