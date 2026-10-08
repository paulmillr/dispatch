use super::*;

impl Herdr {
    pub(super) fn hook(&mut self, io: &mut dyn Io, event: Event) {
        let Event::Hook { peer, reply, .. } = &event else {
            return;
        };
        if let Some(reply) = reply {
            self.hooks.insert(*reply, None);
        }
        if let Some(pid) = peer {
            self.ancestor(io, *pid, event, Vec::new());
        } else if let Event::Hook { message, .. } = &event
            && let Ok(message) = Json::parse(message)
        {
            let pid = self.harnesses.iter().find_map(|harness| {
                harness
                    .borrow_mut()
                    .hook(&message)
                    .ok()
                    .and_then(|hook| hook.pid)
            });
            if let Some(pid) = pid {
                self.ancestor(io, pid, event, Vec::new());
            }
        }
    }

    fn ancestor(&mut self, io: &mut dyn Io, pid: u32, event: Event, mut seen: Vec<u32>) {
        if pid <= 1 || seen.contains(&pid) {
            return;
        }
        seen.push(pid);
        self.job(
            io,
            Job::Process { pid },
            Box::new(move |mux, io, result| {
                let Event::Hook { reply, message, .. } = &event else {
                    return;
                };
                if reply.is_some_and(|reply| !mux.hooks.contains_key(&reply)) {
                    return;
                }
                let Ok(Output::Process(process)) = result else {
                    return;
                };
                let index = mux
                    .agents
                    .values()
                    .chain(
                        mux.endpoints
                            .values()
                            .flat_map(|endpoint| endpoint.agents.values()),
                    )
                    .find_map(|(index, binding)| {
                        crate::process::same(&binding.process, &process).then_some(*index)
                    });
                if let Some(index) = index {
                    let harness = mux.harnesses[index].clone();
                    let hook = Json::parse(message)
                        .and_then(|message| harness.borrow_mut().hook(&message));
                    if hook.is_ok_and(|hook| !hook.interactive || reply.is_some()) {
                        if let Some(reply) = reply {
                            mux.hooks.insert(*reply, Some(index));
                        }
                        mux.hookevents.push_back((index, event));
                    }
                } else {
                    mux.ancestor(io, process.parent, event, seen);
                }
            }),
        );
    }
}
