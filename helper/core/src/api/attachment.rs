//! Files a client uploaded for a chat message (feature `chat.attachments`). The helper keeps a
//! private copy at `<home>/.dispatch/attachments/<32 hex>/<name>`; a message names that copy, and
//! the agent reads it natively (an image) or through its tools (a path line after the text).
use super::Block;
use std::path::{Path, PathBuf};

/// The largest attachment (the app's ChatAttachment.limit).
pub const LIMIT: u64 = 8 << 20;
/// The most attachments one message takes (ChatAttachment.maximumCount).
pub const COUNT: usize = 10;
/// The folder under the account's Dispatch directory.
pub const DIRECTORY: &str = "attachments";
/// Extensions an agent recognises as an image in a pasted path (Claude Code 2.1.302:
/// `/\.(png|jpe?g|gif|webp)$/i`).
const IMAGES: &[&str] = &["png", "jpg", "jpeg", "gif", "webp"];

/// An attachment as history shows it (Block::File): an image or another file, its stored path
/// when known and its name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Shown {
    pub image: bool,
    pub path: Option<String>,
    pub name: Option<String>,
}

/// One stored attachment as a message names it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attachment {
    pub path: String,
    /// Image bytes under an image name: agents attach it natively; anything else is a file.
    pub image: bool,
}

impl Attachment {
    pub fn name(&self) -> &str {
        self.path.rsplit('/').next().unwrap_or_default()
    }
}

/// `<home>/.dispatch/attachments` for the account's `Io::storage` (`<home>/.dispatch/state`).
pub fn root(storage: &Path) -> PathBuf {
    storage.parent().unwrap_or(storage).join(DIRECTORY)
}

/// Characters a stored name keeps; anything else becomes `_`. The name on the host is cosmetic
/// (the reply's `name` is what the app shows), and an agent gets it as a raw path: no shell
/// metacharacters, quotes, spaces, bidi or line separators.
fn plain(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')
}

/// Characters a shown name drops: controls, bidi controls and line/paragraph separators.
fn hidden(c: char) -> bool {
    c.is_control()
        || matches!(c, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{2028}' | '\u{2029}')
}

/// At most 255 bytes, the extension (up to 16 bytes) kept.
fn bounded(mut name: String) -> String {
    if name.len() > 255 {
        let extension = name.rsplit_once('.').map(|(_, ext)| ext).filter(|ext| ext.len() <= 16).unwrap_or("");
        let suffix = if extension.is_empty() { String::new() } else { format!(".{extension}") };
        let mut end = 255 - suffix.len();
        while !name.is_char_boundary(end) {
            end -= 1;
        }
        name = format!("{}{suffix}", &name[..end]);
    }
    name
}

/// A stored name: the last path component without leading dots, every run of characters other
/// than `[A-Za-z0-9._-]` (spaces too) one `_`, at most 255 bytes (the extension kept);
/// `attachment` when nothing is left.
pub fn clean(raw: &str) -> String {
    let last = raw.rsplit('/').next().unwrap_or_default();
    let last = last.trim_matches(|c: char| c.is_whitespace() || hidden(c)).trim_start_matches('.');
    let mut name = String::with_capacity(last.len());
    let mut replaced = false;
    for c in last.chars() {
        if plain(c) {
            name.push(c);
            replaced = false;
        } else if !replaced {
            name.push('_');
            replaced = true;
        }
    }
    let name = bounded(name);
    if name.is_empty() { "attachment".into() } else { name }
}

/// The name the app shows for an upload: the last path component as the user had it, without
/// control, bidi or line separator characters, at most 255 bytes; `stored` (the stored name)
/// when nothing is left.
pub fn shown(raw: &str, stored: &str) -> String {
    let last = raw.rsplit('/').next().unwrap_or_default();
    let kept: String = last.chars().filter(|c| !hidden(*c)).collect();
    let name = bounded(kept.trim().to_owned());
    if name.is_empty() { stored.to_owned() } else { name }
}

/// Whether `head` (the file's first bytes) starts with a PNG, JPEG, GIF or WebP signature that
/// matches the name's extension.
pub fn image(name: &str, head: &[u8]) -> bool {
    let extension = name.rsplit_once('.').map(|(_, ext)| ext.to_ascii_lowercase()).unwrap_or_default();
    match extension.as_str() {
        "png" => head.starts_with(b"\x89PNG\r\n\x1a\n"),
        "jpg" | "jpeg" => head.starts_with(&[0xff, 0xd8, 0xff]),
        "gif" => head.starts_with(b"GIF87a") || head.starts_with(b"GIF89a"),
        "webp" => head.len() >= 12 && head.starts_with(b"RIFF") && &head[8..12] == b"WEBP",
        _ => false,
    }
}

/// Whether a name looks like an image to an agent (its extension only).
pub fn image_name(name: &str) -> bool {
    name.rsplit_once('.').is_some_and(|(_, ext)| IMAGES.iter().any(|known| ext.eq_ignore_ascii_case(known)))
}

/// The folder and name of `path` when it is exactly `<root>/<32 lowercase hex>/<name>` with a
/// name `clean` keeps as it is; anything else (another root, `..`, more components) is None.
pub fn stored<'a>(root: &Path, path: &'a str) -> Option<(&'a str, &'a str)> {
    let rest = path.strip_prefix(root.to_str()?)?.strip_prefix('/')?;
    let (folder, name) = rest.split_once('/')?;
    (folder.len() == 32 && folder.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) && clean(name) == name)
        .then_some((folder, name))
}

/// The text an agent without native attachments gets: the paths after the text, one per line
/// (only the paths when there is no text).
pub fn fallback(text: &str, paths: &[&str]) -> String {
    if paths.is_empty() {
        return text.to_owned();
    }
    let lines = paths.join("\n");
    if text.trim().is_empty() { lines } else { format!("{text}\n\n{lines}") }
}

/// A block for an attachment as history shows it.
pub fn block(path: Option<&str>, name: Option<&str>, image: bool) -> Block {
    Block::File(Shown { image, path: path.map(str::to_owned), name: name.map(str::to_owned) })
}

/// A block for a stored copy named by its path (an image by its name).
fn named(path: &str) -> Block {
    let name = path.rsplit('/').next().unwrap_or_default();
    block(Some(path), Some(name), image_name(name))
}

/// The stored copy `text` starts with under `root` and the text after it: the root, 32 hex, and
/// a stored name (it ends before the first character a stored name never has). It must end
/// there: at the end, before white space, another path or a placeholder.
fn leading<'a>(root: &Path, text: &'a str) -> Option<(&'a str, &'a str)> {
    let rest = text.strip_prefix(root.to_str()?)?.strip_prefix('/')?;
    let folder = rest.get(..32)?;
    let name = rest.get(32..)?.strip_prefix('/')?;
    let name = &name[..name.find(|c: char| !plain(c)).unwrap_or(name.len())];
    let end = text.len() - rest.len() + 33 + name.len();
    let (path, after) = text.split_at(end);
    let bounded = after.is_empty() || after.starts_with(|c: char| c.is_whitespace() || c == '/' || c == '[');
    (bounded && stored(root, path) == Some((folder, name))).then_some((path, after))
}

/// `text` after one image placeholder (`[Image #n]`) it starts with.
fn placeholder(text: &str) -> Option<&str> {
    let tail = text.strip_prefix("[Image #")?;
    let digits = tail.bytes().take_while(u8::is_ascii_digit).count();
    tail[digits..].strip_prefix(']').filter(|_| digits > 0)
}

/// What a message starts with before the typed text: at most `images` image placeholders
/// (Claude Code's `[Image #n]`, one per image it attached) and stored paths under `root` (an
/// image Claude Code did not attach stays in the composer as its path), in any order. The text
/// after them, and those paths in order.
fn lead<'a>(root: Option<&Path>, text: &'a str, images: usize) -> (&'a str, Vec<&'a str>) {
    let (mut rest, mut count, mut paths) = (text, 0, Vec::new());
    loop {
        let trimmed = rest.trim_start();
        if count < images
            && let Some(after) = placeholder(trimmed)
        {
            (rest, count) = (after, count + 1);
        } else if let Some((path, after)) = root.and_then(|root| leading(root, trimmed)) {
            paths.push(path);
            rest = after;
        } else {
            break;
        }
    }
    if count == 0 && paths.is_empty() { (text, paths) } else { (rest.trim_start(), paths) }
}

/// The user's text without the trailing `fallback` lines under `root` (after an empty line, or
/// the whole text), and those paths. A text without them comes back unchanged.
fn split<'a>(root: Option<&Path>, text: &'a str) -> (&'a str, Vec<&'a str>) {
    let Some(root) = root else { return (text, Vec::new()) };
    let lines: Vec<&str> = text.split('\n').collect();
    let count = lines.iter().rev().take_while(|line| stored(root, line).is_some()).count();
    let start = lines.len() - count;
    // The paths stand alone, or after the text and one empty line.
    if count == 0 || (start > 0 && (start < 2 || !lines[start - 1].is_empty())) {
        return (text, Vec::new());
    }
    let kept = lines[..start.saturating_sub(1)].iter().map(|line| line.len() + 1).sum::<usize>();
    (&text[..kept.saturating_sub(1)], lines[start..].to_vec())
}

/// What a harness knows of a user record's attachments beyond its text, for clients of
/// chat.attachments (dispatch/attachments.rs `view`); never encoded: other clients get the
/// record as it always was.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Attached {
    /// The message's own text when the record's text differs from it (Claude and Pi show an
    /// image as an `[Image]` line there); None: the record's text.
    pub text: Option<String>,
    /// The images the agent attached, in order: a local image's path, None for one it keeps as
    /// data only.
    pub images: Vec<Option<String>>,
}

/// The side information for a user record whose text (as encoded for every client) is
/// `record`, its message text `text` (None: the same) and images: None when the message can
/// hold no attachment (no image, no stored path in its text).
pub fn attached(record: &str, text: Option<String>, images: Vec<Option<String>>) -> Option<Box<Attached>> {
    let source = text.as_deref().unwrap_or(record);
    if images.is_empty() && !source.contains("/.dispatch/attachments/") {
        return None;
    }
    let text = text.filter(|text| text != record);
    Some(Box::new(Attached { text, images }))
}

/// A user message as its sender typed it, from what an agent recorded: the text without the
/// image placeholders and stored paths before it and the `fallback` lines after it (paths under
/// `root`, the helper's own attachments root; None strips no path), and a block per image the
/// agent attached (its path when the agent kept one), then per path.
pub fn typed(root: Option<&Path>, text: &str, images: &[Option<String>]) -> (String, Vec<Block>) {
    let (rest, before) = lead(root, text, images.len());
    let (kept, after) = split(root, rest);
    let image = |path: &Option<String>| {
        let name = path.as_deref().and_then(|path| path.rsplit('/').next()).map(str::to_owned);
        Block::File(Shown { image: true, path: path.clone(), name })
    };
    let blocks = images.iter().map(image).chain(before.into_iter().chain(after).map(named)).collect();
    (kept.to_owned(), blocks)
}

#[cfg(test)]
#[path = "attachment.test.rs"]
mod tests;
