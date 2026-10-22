use super::*;
use dispatch_helper_core::api::{Block, attachment};

const FOLDER: &str = "/home/sam/.dispatch/attachments/0123456789abcdef0123456789abcdef";

/// A Pi session line for a user message (Pi 1.3.0 stores ImageContent as `{type, data, mimeType}`).
fn user(content: &str) -> Record {
    let line = format!(
        r#"{{"type":"message","id":"m1","parentId":null,"timestamp":"2026-10-22T10:00:00.000Z","message":{{"role":"user","content":{content},"timestamp":1792000000000}}}}"#
    );
    let document = Json::parse(line.as_bytes()).unwrap();
    let records = project(document.root(), &mut String::new(), true);
    records.into_iter().find(|record| record.kind == RecordKind::User).unwrap()
}

/// A user record as a chat.attachments client sees it (core attachments::view).
fn shown(record: &Record) -> (String, Vec<Block>) {
    let root = std::path::Path::new("/home/sam/.dispatch/attachments");
    match &record.attached {
        Some(attached) => attachment::typed(Some(root), attached.text.as_deref().unwrap_or(&record.text), &attached.images),
        None => (record.text.clone(), record.blocks.clone()),
    }
}

#[test]
fn images_and_path_lines_become_blocks_for_attachment_clients_only() {
    let record = user(&format!(
        r#"[{{"type":"text","text":"Describe these\n\n{FOLDER}/notes.txt"}},{{"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"}}]"#
    ));
    // Every other client: the record as before the feature.
    assert_eq!((record.text.clone(), record.blocks.len()), (format!("Describe these\n\n{FOLDER}/notes.txt\n[Image]"), 0));
    let (text, blocks) = shown(&record);
    assert_eq!(text, "Describe these");
    assert_eq!(
        blocks,
        [
            attachment::block(None, None, true),
            attachment::block(Some(&format!("{FOLDER}/notes.txt")), Some("notes.txt"), false),
        ]
    );
    // Only an image: still a user message ("[Image]" for the others), with no text.
    let record = user(r#"[{"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"}]"#);
    assert_eq!(record.text, "[Image]");
    let (text, blocks) = shown(&record);
    assert_eq!((text.as_str(), blocks.len()), ("", 1));
    // Plain text is as before, with nothing on the side.
    let record = user(r#""hello""#);
    assert_eq!((record.text.as_str(), record.blocks.len(), record.attached.is_none()), ("hello", 0, true));
}
