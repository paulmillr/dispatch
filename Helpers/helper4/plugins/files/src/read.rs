use super::*;

pub(super) struct State {
    pub read: Read,
    pub limit: u64,
    pub chunk: Rc<RefCell<Chunk>>,
    pub done: Done<Metadata>,
}

impl State {
    pub fn submit(self, io: &mut dyn Io, jobs: &Jobs) {
        let job = Job::Read {
            path: self.read.path.clone(),
            offset: self.read.offset,
            length: self.read.length.unwrap_or(self.limit).min(self.limit),
        };
        Files::submit(jobs, io, job, Pending::Read(self));
    }

    pub fn event(mut self, io: &mut dyn Io, jobs: &Jobs, output: Output) {
        let Output::Read {
            before,
            after,
            bytes,
        } = output
        else {
            (self.done)(io, Err(error("internal")));
            return;
        };
        let length = self.read.length.unwrap_or(self.limit).min(self.limit);
        if before.kind != FileKind::File
            || before != after
            || !self.read.revision.matches(&before)
            || bytes.len() as u64 > length
        {
            (self.done)(io, Err(error("changed")));
            return;
        }
        self.read.revision = before.into();
        let end = (bytes.len() as u64) < length;
        self.read.offset += bytes.len() as u64;
        self.read.length = self.read.length.map(|length| length - bytes.len() as u64);
        if bytes.is_empty() {
            (self.done)(io, Ok(before));
            return;
        }
        let chunk = self.chunk.clone();
        let jobs = jobs.clone();
        (chunk.borrow_mut())(
            io,
            bytes,
            deferred(Box::new(move |io, result| match result {
                Err(error) => (self.done)(io, Err(error)),
                Ok(()) if end || self.read.length == Some(0) => (self.done)(io, Ok(before)),
                Ok(()) => self.submit(io, &jobs),
            })),
        );
    }
}
