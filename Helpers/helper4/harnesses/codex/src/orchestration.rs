//! Code Mode wrapper coalescing on whole pages: c1654cc ToolOrchestration.coalesced as the app
//! displayed each turn (ChatModels.swift:418). A sequential wrapper becomes the executions it ran;
//! the first keeps the wrapper's record id, later ones `<wrapper>:<request>` (the old row ids).
use crate::tools::{command, decorate, extract, printable};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Format, Json, Kind, Value},
};
use std::collections::{BTreeMap, BTreeSet};

/// ToolOrchestration.swift:122-131: the last namespace component, lowercased.
fn normalized(title: &str) -> String {
    title.rsplit('.').next().unwrap_or(title).to_lowercase()
}

fn wrapper(record: &Record) -> bool {
    record.kind == RecordKind::Tool
        && matches!(
            normalized(&record.title).as_str(),
            "exec" | "js" | "javascript"
        )
}

/// Old `(?s)/\*.*?\*/|//[^\r\n]*` removal (deliberately unaware of strings).
fn uncommented(source: &str) -> String {
    let mut out = String::new();
    let mut rest = source;
    for _ in 0..=source.len() {
        let Some(at) = rest.find('/') else {
            out.push_str(rest);
            break;
        };
        out.push_str(&rest[..at]);
        let tail = &rest[at..];
        if let Some(end) = tail.strip_prefix("/*").and_then(|body| body.find("*/")) {
            rest = &tail[end + 4..];
        } else if tail.starts_with("//") {
            rest = &tail[tail.find(['\r', '\n']).unwrap_or(tail.len())..];
        } else {
            out.push('/');
            rest = &tail[1..];
        }
    }
    out
}

/// `\A(?:\s*(?:text\s*\(\s*)?await\s+REQUEST\s*\)?\s*;?\s*)+\z`
fn awaited(source: &str) -> bool {
    let mut rest = source;
    for units in 0..=source.len() {
        rest = rest.trim_start();
        if rest.is_empty() {
            return units > 0;
        }
        let call = rest.strip_prefix("text").map(str::trim_start);
        let call = call.and_then(|call| call.strip_prefix('('));
        let unit = call.map_or(rest, str::trim_start);
        let Some(unit) = unit.strip_prefix("await") else {
            return false;
        };
        if !unit.starts_with(char::is_whitespace) {
            return false;
        }
        let Some(unit) = unit.trim_start().strip_prefix("REQUEST") else {
            return false;
        };
        let unit = unit.trim_start();
        let unit = unit.strip_prefix(')').unwrap_or(unit).trim_start();
        rest = unit.strip_prefix(';').unwrap_or(unit);
    }
    false
}

/// `[A-Za-z_$][A-Za-z0-9_$]*` prefix lengths, longest first (regex backtracking order).
fn names(code: &str) -> Vec<usize> {
    let starts = code.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_' || c == '$');
    let length = code
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '$'))
        .unwrap_or(code.len());
    if starts {
        (1..=length).rev().collect()
    } else {
        Vec::new()
    }
}

/// `awaitPromise\.(?:allSettled|all)\(\[(?:REQUEST,?)+\]\)`, returning the rest.
fn batch(code: &str) -> Option<&str> {
    let code = code.strip_prefix("awaitPromise.")?;
    let code = code
        .strip_prefix("allSettled")
        .or_else(|| code.strip_prefix("all"))?;
    let mut rest = code.strip_prefix("([")?;
    for count in 0..=code.len() {
        match rest.strip_prefix("REQUEST") {
            Some(next) => rest = next.strip_prefix(',').unwrap_or(next),
            None if count > 0 => break,
            None => return None,
        }
    }
    rest.strip_prefix("])")
}

/// `\{?text\(<value>\);?\}?\z`
fn prints(code: &str, value: &str) -> bool {
    let code = code.strip_prefix('{').unwrap_or(code);
    let Some(code) = code
        .strip_prefix("text(")
        .and_then(|code| code.strip_prefix(value))
        .and_then(|code| code.strip_prefix(')'))
    else {
        return false;
    };
    let code = code.strip_prefix(';').unwrap_or(code);
    matches!(code, "" | "}")
}

/// `for\((?:const|let)(NAME)of<source>\)` then `prints(NAME)`, trying names like the regex does.
fn iterates(code: &str, source: impl Fn(&str) -> Option<&str>) -> bool {
    let Some(code) = code.strip_prefix("for(") else {
        return false;
    };
    let Some(code) = code
        .strip_prefix("const")
        .or_else(|| code.strip_prefix("let"))
    else {
        return false;
    };
    names(code).into_iter().any(|length| {
        let (name, rest) = code.split_at(length);
        rest.strip_prefix("of")
            .and_then(&source)
            .and_then(|rest| rest.strip_prefix(')'))
            .is_some_and(|rest| prints(rest, name))
    })
}

/// ToolOrchestration.swift:23-40 on whitespace-free code: awaited batches printed whole, by a
/// loop, by forEach or by index, optionally followed by printed awaited requests.
fn printed(code: &str) -> bool {
    let unit = "text(awaitREQUEST)";
    let mut end = code.len();
    for _ in 0..=code.len() {
        let head = &code[..end];
        match head
            .strip_suffix(';')
            .and_then(|head| head.strip_suffix(unit))
        {
            Some(rest) => end = rest.len(),
            None => match head.strip_suffix(unit) {
                Some(rest) => end = rest.len(),
                None => break,
            },
        }
    }
    if end != code.len() && end != 0 && printed(&code[..end]) {
        return true;
    }
    if code
        .strip_prefix("text(")
        .and_then(batch)
        .is_some_and(|rest| matches!(rest, ")" | ");"))
    {
        return true;
    }
    if iterates(code, batch) {
        return true;
    }
    let Some(code) = code
        .strip_prefix("const")
        .or_else(|| code.strip_prefix("let"))
    else {
        return false;
    };
    let Some(&length) = names(code).first() else {
        return false;
    };
    let (name, rest) = code.split_at(length);
    let Some(tail) = rest.strip_prefix('=').and_then(batch) else {
        return false;
    };
    let tail = tail.strip_prefix(';').unwrap_or(tail);
    let each = tail
        .strip_prefix(name)
        .and_then(|tail| tail.strip_prefix(".forEach(text)"))
        .is_some_and(|tail| matches!(tail, "" | ";"));
    let indexed = (|| {
        let tail = tail.strip_prefix("for(let")?;
        let length = *names(tail).first()?;
        let (index, tail) = tail.split_at(length);
        let tail = tail.strip_prefix(&format!("=0;{index}<{name}.length;{index}++)"))?;
        Some(prints(tail, &format!("{{{index},...{name}[{index}]}}")))
    })();
    each || iterates(tail, |rest| rest.strip_prefix(name)) || indexed == Some(true)
}

/// ToolOrchestration.swift:12-21: the literal requests when the code is only those requests.
fn sequential(source: &str) -> Option<Vec<Record>> {
    let parsed = extract(source);
    if parsed.is_empty() {
        return None;
    }
    let mut chars: Vec<char> = source.chars().collect();
    for (_, range) in parsed.iter().rev() {
        chars.splice(range.clone(), "REQUEST".chars());
    }
    let remainder = uncommented(&chars.into_iter().collect::<String>());
    let code: String = remainder.chars().filter(|c| !c.is_whitespace()).collect();
    (awaited(&remainder) || printed(&code))
        .then(|| parsed.into_iter().map(|(record, _)| record).collect())
}

fn json(text: &str) -> Option<Json> {
    Json::parse(text.as_bytes()).ok()
}

/// `\AScript completed\nWall time [0-9]+(?:\.[0-9]+)? seconds\nOutput:\n\z`
fn completed(text: &str) -> bool {
    let Some(time) = text
        .strip_prefix("Script completed\nWall time ")
        .and_then(|rest| rest.strip_suffix(" seconds\nOutput:\n"))
    else {
        return false;
    };
    let (whole, fraction) = time.split_once('.').unwrap_or((time, "0"));
    let digits = |part: &str| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit());
    digits(whole) && digits(fraction)
}

/// ToolOrchestration.swift:219-247: one result per request from the wrapper output.
fn results(raw: &str, count: usize) -> Option<Vec<String>> {
    if raw.is_empty() {
        return Some(Vec::new());
    }
    let document = json(raw);
    let content = document.as_ref().map(Json::root).and_then(|root| {
        let items: Vec<Value<'_>> = root.array()?.collect();
        items
            .iter()
            .all(|item| item.kind() == Kind::Object)
            .then_some(items)
    });
    let Some(content) = content else {
        return (count == 1).then(|| vec![raw.to_owned()]);
    };
    let mut results = Vec::new();
    for item in content {
        let kind = item.get("type").and_then(Value::string).unwrap_or("");
        let text = item.get("text").and_then(Value::string);
        let text = text.filter(|_| matches!(kind, "input_text" | "output_text" | "text"))?;
        if !completed(text) {
            results.push(text.to_owned());
        }
    }
    if results.len() == 1 && count > 1 {
        let batch = json(&results[0]);
        let values: Option<Vec<String>> = batch
            .as_ref()
            .and_then(|batch| batch.root().array())
            .map(|values| values.map(printable).collect());
        if let Some(values) = values.filter(|values| values.len() == count) {
            results = values;
        }
    }
    if results.len() != count {
        return None;
    }
    let settle = |value: String| {
        let Some(document) = json(&value).filter(|document| document.root().object().is_some())
        else {
            return value;
        };
        let root = document.root();
        match (
            root.get("status").and_then(Value::string),
            root.get("value"),
            root.get("reason"),
        ) {
            (Some("fulfilled"), Some(result), _) => printable(result),
            (Some("rejected"), _, Some(reason)) => {
                let output = "Request failed: ".to_owned() + &printable(reason);
                let failed = Data::Object(vec![
                    ("output", Data::String(&output)),
                    ("exit_code", Data::Unsigned(1)),
                ]);
                json::write_with(&failed, Format::PrettySorted)
                    .ok()
                    .and_then(|bytes| String::from_utf8(bytes).ok())
                    .unwrap_or(value)
            }
            _ => value,
        }
    };
    Some(results.into_iter().map(settle).collect())
}

/// `object[first] ?? object[second]` of a JSON object.
fn field<'a>(object: Option<Value<'a>>, first: &str, second: &str) -> Option<Value<'a>> {
    object.and_then(|object| object.get(first).or_else(|| object.get(second)))
}

/// ChatPatch.isPatchOperation (ChatPatch.swift:52-55).
fn patch(record: &Record) -> bool {
    record.kind == RecordKind::Tool
        && (record.patch.is_some()
            || matches!(record.title.as_str(), "Edit" | "MultiEdit" | "Write")
            || matches!(normalized(&record.title).as_str(), "apply_patch" | "patch"))
}

/// ChatPatch.sameEdits (ChatPatch.swift:84-95): the requested patch and the applied change touch
/// the same paths with the same added and removed lines.
fn same(request: &Record, applied: &Record) -> bool {
    let parse = |record: &Record| {
        if record.documents.is_empty() {
            dispatch_helper4_core::tool::patch(&record.text, None)
        } else {
            record.documents.clone()
        }
    };
    let (mut requested, mut actual) = (
        dispatch_helper4_core::tool::patch(&request.text, None),
        parse(applied),
    );
    if requested.is_empty() || requested.len() != actual.len() {
        return false;
    }
    requested.sort_by(|left, right| left.path.cmp(&right.path));
    actual.sort_by(|left, right| left.path.cmp(&right.path));
    let edits = |diff: &str| {
        let lines = diff.split('\n').filter(|line| line.starts_with(['+', '-']));
        lines.map(str::to_owned).collect::<Vec<_>>()
    };
    requested.iter().zip(&actual).all(|(left, right)| {
        left.path == right.path
            && !edits(&left.diff).is_empty()
            && edits(&left.diff) == edits(&right.diff)
    })
}

/// ToolOrchestration.swift:202-217.
fn matches(request: &Record, execution: &Record) -> bool {
    if patch(request) {
        return patch(execution) && same(request, execution);
    }
    if !matches!(request.title.as_str(), "exec_command" | "shell_command")
        || !matches!(
            normalized(&execution.title).as_str(),
            "shell" | "bash" | "exec_command" | "shell_command"
        )
    {
        return false;
    }
    let input = json(&request.text);
    let input = input
        .as_ref()
        .map(Json::root)
        .filter(|value| value.object().is_some());
    let value = json(&execution.text);
    let value = value.as_ref().map(Json::root);
    let object = value.filter(|value| value.object().is_some());
    let actual = field(object, "cmd", "command")
        .or(value)
        .and_then(command)
        .unwrap_or_else(|| execution.text.clone());
    if field(input, "cmd", "command").and_then(command) != Some(actual) {
        return false;
    }
    let directory = |object: Option<Value<'_>>| {
        field(object, "workdir", "cwd").and_then(|value| value.string().map(str::to_owned))
    };
    match (directory(input), directory(object)) {
        (Some(wanted), Some(actual)) => wanted == actual,
        _ => true,
    }
}

/// ToolOrchestration.swift:135-199 over one turn's records; `process` holds execution process ids.
fn turn(items: Vec<Record>, process: &BTreeMap<String, String>) -> Vec<Record> {
    let mut result = Vec::new();
    let mut consumed = BTreeSet::new();
    for index in 0..items.len() {
        if consumed.contains(&index) {
            continue;
        }
        let item = &items[index];
        let source = json(&item.text);
        let code = source
            .as_ref()
            .and_then(|source| {
                source
                    .root()
                    .get("code")
                    .and_then(Value::string)
                    .map(str::to_owned)
            })
            .unwrap_or_else(|| item.text.clone());
        let Some(requests) = wrapper(item).then(|| sequential(&code)).flatten() else {
            result.push(item.clone());
            continue;
        };
        let end = (index + 1..items.len())
            .find(|at| items[*at].kind != RecordKind::Tool || wrapper(&items[*at]))
            .unwrap_or(items.len());
        let outputs = results(&item.output, requests.len());
        let envelope = |ordinal: usize| {
            outputs
                .as_ref()
                .and_then(|outputs| outputs.get(ordinal))
                .and_then(|output| json(output))
                .filter(|document| document.root().object().is_some())
        };
        let mut matched = BTreeSet::new();
        let executions: Vec<Option<usize>> = requests
            .iter()
            .enumerate()
            .map(|(ordinal, request)| {
                let envelope = envelope(ordinal);
                let session = envelope
                    .as_ref()
                    .and_then(|envelope| envelope.root().get("session_id").map(printable));
                // Long-running commands can finish after later wrappers; their handle links them.
                let limit = if session.is_none() { end } else { items.len() };
                let found = (index + 1..limit).find(|at| {
                    !consumed.contains(at)
                        && !matched.contains(at)
                        && matches(request, &items[*at])
                        && (session.is_none() || process.get(&items[*at].id) == session.as_ref())
                });
                if let Some(found) = found {
                    matched.insert(found);
                }
                found
            })
            .collect();
        if outputs.is_none() && executions.iter().any(Option::is_none) {
            result.push(item.clone());
            continue;
        }
        for (ordinal, request) in requests.iter().enumerate() {
            let envelope = envelope(ordinal);
            // Empty polling repeats chunks of the command's final output; the polling records stay.
            if request.title == "write_stdin" {
                let input = json(&request.text);
                let input = input.as_ref().map(Json::root);
                let chars = input
                    .and_then(|input| input.get("chars"))
                    .and_then(Value::string);
                let session = input
                    .and_then(|input| input.get("session_id"))
                    .map(printable);
                let root = envelope.as_ref().map(Json::root);
                let exit = root
                    .and_then(|root| root.get("exit_code"))
                    .and_then(Value::signed);
                let finished = root.is_some_and(|root| {
                    root.get("output").and_then(Value::string).is_some()
                        && (root.get("session_id").is_some() || exit.is_some())
                });
                if chars.unwrap_or("").is_empty()
                    && let Some(session) = session
                    && finished
                    && items.iter().any(|item| {
                        process.get(&item.id) == Some(&session)
                            && item.completed
                            && exit.map(|code| code as i32).or(item.exit_code) == item.exit_code
                    })
                {
                    continue;
                }
            }
            let mut record = match executions[ordinal] {
                Some(found) => {
                    consumed.insert(found);
                    items[found].clone()
                }
                None => {
                    let mut record = request.clone();
                    record.turn = item.turn.clone();
                    if let Some(output) = outputs.as_ref().and_then(|outputs| outputs.get(ordinal))
                    {
                        record.output = output.clone();
                    }
                    decorate(&mut record);
                    record
                }
            };
            record.id = match ordinal {
                0 => item.id.clone(),
                _ => format!("{}:{}", item.id, request.id),
            };
            result.push(record);
        }
    }
    result
}

/// Coalesces each turn of a page (consecutive records of one turn).
pub fn coalesce(records: Vec<Record>, process: &BTreeMap<String, String>) -> Vec<Record> {
    let mut result = Vec::new();
    let mut current: Vec<Record> = Vec::new();
    for record in records {
        if current.last().is_some_and(|last| last.turn != record.turn) {
            result.extend(turn(std::mem::take(&mut current), process));
        }
        current.push(record);
    }
    result.extend(turn(current, process));
    result
}
