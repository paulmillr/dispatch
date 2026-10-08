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
    let Output::Bytes(bytes) = result.map_err(|error| native::error(error.to_string()))? else {
        return Err(error("Invalid foreground process result."));
    };
    let json = Json::parse(&bytes)?;
    let root = json.root();
    if field(root, "group")?.signed() != Some(shell.foreground.into()) {
        return Err(expired("The agent no longer owns this terminal."));
    }
    let processes = field(root, "processes")?
        .array()
        .ok_or_else(|| error("Invalid foreground process list."))?
        .map(read)
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

pub(super) fn read(v: Value<'_>) -> Result<Process, Error> {
    let unsigned = |name| {
        field(v, name)?
            .unsigned()
            .ok_or_else(|| error("Invalid process field."))
    };
    let signed = |name| {
        field(v, name)?
            .signed()
            .and_then(|n| i32::try_from(n).ok())
            .ok_or_else(|| error("Invalid process field."))
    };
    let strings = |name| -> Result<Vec<String>, Error> {
        field(v, name)?
            .array()
            .ok_or_else(|| error("Invalid process field."))?
            .map(|v| {
                v.string()
                    .map(str::to_owned)
                    .ok_or_else(|| error("Invalid process field."))
            })
            .collect()
    };
    let start: Vec<_> = field(v, "start")?
        .array()
        .ok_or_else(|| error("Invalid process birth."))?
        .map(|v| v.unsigned().ok_or_else(|| error("Invalid process birth.")))
        .collect::<Result<_, _>>()?;
    let start = start
        .try_into()
        .map_err(|_| error("Invalid process birth."))?;
    Ok(Process {
        pid: unsigned("pid")?
            .try_into()
            .map_err(|_| error("Invalid PID."))?,
        parent: unsigned("parent")?
            .try_into()
            .map_err(|_| error("Invalid PID."))?,
        group: signed("group")?,
        foreground: signed("foreground")?,
        tty: unsigned("tty")?,
        start,
        executable: text(v, "executable")?.into(),
        arguments: strings("arguments")?,
        files: v
            .get("files")
            .and_then(Value::array)
            .and_then(|v| v.map(OpenFile::parse).collect::<Option<Vec<_>>>())
            .ok_or_else(|| error("Invalid open files."))?,
    })
}
