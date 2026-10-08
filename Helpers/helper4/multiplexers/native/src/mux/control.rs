use super::*;

pub(super) enum Step {
    Root,
    Foreground(Process),
    Check(Process),
}

impl Native {
    pub(super) fn controlled(
        &mut self,
        io: &mut dyn Io,
        terminal: Id,
        step: Step,
        done: Done<Process>,
        result: io::Result<Output>,
    ) {
        enum Next {
            Job(Box<Job>, Step),
            Done(Process),
        }
        let result = (|| {
            if !self
                .terminal(terminal)
                .is_ok_and(|t| !t.closed && !t.exited)
            {
                return Err(error("expired", ""));
            }
            let output = result.map_err(|e| error("io_failure", e))?;
            match (step, output) {
                (Step::Root, Output::Process(shell)) if self.observe(terminal, &shell) => {
                    let input =
                        json::write(&Data::Object(vec![("tty", Data::Unsigned(shell.tty))]))?;
                    Ok(Next::Job(
                        Box::new(Job::Native {
                            name: "foreground",
                            input,
                        }),
                        Step::Foreground(shell),
                    ))
                }
                (Step::Foreground(shell), Output::Bytes(bytes)) => {
                    let members = foreground(&bytes, &shell)?;
                    let [process] = members.as_slice() else {
                        return Err(error("control_process_unavailable", ""));
                    };
                    Ok(Next::Job(
                        Box::new(Job::Process { pid: shell.pid }),
                        Step::Check(process.clone()),
                    ))
                }
                (Step::Check(process), Output::Process(shell))
                    if self.observe(terminal, &shell)
                        && process.tty == shell.tty
                        && process.group == shell.foreground
                        && process.foreground == shell.foreground =>
                {
                    Ok(Next::Done(process))
                }
                _ => Err(error("control_process_unavailable", "")),
            }
        })();
        match result {
            Ok(Next::Job(job, step)) => self.submit(
                io,
                *job,
                Pending::Control {
                    terminal,
                    step,
                    done,
                },
            ),
            Ok(Next::Done(process)) => {
                self.terminal(terminal).unwrap().control = Some(process.clone());
                deferred(done)(io, Ok(process));
            }
            Err(error) => deferred(done)(io, Err(error)),
        }
    }
}
