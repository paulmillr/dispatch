use crate::terminal::error;
use dispatch_helper_core::{api::*, json::Data, wire::body};

pub(crate) fn same(left: &Process, right: &Process) -> bool {
    owns(left, right) && left.executable == right.executable
}

pub(crate) fn owns(left: &Process, right: &Process) -> bool {
    left.pid == right.pid && left.start == right.start && left.tty == right.tty
}

pub(crate) fn foreground(bytes: &[u8], shell: &Process) -> Result<Vec<Process>, Error> {
    let root = body::decode_plain(bytes)?;
    if shell.foreground <= 1 || root.get("group").and_then(Data::signed) != Some(shell.foreground.into()) {
        return Err(error("agent_changed", ""));
    }
    let members = root
        .get("processes")
        .and_then(Data::array)
        .ok_or_else(|| error("foreground_missing", ""))?
        .map(|value| Process::read(value).ok_or_else(|| error("process_identity_invalid", "")))
        .collect::<Result<Vec<_>, _>>()?;
    if members.iter().any(|p| {
        p.tty != shell.tty || p.group != shell.foreground || p.foreground != shell.foreground
    }) {
        return Err(error("agent_changed", ""));
    }
    Ok(members)
}
