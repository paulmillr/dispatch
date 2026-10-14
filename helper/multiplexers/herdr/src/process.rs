use super::*;

pub(super) fn same(left: &Process, right: &Process) -> bool {
    left.pid == right.pid && left.start == right.start && left.executable == right.executable
}

pub(super) fn owns(shell: &Process, current: &Process, expected: &Process) -> bool {
    same(current, expected)
        && shell.tty != 0
        && current.tty == shell.tty
        && shell.foreground > 1
        && current.group == shell.foreground
}

pub(super) fn select(
    processes: &[Process],
    matches: impl Fn(&Process) -> Option<usize>,
) -> Option<(usize, &Process)> {
    let mut candidates = processes
        .iter()
        .filter_map(|process| matches(process).map(|index| (index, process)));
    let candidate = candidates.next()?;
    candidates.next().is_none().then_some(candidate)
}

pub(super) fn foreground(
    result: io::Result<Output>,
    shell: &Process,
) -> Result<Vec<Process>, Error> {
    let Output::Value(bytes) = result.map_err(|error| native::error(error.to_string()))? else {
        return Err(error("Invalid foreground process result."));
    };
    let root = body::decode_plain(&bytes)?;
    if root.get("group").and_then(D::signed) != Some(shell.foreground.into()) {
        return Err(expired("The agent no longer owns this terminal."));
    }
    let processes = root
        .get("processes")
        .and_then(D::array)
        .ok_or_else(|| error("Invalid foreground process list."))?
        .map(|value| Process::read(value).ok_or_else(|| error("Invalid process field.")))
        .collect::<Result<Vec<_>, _>>()?;
    if processes.iter().any(|process| {
        process.tty != shell.tty
            || process.group != shell.foreground
            || process.foreground != shell.foreground
    }) {
        return Err(expired("The agent no longer owns this terminal."));
    }
    Ok(processes)
}

