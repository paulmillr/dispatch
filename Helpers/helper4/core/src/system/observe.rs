//! Native process invalidation, separate from owned-child exit and reaping.
use super::reactor::{Exit, Reactor, Ready};
use std::{collections::BTreeMap, io, os::fd::AsRawFd};

pub(super) struct Observer {
    reactor: Reactor,
    parent: std::sync::Arc<std::os::fd::OwnedFd>,
    sources: BTreeMap<u32, Exit>,
    targets: BTreeMap<u64, (u32, String)>,
    capacity: usize,
}

impl Drop for Observer {
    fn drop(&mut self) {
        let _ = Reactor::queue(
            self.parent.as_raw_fd(),
            self.reactor.handle().as_raw_fd(),
            false,
        );
    }
}

impl Observer {
    pub fn new(parent: &Reactor, capacity: usize) -> io::Result<Self> {
        let reactor = Reactor::new()?;
        // A separate native queue prevents a Darwin observer from replacing the
        // one-shot NOTE_EXIT registration which belongs to the child reaper.
        let queue = reactor.handle();
        let fd = queue.as_raw_fd();
        Reactor::queue(parent.handle().as_raw_fd(), fd, true)?;
        Ok(Self {
            reactor,
            parent: parent.handle(),
            sources: BTreeMap::new(),
            targets: BTreeMap::new(),
            capacity,
        })
    }
    pub fn set(&mut self, id: u64, pid: u32, owner: &str) -> io::Result<()> {
        if self.targets.len() >= self.capacity {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        if !self.sources.contains_key(&pid) {
            self.sources.insert(pid, self.reactor.observe(pid)?);
        }
        self.targets.insert(id, (pid, owner.into()));
        Ok(())
    }
    pub fn remove(&mut self, id: u64) {
        if let Some((pid, _)) = self.targets.remove(&id) {
            if !self.targets.values().any(|(source, _)| *source == pid) {
                self.sources.remove(&pid);
            }
        }
    }
    pub fn changed(
        &mut self,
        parent: Ready,
        mut emit: impl FnMut(String, u64, u32),
    ) -> io::Result<()> {
        if parent.process || parent.fd != self.reactor.handle().as_raw_fd() {
            return Ok(());
        }
        loop {
            let Some(ready) = self.reactor.poll()? else {
                break;
            };
            if let Some(pid) = self
                .sources
                .iter()
                .find_map(|(&pid, source)| source.matches(ready).then_some(pid))
            {
                for (&id, (source, owner)) in &self.targets {
                    if *source == pid {
                        emit(owner.clone(), id, pid);
                    }
                }
                if self.sources[&pid].exited(ready) {
                    self.sources.remove(&pid);
                    self.targets.retain(|_, (source, _)| *source != pid);
                }
            }
        }
        Ok(())
    }
}
