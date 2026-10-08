//! Native tool fields; shared display grammars handle shell and patch text.
use dispatch_helper_core::{
    api::{Block, Document, DocumentKind, Record, RecordKind, Tool},
    json::{Data, Format, Json, Kind, Value, write_with},
    tool,
};
use std::path::Path;

pub fn status(value: &str, started: bool) -> String {
    if matches!(
        value,
        "generating" | "applying" | "completed" | "failed" | "declined" | "interrupted"
    ) {
        value.to_owned()
    } else if started {
        "applying".into()
    } else {
        "completed".into()
    }
}

/// c1654cc ToolPresentation.swift:158-169: only the exact shell -c/-lc form unwraps; other argv is shell-quoted.
pub(crate) fn command(value: Value<'_>) -> Option<String> {
    let words = value.string().and_then(crate::command::words);
    let arguments = if let Some(words) = &words {
        words.iter().map(String::as_str).collect()
    } else if let Some(command) = value.string() {
        return Some(command.into());
    } else {
        value.array()?.map(Value::string).collect::<Option<Vec<_>>>()?
    };
    match arguments[..] {
        [] => value.string().map(str::to_owned),
        [shell, "-c" | "-lc", command]
            if matches!(
                shell.rsplit('/').next(),
                Some("sh" | "bash" | "zsh" | "dash" | "fish")
            ) =>
        {
            Some(command.into())
        }
        _ if value.string().is_some() => value.string().map(str::to_owned),
        _ => Some(
            arguments
                .iter()
                .map(|argument| {
                    if !argument.is_empty()
                        && argument.bytes().all(|byte| {
                            byte.is_ascii_alphanumeric() || b"_./:@%+=,-".contains(&byte)
                        })
                    {
                        (*argument).to_owned()
                    } else {
                        format!("'{}'", argument.replace('\'', "'\\''"))
                    }
                })
                .collect::<Vec<_>>()
                .join(" "),
        ),
    }
}

/// Foundation printable: strings stay raw, other values are pretty sorted JSON; c1654cc TranscriptReader.swift:203-208.
pub fn printable(value: Value<'_>) -> String {
    value.string().map(str::to_owned).unwrap_or_else(|| {
        value
            .write_with(Format::PrettySorted)
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .unwrap_or_default()
    })
}

/// Display-only decoding of native function output; c1654cc ToolOutput.swift:5-131.
#[derive(Default)]
struct Output {
    blocks: Vec<Block>,
    code: Option<i64>,
    failed: bool,
    running: bool,
}

impl Output {
    fn append(&mut self, other: Output) {
        self.blocks.extend(other.blocks);
        if self.code.is_none_or(|code| code == 0) {
            self.code = other.code.or(self.code);
        }
        self.failed |= other.failed;
        self.running |= other.running;
    }

    /// Exact observed transport header: `<status>\nWall time <n> seconds\nOutput:\n` or `Wall time: <n> seconds\nOutput:`.
    fn header(raw: &str) -> Option<(&str, &str)> {
        fn seconds(rest: &str) -> Option<&str> {
            let end = rest.find(|c: char| !c.is_ascii_digit() && c != '.')?;
            let (whole, fraction) = rest[..end].split_once('.').unwrap_or((&rest[..end], "0"));
            if whole.is_empty() || fraction.is_empty() || fraction.contains('.') {
                return None;
            }
            rest[end..].strip_prefix(" seconds\nOutput:")
        }
        if let Some(rest) = raw.strip_prefix("Wall time: ") {
            let rest = seconds(rest)?;
            return (rest.is_empty() || rest.starts_with('\n'))
                .then(|| ("", rest.get(1..).unwrap_or("")));
        }
        let (status, rest) = raw.split_once('\n')?;
        if !matches!(
            status,
            "Script completed" | "Script failed" | "Script terminated"
        ) && status
            .strip_prefix("Script running with cell ID ")
            .is_none_or(str::is_empty)
        {
            return None;
        }
        Some((
            status,
            seconds(rest.strip_prefix("Wall time ")?)?.strip_prefix('\n')?,
        ))
    }

    fn decode(raw: &str, depth: usize, prose: bool) -> Output {
        let document = Json::parse(raw.as_bytes()).ok();
        let value = document.as_ref().map(Json::root);
        let fallback = || Output {
            blocks: if raw.is_empty() {
                Vec::new()
            } else if value.is_some() {
                vec![Block::Code {
                    language: "json".into(),
                    text: raw.into(),
                }]
            } else if prose {
                vec![Block::Markdown(raw.into())]
            } else {
                vec![Block::Code {
                    language: "text".into(),
                    text: raw.into(),
                }]
            },
            ..Output::default()
        };
        if depth >= 6 {
            return fallback();
        }
        if let Some(object) = value.filter(|value| value.object().is_some()) {
            if let Some(output) = object.get("output").and_then(Value::string)
                && (object.get("exit_code").is_some()
                    || object.get("chunk_id").is_some()
                    || object.get("wall_time_seconds").is_some()
                    || object.get("session_id").and_then(Value::signed).is_some())
            {
                let mut result = Output::decode(output, depth + 1, false);
                let exit = object.get("exit_code").and_then(Value::signed);
                result.code = exit.or(result.code);
                result.failed |= result.code.is_some_and(|code| code != 0);
                result.running |=
                    object.get("session_id").and_then(Value::signed).is_some() && exit.is_none();
                return result;
            }
            if let Some(content) = object.get("content").and_then(objects)
                && (content.iter().any(|item| Content::read(*item).is_some())
                    || object.get("structuredContent").is_some()
                    || object.get("isError").and_then(Value::boolean).is_some())
            {
                let mut result = Output::items(&content, depth);
                result.failed |= object.get("isError").and_then(Value::boolean) == Some(true);
                // Structured data can add information absent from the text.
                if let Some(structured) = object
                    .get("structuredContent")
                    .filter(|value| value.kind() != Kind::Null)
                {
                    result.blocks.push(Block::Code {
                        language: "json".into(),
                        text: printable(structured),
                    });
                }
                return result;
            }
        }
        if let Some(items) = value.and_then(objects).filter(|items| !items.is_empty()) {
            if items
                .iter()
                .all(|item| item.get("type").and_then(Value::string).is_some())
                && items.iter().any(|item| Content::read(*item).is_some())
            {
                return Output::items(&items, depth);
            }
            fn status(item: Value<'_>) -> Option<&str> {
                item.get("status").and_then(Value::string)
            }
            if items.iter().all(|item| {
                status(*item) == Some("fulfilled") && item.get("value").is_some()
                    || status(*item) == Some("rejected") && item.get("reason").is_some()
            }) {
                let mut result = Output::default();
                for item in items {
                    if let Some(reason) = item
                        .get("reason")
                        .filter(|_| status(item) == Some("rejected"))
                    {
                        result.failed = true;
                        result.blocks.push(Block::Code {
                            language: "text".into(),
                            text: "Request failed: ".to_owned() + &printable(reason),
                        });
                    } else {
                        result.append(Output::decode(
                            &printable(item.get("value").unwrap()),
                            depth + 1,
                            false,
                        ));
                    }
                }
                return result;
            }
        }
        // Exact observed transport headers only; a program's own Output: line is not an envelope.
        if raw.starts_with("Chunk ID:")
            && let Some((header, rest)) = raw.split_once("\nOutput:\n")
        {
            let code = header
                .split('\n')
                .find_map(|line| line.strip_prefix("Process exited with code "))
                .and_then(|code| code.parse::<i64>().ok());
            let mut result = Output::decode(rest, depth + 1, false);
            result.code = code.or(result.code);
            result.failed |= code.is_some_and(|code| code != 0);
            result.running |=
                code.is_none() && header.contains("\nProcess running with session ID ");
            return result;
        }
        if let Some((status, rest)) = Output::header(raw) {
            let mut result = Output::decode(rest, depth + 1, prose);
            result.failed |= status == "Script failed";
            let notice = if status.starts_with("Script running ") {
                result.running = true;
                "Tools are still running\u{2026}"
            } else if status == "Script terminated" {
                "Tool activity stopped"
            } else {
                ""
            };
            if !notice.is_empty() {
                result.blocks.insert(0, Block::Attachment(notice.into()));
            }
            return result;
        }
        fallback()
    }

    fn items(items: &[Value<'_>], depth: usize) -> Output {
        let mut result = Output::default();
        for item in items {
            match Content::read(*item) {
                Some(Content::Text(text)) => result.append(Output::decode(text, depth + 1, true)),
                Some(Content::Attachment(text)) => {
                    result.blocks.push(Block::Attachment(text.into()))
                }
                // Future or malformed items stay visible.
                None => result.blocks.push(Block::Code {
                    language: "json".into(),
                    text: printable(*item),
                }),
            }
        }
        result
    }
}

/// Foundation `as? [[String: Any]]`: every element must be an object.
fn objects(value: Value<'_>) -> Option<Vec<Value<'_>>> {
    value
        .array()?
        .map(|item| item.object().map(|_| item))
        .collect()
}

/// Recognition and rendering share one validation; c1654cc ToolOutput.swift:95-117.
enum Content<'a> {
    Text(&'a str),
    Attachment(&'static str),
}

impl<'a> Content<'a> {
    fn read(item: Value<'a>) -> Option<Self> {
        let has = |key| item.get(key).and_then(Value::string).is_some();
        Some(match item.get("type")?.string()? {
            "input_text" | "output_text" | "text" => Content::Text(item.get("text")?.string()?),
            "input_image" if has("image_url") => {
                Content::Attachment("Image \u{b7} available in Tool details")
            }
            "image" if has("data") => Content::Attachment("Image \u{b7} available in Tool details"),
            "input_audio" if has("audio_url") => {
                Content::Attachment("Audio \u{b7} available in Tool details")
            }
            "audio" if has("data") => Content::Attachment("Audio \u{b7} available in Tool details"),
            "encrypted_content" if has("encrypted_content") => {
                Content::Attachment("Encrypted content")
            }
            _ => return None,
        })
    }
}

pub fn changes(value: Value<'_>) -> Option<Vec<Document>> {
    let values = if let Some(values) = value.array() {
        values
            .map(|change| {
                Some((
                    change.get("path")?.string()?,
                    change
                        .get("kind")
                        .and_then(|kind| kind.get("type"))
                        .and_then(Value::string),
                    change
                        .get("kind")
                        .and_then(|kind| kind.get("movePath"))
                        .and_then(Value::string),
                    change.get("diff")?.string()?,
                ))
            })
            .collect::<Option<Vec<_>>>()?
    } else {
        let mut values = value
            .object()?
            .map(|(path, change)| {
                let kind = change.get("type")?.string()?;
                Some((
                    path,
                    Some(kind),
                    change.get("move_path").and_then(Value::string),
                    change
                        .get(if kind == "update" {
                            "unified_diff"
                        } else {
                            "content"
                        })?
                        .string()?,
                ))
            })
            .collect::<Option<Vec<_>>>()?;
        values.sort_by_key(|value| value.0);
        values
    };
    Some(
        values
            .into_iter()
            .map(|(path, kind, moved, diff)| {
                let kind = match kind {
                    Some("add") => Some(DocumentKind::Add),
                    Some("delete") => Some(DocumentKind::Delete),
                    Some("update") => Some(DocumentKind::Update),
                    _ => None,
                };
                let diff = if matches!(kind, Some(DocumentKind::Add | DocumentKind::Delete)) {
                    let mut lines: Vec<_> = if diff.is_empty() {
                        Vec::new()
                    } else {
                        diff.split('\n').collect()
                    };
                    if diff.ends_with('\n') {
                        lines.pop();
                    }
                    let adding = kind == Some(DocumentKind::Add);
                    let range = if adding {
                        format!("-0,0 +1,{}", lines.len())
                    } else {
                        format!("-1,{} +0,0", lines.len())
                    };
                    let lines = lines
                        .into_iter()
                        .map(|line| format!("{}{line}", if adding { '+' } else { '-' }))
                        .collect::<Vec<_>>();
                    format!("@@ {range} @@\n{}", lines.join("\n"))
                } else {
                    diff.into()
                };
                Document {
                    path: moved.unwrap_or(path).into(),
                    kind,
                    diff,
                    workdir: None,
                }
            })
            .collect(),
    )
}

/// The record id of a tool call or item (Codex call_id / item id); old ChatItem "tool-" + id.
pub fn record(id: &str) -> String {
    format!("tool-{id}")
}

pub fn item(value: Value<'_>, started: bool) -> Option<Record> {
    let id = value.get("id")?.string()?;
    let mut record = Record {
        id: record(id),
        kind: RecordKind::Tool,
        ..Record::default()
    };
    match value.get("type")?.string()? {
        "fileChange" | "FileChange" => {
            let status = value.get("status").and_then(Value::string).unwrap_or("");
            let mut record = change(id, value.get("changes")?, self::status(status, started))?;
            // TranscriptReader.swift:165-167: the present stdout/stderr strings, joined by newline.
            let streams = ["stdout", "stderr"].map(|key| value.get(key).and_then(Value::string));
            record.output = streams.into_iter().flatten().collect::<Vec<_>>().join("\n");
            return Some(record);
        }
        "commandExecution" | "CommandExecution" => {
            let raw = value.get("command")?;
            command(raw)?;
            let cwd = value.get("cwd").and_then(Value::string);
            let mut input = vec![("command", Data::Value(raw))];
            if let Some(cwd) = cwd {
                input.push(("cwd", Data::String(cwd)));
            }
            record.text =
                String::from_utf8(write_with(&Data::Object(input), Format::PrettySorted).ok()?)
                    .ok()?;
            record.title = "Shell".into();
            record.output = value
                .get("aggregatedOutput")
                .or_else(|| value.get("aggregated_output"))
                .or_else(|| value.get("formattedOutput"))
                .or_else(|| value.get("formatted_output"))
                .and_then(Value::string)
                .map(str::to_owned)
                .unwrap_or_else(|| {
                    ["stdout", "stderr"]
                        .into_iter()
                        .filter_map(|key| value.get(key).and_then(Value::string))
                        .collect::<Vec<_>>()
                        .join("\n")
                });
            record.completed =
                !started && value.get("status").and_then(Value::string) != Some("inProgress");
            // Native user-shell output is a command result, not a model tool call.
            if record.completed
                && value.get("source").and_then(Value::string).is_some_and(|source| {
                    source.to_lowercase().replace('_', "") == "usershell"
                })
            {
                record.kind = RecordKind::Output;
                record.text = record.output.clone();
            }
            record.exit_code = value
                .get("exitCode")
                .or_else(|| value.get("exit_code"))
                .and_then(Value::signed)
                .and_then(|code| code.try_into().ok());
        }
        _ => return None,
    }
    decorate(&mut record);
    Some(record)
}

pub fn change(id: &str, value: Value<'_>, status: String) -> Option<Record> {
    let mut record = Record {
        id: record(id),
        kind: RecordKind::Tool,
        title: "apply_patch".into(),
        documents: changes(value)?,
        completed: matches!(status.as_str(), "completed" | "failed" | "declined"),
        exit_code: matches!(status.as_str(), "failed" | "declined").then_some(1),
        patch: Some(status),
        ..Record::default()
    };
    decorate(&mut record);
    Some(record)
}

/// JSON5 as Foundation's `.json5Allowed` reads a Code Mode argument (ToolOrchestration.swift:109),
/// rewritten to JSON: comments, identifier keys, single-quoted strings with JSON5 escapes,
/// trailing commas, hexadecimal, plus-signed and leading/trailing-dot numbers. Infinity and NaN
/// have no JSON form, so such an argument is not shown as a request.
fn json5(text: &str) -> Option<String> {
    let chars: Vec<char> = text.chars().collect();
    let next = |from: usize| {
        chars[from.min(chars.len())..]
            .iter()
            .find(|c| !c.is_whitespace())
            .copied()
    };
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    for _ in 0..=chars.len() {
        let Some(&c) = chars.get(index) else {
            return Some(out);
        };
        let word: String = chars[index..]
            .iter()
            .take_while(|c| c.is_alphanumeric() || matches!(c, '_' | '$' | '.' | '+' | '-'))
            .collect();
        match c {
            '/' if chars.get(index + 1) == Some(&'/') => {
                index += chars[index..]
                    .iter()
                    .position(|c| *c == '\n')
                    .unwrap_or(chars.len() - index);
            }
            '/' if chars.get(index + 1) == Some(&'*') => {
                let end = chars[index + 2..]
                    .windows(2)
                    .position(|pair| pair == ['*', '/'])?;
                index += end + 4;
            }
            '"' | '\'' => {
                out.push('"');
                index += 1;
                for _ in 0..chars.len() {
                    let ch = *chars.get(index)?;
                    index += 1;
                    match ch {
                        _ if ch == c => break,
                        '"' => out.push_str("\\\""),
                        '\\' => {
                            let escaped = *chars.get(index)?;
                            index += 1;
                            match escaped {
                                '\n' => {}
                                '\r' => index += usize::from(chars.get(index) == Some(&'\n')),
                                '\'' => out.push('\''),
                                'x' => {
                                    let hex: String = chars.get(index..index + 2)?.iter().collect();
                                    out.push_str(&format!("\\u00{}", hex));
                                    index += 2;
                                }
                                _ => {
                                    out.push('\\');
                                    out.push(escaped);
                                }
                            }
                        }
                        _ => out.push(ch),
                    }
                }
                out.push('"');
            }
            ',' if matches!(next(index + 1), Some('}' | ']')) => index += 1,
            _ if c == '_' || c == '$' || c.is_alphabetic() => {
                let name: String = word
                    .chars()
                    .take_while(|c| c.is_alphanumeric() || matches!(c, '_' | '$'))
                    .collect();
                index += name.chars().count();
                if next(index) == Some(':') {
                    out.push_str(&format!("\"{name}\""));
                } else if matches!(name.as_str(), "true" | "false" | "null") {
                    out.push_str(&name);
                } else {
                    return None;
                }
            }
            '+' | '-' | '.' | '0'..='9' => {
                index += word.chars().count();
                let (sign, body) = match word.strip_prefix('-') {
                    Some(body) => ("-", body),
                    None => ("", word.strip_prefix('+').unwrap_or(&word)),
                };
                let number = match body.strip_prefix("0x").or_else(|| body.strip_prefix("0X")) {
                    Some(hex) => u64::from_str_radix(hex, 16).ok()?.to_string(),
                    None => {
                        let body = if body.starts_with('.') {
                            format!("0{body}")
                        } else {
                            body.to_owned()
                        };
                        let body = body
                            .strip_suffix('.')
                            .map_or(body.clone(), |body| format!("{body}.0"));
                        body.parse::<f64>().ok().filter(|value| value.is_finite())?;
                        body
                    }
                };
                out.push_str(sign);
                out.push_str(&number);
            }
            _ => {
                out.push(c);
                index += 1;
            }
        }
    }
    Some(out)
}

/// Literal `tools.<name>(<object or string>)` calls in Code Mode source with their char ranges
/// (`tools` through `)`), for display only: no evaluation; templates and regex literals give up;
/// at most 32; c1654cc ToolOrchestration.swift:42-118. Arguments are JSON5 like the old parser.
pub(crate) fn extract(source: &str) -> Vec<(Record, std::ops::Range<usize>)> {
    if source.len() > 131_072 {
        return Vec::new();
    }
    let chars: Vec<char> = source.chars().collect();
    let identifier = |c: char| c.is_alphanumeric() || c == '_' || c == '$';
    let whitespace = |index: &mut usize| {
        let skipped = chars[(*index).min(chars.len())..]
            .iter()
            .take_while(|c| c.is_whitespace())
            .count();
        *index += skipped;
    };
    // Past a quoted string starting at `index`; false if it never closes.
    let quoted = |index: &mut usize| {
        let quote = chars[*index];
        *index += 1;
        for _ in 0..=chars.len() {
            match chars.get(*index) {
                None => return false,
                Some('\\') => *index += 2,
                Some(&c) if c == quote => {
                    *index += 1;
                    return true;
                }
                Some(_) => *index += 1,
            }
        }
        false
    };
    let mut requests = Vec::new();
    let mut index = 0;
    for _ in 0..=chars.len() {
        let Some(&c) = chars.get(index) else {
            break;
        };
        match c {
            '`' => return Vec::new(),
            '"' | '\'' => {
                if !quoted(&mut index) {
                    return Vec::new();
                }
                continue;
            }
            '/' if chars.get(index + 1) == Some(&'/') => {
                index += chars[index..].iter().take_while(|c| **c != '\n').count();
                continue;
            }
            '/' if chars.get(index + 1) == Some(&'*') => {
                let Some(end) = (index + 2..chars.len().saturating_sub(1))
                    .find(|at| chars[*at] == '*' && chars[*at + 1] == '/')
                else {
                    return Vec::new();
                };
                index = end + 2;
                continue;
            }
            '/' => return Vec::new(),
            _ if !identifier(c) => {
                index += 1;
                continue;
            }
            _ => {}
        }
        let start = index;
        index += chars[index..]
            .iter()
            .take_while(|c| identifier(**c))
            .count();
        if chars[start..index].iter().collect::<String>() != "tools" {
            continue;
        }
        // Reject other.tools and other?.tools.
        let before = chars[..start].iter().rev().find(|c| !c.is_whitespace());
        if before == Some(&'.') {
            continue;
        }
        whitespace(&mut index);
        if chars.get(index) != Some(&'.') {
            continue;
        }
        index += 1;
        whitespace(&mut index);
        let name_start = index;
        index += chars[index..]
            .iter()
            .take_while(|c| identifier(**c))
            .count();
        let name: String = chars[name_start..index].iter().collect();
        if name.is_empty() {
            continue;
        }
        whitespace(&mut index);
        if chars.get(index) != Some(&'(') {
            continue;
        }
        index += 1;
        whitespace(&mut index);
        let argument_start = index;
        match chars.get(index) {
            None => return Vec::new(),
            Some('{') => {
                let mut depth = 0;
                for _ in 0..=chars.len() {
                    match chars.get(index) {
                        Some('"' | '\'') => {
                            if !quoted(&mut index) {
                                return Vec::new();
                            }
                        }
                        Some(c) => {
                            depth += match c {
                                '{' => 1,
                                '}' => -1,
                                _ => 0,
                            };
                            index += 1;
                        }
                        None => break,
                    }
                    if depth == 0 || index >= chars.len() {
                        break;
                    }
                }
                if depth != 0 {
                    return Vec::new();
                }
            }
            Some('"' | '\'') => {
                if !quoted(&mut index) {
                    return Vec::new();
                }
            }
            Some(_) => continue,
        }
        let argument: String = chars[argument_start..index].iter().collect();
        whitespace(&mut index);
        if chars.get(index) != Some(&')') {
            continue;
        }
        let Some(value) = json5(&argument).and_then(|text| Json::parse(text.as_bytes()).ok())
        else {
            continue;
        };
        let root = value.root();
        let text = match root.string() {
            Some(patch) if name == "apply_patch" => patch.to_owned(),
            _ if root.object().is_some() => printable(root),
            _ => continue,
        };
        let mut record = Record {
            id: format!("request-{start}"),
            kind: RecordKind::Tool,
            title: name,
            text,
            ..Record::default()
        };
        decorate(&mut record);
        requests.push((record, start..index + 1));
        if requests.len() >= 32 {
            break;
        }
    }
    requests
}

/// The pretty input of a JSON call, else its raw text (TranscriptParser.printable).
fn input(document: &Option<Json>, text: &str) -> String {
    let pretty = document
        .as_ref()
        .and_then(|document| write_with(&Data::Value(document.root()), Format::PrettySorted).ok());
    pretty
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .unwrap_or_else(|| text.to_owned())
}

/// c1654cc WebToolPresentation (ToolPresentation.swift:269-335): a Codex web call's actions,
/// from its arguments only. Claude's WebSearch/WebFetch are native presentations there.
fn web(title: &str, root: Option<Value<'_>>) -> Option<Tool> {
    let name = title.to_lowercase();
    if name != "web.run" && name != "web__run" && !name.ends_with(".web__run") {
        return None;
    }
    // NSNumber.stringValue for numbers and booleans.
    let value = |row: Value<'_>, key: &str| match row.get(key) {
        Some(value) if value.string().is_some() => value.string().unwrap().to_owned(),
        Some(value) if value.boolean().is_some() => u8::from(value.boolean().unwrap()).to_string(),
        Some(value) => value
            .signed()
            .map(|number| number.to_string())
            .or_else(|| value.number().map(|number| number.to_string()))
            .unwrap_or_default(),
        None => String::new(),
    };
    // URL(string:) with an http(s) scheme; anything else is a search result identifier.
    let page = |row: Value<'_>| {
        let reference = value(row, "ref_id");
        let scheme = reference
            .split_once(':')
            .map(|(scheme, _)| scheme.to_lowercase());
        match scheme.as_deref() {
            Some("https" | "http") => reference,
            _ => "Search result".to_owned(),
        }
    };
    let kinds = [
        "search_query",
        "image_query",
        "open",
        "find",
        "click",
        "screenshot",
        "weather",
        "finance",
        "sports",
        "time",
    ];
    let mut actions: Vec<(&str, String, bool)> = Vec::new();
    for kind in kinds {
        // `as? [[String: Any]]`: every row must be an object.
        let rows = root.and_then(|root| root.get(kind)).and_then(Value::array);
        let rows: Vec<Value<'_>> = rows.map(Iterator::collect).unwrap_or_default();
        if rows.iter().any(|row| row.kind() != Kind::Object) {
            continue;
        }
        for row in rows {
            let has = |key| row.get(key).is_some();
            let (title, detail) = match kind {
                "search_query" => ("Search web", value(row, "q")),
                "image_query" => ("Search images", value(row, "q")),
                "open" => {
                    let line = if has("lineno") {
                        format!(" · line {}", value(row, "lineno"))
                    } else {
                        String::new()
                    };
                    ("Open page", page(row) + &line)
                }
                "find" => (
                    "Find on page",
                    format!("“{}” · {}", value(row, "pattern"), page(row)),
                ),
                "click" => {
                    let link = if has("id") {
                        format!(" · link {}", value(row, "id"))
                    } else {
                        String::new()
                    };
                    ("Follow link", page(row) + &link)
                }
                "screenshot" => {
                    let number = row.get("pageno").and_then(Value::signed);
                    let suffix = number
                        .map(|number| format!(" · page {}", number + 1))
                        .unwrap_or_default();
                    ("View screenshot", page(row) + &suffix)
                }
                "weather" => ("Check weather", value(row, "location")),
                "finance" => ("Look up prices", value(row, "ticker")),
                "sports" => {
                    let parts = [
                        value(row, "league").to_uppercase(),
                        value(row, "team"),
                        value(row, "fn"),
                    ];
                    let parts: Vec<_> = parts.into_iter().filter(|part| !part.is_empty()).collect();
                    ("Look up sports", parts.join(" · "))
                }
                _ => ("Check time", format!("UTC{}", value(row, "utc_offset"))),
            };
            actions.push((
                title,
                detail,
                matches!(kind, "search_query" | "image_query"),
            ));
        }
    }
    let search = !actions.is_empty() && actions.iter().all(|action| action.2);
    let titles: std::collections::BTreeSet<_> = actions.iter().map(|action| action.0).collect();
    let same = titles.len() == 1;
    let descriptions: Vec<String> = actions
        .iter()
        .take(3)
        .map(|(title, detail, _)| {
            let detail = detail.split_whitespace().collect::<Vec<_>>().join(" ");
            match (same, detail.is_empty()) {
                (true, _) => detail,
                (false, true) => title.to_string(),
                (false, false) => format!("{title}: {detail}"),
            }
        })
        .collect();
    let more = if actions.len() > 3 {
        format!(" · +{} more", actions.len() - 3)
    } else {
        String::new()
    };
    Some(Tool {
        kind: "tool".into(),
        title: if same { actions[0].0 } else { "Web" }.into(),
        symbol: if search { "magnifyingglass" } else { "globe" }.into(),
        summary: if actions.is_empty() {
            "Web request".into()
        } else {
            descriptions.join(" · ") + &more
        },
        ..Tool::default()
    })
}

/// ToolPresentation.swift:59-69,76-81: request_user_input shows its questions and, once its
/// output answers them, each question with its answer as the output.
fn questions(root: Option<Value<'_>>, output: &mut Output) -> Option<Tool> {
    // `as? [[String: Any]]`: every element an object.
    let objects = |value: Value<'_>| {
        value
            .array()
            .is_some_and(|mut values| values.all(|value| value.kind() == Kind::Object))
    };
    let questions: Vec<Value<'_>> = root?
        .get("questions")
        .filter(|value| objects(*value))?
        .array()?
        .collect();
    let joined = output
        .blocks
        .iter()
        .map(text)
        .collect::<Vec<_>>()
        .join("\n\n");
    let document = Json::parse(joined.as_bytes()).ok();
    let answers = document
        .as_ref()
        .and_then(|document| document.root().get("answers"))
        .filter(|answers| {
            answers
                .object()
                .is_some_and(|mut fields| fields.all(|(_, answer)| answer.kind() == Kind::Object))
        });
    let field =
        |question: &Value<'_>, key| question.get(key).and_then(Value::string).map(str::to_owned);
    if let Some(answers) = answers {
        let rows = questions.iter().filter_map(|question| {
            let (id, title) = (field(question, "id")?, field(question, "question")?);
            let given = answers.get(&id).and_then(|answer| answer.get("answers"));
            let given: Vec<&str> = given
                .and_then(Value::array)
                .and_then(|values| values.map(Value::string).collect::<Option<_>>())
                .unwrap_or_default();
            let secret = question.get("isSecret").and_then(Value::boolean) == Some(true);
            let answer = match (given.is_empty(), secret) {
                (true, _) => "Skipped".to_owned(),
                (false, true) => "Private answer sent".to_owned(),
                (false, false) => given.join(", "),
            };
            Some(format!("{title}\n{answer}"))
        });
        let text = rows.collect::<Vec<_>>().join("\n\n");
        output.blocks = vec![Block::Code {
            language: "text".into(),
            text,
        }];
    }
    let texts = |key| {
        questions
            .iter()
            .filter_map(|question| field(question, key))
            .collect::<Vec<_>>()
    };
    Some(Tool {
        kind: "tool".into(),
        title: if answers.is_some() {
            "Questions answered"
        } else {
            "Questions"
        }
        .into(),
        symbol: "questionmark.bubble".into(),
        summary: texts("header").join(", "),
        input: if answers.is_some() {
            String::new()
        } else {
            texts("question").join("\n\n")
        },
        language: "text".into(),
        ..Tool::default()
    })
}

/// A block's text (ToolOutput.Block.text).
fn text(block: &Block) -> &str {
    match block {
        Block::Code { text, .. } | Block::Markdown(text) | Block::Attachment(text) => text,
    }
}

pub fn decorate(record: &mut Record) {
    if record.kind != RecordKind::Tool {
        return;
    }
    let document = Json::parse(record.text.as_bytes()).ok();
    let root = document.as_ref().map(Json::root);
    let name = record.title.rsplit('.').next().unwrap_or("").to_lowercase();
    let directory = root
        .and_then(|root| root.get("workdir").or_else(|| root.get("cwd")))
        .and_then(Value::string)
        .map(Path::new);
    let command = root
        .and_then(|root| {
            root.get("cmd")
                .or_else(|| root.get("command"))
                .or_else(|| root.array().map(|_| root))
        })
        .and_then(command)
        .or_else(|| {
            (document.is_none()
                && matches!(
                    name.as_str(),
                    "shell" | "exec_command" | "shell_command" | "bash"
                ))
            .then(|| record.text.clone())
        });
    // Code Mode wrappers show their literal requests, never documents; ToolPresentation.swift:37-49.
    let orchestration = matches!(name.as_str(), "exec" | "js" | "javascript");
    let mutation = matches!(name.as_str(), "edit" | "multiedit" | "write");
    if record.documents.is_empty() && mutation {
        let documents = (|| {
            let root = root?;
            let path = root
                .get("file_path")?
                .string()
                .filter(|path| !path.is_empty())?;
            let edits = if name == "multiedit" {
                let edits: Vec<_> = root.get("edits")?.array()?.collect();
                if edits.is_empty() {
                    return None;
                }
                edits
            } else {
                vec![root]
            };
            let mut hunks = Vec::new();
            for edit in edits {
                let (old, new, heading) = if name == "write" {
                    let content = edit.get("content")?.string()?;
                    (
                        "",
                        content,
                        if content.is_empty() {
                            "Written content (empty)"
                        } else {
                            "Written content"
                        },
                    )
                } else {
                    (
                        edit.get("old_string")?.string()?,
                        edit.get("new_string")?.string()?,
                        if edit.get("replace_all").and_then(Value::boolean) == Some(true) {
                            "Replace all occurrences"
                        } else {
                            "Replacement"
                        },
                    )
                };
                let mut lines = vec![format!("@@ {heading} @@")];
                for (prefix, content) in [("-", old), ("+", new)] {
                    if !content.is_empty() {
                        lines.extend(
                            content
                                .strip_suffix('\n')
                                .unwrap_or(content)
                                .split('\n')
                                .map(|line| format!("{prefix}{line}")),
                        );
                    }
                }
                hunks.push(lines.join("\n"));
            }
            Some(vec![Document {
                path: path.into(),
                workdir: directory.map(Path::to_owned),
                diff: hunks.join("\n"),
                ..Document::default()
            }])
        })();
        record.documents = documents.unwrap_or_default();
    }
    if record.documents.is_empty() && !orchestration && !mutation {
        let input = root
            .and_then(|root| {
                ["patch", "input", "cmd", "command"]
                    .into_iter()
                    .find_map(|key| root.get(key).and_then(Value::string))
            })
            .unwrap_or(&record.text);
        record.documents = tool::patch(input, directory);
        if record.documents.is_empty()
            && (record.output.contains("+++ ") || record.output.contains("*** Update File: "))
        {
            record.documents = tool::patch(&record.output, directory);
        }
        if record.documents.is_empty()
            && let Some(path) = root.and_then(|root| {
                ["file_path", "path", "file_name"]
                    .into_iter()
                    .find_map(|key| root.get(key).and_then(Value::string))
            })
        {
            record.documents.push(Document {
                path: path.into(),
                workdir: directory.map(Path::to_owned),
                ..Document::default()
            });
        }
    }
    let patch = matches!(name.as_str(), "apply_patch" | "patch")
        || mutation && !record.documents.is_empty();
    let mut output = Output::decode(&record.output, 0, false);
    let mut presentation = if let Some(tool) = (name == "request_user_input")
        .then(|| questions(root, &mut output))
        .flatten()
    {
        tool
    } else if orchestration {
        let code = root
            .and_then(|root| root.get("code"))
            .and_then(Value::string)
            .unwrap_or(&record.text);
        let children: Vec<Record> = extract(code)
            .into_iter()
            .map(|(record, _)| record)
            .collect();
        // ToolPresentation.swift:85-88.
        let summary = match &children[..] {
            [child] => child
                .tool
                .as_ref()
                .map(|tool| tool.summary.clone())
                .unwrap_or_default(),
            [] if record.output.is_empty() => "Agent activity".into(),
            [] => "Tool output".into(),
            _ => format!("{} operations", children.len()),
        };
        Tool {
            kind: "tool".into(),
            title: "Tools".into(),
            symbol: "wrench.and.screwdriver".into(),
            summary,
            language: "text".into(),
            orchestration: true,
            children,
            ..Tool::default()
        }
    } else if let Some(mut tool) = web(&record.title, root) {
        tool.input = input(&document, &record.text);
        tool.language = if document.is_some() { "json" } else { "text" }.into();
        tool
    } else if name == "write_stdin"
        && root
            .and_then(|root| root.get("session_id"))
            .and_then(Value::signed)
            .is_some()
        && root
            .and_then(|root| root.get("chars"))
            .is_none_or(|chars| chars.string() == Some(""))
    {
        // ToolCommandPresentation.waiting (ToolCommandPresentation.swift:12-13), chosen at
        // ToolPresentation.swift:42-44; its input stays the raw arguments.
        Tool {
            kind: "tool".into(),
            title: "Wait for command".into(),
            symbol: "hourglass".into(),
            input: record.text.clone(),
            language: if document.is_some() { "json" } else { "shell" }.into(),
            ..Tool::default()
        }
    } else if patch || !record.documents.is_empty() {
        let changed = record
            .documents
            .iter()
            .any(|document| !document.diff.is_empty());
        Tool {
            kind: if patch {
                "patch"
            } else if changed {
                "diff"
            } else {
                "read"
            }
            .into(),
            title: if patch {
                "Patch"
            } else if changed {
                "Review changes"
            } else {
                "Read"
            }
            .into(),
            symbol: if patch {
                "pencil.line"
            } else if changed {
                "doc.text.magnifyingglass"
            } else {
                "doc.text"
            }
            .into(),
            summary: record
                .documents
                .iter()
                .map(|document| document.path.as_str())
                .collect::<Vec<_>>()
                .join(", "),
            input: command.clone().unwrap_or_default(),
            language: "shell".into(),
            patch,
            ..Tool::default()
        }
    } else if let Some(command) = command {
        tool::shell(&command, directory.unwrap_or(Path::new("")))
    } else {
        Tool {
            kind: "tool".into(),
            title: if name == "write_stdin" {
                "Terminal input"
            } else if record.title.is_empty() {
                "Tool"
            } else {
                &record.title
            }
            .into(),
            symbol: "wrench.and.screwdriver".into(),
            input: input(&document, &record.text),
            language: if document.is_some() { "json" } else { "text" }.into(),
            summary: root
                .and_then(|root| root.get("description").or_else(|| root.get("query")))
                .and_then(Value::string)
                .unwrap_or("")
                .into(),
            ..Tool::default()
        }
    };
    record.blocks = output.blocks;
    record.exit_code = output
        .code
        .and_then(|code| code.try_into().ok())
        .or(record.exit_code);
    record.completed = !output.running && (record.completed || record.exit_code.is_some());
    presentation.directory = directory.map(Path::to_owned);
    presentation.failed = output.failed || record.exit_code.is_some_and(|code| code != 0);
    presentation.additions = record
        .documents
        .iter()
        .map(|document| {
            document
                .diff
                .split('\n')
                .filter(|line| line.starts_with('+'))
                .count() as u64
        })
        .sum();
    presentation.deletions = record
        .documents
        .iter()
        .map(|document| {
            document
                .diff
                .split('\n')
                .filter(|line| line.starts_with('-'))
                .count() as u64
        })
        .sum();
    record.tool = Some(presentation);
}
