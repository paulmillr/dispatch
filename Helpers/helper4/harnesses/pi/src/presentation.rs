//! Native Pi fields feed Dispatch's common shell and patch display policies.
use crate::records::printable;
use dispatch_helper4_core::{
    api::{Document, Record, RecordKind, Tool},
    json::{Json, Value},
    tool,
};
use std::path::Path;

pub fn apply(row: &mut Record) {
    if row.kind != RecordKind::Tool || row.text.is_empty() {
        return;
    }
    let parsed = Json::parse(row.text.as_bytes()).ok();
    let value = parsed.as_ref().map(Json::root);
    let field = |key| {
        value
            .and_then(|value| value.get(key))
            .and_then(Value::string)
    };
    let directory = field("workdir").or_else(|| field("cwd")).map(Path::new);
    let command = field("cmd").or_else(|| field("command"));
    let input = field("patch")
        .or_else(|| field("input"))
        .or(command)
        .unwrap_or(&row.text);
    let name = row.title.rsplit('.').next().unwrap_or("").to_lowercase();
    let shell = matches!(
        name.as_str(),
        "shell" | "bash" | "exec_command" | "shell_command"
    );
    let mut display = if shell && (command.is_some() || parsed.is_none()) {
        tool::shell(
            command.unwrap_or(&row.text),
            directory.unwrap_or(Path::new("")),
        )
    } else {
        Tool::default()
    };
    row.documents = if display.read.is_some() {
        Vec::new()
    } else {
        tool::patch(input, field("workdir").map(Path::new))
    };
    if row.documents.is_empty()
        && (row.output.contains("+++ ") || row.output.contains("*** Update File: "))
    {
        row.documents = tool::patch(&row.output, field("workdir").map(Path::new));
    }
    if row.documents.is_empty() {
        if let Some(path) = field("file_path")
            .or_else(|| field("path"))
            .or_else(|| field("file_name"))
        {
            row.documents.push(Document {
                path: path.into(),
                workdir: field("workdir").map(Into::into),
                ..Document::default()
            });
        }
    }
    let patch = matches!(row.title.as_str(), "Edit" | "MultiEdit" | "Write")
        || matches!(name.as_str(), "apply_patch" | "patch");
    if display.title.is_empty() && !row.documents.is_empty() {
        let diff = row
            .documents
            .iter()
            .any(|document| !document.diff.is_empty());
        display.kind = if patch {
            "patch"
        } else if diff {
            "diff"
        } else {
            "read"
        }
        .into();
        display.title = if patch {
            "Patch"
        } else if diff {
            "Review changes"
        } else {
            "Read"
        }
        .into();
        display.symbol = if patch {
            "pencil.line"
        } else if diff {
            "doc.text.magnifyingglass"
        } else {
            "doc.text"
        }
        .into();
        display.summary = row
            .documents
            .iter()
            .map(|document| document.path.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        display.input = command.unwrap_or("").into();
        display.language = "shell".into();
    } else if display.title.is_empty() {
        display.kind = "tool".into();
        display.title = if row.title.is_empty() {
            "Tool"
        } else {
            &row.title
        }
        .into();
        display.symbol = "wrench.and.screwdriver".into();
        display.input = value.map(printable).unwrap_or_else(|| row.text.clone());
        display.language = if parsed.is_some() { "json" } else { "text" }.into();
        display.summary = field("description")
            .or_else(|| field("query"))
            .unwrap_or("")
            .into();
    }
    display.directory = directory.map(Path::to_path_buf);
    display.patch = patch;
    display.failed = row.exit_code.is_some_and(|code| code != 0);
    for document in &row.documents {
        display.additions += document
            .diff
            .split('\n')
            .filter(|line| line.starts_with('+'))
            .count() as u64;
        display.deletions += document
            .diff
            .split('\n')
            .filter(|line| line.starts_with('-'))
            .count() as u64;
    }
    row.tool = Some(display);
}
