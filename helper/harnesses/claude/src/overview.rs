//! chat.list's read of a Claude transcript (`Harness::overview`) and the list pushes
//! (`Harness::listen`): only the transcript's end (core tail.rs), projected line by line with the
//! chat's own parser, never through the live cache a chat continues, so an open chat's page,
//! `earlier` cursor, state and cards stay as they were.
use super::*;
use dispatch_helper_core::{
    json::Json,
    tail::{self, Classify, Line},
};

/// A record comes only from a line with a uuid, a title from one naming its type.
fn named(line: &[u8]) -> bool {
    contains(line, b"\"uuid\"") || contains(line, b"-title\"")
}
fn contains(line: &[u8], needle: &[u8]) -> bool {
    line.windows(needle.len()).any(|window| window == needle)
}

/// Claude's lines as a list row sees them: the records `Parser` makes of each (assistant text,
/// turn starts and ends, any record's time) and title records, newest first. Once the newest
/// record is known, tool results (which yield only tool records) are not parsed.
pub(crate) fn classify(session: &str) -> Classify {
    let session = session.to_owned();
    let mut parser = Parser::new(session.clone());
    let mut timed = false;
    Box::new(move |line: &[u8]| {
        let mut out = Line::default();
        if !named(line) || timed && contains(line, b"\"tool_result\"") {
            return out;
        }
        let Ok(document) = Json::parse(line) else { return out };
        let root = document.root();
        if root.get("isSidechain").and_then(|v| v.boolean()) == Some(true)
            || text(root, "sessionId").is_none_or(|id| !uuid(id) || id != session)
            || text(root, "type").is_none()
        {
            return out;
        }
        if let Some(title) = Parser::title(root) {
            out.title = title;
            return out;
        }
        if Parser::notification(root).is_some() {
            return out;
        }
        let Some(id) = text(root, "uuid") else { return out };
        let records = parser.parse(root, id);
        out.time_ms = records.iter().rev().find_map(|record| record.time_ms);
        timed |= out.time_ms.is_some();
        out.answer = records
            .iter()
            .rev()
            .find(|record| record.kind == RecordKind::Assistant && !record.text.trim().is_empty())
            .map(|record| (record.text.clone(), record.time_ms));
        let time = |kind: RecordKind| records.iter().filter(|record| record.kind == kind).find_map(|record| record.time_ms);
        out.ended = time(RecordKind::TurnEnded);
        out.started = time(RecordKind::TurnStarted);
        out
    })
}

impl Claude {
    pub(super) fn overview_of(&mut self, io: &mut dyn Io, binding: &Binding, done: Done<Overview>) {
        if self.sides.borrow().contains(binding) {
            let page = self.sides.borrow().page(binding);
            return finish(io, done, Ok(Overview::of(&page.records)));
        }
        let Some(path) = binding.transcript.clone() else {
            return finish(io, done, Err(error("transcript", "Claude has no transcript path")));
        };
        let (key, known) = (key(binding), self.overviews.clone());
        tail::listing(
            &self.tails,
            io,
            &path,
            &binding.session,
            true,
            classify,
            Box::new(move |io, result| {
                if let Ok(overview) = &result {
                    known.borrow_mut().insert(key, overview.clone());
                }
                done(io, result)
            }),
        );
    }

    /// Watch what list clients list: the transcript and the registry (`watch`).
    pub(super) fn listen_to(&mut self, io: &mut dyn Io, bindings: &[Binding]) {
        let listed: BTreeMap<Key, Binding> = bindings.iter().map(|binding| (key(binding), binding.clone())).collect();
        for (key, binding) in &listed {
            if self.listed.contains_key(key) {
                continue;
            }
            match &binding.transcript {
                Some(path) => self.watch(io, binding, path),
                None => {
                    if let Some(session) = self.sessions.get(key).cloned() {
                        self.registry(io, &session);
                    }
                }
            }
        }
        // Watches of bindings no longer listed end at their next event (as a chat's do).
        self.overviews.borrow_mut().retain(|key, _| listed.contains_key(key));
        self.listed = listed;
    }

    /// A listed transcript changed: read its end again, and publish what changed for its row.
    pub(super) fn relist(&mut self, io: &mut dyn Io, binding: &Binding, path: &Path) {
        let (key, known, pushed, owner) = (key(binding), self.overviews.clone(), self.pushed.clone(), binding.clone());
        tail::listing(
            &self.tails,
            io,
            path,
            &binding.session,
            true,
            classify,
            Box::new(move |io, result| {
                let Ok(overview) = result else { return };
                let changed = known.borrow().get(&key).is_none_or(|old| overview.differs(old));
                known.borrow_mut().insert(key, overview.clone());
                if changed {
                    pushed.borrow_mut().push(Update::Overview { binding: owner, overview });
                    let now = io.now();
                    io.timer(now);
                }
            }),
        );
    }
}
