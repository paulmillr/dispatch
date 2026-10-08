use super::*;

pub(super) fn parse(input: &str, directory: &Path) -> Option<Tool> {
    if input.len() > 8192 {
        return None;
    }
    if input.chars().any(newline) {
        let lines: Vec<_> = input.split(newline).filter(|s| !s.is_empty()).collect();
        if lines.len() <= 1 {
            return lines.first().and_then(|line| parse(line, directory));
        }
        let (mut descriptions, mut reads) = (Vec::new(), Vec::new());
        for line in lines.iter().take(3) {
            if let Some(read) = read(line) {
                let text = summary(&read, directory);
                descriptions.push(format!("Read {text}"));
                reads.push(text);
            } else if let Some(tool) = parse(line, directory) {
                let detail = if tool.summary.is_empty() {
                    String::new()
                } else {
                    format!(" · {}", tool.summary)
                };
                descriptions.push(tool.title + &detail);
            } else {
                break;
            }
        }
        if descriptions.is_empty() {
            return None;
        }
        let (kind, title, symbol, text) = if reads.len() == lines.len() {
            ("reads", "Read files", "doc.text", reads.join(" · "))
        } else {
            if descriptions.len() < lines.len() {
                descriptions.push("additional commands".into());
            }
            (
                "commands",
                "Run commands",
                "terminal",
                descriptions.join(" · "),
            )
        };
        return Some(Tool {
            kind: kind.into(),
            title: title.into(),
            symbol: symbol.into(),
            summary: text,
            ..Tool::default()
        });
    }
    let mut words = words(input)?;
    let executable = words.pop_front()?;
    let executable = executable.rsplit('/').next()?;
    let (kind, title, symbol, text) = if matches!(executable, "rg" | "grep") {
        let files = executable == "rg" && words.front().is_some_and(|s| s == "--files");
        if files {
            words.pop_front();
        } else {
            for _ in 0..words.len() {
                if !words
                    .front()
                    .is_some_and(|s| s == "-n" || s == "--line-number")
                {
                    break;
                }
                words.pop_front();
            }
        }
        let terminated = !files && words.front().is_some_and(|s| s == "--");
        if terminated {
            words.pop_front();
        }
        let pattern = if files {
            String::new()
        } else {
            words.pop_front()?
        };
        if !files && (pattern.is_empty() || (!terminated && pattern.starts_with('-'))) {
            return None;
        }
        if words
            .iter()
            .any(|s| s.is_empty() || (!files && s == "-") || (!terminated && s.starts_with('-')))
        {
            return None;
        }
        let paths: Vec<_> = words.into_iter().collect();
        let stdin = !files && executable == "grep" && paths.is_empty();
        let location = if stdin {
            "in standard input".into()
        } else if paths.is_empty() {
            "in current directory".into()
        } else {
            format!("in {}", paths.join(", "))
        };
        return Some(Tool {
            kind: if files { "find" } else { "search" }.into(),
            title: if files { "Find files" } else { "Search" }.into(),
            symbol: if files {
                "doc.text.magnifyingglass"
            } else {
                "magnifyingglass"
            }
            .into(),
            summary: if files {
                location
            } else {
                format!("{pattern} · {location}")
            },
            search: Some(ToolSearch {
                pattern,
                paths,
                filters: Vec::new(),
                standard_input: stdin,
            }),
            ..Tool::default()
        });
    } else if executable == "git" {
        match words.pop_front()?.as_str() {
            "status"
                if words.iter().all(|s| {
                    matches!(
                        s.as_str(),
                        "--short" | "-s" | "--porcelain" | "--porcelain=v1"
                    )
                }) =>
            {
                (
                    "status",
                    "Check working-tree changes",
                    "list.bullet",
                    String::new(),
                )
            }
            "diff" => {
                let staged = words
                    .front()
                    .is_some_and(|s| s == "--cached" || s == "--staged");
                if staged {
                    words.pop_front();
                }
                if !words.is_empty() {
                    if words.pop_front()?.as_str() != "--"
                        || words.is_empty()
                        || words
                            .iter()
                            .any(|s| s.is_empty() || s.contains(['*', '?', '[', ']', ':']))
                    {
                        return None;
                    }
                }
                let files = words.into_iter().collect::<Vec<_>>().join(", ");
                let text = if staged && files.is_empty() {
                    "Staged changes".into()
                } else if staged {
                    format!("Staged · {files}")
                } else {
                    files
                };
                ("diff", "Review changes", "doc.text.magnifyingglass", text)
            }
            _ => return None,
        }
    } else if matches!(executable, "swift" | "cargo")
        && words.len() == 1
        && words.front().is_some_and(|s| s == "test" || s == "build")
    {
        let test = words.front()?.as_str() == "test";
        return Some(Tool {
            kind: if test { "test" } else { "build" }.into(),
            title: if test { "Run tests" } else { "Build" }.into(),
            symbol: if test { "checkmark.circle" } else { "hammer" }.into(),
            summary: if executable == "swift" {
                "Swift"
            } else {
                "Rust"
            }
            .into(),
            shell: Some(ToolShell {
                swift_tests: test && executable == "swift",
                ..ToolShell::default()
            }),
            ..Tool::default()
        });
    } else {
        return None;
    };
    Some(Tool {
        kind: kind.into(),
        title: title.into(),
        symbol: symbol.into(),
        summary: text,
        ..Tool::default()
    })
}
