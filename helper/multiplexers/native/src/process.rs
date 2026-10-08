use crate::terminal::error;
use dispatch_helper_core::{api::*, json::Value};

pub(crate) fn same(left: &Process, right: &Process) -> bool {
    owns(left, right) && left.executable == right.executable
}

pub(crate) fn owns(left: &Process, right: &Process) -> bool {
    left.pid == right.pid && left.start == right.start && left.tty == right.tty
}

pub(crate) fn foreground(bytes: &[u8], shell: &Process) -> Result<Vec<Process>, Error> {
    let doc = Json::parse(bytes)?;
    let root = doc.root();
    if shell.foreground <= 1
        || root.get("group").and_then(Value::signed) != Some(shell.foreground.into())
    {
        return Err(error("agent_changed", ""));
    }
    let members = root
        .get("processes")
        .and_then(Value::array)
        .ok_or_else(|| error("foreground_missing", ""))?
        .map(process)
        .collect::<Result<Vec<_>, _>>()?;
    if members.iter().any(|p| {
        p.tty != shell.tty || p.group != shell.foreground || p.foreground != shell.foreground
    }) {
        return Err(error("agent_changed", ""));
    }
    Ok(members)
}

pub(crate) fn process(value: Value<'_>) -> Result<Process, Error> {
    let integer = |name| {
        value
            .get(name)
            .and_then(Value::signed)
            .ok_or_else(|| error("process_identity_missing", ""))
    };
    let list = |name| {
        value
            .get(name)
            .and_then(Value::array)
            .ok_or_else(|| error("process_identity_missing", ""))?
            .map(|v| {
                v.string()
                    .map(str::to_owned)
                    .ok_or_else(|| error("process_identity_missing", ""))
            })
            .collect::<Result<Vec<_>, _>>()
    };
    let start = value
        .get("start")
        .and_then(Value::array)
        .ok_or_else(|| error("process_identity_missing", ""))?
        .map(|v| {
            v.unsigned()
                .ok_or_else(|| error("process_identity_missing", ""))
        })
        .collect::<Result<Vec<_>, _>>()?;
    let number = || error("process_identity_invalid", "");
    Ok(Process {
        pid: integer("pid")?.try_into().map_err(|_| number())?,
        parent: integer("parent")?.try_into().map_err(|_| number())?,
        group: integer("group")?.try_into().map_err(|_| number())?,
        foreground: integer("foreground")?.try_into().map_err(|_| number())?,
        tty: value
            .get("tty")
            .and_then(Value::unsigned)
            .ok_or_else(number)?,
        start: start.try_into().map_err(|_| number())?,
        executable: value
            .get("executable")
            .and_then(Value::string)
            .ok_or_else(number)?
            .into(),
        arguments: list("arguments")?,
        files: value
            .get("files")
            .and_then(Value::array)
            .and_then(|v| v.map(OpenFile::parse).collect::<Option<Vec<_>>>())
            .ok_or_else(number)?,
    })
}
