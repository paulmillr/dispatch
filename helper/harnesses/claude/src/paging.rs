//! The native reverse-page algorithm. Every block is supplied by a System read completion.
use crate::history::{Parser, error, text};
use dispatch_helper_core::api::*;
use dispatch_helper_core::json::Json;
use dispatch_helper_core::rpc::Reverse;
use std::path::PathBuf;

pub struct Reader {
    path: PathBuf,
    parser: Option<Parser>,
    before: Option<u64>,
    reverse: Option<Reverse>,
    limit: usize,
    budget: u64,
    count: u64,
    lines: Vec<Vec<u8>>,
    after: Option<u64>,
    selected: Option<String>,
    probe: bool,
    /// An initial page waiting for the title or model call that lie before it.
    scan: Option<(Page, Parser)>,
    context: Option<String>,
    cursor: u64,
    pub metadata: Option<Metadata>,
    pub prefix: Vec<u8>,
    pub tail: Vec<u8>,
    pub position: u64,
}
impl Reader {
    pub fn new(path: PathBuf, parser: Parser, before: Option<u64>) -> Self {
        Self {
            path,
            parser: Some(parser),
            before,
            reverse: None,
            limit: if before.is_some() { 200 } else { 400 },
            budget: if before.is_some() {
                2_097_152
            } else {
                4_194_304
            },
            count: 0,
            lines: Vec::new(),
            after: None,
            selected: None,
            probe: false,
            scan: None,
            context: None,
            cursor: 0,
            metadata: None,
            prefix: Vec::new(),
            tail: Vec::new(),
            position: 0,
        }
    }
    pub fn live(path: PathBuf, parser: Parser, position: u64) -> Self {
        Self {
            after: Some(position),
            position,
            ..Self::new(path, parser, None)
        }
    }
    pub fn selected(path: PathBuf, parser: Parser, id: String) -> Self {
        Self {
            selected: Some(id),
            ..Self::new(path, parser, None)
        }
    }
    pub fn idle(&mut self) -> Option<(Page, Parser)> {
        (self.after.is_some() && self.after == self.metadata.map(|m| m.size)).then(|| {
            (
                Page {
                    records: Vec::new(),
                    earlier: None,
                },
                self.parser.take().unwrap(),
            )
        })
    }
    pub fn job(&self) -> Job {
        if let Some(offset) = self.after
            && self.metadata.is_some()
        {
            return Job::Read {
                path: self.path.clone(),
                offset,
                length: 524_288,
            };
        }
        if let Some(reverse) = &self.reverse {
            return reverse.job().expect("Completed reads return their page");
        }
        Job::Read {
            path: self.path.clone(),
            offset: 0,
            length: 256,
        }
    }
    pub fn complete(&mut self, output: Output) -> Result<Option<(Page, Parser)>, Error> {
        let Output::Read {
            before,
            after,
            bytes,
        } = output
        else {
            return Err(error("io", "Expected transcript read"));
        };
        if before != after || self.metadata.is_some_and(|old| old != before) {
            return Err(error("changed", "Transcript changed during read"));
        }
        if self.metadata.is_none() {
            self.metadata = Some(before);
            self.prefix = bytes;
            if self.after.is_some() {
                return Ok(None);
            }
            let position = self.before.unwrap_or(before.size);
            if position > before.size {
                return Err(error("changed", "History cursor is beyond the transcript"));
            }
            if position == 0 {
                return self.result();
            }
            self.reverse = Some(Reverse::new(self.path.clone(), 0, position, 4_194_304));
            return Ok(None);
        }
        if let Some(offset) = self.after {
            self.position = offset + bytes.len() as u64;
            self.tail = bytes[bytes.len().saturating_sub(256)..].to_vec();
            let mut parser = self.parser.take().unwrap();
            let records = parser.feed(&bytes)?;
            return Ok(Some((
                Page {
                    records,
                    earlier: None,
                },
                parser,
            )));
        }
        if self.tail.is_empty() && self.before.is_none() {
            self.tail = bytes[bytes.len().saturating_sub(256)..].to_vec()
        }
        let reverse = self.reverse.as_mut().unwrap();
        let lines = reverse.feed(Output::Read {
            before,
            after,
            bytes,
        })?;
        let mut position = reverse.position();
        let mut finished = false;
        for line in lines {
            if let Some((_, parser)) = &mut self.scan {
                finished = parser.earlier(&line.bytes);
            } else if self.probe {
                if let Some((context, _)) = self.parser.as_ref().unwrap().context(&line.bytes) {
                    self.context = Some(context);
                    finished = true;
                }
            } else if let Some(selected) = &self.selected {
                if let Ok(doc) = Json::parse(&line.bytes) {
                    let found = doc
                        .root()
                        .get("message")
                        .and_then(|v| v.get("content"))
                        .and_then(|v| v.array())
                        .into_iter()
                        .flatten()
                        .find_map(|block| match text(block, "type") {
                            Some("tool_use")
                                if text(block, "id") == selected.strip_prefix("tool-") =>
                            {
                                Some(true)
                            }
                            Some("tool_result")
                                if text(block, "tool_use_id") == selected.strip_prefix("tool-") =>
                            {
                                Some(false)
                            }
                            _ => None,
                        });
                    if let Some(start) = found {
                        self.lines.push(line.bytes);
                        finished = start;
                    }
                }
            } else {
                self.count += line.end - line.start;
                self.lines.push(line.bytes);
                finished = self.lines.len() >= self.limit || self.count >= self.budget;
            }
            if finished {
                position = line.start;
                break;
            }
        }
        if finished || position == 0 {
            if let Some(page) = self.scan.take() {
                return Ok(Some(page));
            }
            if self.probe {
                return self.result();
            }
            self.cursor = position;
            self.lines.reverse();
            let parser = self.parser.as_ref().unwrap();
            self.context = self
                .lines
                .iter()
                .find_map(|b| parser.context(b))
                .filter(|(_, start)| !*start)
                .map(|(id, _)| id);
            if self.context.is_none()
                && !self
                    .lines
                    .first()
                    .and_then(|b| parser.context(b))
                    .is_some_and(|(_, start)| start)
                && self.cursor > 0
            {
                self.probe = true;
                self.reverse = Some(Reverse::new(self.path.clone(), 0, self.cursor, 4_194_304));
                return Ok(None);
            }
            return self.result();
        }
        Ok(None)
    }
    fn result(&mut self) -> Result<Option<(Page, Parser)>, Error> {
        self.position = self.metadata.unwrap().size;
        let mut parser = self.parser.take().unwrap();
        parser.page(&self.lines, self.context.take());
        let mut records = Vec::new();
        for line in &self.lines {
            records.extend(parser.feed(line)?)
        }
        parser.finish();
        let page = Page {
            records,
            earlier: (self.selected.is_none() && self.cursor > 0).then(|| self.cursor.to_string()),
        };
        // c1654cc TranscriptReader.swift:420-460: the latest title and model call of an initial
        // page may lie before it; read back from the page until both are known or the file starts.
        if self.before.is_none()
            && page.earlier.is_some()
            && (parser.state.title.is_none() || parser.configured.is_none())
        {
            self.reverse = Some(Reverse::new(self.path.clone(), 0, self.cursor, 4_194_304));
            self.scan = Some((page, parser));
            return Ok(None);
        }
        Ok(Some((page, parser)))
    }
}
