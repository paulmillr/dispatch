//! Claude's structured tool arguments. Shared shell/patch grammars live in core.
use crate::history::text;
use dispatch_helper_core::{
    api::*,
    json::{Format, Value},
};
use std::path::Path;

pub fn project(name: &str, input: Value<'_>, cwd: Option<&str>) -> (Tool, Vec<Document>) {
    native(name, input, cwd).unwrap_or_else(|| (generic(name, input, cwd), Vec::new()))
}

fn native(name: &str, input: Value<'_>, cwd: Option<&str>) -> Option<(Tool, Vec<Document>)> {
    if name == "Bash" {
        let command = text(input, "command")?;
        let mut tool = dispatch_helper_core::tool::shell(command, Path::new(cwd.unwrap_or("")));
        tool.directory = cwd.map(Into::into);
        return Some((tool, Vec::new()));
    }
    if name == "AskUserQuestion" {
        let questions = input.get("questions")?.array()?.collect::<Vec<_>>();
        let mut headers = Vec::new();
        let mut body = Vec::new();
        for question in questions {
            if let Some(header) = text(question, "header") {
                headers.push(header);
            }
            let mut lines = vec![text(question, "question")?.to_owned()];
            for option in question
                .get("options")
                .and_then(|v| v.array())
                .into_iter()
                .flatten()
            {
                if let Some(label) = text(option, "label") {
                    let detail = text(option, "description")
                        .map(|s| format!(" — {s}"))
                        .unwrap_or_default();
                    lines.push(format!("• {label}{detail}"));
                }
            }
            body.push(lines.join("\n"));
        }
        return Some((
            Tool {
                kind: "questions".into(),
                title: "Questions".into(),
                symbol: "questionmark.bubble".into(),
                summary: headers.join(", "),
                input: body.join("\n\n"),
                language: "text".into(),
                directory: cwd.map(Into::into),
                ..Tool::default()
            },
            Vec::new(),
        ));
    }
    if name == "TodoWrite" {
        let todos = input
            .get("todos")?
            .array()?
            .map(|todo| {
                Some(format!(
                    "[{}] {}",
                    text(todo, "status")?,
                    text(todo, "content")?
                ))
            })
            .collect::<Option<Vec<_>>>()?;
        return Some((
            Tool {
                kind: "tool".into(),
                title: "Tasks".into(),
                symbol: "checklist".into(),
                summary: format!(
                    "{} {}",
                    todos.len(),
                    if todos.len() == 1 { "task" } else { "tasks" }
                ),
                input: todos.join("\n"),
                language: "text".into(),
                directory: cwd.map(Into::into),
                ..Tool::default()
            },
            Vec::new(),
        ));
    }
    if let Some(tool) = structured(name, input, cwd) {
        return Some((tool, Vec::new()));
    }
    let path = text(input, "file_path").filter(|path| !path.is_empty())?;
    let mut tool = Tool {
        language: "text".into(),
        directory: cwd.map(Into::into),
        ..Tool::default()
    };
    let mut suffix = String::new();
    let mut documents = Vec::new();
    match name {
        "Read" => {
            tool.kind = "read".into();
            tool.title = "Read".into();
            tool.symbol = "doc.text".into();
            let offset = input.get("offset").and_then(|value| value.signed());
            let start = offset.unwrap_or(1);
            let limit = input.get("limit").and_then(|value| value.signed());
            if let Some(count) =
                limit.filter(|count| start > 0 && *count > 0 && start.checked_add(*count).is_some())
            {
                suffix = if count == 1 {
                    format!("line {start}")
                } else {
                    format!("lines {start}–{}", start + count - 1)
                };
            } else if offset.is_some() {
                suffix = format!("from line {start}");
            }
            if let Some(pages) = text(input, "pages").filter(|pages| !pages.is_empty()) {
                suffix = format!("pages {pages}");
            }
        }
        "Edit" | "MultiEdit" | "Write" => {
            let edits = if name == "MultiEdit" {
                let edits = input.get("edits")?.array()?.collect::<Vec<_>>();
                if edits.is_empty() {
                    return None;
                }
                edits
            } else {
                vec![input]
            };
            let mut hunks = Vec::new();
            for edit in edits {
                let (old, new, heading) = if name == "Write" {
                    let content = text(edit, "content")?;
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
                        text(edit, "old_string")?,
                        text(edit, "new_string")?,
                        if edit.get("replace_all").and_then(|value| value.boolean()) == Some(true) {
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
                                .split_terminator('\n')
                                .map(|line| format!("{prefix}{line}")),
                        );
                    }
                }
                hunks.push(lines.join("\n"));
            }
            documents.push(Document {
                path: path.into(),
                kind: (name != "Write").then_some(DocumentKind::Update),
                diff: hunks.join("\n"),
                workdir: None,
            });
            tool.kind = "patch".into();
            tool.title = "Patch".into();
            tool.symbol = "pencil.line".into();
            tool.patch = true;
            if input.get("replace_all").and_then(|value| value.boolean()) == Some(true) {
                suffix = "replace all".into();
            }
            for line in documents
                .iter()
                .flat_map(|document| document.diff.split('\n'))
            {
                tool.additions += u64::from(line.starts_with('+'));
                tool.deletions += u64::from(line.starts_with('-'));
            }
        }
        _ => return None,
    }
    tool.summary = [label(path, cwd)?, &suffix]
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" · ");
    Some((tool, documents))
}

/// Step label of a path: its file name inside the working directory, else the whole path.
fn label<'a>(path: &'a str, cwd: Option<&str>) -> Option<&'a str> {
    if cwd.is_some_and(|cwd| Path::new(path).strip_prefix(cwd).is_ok()) {
        Path::new(path).file_name()?.to_str()
    } else {
        Some(path)
    }
}

/// Non-file native tools; c1654cc ToolPresentation.swift:207-252 (NativeToolPresentation).
fn structured(name: &str, input: Value<'_>, cwd: Option<&str>) -> Option<Tool> {
    let field = |key| text(input, key).unwrap_or("");
    let joined = |parts: &[&str]| {
        parts
            .iter()
            .filter(|s| !s.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join(" · ")
    };
    let (title, symbol, detail, body, language, path) = match name {
        "WebSearch" => {
            let query = text(input, "query")?;
            (
                "Search web",
                "magnifyingglass",
                query.into(),
                query,
                "text",
                None,
            )
        }
        "Grep" | "Glob" => {
            let pattern = text(input, "pattern")?;
            (
                if name == "Grep" {
                    "Search"
                } else {
                    "Find files"
                },
                "magnifyingglass",
                pattern.into(),
                pattern,
                "text",
                text(input, "path").filter(|path| !path.is_empty()),
            )
        }
        "WebFetch" => (
            "Open page",
            "globe",
            text(input, "url")?.into(),
            field("prompt"),
            "text",
            None,
        ),
        "Agent" | "Task" => {
            let prompt = text(input, "prompt")?;
            (
                "Agent",
                "person.2",
                field("description").into(),
                prompt,
                "text",
                None,
            )
        }
        "TaskCreate" | "TaskUpdate" | "TaskGet" | "TaskList" | "TaskOutput" | "TaskStop" => (
            match name {
                "TaskCreate" => "Create task",
                "TaskUpdate" => "Update task",
                "TaskGet" => "Read task",
                "TaskList" => "List tasks",
                "TaskOutput" => "Task output",
                _ => "Stop task",
            },
            if name == "TaskStop" {
                "stop.circle"
            } else {
                "checklist"
            },
            joined(&[
                field("subject"),
                field("taskId"),
                field("task_id"),
                field("status"),
            ]),
            field("description"),
            "text",
            None,
        ),
        "Skill" => (
            "Skill",
            "book",
            text(input, "skill")?.into(),
            field("args"),
            "text",
            None,
        ),
        "EnterPlanMode" => (
            "Enter plan mode",
            "list.bullet",
            String::new(),
            field("plan"),
            "text",
            None,
        ),
        "ExitPlanMode" => (
            "Review plan",
            "list.bullet",
            String::new(),
            field("plan"),
            "markdown",
            None,
        ),
        "NotebookEdit" => (
            "Edit notebook",
            "pencil.line",
            String::new(),
            text(input, "new_source")?,
            "text",
            Some(text(input, "notebook_path")?),
        ),
        _ => return None,
    };
    let suffix = match name {
        "NotebookEdit" => {
            let cell = text(input, "cell_id").map(|cell| format!("cell {cell}"));
            joined(&[cell.as_deref().unwrap_or(""), field("edit_mode")])
        }
        "Grep" | "Glob" => joined(&[field("glob"), field("type")]),
        _ => String::new(),
    };
    // A search names the directory it ran in, not one file.
    let file = match path {
        Some(path) if matches!(name, "Grep" | "Glob") => format!(
            "in {}",
            dispatch_helper_core::tool::display_path(path, Path::new(cwd.unwrap_or("")))
        ),
        Some(path) => label(path, cwd)?.into(),
        None => String::new(),
    };
    Some(Tool {
        kind: "tool".into(),
        title: title.into(),
        symbol: symbol.into(),
        summary: joined(&[&detail, &file, &suffix]),
        input: body.into(),
        language: language.into(),
        directory: cwd.map(Into::into),
        ..Tool::default()
    })
}

/// Any other call keeps the old app's generic card (c1654cc ToolPresentation.swift:119-124):
/// its name, a description or query, and the input as JSON.
fn generic(name: &str, input: Value<'_>, cwd: Option<&str>) -> Tool {
    Tool {
        kind: "tool".into(),
        title: name.into(),
        symbol: "wrench.and.screwdriver".into(),
        summary: text(input, "description")
            .or_else(|| text(input, "query"))
            .unwrap_or("")
            .into(),
        input: input
            .write_with(Format::PrettySorted)
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .unwrap_or_default(),
        language: "json".into(),
        directory: cwd.map(Into::into),
        ..Tool::default()
    }
}
