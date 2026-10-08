/// Bounded encoded messages. A partial write keeps its whole allocation admitted.
pub struct Queue {
    frames: std::collections::VecDeque<(Option<u64>, Vec<u8>)>,
    offset: usize,
    retained: usize,
    limit: usize,
}

impl Queue {
    pub fn new(limit: usize) -> Self {
        Self {
            frames: std::collections::VecDeque::new(),
            offset: 0,
            retained: 0,
            limit,
        }
    }

    pub fn push(&mut self, bytes: Vec<u8>) -> Result<(), Error> {
        self.record(None, bytes)
    }

    pub fn record(&mut self, id: Option<u64>, bytes: Vec<u8>) -> Result<(), Error> {
        if bytes.len() > self.limit - self.retained {
            return Err(Error::Limit);
        }
        if !bytes.is_empty() {
            self.retained += bytes.len();
            self.frames.push_back((id, bytes));
        }
        Ok(())
    }

    pub fn front(&self) -> Option<&[u8]> {
        self.frames.front().map(|(_, bytes)| &bytes[self.offset..])
    }
    pub fn remaining(&self) -> usize {
        self.retained - self.offset
    }
    pub fn space(&self) -> usize {
        self.limit - self.retained
    }

    /// Cancel unsent records; a partly written frame must finish to preserve the stream.
    pub fn cancel(&mut self, id: u64) {
        let mut index = 0;
        self.frames.retain(|(record, bytes)| {
            let keep = *record != Some(id) || (index == 0 && self.offset != 0);
            index += 1;
            if !keep {
                self.retained -= bytes.len();
            }
            keep
        });
    }

    pub fn consume(&mut self, count: usize) -> Result<(), Error> {
        if count > self.front().map_or(0, <[u8]>::len) {
            return Err(Error::Length);
        }
        self.offset += count;
        if let Some((_, bytes)) = self
            .frames
            .pop_front_if(|(_, bytes)| self.offset == bytes.len())
        {
            self.retained -= bytes.len();
            self.offset = 0;
        }
        Ok(())
    }
}

#[derive(Debug)]
pub enum Error {
    Limit,
    Length,
}
