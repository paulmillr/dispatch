use super::*;

/// A transcript's first lines as Pi 1.5 writes them: the header, its settings, then the conversation.
fn transcript(lines: &[&str]) -> Vec<u8> {
    let mut bytes = br#"{"type":"session","version":3,"id":"s1","timestamp":"2026-11-10T10:00:00.000Z","cwd":"/home/sam/app"}"#.to_vec();
    for line in lines {
        bytes.push(b'\n');
        bytes.extend_from_slice(line.as_bytes());
    }
    bytes
}

const MODEL: &str = r#"{"type":"model_change","id":"a1","parentId":null,"timestamp":"2026-11-10T10:00:00.001Z","provider":"anthropic","modelId":"model"}"#;

/// An unnamed session is titled by its first user message as one line, as Pi's own session list labels it: settings
/// and the agent's messages before it are skipped, text blocks join, white space and control characters fold.
#[test]
fn first_prompt_titles_an_unnamed_session() {
    let bytes = transcript(&[
        MODEL,
        r#"{"type":"message","id":"m1","parentId":"a1","timestamp":"2026-11-10T10:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Ready."}]}}"#,
        r#"{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-11-10T10:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"Fix the\n\tlogin  bug"},{"type":"text","text":"in auth.rs"}]}}"#,
        r#"{"type":"message","id":"m3","parentId":"m2","timestamp":"2026-11-10T10:00:03.000Z","message":{"role":"user","content":"Later prompt"}}"#,
    ]);
    assert_eq!(first_prompt(&bytes).as_deref(), Some("Fix the login bug in auth.rs"));
    // A head cut inside a line still finds a prompt in a complete one; none yet is no title.
    assert_eq!(first_prompt(&transcript(&[MODEL])), None);
    let cut = transcript(&[r#"{"type":"message","id":"m2","parentId":null,"message":{"role":"user","content":"Fix"#]);
    assert_eq!(first_prompt(&cut), None);
}

/// A title is one line of at most `TITLE` characters, a longer one cut at a word with "…".
#[test]
fn titles_are_one_bounded_line() {
    assert_eq!(title("  \n "), None);
    assert_eq!(title("Rename\u{7}the tab").as_deref(), Some("Rename the tab"));
    let long = "word ".repeat(40);
    let cut = title(&long).unwrap();
    assert!(cut.ends_with("word…"), "{cut}");
    assert!(cut.chars().count() <= TITLE + 1, "{cut}");
    let unbroken = "x".repeat(150);
    assert_eq!(title(&unbroken).unwrap().chars().count(), TITLE + 1);
}
