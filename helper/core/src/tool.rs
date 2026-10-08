//! Common display policies from c1654cc ToolDocument and ToolCommandPresentation.
//! Producers extract native fields; these functions never read files or run commands.
use crate::api::{Document, DocumentKind, ReadSelection, Tool, ToolRead, ToolSearch, ToolShell};
use std::{collections::VecDeque, path::Path};
mod command;

pub fn patch(input: &str, workdir: Option<&Path>) -> Vec<Document> {
    let mut documents: Vec<Document> = Vec::new();
    let mut old = None;
    let mut ended = false;
    let mut custom = false;
    let (mut before, mut after) = (0, 0);
    for line in input.split('\n') {
        if line == "*** End Patch" {
            ended = true;
            continue;
        }
        if ended {
            continue;
        }
        if let Some(document) = documents.last_mut()
            && ((custom && !line.starts_with("*** ")) || before > 0 || after > 0)
        {
            document.diff.push_str(line);
            document.diff.push('\n');
            if line.starts_with('-') {
                before = (before - 1).max(0);
            } else if line.starts_with('+') {
                after = (after - 1).max(0);
            } else if line.starts_with(' ') {
                before = (before - 1).max(0);
                after = (after - 1).max(0);
            }
            continue;
        }
        if line.starts_with("@@ ") && !documents.is_empty() {
            let fields: Vec<_> = line.split(' ').filter(|s| !s.is_empty()).collect();
            if fields.len() >= 4 && fields[1].starts_with('-') && fields[2].starts_with('+') {
                let count = |field: &str| {
                    let parts: Vec<_> = field[1..].split(',').filter(|s| !s.is_empty()).collect();
                    if parts.len() == 2 {
                        parts[1].parse::<i64>().unwrap_or(0)
                    } else {
                        1
                    }
                };
                before = count(fields[1]);
                after = count(fields[2]);
            }
        }
        if let Some(name) = line.strip_prefix("--- ") {
            let name = name.split('\t').next().unwrap();
            old = Some(name.strip_prefix("a/").unwrap_or(name));
        } else if let Some((name, kind)) = [
            ("*** Update File: ", DocumentKind::Update),
            ("*** Add File: ", DocumentKind::Add),
            ("*** Delete File: ", DocumentKind::Delete),
        ]
        .iter()
        .find_map(|(prefix, kind)| line.strip_prefix(prefix).map(|name| (name, *kind)))
        {
            custom = true;
            documents.push(Document {
                path: name.into(),
                kind: Some(kind),
                ..Document::default()
            });
        } else if let Some(name) = line.strip_prefix("*** Move to: ") {
            if let Some(document) = documents.last_mut() {
                document.path = name.into();
            }
        } else if let Some(name) = line.strip_prefix("+++ ") {
            let name = name.split('\t').next().unwrap();
            let path = if name == "/dev/null" {
                old.filter(|path| *path != "/dev/null")
            } else {
                Some(name.strip_prefix("b/").unwrap_or(name))
            };
            if let Some(path) = path {
                documents.push(Document {
                    path: path.into(),
                    kind: match (old, name) {
                        (_, "/dev/null") => Some(DocumentKind::Delete),
                        (Some("/dev/null"), _) => Some(DocumentKind::Add),
                        (Some(_), _) => Some(DocumentKind::Update),
                        (None, _) => None,
                    },
                    ..Document::default()
                });
            }
        } else if let Some(document) = documents.last_mut()
            && !line.starts_with("*** ")
            && !line.starts_with("--- ")
            && !line.starts_with("diff --git")
        {
            document.diff.push_str(line);
            document.diff.push('\n');
        }
    }
    let mut merged: Vec<Document> = Vec::new();
    for mut document in documents {
        document.workdir = workdir.map(Path::to_path_buf);
        if let Some(previous) = merged.iter_mut().find(|d| d.path == document.path) {
            previous.diff.push_str(&document.diff);
            if previous.kind != document.kind {
                previous.kind = None;
            }
        } else {
            merged.push(document);
        }
    }
    merged
}

/// Recognize the same literal shell subset as Dispatch. Unsupported scripts keep
/// their original command and first-line summary, including quotes and operators.
pub fn shell(input: &str, directory: &Path) -> Tool {
    let label = (|| {
        let directory = directory.to_str()?.strip_prefix('/')?;
        let text = input.trim_start_matches([' ', '\t']);
        if !text.starts_with("cd ") && !text.starts_with("cd\t") {
            return None;
        }
        let (mut quote, mut escaped) = (None, false);
        for (index, c) in text.char_indices() {
            if escaped {
                escaped = false;
            } else if let Some(current) = quote {
                if c == current {
                    quote = None;
                } else if current == '"' && c == '\\' {
                    escaped = true;
                }
            } else if newline(c) {
                return None;
            } else if c == '\\' {
                escaped = true;
            } else if matches!(c, '\'' | '"') {
                quote = Some(c);
            } else if c == ';' || c == '&' {
                let length = if c == ';' {
                    1
                } else if text[index..].starts_with("&&") {
                    2
                } else {
                    return None;
                };
                let words = words(&text[..index])?;
                let path = words.get(1)?.strip_prefix('/')?;
                if words.len() != 2
                    || path.strip_suffix('/').unwrap_or(path)
                        != directory.strip_suffix('/').unwrap_or(directory)
                {
                    return None;
                }
                let rest = text[index + length..].trim_start_matches([' ', '\t']);
                return (!rest.is_empty() && !rest.starts_with([';', '&', '|'])).then_some(rest);
            }
        }
        None
    })()
    .unwrap_or(input);
    let mut tool = if let Some(read) = read(label) {
        Tool {
            kind: "read".into(),
            title: "Read".into(),
            symbol: "doc.text".into(),
            summary: summary(&read, directory),
            read: Some(read),
            ..Tool::default()
        }
    } else if let Some(tool) = command::parse(label, directory) {
        tool
    } else {
        let executable = label
            .split_whitespace()
            .next()
            .unwrap_or("")
            .rsplit('/')
            .next()
            .unwrap();
        let (kind, title, symbol) = match executable {
            "cat" | "head" | "tail" | "sed" => ("read", "Read", "doc.text"),
            "rg" | "grep" | "find" => ("search", "Search", "magnifyingglass"),
            _ => ("shell", "Shell", "terminal"),
        };
        Tool {
            kind: kind.into(),
            title: title.into(),
            symbol: symbol.into(),
            summary: label.split('\n').next().unwrap_or("").into(),
            ..Tool::default()
        }
    };
    tool.input = input.into();
    tool.language = "shell".into();
    tool.directory = Some(directory.to_path_buf());
    let swift_tests = tool.shell.as_ref().is_some_and(|shell| shell.swift_tests);
    tool.shell = Some(ToolShell {
        command: input.into(),
        kind: tool.kind.clone(),
        swift_tests,
    });
    tool
}

fn newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

fn words(input: &str) -> Option<VecDeque<String>> {
    if input.len() > 8192 || input.chars().any(|c| newline(c) || c == '\0') {
        return None;
    }
    let mut words = VecDeque::new();
    let mut word = String::new();
    let (mut quote, mut escaped, mut started) = (None, false, false);
    for c in input.chars() {
        if escaped {
            word.push(c);
            escaped = false;
        } else if let Some(current) = quote {
            if c == current {
                quote = None;
            } else {
                if current == '"' && "$`\\".contains(c) {
                    return None;
                }
                word.push(c);
            }
        } else if c == '\\' {
            escaped = true;
            started = true;
        } else if matches!(c, '\'' | '"') {
            quote = Some(c);
            started = true;
        } else if matches!(c, ' ' | '\t') {
            if started {
                words.push_back(std::mem::take(&mut word));
                started = false;
            }
        } else {
            if "$`|&;<>()[]{}*?~#!".contains(c) {
                return None;
            }
            word.push(c);
            started = true;
        }
    }
    if quote.is_some() || escaped {
        return None;
    }
    if started {
        words.push_back(word);
    }
    Some(words)
}

fn read(input: &str) -> Option<ToolRead> {
    let mut words = words(input)?;
    let executable = words.pop_front()?;
    let number = |s: &str| {
        if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        s.parse::<u64>()
            .ok()
            .filter(|n| *n > 0 && *n <= i64::MAX as u64 - 32768)
    };
    let selection = match executable.rsplit('/').next()? {
        "cat" => ReadSelection::All,
        "sed" => {
            if words.pop_front()?.as_str() != "-n" {
                return None;
            }
            if words.front().is_some_and(|s| s == "-e") {
                words.pop_front();
            }
            let expression = words.pop_front()?;
            let range: Vec<_> = expression.strip_suffix('p')?.split(',').collect();
            if !(1..=2).contains(&range.len()) {
                return None;
            }
            let start = number(range[0])?;
            let end = number(range[range.len() - 1])?;
            if end < start {
                return None;
            }
            ReadSelection::Lines { start, end }
        }
        kind @ ("head" | "tail") => {
            let mut count = 10;
            if words
                .front()
                .is_some_and(|s| s != "--" && s.starts_with('-'))
            {
                let option = words.pop_front()?;
                let value = if option == "-n" || option == "--lines" {
                    words.pop_front()?
                } else {
                    option
                        .strip_prefix("--lines=")
                        .or_else(|| option.strip_prefix("-n"))
                        .unwrap_or(&option[1..])
                        .into()
                };
                count = number(&value)?;
            }
            if kind == "head" {
                ReadSelection::First(count)
            } else {
                ReadSelection::Last(count)
            }
        }
        _ => return None,
    };
    let terminated = words.front().is_some_and(|s| s == "--");
    if terminated {
        words.pop_front();
    }
    let path = words.pop_front()?;
    if !words.is_empty() || path.is_empty() || path == "-" || (!terminated && path.starts_with('-'))
    {
        return None;
    }
    Some(ToolRead {
        path,
        selection,
        source: false,
    })
}

/// An absolute path relative to an absolute directory, else the path as given;
/// c1654cc ToolDocument.swift displayPath.
pub fn display_path(path: &str, directory: &Path) -> String {
    let base = directory.to_string_lossy();
    if path.starts_with('/') && base.starts_with('/') {
        let parts = |path: &str| {
            let mut result = Vec::new();
            for part in path.split('/') {
                match part {
                    "" | "." => {}
                    ".." => {
                        result.pop();
                    }
                    _ => result.push(part.to_owned()),
                }
            }
            result
        };
        let (target, base) = (parts(path), parts(&base));
        let shared = target.iter().zip(&base).take_while(|(a, b)| a == b).count();
        let mut components = vec!["..".into(); base.len() - shared];
        components.extend_from_slice(&target[shared..]);
        return if components.is_empty() {
            ".".into()
        } else {
            components.join("/")
        };
    }
    path.into()
}

fn label(path: &str, directory: &Path) -> String {
    let relative = display_path(path, directory);
    if relative.starts_with('/') || relative.starts_with('~') {
        return relative;
    }
    let mut components = Vec::new();
    for part in relative.split('/').filter(|s| !s.is_empty() && *s != ".") {
        if part == ".." && components.last().is_some_and(|s| *s != "..") {
            components.pop();
        } else {
            components.push(part);
        }
    }
    if components.first() == Some(&"..") {
        relative
    } else {
        components.last().map_or(relative.clone(), |s| (*s).into())
    }
}

fn summary(read: &ToolRead, directory: &Path) -> String {
    let file = label(&read.path, directory);
    match read.selection {
        ReadSelection::All => file,
        ReadSelection::Lines { start, end } if start == end => format!("{file} · line {start}"),
        ReadSelection::Lines { start, end } => format!("{file} · lines {start}–{end}"),
        ReadSelection::First(count) | ReadSelection::Last(count) => {
            let kind = if matches!(read.selection, ReadSelection::First(_)) {
                "first"
            } else {
                "last"
            };
            format!(
                "{file} · {kind} {count} {}",
                if count == 1 { "line" } else { "lines" }
            )
        }
    }
}
