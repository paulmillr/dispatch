//! Preserve unrelated settings/handlers; refuse malformed native settings rather than repairing them.
use crate::history::{error, text};
use dispatch_helper_core::api::Error;
use dispatch_helper_core::json::{self, Data, Format, Json, Kind, Value};
use std::collections::BTreeMap;

const LIFECYCLE: [&str; 7] = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PostToolUse",
    "SubagentStart",
    "SubagentStop",
    "Stop",
];

/// Remote setup preserves native group/handler positions and leaves no-ops unwritten.
pub fn installation(previous: Option<&[u8]>, command: &str) -> Result<Option<Vec<u8>>, Error> {
    let invalid = || error("settings", "Invalid agent hook configuration");
    if command.is_empty() || command.len() > 4096 || command.chars().any(char::is_control) {
        return Err(invalid());
    }
    if previous.is_some_and(|bytes| bytes.len() > 1_048_576) {
        return Err(invalid());
    }
    let doc = previous
        .map(Json::parse)
        .transpose()
        .map_err(|_| invalid())?;
    let mut fields = BTreeMap::new();
    let mut hooks = BTreeMap::new();
    if let Some(doc) = &doc {
        for (key, value) in doc.root().object().ok_or_else(invalid)? {
            if fields.insert(key, strict(value, 1)?).is_some() {
                return Err(invalid());
            }
        }
        if let Some(value) = doc.root().get("hooks") {
            for (event, groups) in value.object().ok_or_else(invalid)? {
                let mut rows = Vec::new();
                for group in groups.array().ok_or_else(invalid)? {
                    if group.kind() != Kind::Object
                        || group
                            .get("matcher")
                            .is_some_and(|value| !matches!(value.kind(), Kind::String | Kind::Null))
                    {
                        return Err(invalid());
                    }
                    for handler in group
                        .get("hooks")
                        .and_then(Value::array)
                        .ok_or_else(invalid)?
                    {
                        let kind = text(handler, "type")
                            .filter(|kind| !kind.is_empty())
                            .ok_or_else(invalid)?;
                        if kind == "command" && text(handler, "command").is_none()
                            || handler.get("timeout").is_some_and(|value| {
                                value.kind() != Kind::Null
                                    && !value.unsigned().is_some_and(|value| value > 0)
                            })
                            || handler
                                .get("async")
                                .is_some_and(|value| value.boolean().is_none())
                        {
                            return Err(invalid());
                        }
                    }
                    rows.push(strict(group, 3)?);
                }
                hooks.insert(event, rows);
            }
        }
    }
    let mut changed = false;
    for (event, matcher, timeout) in [
        ("PermissionRequest", None, 60),
        ("PreToolUse", Some("AskUserQuestion"), 190),
    ] {
        let installed = doc
            .as_ref()
            .and_then(|doc| doc.root().get("hooks"))
            .and_then(|hooks| hooks.get(event))
            .and_then(Value::array)
            .into_iter()
            .flatten()
            .any(|group| {
                let matches = match matcher {
                    Some(matcher) => text(group, "matcher") == Some(matcher),
                    None => group
                        .get("matcher")
                        .is_none_or(|value| value.kind() == Kind::Null),
                };
                matches
                    && group
                        .get("hooks")
                        .and_then(Value::array)
                        .into_iter()
                        .flatten()
                        .any(|handler| {
                            text(handler, "type") == Some("command")
                                && text(handler, "command") == Some(command)
                                && handler
                                    .get("async")
                                    .is_none_or(|value| value.boolean() == Some(false))
                        })
            });
        if installed {
            continue;
        }
        let mut group = vec![(
            "hooks",
            Data::Array(vec![Data::Object(vec![
                ("command", Data::String(command)),
                ("timeout", Data::Unsigned(timeout)),
                ("type", Data::String("command")),
            ])]),
        )];
        if let Some(matcher) = matcher {
            group.push(("matcher", Data::String(matcher)));
        }
        hooks.entry(event).or_default().push(Data::Object(group));
        changed = true;
    }
    if !changed {
        return Ok(None);
    }
    fields.insert(
        "hooks",
        Data::Object(
            hooks
                .into_iter()
                .map(|(key, groups)| (key, Data::Array(groups)))
                .collect(),
        ),
    );
    let mut bytes = json::write(&Data::Object(fields.into_iter().collect()))?;
    bytes.push(b'\n');
    if bytes.len() > 1_048_576 {
        return Err(invalid());
    }
    Ok(Some(bytes))
}

fn strict(value: Value<'_>, depth: usize) -> Result<Data<'_>, Error> {
    let invalid = || error("settings", "Invalid agent hook configuration");
    if depth >= 128 {
        return Err(invalid());
    }
    Ok(match value.kind() {
        Kind::Object => {
            let mut fields = BTreeMap::new();
            for (key, value) in value.object().unwrap() {
                if fields.insert(key, strict(value, depth + 1)?).is_some() {
                    return Err(invalid());
                }
            }
            Data::Object(fields.into_iter().collect())
        }
        Kind::Array => Data::Array(
            value
                .array()
                .unwrap()
                .map(|value| strict(value, depth + 1))
                .collect::<Result<_, _>>()?,
        ),
        _ => Data::Value(value),
    })
}

pub fn merge(doc: Option<&Json>, command: &str, enabled: bool) -> Result<Vec<u8>, Error> {
    let root = doc.map(Json::root);
    if root.is_some_and(|v| v.kind() != Kind::Object) {
        return Err(error(
            "settings",
            "Invalid agent hook settings JSON; file was not changed",
        ));
    }
    let mut hooks = BTreeMap::new();
    if let Some(value) = root.and_then(|v| v.get("hooks")) {
        for (event, groups) in value
            .object()
            .ok_or_else(|| error("settings", "hooks must map events to matcher groups"))?
        {
            let mut kept = Vec::new();
            let mut count = 0;
            for group in groups
                .array()
                .ok_or_else(|| error("settings", "Invalid matcher groups"))?
            {
                count += 1;
                if group.kind() != Kind::Object
                    || group.get("matcher").is_some_and(|v| v.string().is_none())
                {
                    return Err(error("settings", "Invalid hook matcher"));
                }
                let handlers = group
                    .get("hooks")
                    .and_then(|v| v.array())
                    .ok_or_else(|| error("settings", "Each matcher group needs a hooks array"))?;
                let mut remaining = Vec::new();
                let mut removed = false;
                for handler in handlers {
                    let kind = text(handler, "type")
                        .ok_or_else(|| error("settings", "Invalid hook handler type"))?;
                    if kind == "command" && text(handler, "command").is_none()
                        || handler.get("timeout").is_some_and(|v| {
                            v.number()
                                .or_else(|| v.boolean().map(|v| if v { 1.0 } else { 0.0 }))
                                .is_none_or(|n| n <= 0.0)
                        })
                    {
                        return Err(error("settings", "Invalid hook command or timeout"));
                    }
                    if kind == "command" && text(handler, "command") == Some(command) {
                        removed = true
                    } else {
                        remaining.push(Data::Value(handler))
                    }
                }
                if !removed {
                    kept.push(Data::Value(group))
                } else if !remaining.is_empty() {
                    let mut fields = group
                        .object()
                        .unwrap()
                        .filter(|(k, _)| *k != "hooks")
                        .map(|(k, v)| (k, Data::Value(v)))
                        .collect::<Vec<_>>();
                    fields.push(("hooks", Data::Array(remaining)));
                    kept.push(Data::Object(fields));
                }
            }
            if !kept.is_empty()
                || event != "PreToolUse" && !(LIFECYCLE.contains(&event) && count > 0)
            {
                hooks.insert(event, kept);
            }
        }
    }
    if enabled {
        for event in ["PermissionRequest", "PreToolUse"]
            .into_iter()
            .chain(LIFECYCLE)
        {
            let timeout = if event == "PreToolUse" {
                190
            } else if event == "PermissionRequest" {
                60
            } else {
                3
            };
            let mut group = vec![(
                "hooks",
                Data::Array(vec![Data::Object(vec![
                    ("type", Data::String("command")),
                    ("command", Data::String(command)),
                    ("timeout", Data::Unsigned(timeout)),
                ])]),
            )];
            if event == "PreToolUse" {
                group.push(("matcher", Data::String("AskUserQuestion")))
            }
            hooks.entry(event).or_default().push(Data::Object(group));
        }
    }
    let mut fields = root
        .and_then(Value::object)
        .into_iter()
        .flatten()
        .filter(|(k, _)| *k != "hooks")
        .map(|(k, v)| (k, Data::Value(v)))
        .collect::<Vec<_>>();
    fields.push((
        "hooks",
        Data::Object(
            hooks
                .into_iter()
                .map(|(k, v)| (k, Data::Array(v)))
                .collect(),
        ),
    ));
    json::write_with(&Data::Object(fields), Format::PrettySortedUnescaped)
}
