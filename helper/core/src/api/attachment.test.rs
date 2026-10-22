use super::*;

const ROOT: &str = "/home/sam/.dispatch/attachments";
const FOLDER: &str = "0123456789abcdef0123456789abcdef";
const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";

fn path(name: &str) -> String {
    format!("{ROOT}/{FOLDER}/{name}")
}

#[test]
fn stored_names_keep_only_plain_characters_and_the_extension() {
    assert_eq!(clean("diagram.png"), "diagram.png");
    assert_eq!(clean("/Users/sam/Desktop/diagram.png"), "diagram.png");
    assert_eq!(clean("../../etc/passwd"), "passwd");
    assert_eq!(clean("..hidden.txt"), "hidden.txt");
    assert_eq!(clean("a\nb\0c\u{7f}.txt"), "a_b_c_.txt");
    assert_eq!(clean("Notes from Sam.pdf"), "Notes_from_Sam.pdf");
    // A macOS screenshot name (U+202F before AM), shell metacharacters, quotes, bidi and line
    // separators: one `_` per run.
    assert_eq!(clean("Screenshot 2026-10-22 at 10.00.00\u{202f}AM.png"), "Screenshot_2026-10-22_at_10.00.00_AM.png");
    assert_eq!(clean("$(rm -rf ~);`id`'\"x\".png"), "_rm_-rf_id_x_.png");
    assert_eq!(clean("evil\u{202e}gnp.txt"), "evil_gnp.txt");
    assert_eq!(clean("a\u{2028}b.md"), "a_b.md");
    assert_eq!(clean("snake_case__name.rs"), "snake_case__name.rs");
    for empty in ["", "..", "dir/", "\n\t", " . "] {
        assert_eq!(clean(empty), "attachment", "{empty:?}");
    }
    let long = format!("{}.jpeg", "é".repeat(200));
    assert_eq!(clean(&long), "_.jpeg");
    let long = format!("{}.jpeg", "a".repeat(400));
    let kept = clean(&long);
    assert!(kept.len() == 255 && kept.ends_with(".jpeg"), "{kept}");
    for name in [kept.as_str(), "Notes_from_Sam.pdf", "_rm_-rf_id_x_.png", "a.b.c"] {
        assert_eq!(clean(name), name, "a clean name stays as it is");
    }
}

#[test]
fn shown_names_are_the_users_without_controls_bidi_or_line_separators() {
    assert_eq!(shown("/Users/sam/Desktop/Notes from Sam.pdf", "Notes_from_Sam.pdf"), "Notes from Sam.pdf");
    assert_eq!(shown("evil\u{202e}gnp.txt", "evil_gnp.txt"), "evilgnp.txt");
    assert_eq!(shown("a\u{2028}b\nc\u{2066}.md", "x"), "abc.md");
    assert_eq!(shown("$(id).png", "_id_.png"), "$(id).png");
    assert_eq!(shown("\u{202e}", "attachment"), "attachment");
    assert!(shown(&"é".repeat(300), "x").len() <= 255);
}

#[test]
fn an_image_needs_its_signature_and_a_matching_extension() {
    assert!(image("a.png", PNG));
    assert!(image("A.PNG", PNG));
    assert!(image("photo.jpg", &[0xff, 0xd8, 0xff, 0xe0]));
    assert!(image("photo.JPEG", &[0xff, 0xd8, 0xff, 0xdb]));
    assert!(image("anim.gif", b"GIF89a\x01\0"));
    assert!(image("sticker.webp", b"RIFF\x10\0\0\0WEBPVP8 "));
    assert!(!image("a.jpg", PNG), "a PNG under a JPEG name");
    assert!(!image("a.png.txt", PNG));
    assert!(!image("a", PNG));
    assert!(!image("a.png", b"not a png"));
    assert!(!image("a.webp", b"RIFF\x10\0\0\0WAVE"));
    assert!(!image("a.heic", b"\0\0\0\x18ftypheic"));
}

#[test]
fn only_the_shape_put_makes_is_a_stored_attachment() {
    let root = Path::new(ROOT);
    assert_eq!(stored(root, &path("diagram.png")), Some((FOLDER, "diagram.png")));
    assert_eq!(stored(root, &path("Notes_from_Sam.pdf")), Some((FOLDER, "Notes_from_Sam.pdf")));
    for bad in [
        format!("{ROOT}/{FOLDER}"),
        format!("{ROOT}/{FOLDER}/"),
        format!("{ROOT}/{FOLDER}/../{FOLDER}/a.png"),
        format!("{ROOT}/{FOLDER}/sub/a.png"),
        format!("{ROOT}/{}/a.png", FOLDER.to_uppercase()),
        format!("{ROOT}/{}/a.png", &FOLDER[1..]),
        format!("{ROOT}/../attachments/{FOLDER}/a.png"),
        format!("{ROOT}/{FOLDER}/.hidden"),
        format!("{ROOT}/{FOLDER}/a\nb.png"),
        format!("{ROOT}x/{FOLDER}/a.png"),
        format!("/home/eve/.dispatch/attachments/{FOLDER}/a.png"),
        format!("{ROOT}/{FOLDER}/.."),
        format!("{ROOT}/{FOLDER}/Notes from Sam.pdf"),
        "relative/a.png".into(),
    ] {
        assert_eq!(stored(root, &bad), None, "{bad}");
    }
    assert_eq!(super::root(Path::new("/home/sam/.dispatch/state")), Path::new(ROOT));
}

#[test]
fn the_fallback_puts_one_path_per_line_after_the_text() {
    let (a, b) = (path("notes.txt"), path("diagram.png"));
    assert_eq!(fallback("Look", &[]), "Look");
    assert_eq!(fallback("Look", &[&a, &b]), format!("Look\n\n{a}\n{b}"));
    assert_eq!(fallback("", &[&a]), a);
    assert_eq!(fallback("  \n", &[&a]), a);
}

fn root() -> Option<&'static Path> {
    Some(Path::new(ROOT))
}

#[test]
fn history_splits_the_fallback_back_into_blocks() {
    let (a, b) = (path("notes.txt"), path("diagram.png"));
    let (text, blocks) = typed(root(), &fallback("Look at\n\nthese", &[&a, &b]), &[]);
    assert_eq!(text, "Look at\n\nthese");
    assert_eq!(
        blocks,
        [block(Some(&a), Some("notes.txt"), false), block(Some(&b), Some("diagram.png"), true)]
    );
    assert_eq!(typed(root(), &a, &[]), (String::new(), vec![block(Some(&a), Some("notes.txt"), false)]));
    // A command-like text went fenced, its path lines after the fence: the fenced text stays.
    let fenced = format!("```\n/compact these\n```\n\n{a}");
    assert_eq!(typed(root(), &fenced, &[]).0, "```\n/compact these\n```");
    // Another account's root, or no root at all, is the user's text.
    let other = format!("/Users/sam/.dispatch/attachments/{FOLDER}/a.txt");
    for (root, text) in [(root(), format!("x\n\n{other}")), (None, format!("x\n\n{a}"))] {
        assert_eq!(typed(root, &text, &[]), (text.clone(), Vec::new()), "{text}");
    }
    // A path the user typed is text: no empty line before it, or not the stored shape.
    for text in [format!("see\n{a}"), format!("see\n\n{a}\nthanks"), "see\n\n/tmp/a.txt".into(), "plain".into()] {
        assert_eq!(typed(root(), &text, &[]), (text.clone(), Vec::new()), "{text}");
    }
}

#[test]
fn placeholders_before_the_text_stand_for_as_many_images() {
    let one = [None];
    let two = [None, None];
    assert_eq!(typed(root(), "[Image #1] [Image #2]Describe these", &two).0, "Describe these");
    assert_eq!(typed(root(), "[Image #12] [Image #13] Describe", &two).0, "Describe");
    assert_eq!(typed(root(), "[Image #3]", &one), (String::new(), vec![block(None, None, true)]));
    // No more placeholders than images: the user typed the rest.
    assert_eq!(typed(root(), "[Image #1] [Image #2] x", &one).0, "[Image #2] x");
    assert_eq!(typed(root(), "[Image #1] hi", &[]).0, "[Image #1] hi");
    assert_eq!(typed(root(), "look at [Image #1]", &one).0, "look at [Image #1]");
    assert_eq!(typed(root(), "[Image #] x", &one).0, "[Image #] x");
    assert_eq!(typed(root(), "  plain", &[]).0, "  plain");
}

#[test]
fn images_claude_left_as_paths_lead_the_text() {
    let (a, b, c) = (path("a.png"), path("b.png"), path("notes.txt"));
    // a.png stayed in the composer as its path, b.png became [Image #1], then the text.
    for text in [
        format!("{a} [Image #1] Describe\n\n{c}"),
        format!("{a}[Image #1]Describe\n\n{c}"),
        format!("[Image #1] {a} Describe\n\n{c}"),
    ] {
        let (kept, blocks) = typed(root(), &text, &[None]);
        assert_eq!(kept, "Describe", "{text}");
        assert_eq!(
            blocks,
            [block(None, None, true), block(Some(&a), Some("a.png"), true), block(Some(&c), Some("notes.txt"), false)]
        );
    }
    // Both left as paths, pasted one after the other.
    let (kept, blocks) = typed(root(), &format!("{a}{b} Look"), &[]);
    assert_eq!((kept.as_str(), blocks.len()), ("Look", 2));
    // A stored path that runs on into other text is the user's.
    let text = format!("{a}#x Look");
    assert_eq!(typed(root(), &text, &[]).0, text);
}

#[test]
fn side_information_only_for_messages_that_can_hold_attachments() {
    assert_eq!(attached("hello", None, Vec::new()), None);
    assert_eq!(attached("[Image]", Some(String::new()), vec![None]), Some(Box::new(Attached { text: Some(String::new()), images: vec![None] })));
    assert_eq!(attached("x", Some("x".into()), vec![None]), Some(Box::new(Attached { text: None, images: vec![None] })));
    let line = format!("Look\n\n{}", path("a.txt"));
    assert_eq!(attached(&line, None, Vec::new()), Some(Box::new(Attached { text: None, images: Vec::new() })));
}
