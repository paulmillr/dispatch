use super::*;

pub(super) struct Check {
    pub done: Done<()>,
    node: Id,
    owners: Vec<(Id, u32, Option<Process>)>,
    index: usize,
    query: bool,
}

impl Native {
    pub(super) fn prompt(&mut self, io: &mut dyn Io, node: Id, query: bool, done: Done<()>) {
        let owners: Vec<_> = self
            .terminals
            .iter()
            .filter(|t| (node == self.root.id || t.node.id == node) && !t.closed && !t.exited)
            .map(|t| (t.node.id, t.child.pid, None))
            .collect();
        if !owners.is_empty() {
            self.close_check(
                io,
                Check {
                    done,
                    node,
                    owners,
                    index: 0,
                    query,
                },
            );
        } else if node == self.root.id {
            deferred(done)(io, Ok(()));
        } else {
            deferred(done)(io, Err(error("expired", "")));
        }
    }

    fn close_check(&mut self, io: &mut dyn Io, check: Check) {
        let (_, pid, process) = &check.owners[check.index];
        let Some(process) = process else {
            self.submit(io, Job::Process { pid: *pid }, Pending::Close(check));
            return;
        };
        let input = json::write(&Data::Object(vec![
            ("pid", Data::Unsigned(process.pid.into())),
            (
                "start",
                Data::Array(process.start.iter().map(|v| Data::Unsigned(*v)).collect()),
            ),
        ]));
        match input {
            Ok(input) => self.submit(
                io,
                Job::Native {
                    name: "idle",
                    input,
                },
                Pending::Close(check),
            ),
            Err(_) => deferred(check.done)(io, Err(error("busy", ""))),
        }
    }

    pub(super) fn closing(
        &mut self,
        io: &mut dyn Io,
        mut check: Check,
        result: io::Result<Output>,
    ) {
        if check
            .owners
            .iter()
            .any(|(id, _, _)| self.terminal(*id).is_err())
        {
            deferred(check.done)(io, Err(error("expired", "")));
            return;
        }
        if let Ok(Output::Process(process)) = result {
            let (id, pid, observed) = &mut check.owners[check.index];
            if observed.is_none() && process.pid == *pid && self.observe(*id, &process) {
                *observed = Some(process);
                self.close_check(io, check);
            } else {
                deferred(check.done)(io, Err(error("busy", "")));
            }
            return;
        }
        let idle = match result {
            Ok(Output::Bytes(bytes)) => Json::parse(&bytes)
                .is_ok_and(|doc| doc.root().get("idle").and_then(Value::boolean) == Some(true)),
            _ => false,
        };
        let current: Vec<_> = self
            .terminals
            .iter()
            .filter(|t| {
                (check.node == self.root.id || t.node.id == check.node) && !t.closed && !t.exited
            })
            .collect();
        if !idle
            || current.len() != check.owners.len()
            || current.iter().any(|t| {
                !check.owners.iter().any(|(id, pid, process)| {
                    *id == t.node.id
                        && t.child.pid == *pid
                        && process
                            .as_ref()
                            .is_none_or(|p| t.observed.as_ref().is_some_and(|now| owns(now, p)))
                })
            })
        {
            deferred(check.done)(io, Err(error("busy", "")));
            return;
        }
        check.index += 1;
        if check.index == check.owners.len() {
            if check.query {
                deferred(check.done)(io, Ok(()));
            } else {
                self.close(io, check.node, Close::Terminate, check.done);
            }
        } else {
            self.close_check(io, check);
        }
    }
}
