//! Chat attachments for Codex: input items, the TUI's pasted image paths, and their history.
use super::*;
use crate::history;
use dispatch_helper_core::api::attachment;
use std::{io, os::fd::RawFd, path::PathBuf, time::Instant};

const FOLDER: &str = "/home/sam/.dispatch/attachments/0123456789abcdef0123456789abcdef";

fn file(name: &str) -> Attachment {
    Attachment { path: format!("{FOLDER}/{name}"), image: name.ends_with(".png") }
}

/// Runs deferred completions; nothing else is expected.
#[derive(Default)]
struct Later(Vec<Box<dyn FnOnce(&mut dyn Io)>>);
#[rustfmt::skip]
impl Io for Later {
    fn now(&self) -> Instant { Instant::now() }
    fn timer(&mut self, _: Instant) {}
    fn defer(&mut self, work: Box<dyn FnOnce(&mut dyn Io)>) { self.0.push(work); }
    fn interest(&mut self, _: RawFd, _: bool, _: bool) -> io::Result<()> { unreachable!() }
    fn read(&mut self, _: RawFd, _: &mut [u8]) -> io::Result<usize> { unreachable!() }
    fn write(&mut self, _: RawFd, _: &[u8]) -> io::Result<usize> { unreachable!() }
    fn close(&mut self, _: RawFd) {}
    fn accept(&mut self, _: RawFd) -> io::Result<RawFd> { unreachable!() }
    fn child(&mut self, _: u32) -> io::Result<()> { unreachable!() }
    fn submit(&mut self, _: Job) -> io::Result<Work> { unreachable!() }
    fn cancel(&mut self, _: Work) -> bool { true }
    fn watch(&mut self, _: &Path, _: bool) -> io::Result<u64> { unreachable!() }
    fn unwatch(&mut self, _: u64) {}
    fn spawn(&mut self, _: Command, _: Option<Grid>) -> io::Result<Spawned> { unreachable!() }
    fn resize(&mut self, _: RawFd, _: Grid) -> io::Result<()> { unreachable!() }
    fn hangup(&mut self, _: RawFd) -> io::Result<()> { unreachable!() }
    fn connect(&mut self, _: &Address) -> io::Result<RawFd> { unreachable!() }
    fn route(&mut self) -> io::Result<(u64, PathBuf)> { unreachable!() }
    fn reply(&mut self, _: u64, _: &[u8]) -> io::Result<()> { unreachable!() }
}

fn binding() -> Binding {
    Binding {
        session: "019a0000-0000-7000-8000-000000000001".into(),
        transcript: None,
        process: Process { pid: 42, parent: 1, group: 42, foreground: 42, tty: 0, start: [5, 6], executable: "/bin/codex".into(), arguments: Vec::new(), files: Vec::new() },
    }
}

/// What the main TUI is sent for these attachments.
fn typed(text: &str, attachments: &[Attachment]) -> Vec<Input> {
    let mut io = Later::default();
    let sent = Rc::new(RefCell::new(None));
    let sink = sent.clone();
    Codex::default().send_attached(&mut io, &binding(), text, Mode::Prompt, attachments, Box::new(move |_, result| {
        *sink.borrow_mut() = Some(result);
    }));
    while let Some(work) = io.0.pop() {
        work(&mut io);
    }
    match sent.borrow_mut().take() {
        Some(Ok(Sent::Keys(keys))) => keys,
        other => panic!("{other:?}"),
    }
}

#[test]
fn the_tui_gets_each_image_path_pasted_alone_then_the_text() {
    let keys = typed("Describe these", &[file("a.png"), file("notes.txt"), file("b b.png")]);
    assert_eq!(
        keys,
        [
            Input::Paste(format!("{FOLDER}/a.png")),
            // A raw path with spaces stays text in Codex 0.163; quoted it attaches.
            Input::Paste(format!("'{FOLDER}/b b.png'")),
            Input::Paste(format!("Describe these\n\n{FOLDER}/notes.txt")),
            Input::Key(Key::Enter),
        ]
    );
    assert_eq!(typed("", &[file("a.png")]), [Input::Paste(format!("{FOLDER}/a.png")), Input::Key(Key::Enter)]);
    // Files alone: the text fenced when it starts like a command, the path lines after the
    // fence; a file without text is its path, never fenced.
    assert_eq!(
        typed("/review", &[file("notes.txt")]),
        [Input::Paste(format!("```\n/review\n```\n\n{FOLDER}/notes.txt")), Input::Key(Key::Enter)]
    );
    assert_eq!(typed("", &[file("notes.pdf")]), [Input::Paste(format!("{FOLDER}/notes.pdf")), Input::Key(Key::Enter)]);
}

#[test]
fn paths_are_quoted_the_way_the_composer_attaches_them() {
    assert_eq!(control::quoted("/a/b.png"), "/a/b.png");
    assert_eq!(control::quoted("/a/Screen Shot.png"), "'/a/Screen Shot.png'");
    assert_eq!(control::quoted("/a/Sam's shot.png"), "/a/Sam\\'s\\ shot.png");
}

#[test]
fn native_input_is_the_text_then_a_local_image_per_image() {
    let attachments = [file("a.png"), file("notes.txt")];
    let items = attached("Look", &attachments);
    let text = dispatch_helper_core::json::write(&items).unwrap();
    assert_eq!(
        String::from_utf8(text).unwrap(),
        format!(r#"[{{"type":"text","text":"Look","text_elements":[]}},{{"type":"localImage","path":"{FOLDER}/a.png"}}]"#)
    );
    let only = dispatch_helper_core::json::write(&attached(" ", &attachments[..1])).unwrap();
    assert_eq!(String::from_utf8(only).unwrap(), format!(r#"[{{"type":"localImage","path":"{FOLDER}/a.png"}}]"#));
}

#[test]
fn a_queued_message_with_images_previews_them_and_steers_again_as_it_is() {
    let input = format!(r#"[{{"type":"text","text":"Look","text_elements":[]}},{{"type":"localImage","path":"{FOLDER}/a.png"}}]"#);
    let row = format!(r#"{{"id":"q1","clientUserMessageId":"c1","input":{input}}}"#);
    let document = Json::parse(row.as_bytes()).unwrap();
    let row = queue::row(document.root()).unwrap();
    assert_eq!(row.preview, [Preview::Text("Look".into()), Preview::Attachment("localImage".into())]);
    assert!(!row.editable);
    assert!(queue::resendable(input.as_bytes()));
    let mention = r#"[{"type":"mention","name":"x","path":"app://x"}]"#;
    assert!(!queue::resendable(mention.as_bytes()));
}

/// Codex 0.163's rollout line for a TUI message with two pasted images (loopback fixture).
fn completed(text: &str) -> String {
    format!(
        r#"{{"timestamp":"2026-10-22T10:00:00.000Z","type":"event_msg","payload":{{"type":"item_completed","thread_id":"t","turn_id":"turn-1","item":{{"type":"UserMessage","id":"i1","content":[{{"type":"local_image","path":"{FOLDER}/a.png"}},{{"type":"local_image","path":"{FOLDER}/b.png"}},{{"type":"text","text":"{text}","text_elements":[{{"byte_range":{{"start":0,"end":10}},"placeholder":"[Image #1]"}}]}}]}}}}}}"#
    ) + "\n"
}

/// A user record as a chat.attachments client sees it (core attachments::view).
fn shown(record: &Record) -> (String, Vec<dispatch_helper_core::api::Block>) {
    let root = std::path::Path::new("/home/sam/.dispatch/attachments");
    match &record.attached {
        Some(attached) => attachment::typed(Some(root), attached.text.as_deref().unwrap_or(&record.text), &attached.images),
        None => (record.text.clone(), record.blocks.clone()),
    }
}

#[test]
fn history_shows_local_images_with_their_paths_and_the_typed_text() {
    let line = completed("[Image #1] [Image #2] Describe these");
    let (page, ..) = history::page([(0, line.as_bytes())], "t", None).unwrap();
    let user = page.records.iter().find(|record| record.kind == RecordKind::User).unwrap();
    // Every other client: the record as before the feature.
    assert_eq!((user.text.as_str(), user.blocks.len()), ("[Image #1] [Image #2] Describe these", 0));
    let (text, blocks) = shown(user);
    assert_eq!(text, "Describe these");
    assert_eq!(
        blocks,
        [
            attachment::block(Some(&format!("{FOLDER}/a.png")), Some("a.png"), true),
            attachment::block(Some(&format!("{FOLDER}/b.png")), Some("b.png"), true),
        ]
    );
    // The id is still the recorded text's.
    assert_eq!(user.id, format!("user-{}", history::key(b"[Image #1] [Image #2] Describe these")));
    // An older user_message event lists them in local_images; a file goes as a path line.
    let event = format!(
        r#"{{"timestamp":"2026-10-22T10:00:00.000Z","type":"event_msg","payload":{{"type":"user_message","message":"Look\n\n{FOLDER}/notes.txt","local_images":["{FOLDER}/a.png"],"images":[]}}}}"#
    ) + "\n";
    let (page, ..) = history::page([(0, event.as_bytes())], "t", None).unwrap();
    let user = page.records.iter().find(|record| record.kind == RecordKind::User).unwrap();
    assert_eq!(user.text, format!("Look\n\n{FOLDER}/notes.txt"));
    let (text, blocks) = shown(user);
    assert_eq!(text, "Look");
    assert_eq!(
        blocks,
        [
            attachment::block(Some(&format!("{FOLDER}/a.png")), Some("a.png"), true),
            attachment::block(Some(&format!("{FOLDER}/notes.txt")), Some("notes.txt"), false),
        ]
    );
    // A message without attachments carries nothing on the side.
    let plain = completed("hello").replace(&format!(r#"{{"type":"local_image","path":"{FOLDER}/a.png"}},{{"type":"local_image","path":"{FOLDER}/b.png"}},"#), "");
    let (page, ..) = history::page([(0, plain.as_bytes())], "t", None).unwrap();
    let user = page.records.iter().find(|record| record.kind == RecordKind::User).unwrap();
    assert!(user.attached.is_none());
}
