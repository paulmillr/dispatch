use super::*;
use super::super::tests::{record, write};

fn template(text: &str) -> Template {
    Template::parse(text).unwrap()
}

fn temporary(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("migrate-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    root
}

fn strings(args: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    fn walk(value: &Data<'_>, out: &mut Vec<String>) {
        match value {
            Data::String(text) => out.push((*text).to_owned()),
            Data::Array(items) => items.iter().for_each(|item| walk(item, out)),
            Data::Object(fields) => fields.iter().for_each(|(_, value)| walk(value, out)),
            _ => {}
        }
    }
    walk(&body::decode_plain(args).unwrap(), &mut out);
    out
}

#[test]
fn templates_fill_their_slots_and_match_the_shell_quoted_form_too() {
    let pairs = vec![(template("enter_private '{{digest}}' || exit 1"),
                      template("enter_private '{{digest}}'\ncommand -v shasum || fail \"no shasum\""))];
    // As a script holds it, and inside `exec /bin/sh -c '…'`, where each ' is '"'"'.
    let (raw, count) = replaced("a\nenter_private 'ab12' || exit 1\nb", &pairs).unwrap();
    assert_eq!((raw.as_str(), count), ("a\nenter_private 'ab12'\ncommand -v shasum || fail \"no shasum\"\nb", 1));
    let quoted = "exec /bin/sh -c 'enter_private '\"'\"'ab12'\"'\"' || exit 1'";
    let (text, count) = replaced(quoted, &pairs).unwrap();
    assert_eq!(count, 1);
    assert_eq!(text, "exec /bin/sh -c 'enter_private '\"'\"'ab12'\"'\"'\ncommand -v shasum || fail \"no shasum\"'");
    // A slot named twice matches the same text; nothing matching is no change.
    assert!(Template::parse("{{x}}").is_err(), "a template starts with text");
    let same = vec![(template("a={{v}} b={{v}}"), template("ab={{v}}"))];
    assert_eq!(replaced("a=1 b=2 a=3 b=3", &same).unwrap().0, "a=1 b=2 ab=3");
    assert!(replaced("nothing here", &pairs).is_none());
    assert!(Template::parse("x{{a}}{{b}}").is_err(), "two slots need text between them");
}

#[test]
fn a_rewrite_changes_text_only_and_keeps_keys_numbers_and_bytes() {
    let value = Data::Object(vec![
        ("executable", Data::String("/usr/bin/ssh")),
        ("arguments", Data::Array(vec![Data::String("-T"), Data::String("exec /bin/sh -c 'old'")])),
        ("input", Data::Bytes(b"old bytes")),
        ("old", Data::Unsigned(7)),
    ]);
    let bytes = body::encode_plain(&value).unwrap();
    let change = |text: &str| text.contains("old").then(|| text.replace("old", "newer"));
    let rewritten = rewritten_value(&bytes, &change).unwrap().unwrap();
    let expected = Data::Object(vec![
        ("executable", Data::String("/usr/bin/ssh")),
        ("arguments", Data::Array(vec![Data::String("-T"), Data::String("exec /bin/sh -c 'newer'")])),
        ("input", Data::Bytes(b"old bytes")),
        ("old", Data::Unsigned(7)),
    ]);
    assert_eq!(rewritten, body::encode_plain(&expected).unwrap());
    assert!(rewritten_value(&bytes, &|_| None).unwrap().is_none());
}

/// A corpus with one case: the command the app sent (an input) and what it read back (a result holding the same text).
fn corpus(root: &Path) -> PathBuf {
    let replays = root.join("replays");
    let sent = Data::Object(vec![("arguments", Data::Array(vec![Data::String("exec /bin/sh -c 'test -e x || mkdir x'")]))]);
    write(&replays.join("SSHTests/testOne/app.rpl.zst"), &[
        record("open.command", &sent, &Data::Null),
        record("in.result", &Data::Null, &Data::String("test -e x || mkdir x")),
    ]);
    write(&replays.join("GitTests/testLog/app.rpl.zst"), &[record("open.query", &Data::Null, &Data::Null)]);
    replays
}

fn migration(directory: &Path, name: &str, json: &str) {
    std::fs::create_dir_all(directory).unwrap();
    std::fs::write(directory.join(format!("{name}.json")), json).unwrap();
}

#[test]
fn migrate_rewrites_inputs_retires_changed_tests_and_keeps_a_ledger() {
    let root = temporary("run");
    let replays = corpus(&root);
    let migrations = root.join("migrations");
    migration(&migrations, "0000-baseline", r#"{"kind": "baseline", "why": "the corpus as it was"}"#);
    migration(&migrations, "0001-mkdir", r#"{"kind": "rewrite", "why": "create, then check",
        "ops": ["open.command"], "replace": [{"old": "test -e {{f}} || mkdir {{f}}", "new": "mkdir {{f}} 2>/dev/null"}]}"#);
    migration(&migrations, "0002-log", r#"{"kind": "rerecord", "why": "new requests", "tests": ["GitTests/testLog"]}"#);
    let args = |extra: &[&str]| -> Vec<String> {
        extra.iter().map(|arg| (*arg).to_owned())
            .chain([replays.display().to_string(), migrations.display().to_string()]).collect()
    };
    // Without a ledger the baseline counts as applied; the others are pending.
    assert!(run(args(&["--check"])).is_err());
    run(args(&["--dry-run"])).unwrap();
    assert!(!replays.join("MIGRATIONS").exists(), "a dry run writes nothing");
    run(args(&[])).unwrap();
    let records = trace::read(File::open(replays.join("SSHTests/testOne/app.rpl.zst")).unwrap(), usize::MAX).unwrap().1;
    assert_eq!(strings(&records[0].args), ["exec /bin/sh -c 'mkdir x 2>/dev/null'"]);
    assert_eq!(records[1], record("in.result", &Data::Null, &Data::String("test -e x || mkdir x")), "results are never rewritten");
    assert!(!replays.join("GitTests/testLog").exists());
    assert!(root.join("build/retired-replays/0002-log/GitTests/testLog/app.rpl.zst").exists());
    assert_eq!(std::fs::read_to_string(replays.join("MIGRATIONS")).unwrap(), "0000-baseline\n0001-mkdir\n0002-log\n");
    // Up to date: nothing pending, nothing written again.
    run(args(&["--check"])).unwrap();
    // A fresh copy of the old corpus (a test VM's, synced again) migrates beside what an earlier one retired.
    std::fs::remove_file(replays.join("MIGRATIONS")).unwrap();
    write(&replays.join("GitTests/testLog/app.rpl.zst"), &[record("open.query", &Data::Null, &Data::Null)]);
    run(args(&[])).unwrap();
    assert!(root.join("build/retired-replays/0002-log-2/GitTests/testLog/app.rpl.zst").exists());
    std::fs::remove_dir_all(&root).unwrap();
}

/// A storage migration writes every capture again with the same records.
#[test]
fn encode_rewrites_every_capture_and_keeps_its_records() {
    let root = temporary("encode");
    let replays = corpus(&root);
    let file = replays.join("SSHTests/testOne/app.rpl.zst");
    let before = trace::read(File::open(&file).unwrap(), usize::MAX).unwrap();
    let migrations = root.join("migrations");
    migration(&migrations, "0000-baseline", r#"{"kind": "baseline", "why": "the corpus as it was"}"#);
    migration(&migrations, "0001-encode", r#"{"kind": "encode", "why": "rsyncable"}"#);
    run(vec![replays.display().to_string(), migrations.display().to_string()]).unwrap();
    assert_eq!(trace::read(File::open(&file).unwrap(), usize::MAX).unwrap(), before);
    assert_eq!(std::fs::read_to_string(replays.join("MIGRATIONS")).unwrap(), "0000-baseline\n0001-encode\n");
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn a_migration_must_say_why_and_rewrite_inputs_only() {
    let root = temporary("parse");
    migration(&root, "0001-results", r#"{"kind": "rewrite", "why": "x", "ops": ["in.result"], "replace": [{"old": "a", "new": "b"}]}"#);
    assert!(load(&root).unwrap_err().to_string().contains("open.*"));
    std::fs::remove_file(root.join("0001-results.json")).unwrap();
    migration(&root, "0001-silent", r#"{"kind": "baseline"}"#);
    assert!(load(&root).unwrap_err().to_string().contains("no why"));
    std::fs::remove_dir_all(&root).unwrap();
}

/// The code's wire generation has its dictionary checked in, which the current table only extends (names and layouts
/// are appended, never moved: src/wire/registry.txt), and the last migration naming the wire names this generation: a
/// breaking change ships with the migration that converts the corpus (docs/replay.md, Migrations).
#[test]
fn the_current_schema_has_its_dictionary_and_migration() {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/replay-migrations");
    let current = schema(wire::VERSION);
    let snapshot = directory.join("wire").join(format!("{current}.json"));
    let (version, checked) = dictionary(&snapshot).unwrap_or_else(|_| panic!("no dictionary for this generation: write it with \
        `dispatch-helper capture dictionary {}` and add a wire migration naming fingerprint wire = {current}", directory.join("wire").display()));
    assert_eq!(version, wire::VERSION);
    assert!(body::SYMBOLS.starts_with(checked.symbols), "a wire name moved or went: src/wire/registry.txt is append-only");
    assert!(body::RECORDS.starts_with(checked.records), "a record layout moved or went: src/wire/registry.txt is append-only");
    let declared = load(&directory).unwrap().into_iter().rev()
        .find_map(|migration| migration.fingerprints.into_iter().find(|(name, _)| name == "wire").map(|(_, hash)| hash));
    assert_eq!(declared.as_deref(), Some(current.as_str()), "the last migration naming the wire names another generation");
}

/// Names keep their numbers whatever is appended: the table is in number order, and lookups go through the sorted order.
#[test]
fn every_wire_name_encodes_as_its_permanent_number() {
    for (number, name) in body::SYMBOLS.iter().enumerate() {
        assert_eq!(body::symbol(name), Some(number as u16), "{name}");
    }
    assert_eq!(body::symbol("not a wire name"), None);
}
