use super::*;

fn binding() -> Binding {
    Binding {
        session: "4dd13d79-9d1a-4cab-8bbd-29cf0e7ec160".into(),
        transcript: Some("/home/example/.claude/projects/demo/4dd13d79.jsonl".into()),
        process: Process {
            pid: 4242, parent: 1, group: 4242, foreground: 4242, tty: 7, start: [1_800_000_000, 0],
            executable: "/opt/example/claude".into(), arguments: vec!["claude".into()], files: vec![],
        },
    }
}

#[test]
fn only_who_the_agent_is_changes_it() {
    let known = (0, binding());
    // What moves with the agent's own work: its foreground group, arguments and open files.
    let mut busy = binding();
    busy.process.foreground = 5151;
    busy.process.arguments.push("--resume".into());
    busy.process.files = vec![OpenFile { path: "/tmp/example.lock".into(), identity: FileIdentity { device: 1, inode: 2 } }];
    assert!(same_agent(&known, 0, &busy));
    // Another conversation, transcript, process, or harness is another agent.
    let mut other = binding();
    other.session = "5ee24e8a-0a1b-4dbc-9cf0-6f3a9b8c7d21".into();
    assert!(!same_agent(&known, 0, &other));
    let mut moved = binding();
    moved.transcript = Some("/home/example/.claude/projects/demo/5ee24e8a.jsonl".into());
    assert!(!same_agent(&known, 0, &moved));
    let mut restarted = binding();
    restarted.process.start = [1_800_000_100, 0];
    assert!(!same_agent(&known, 0, &restarted));
    assert!(!same_agent(&known, 1, &binding()));
}
