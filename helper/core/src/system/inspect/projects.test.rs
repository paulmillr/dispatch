use super::*;
use std::time::{Duration, SystemTime};

fn session(path: &Path, header: &str, age: u64) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, format!("{header}\n{{\"type\":\"other\"}}\n")).unwrap();
    let time = SystemTime::now() - Duration::from_secs(age);
    fs::File::options().write(true).open(path).unwrap().set_modified(time).unwrap();
}

#[test]
fn folders_from_claude_codex_and_pi_sessions_newest_first() {
    let root = std::env::temp_dir().join(format!("projects-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let (claude, codex, pi) = (root.join("claude"), root.join("codex"), root.join("pi"));
    let work = root.join("work");
    fs::create_dir_all(&work).unwrap();
    let work_text = work.to_str().unwrap();
    session(&claude.join("projects/-work/a.jsonl"), &format!(r#"{{"type":"user","cwd":"{work_text}"}}"#), 300);
    session(&claude.join("projects/-gone/b.jsonl"), r#"{"type":"user","cwd":"/nonexistent/gone"}"#, 100);
    session(&codex.join("sessions/2026/10/18/rollout-1.jsonl"),
        &format!(r#"{{"type":"session_meta","payload":{{"id":"x","cwd":"{work_text}"}}}}"#), 10);
    session(&pi.join("sessions/--work--/s.jsonl"), r#"{"type":"session","cwd":"relative/ignored"}"#, 5);
    let input = Data::Object(vec![
        ("claude", Data::from(claude.as_path())),
        ("codex", Data::from(codex.as_path())),
        ("pi", Data::from(pi.as_path())),
        ("limit", Data::Unsigned(10)),
    ]);
    let bytes = collect(&input).unwrap();
    let value = crate::wire::body::decode_plain(&bytes).unwrap();
    let rows: Vec<_> = value.array().unwrap().collect();
    assert_eq!(rows.len(), 2, "the relative Pi cwd is not a folder");
    assert_eq!(rows[0].get("path").and_then(Data::string), Some(work_text), "Codex touched it last");
    let agents: Vec<_> = rows[0].get("agents").unwrap().array().unwrap().filter_map(Data::string).collect();
    assert_eq!(agents, ["claude", "codex"]);
    assert_eq!(rows[0].get("exists").and_then(Data::boolean), Some(true));
    assert_eq!(rows[1].get("path").and_then(Data::string), Some("/nonexistent/gone"));
    assert_eq!(rows[1].get("exists").and_then(Data::boolean), Some(false));
    assert!(rows[0].get("time_ms").and_then(Data::signed).unwrap() > rows[1].get("time_ms").and_then(Data::signed).unwrap());
    let limited = collect(&Data::Object(vec![("codex", Data::from(codex.as_path())), ("limit", Data::Unsigned(1))])).unwrap();
    assert_eq!(crate::wire::body::decode_plain(&limited).unwrap().array().unwrap().count(), 1);
    fs::remove_dir_all(&root).unwrap();
}
