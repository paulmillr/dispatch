//! A limits read's steps: what it writes, that the file goes back byte for byte, and what it refuses.
use super::*;
use std::{cell::RefCell, rc::Rc};

const COMMAND: &str = "'/home/sam/.dispatch/bin/dispatch-helper' hook claude";
const SESSION: &str = "00000000-0000-4000-8000-000000000001";

fn metadata(kind: FileKind, size: u64, inode: u64) -> Metadata {
    Metadata { kind, size, device: 1, inode, modified_ns: 1, changed_ns: 1 }
}

type Answer = Rc<RefCell<Option<Result<Vec<LimitWindow>, Error>>>>;

fn reading() -> (Reading, Job, Answer) {
    let answer: Answer = Rc::default();
    let kept = answer.clone();
    let (reading, job) = Reading::new(
        Path::new("/work/invoices"),
        COMMAND.into(),
        SESSION.into(),
        Box::new(move |_, result| *kept.borrow_mut() = Some(result)),
    );
    (reading, job, answer)
}

fn missing() -> io::Result<Output> {
    Err(io::ErrorKind::NotFound.into())
}

fn job(next: Next) -> Job {
    match next {
        Next::Job(job) => job,
        _ => panic!("expected a job"),
    }
}

fn parsed(json: &str) -> Vec<LimitWindow> {
    windows(Json::parse(json.as_bytes()).unwrap().root())
}

#[test]
fn only_a_status_lines_json_counts_as_one() {
    let line = Json::parse(br#"{"session_id":"s","workspace":{"project_dir":"/work"}}"#).unwrap();
    assert!(status_line(line.root()));
    let hook = Json::parse(br#"{"hook_event_name":"Stop","workspace":{}}"#).unwrap();
    assert!(!status_line(hook.root()));
    let other = Json::parse(br#"{"session_id":"s"}"#).unwrap();
    assert!(!status_line(other.root()));
}

#[test]
fn windows_keep_what_claude_reports_and_nothing_invented() {
    assert_eq!(
        parsed(r#"{"rate_limits":{"seven_day":{"used_percentage":18,"resets_at":1794866400}}}"#),
        [LimitWindow("seven_day".into(), 18, 1794866400)]
    );
    assert_eq!(
        parsed(r#"{"rate_limits":{"five_hour":{"used_percentage":41.6,"resets_at":1794866400},"seven_day":{"resets_at":1}}}"#),
        [LimitWindow("five_hour".into(), 42, 1794866400)]
    );
    assert!(parsed(r#"{"workspace":{}}"#).is_empty());
    assert!(parsed(r#"{"rate_limits":{"five_hour":{"used_percentage":-1,"resets_at":5}}}"#).is_empty());
}

#[test]
fn settings_gain_the_status_line_and_keep_the_rest() {
    let after = with_status_line(Some(br#"{"model":"sonnet"}"#), COMMAND).unwrap();
    let document = Json::parse(&after).unwrap();
    assert_eq!(text(document.root(), "model"), Some("sonnet"));
    assert_eq!(document.root().get("statusLine").and_then(|line| text(line, "command")), Some(COMMAND));
}

#[test]
fn a_folders_own_status_line_or_broken_settings_are_left_alone() {
    assert_eq!(with_status_line(Some(br#"{"statusLine":{"type":"command","command":"x"}}"#), COMMAND).unwrap_err().code, "unavailable");
    assert_eq!(with_status_line(Some(b"not json"), COMMAND).unwrap_err().code, "settings");
    assert_eq!(with_status_line(Some(b"[]"), COMMAND).unwrap_err().code, "settings");
}

#[test]
fn repair_takes_out_only_this_helpers_entry() {
    let ours = format!(r#"{{"model":"sonnet","statusLine":{{"type":"command","command":{COMMAND:?}}}}}"#);
    let kept = without_status_line(ours.as_bytes(), COMMAND).unwrap();
    let document = Json::parse(&kept).unwrap();
    assert!(document.root().get("statusLine").is_none());
    assert_eq!(text(document.root(), "model"), Some("sonnet"));
    let alone = format!(r#"{{"statusLine":{{"type":"command","command":{COMMAND:?}}}}}"#);
    assert_eq!(without_status_line(alone.as_bytes(), COMMAND), Some(Vec::new()));
    assert_eq!(without_status_line(br#"{"statusLine":{"type":"command","command":"theirs"}}"#, COMMAND), None);
    assert_eq!(without_status_line(br#"{"model":"sonnet"}"#, COMMAND), None);
}

/// A read's line names its helper's route (`reading_command`): any helper's repair takes it out, and a line naming a
/// route that merely starts like ours is not ours.
#[test]
fn a_reads_line_with_its_route_is_ours_too() {
    let line = |command: &str| format!(r#"{{"statusLine":{{"type":"command","command":{}}}}}"#, json_string(command));
    let routed = line(&format!("{COMMAND} '/home/sam/.dispatch/run/123/routes/harness-1/77'"));
    assert_eq!(without_status_line(routed.as_bytes(), COMMAND), Some(Vec::new()));
    assert_eq!(without_status_line(line(&format!("{COMMAND} --other")).as_bytes(), COMMAND), None);
    assert_eq!(without_status_line(line(&format!("{COMMAND}x '/r'")).as_bytes(), COMMAND), None);
}

fn json_string(text: &str) -> String {
    format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
}

#[test]
fn a_new_file_and_folder_are_removed_again() {
    let now = Instant::now();
    let (mut reading, first, _) = reading();
    assert!(matches!(first, Job::Stat { follow: false, .. }));
    assert!(matches!(job(reading.complete(now, missing())), Job::Write { expected: Expected::Absent, .. }));
    assert!(matches!(job(reading.complete(now, Ok(Output::Written))), Job::Stat { follow: false, .. }));
    assert!(matches!(reading.complete(now, Ok(Output::Metadata(metadata(FileKind::File, 60, 9)))), Next::Wait(_)));
    let next = reading.answered(now, Some(SESSION), vec![LimitWindow("seven_day".into(), 18, 5)]).unwrap();
    assert!(matches!(job(next), Job::Remove { expected: Expected::Same(_), .. }));
    match job(reading.complete(now, Ok(Output::Written))) {
        Job::Remove { path, expected: Expected::Any } => assert_eq!(path, Path::new("/work/invoices/.claude")),
        _ => panic!("expected the folder's removal"),
    }
    assert!(matches!(reading.complete(now, Ok(Output::Written)), Next::Finished));
    assert_eq!(reading.take().1.unwrap(), [LimitWindow("seven_day".into(), 18, 5)]);
}

#[test]
fn an_existing_file_goes_back_byte_for_byte() {
    let now = Instant::now();
    let original = b"{ \"model\":   \"sonnet\" }\n".to_vec();
    let size = original.len() as u64;
    let (mut reading, _, _) = reading();
    assert!(matches!(job(reading.complete(now, Ok(Output::Metadata(metadata(FileKind::Directory, 0, 2))))), Job::Stat { .. }));
    assert!(matches!(job(reading.complete(now, Ok(Output::Metadata(metadata(FileKind::File, size, 3))))), Job::Read { .. }));
    let file = metadata(FileKind::File, size, 3);
    let read = Output::Read { before: file.clone(), after: file, bytes: original.clone() };
    assert!(matches!(job(reading.complete(now, Ok(read))), Job::Write { expected: Expected::Same(_), .. }));
    job(reading.complete(now, Ok(Output::Written)));
    reading.complete(now, Ok(Output::Metadata(metadata(FileKind::File, 90, 4))));
    match job(reading.answered(now, Some(SESSION), Vec::new()).unwrap()) {
        Job::Write { bytes, expected: Expected::Same(_), .. } => assert_eq!(bytes, original),
        _ => panic!("expected the original back"),
    }
    assert!(matches!(reading.complete(now, Ok(Output::Written)), Next::Finished));
    assert_eq!(reading.take().1.unwrap(), []);
}

#[test]
fn a_linked_folder_or_file_is_refused_before_anything_is_written() {
    let now = Instant::now();
    let (mut reading_folder, _, _) = reading();
    assert!(matches!(reading_folder.complete(now, Ok(Output::Metadata(metadata(FileKind::Symlink, 0, 2)))), Next::Finished));
    let (mut reading_file, _, _) = reading();
    reading_file.complete(now, Ok(Output::Metadata(metadata(FileKind::Directory, 0, 2))));
    assert!(matches!(reading_file.complete(now, Ok(Output::Metadata(metadata(FileKind::Symlink, 0, 3)))), Next::Finished));
}

#[test]
fn another_session_is_not_the_answer_and_silence_still_restores() {
    let now = Instant::now();
    let (mut reading, _, _) = reading();
    reading.complete(now, missing());
    reading.complete(now, Ok(Output::Written));
    reading.complete(now, Ok(Output::Metadata(metadata(FileKind::File, 60, 9))));
    assert!(reading.answered(now, Some("00000000-0000-4000-8000-000000000002"), Vec::new()).is_none());
    assert!(reading.expired(now).is_none());
    assert!(matches!(job(reading.expired(now + WAIT).unwrap()), Job::Remove { .. }));
    assert_eq!(reading.answer.as_ref().unwrap().as_ref().unwrap_err().code, "expired");
}

#[test]
fn an_answer_before_the_written_files_stat_restores_after_it() {
    let now = Instant::now();
    let (mut reading, _, _) = reading();
    reading.complete(now, missing());
    reading.complete(now, Ok(Output::Written));
    assert!(reading.answered(now, Some(SESSION), Vec::new()).is_none());
    assert!(matches!(job(reading.complete(now, Ok(Output::Metadata(metadata(FileKind::File, 60, 9))))), Job::Remove { .. }));
}
