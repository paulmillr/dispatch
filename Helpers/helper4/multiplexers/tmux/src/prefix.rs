//! The server's own prefix table and the single server commands its bindings may run (core
//! decision 'prefix key table'; upstream df8e2fe TmuxSession.loadPrefixTable, PrefixKeys.swift
//! PrefixTable.tmux/tmuxAction). The app maps commands to its own actions.
use crate::mux::{Tmux, error, finish};
use dispatch_helper4_core::api::*;

/// Commands whose single reply is certain (df8e2fe PrefixKeys.swift forwardable).
const FORWARDABLE: [&str; 22] = [
    "select-pane",
    "selectp",
    "last-pane",
    "lastp",
    "select-window",
    "selectw",
    "last-window",
    "last",
    "select-layout",
    "selectl",
    "next-layout",
    "nextl",
    "previous-layout",
    "prevl",
    "resize-pane",
    "resizep",
    "swap-pane",
    "swapp",
    "rotate-window",
    "rotatew",
    "swap-window",
    "swapw",
];

/// One `list-keys` line as the old parser read it: `bind-key [-r] [-T table] key command`.
fn binding(line: &str) -> Option<PrefixBinding> {
    let mut rest = line;
    let mut word = || {
        rest = rest.trim_start_matches([' ', '\t']);
        let end = rest.find([' ', '\t']).unwrap_or(rest.len());
        let (word, next) = rest.split_at(end);
        rest = next;
        (!word.is_empty()).then_some(word)
    };
    if word()? != "bind-key" {
        return None;
    }
    let (mut repeat, mut table, mut key) = (false, None, None);
    while key.is_none() {
        match word()? {
            "-r" => repeat = true,
            "-T" => table = word(),
            other => key = Some(other),
        }
    }
    let (key, command) = (key?, rest.trim_matches([' ', '\t']));
    (table == Some("prefix") && !command.is_empty()).then(|| PrefixBinding {
        key: key.into(),
        command: command.into(),
        repeat,
    })
}

impl Tmux {
    pub(crate) fn prefix(&mut self, io: &mut dyn Io, node: Id, done: Done<Prefix>) {
        let loc = match self.target(node).map(|(loc, _)| loc) {
            Ok(loc) => loc,
            Err(e) => return finish(io, done, Err(e)),
        };
        let commands = [
            "show-options -gv prefix",
            "show-options -gv repeat-time",
            "list-keys -T prefix",
        ];
        self.request(
            io,
            loc,
            commands.map(str::to_owned).to_vec(),
            Box::new(move |_, io, result| {
                let table = result.map(|rows| {
                    let text = |row: &crate::control::Lines| {
                        String::from_utf8_lossy(row.text()).trim().to_owned()
                    };
                    Prefix {
                        key: Some(text(&rows[0])).filter(|key| !key.is_empty()),
                        repeat_ms: text(&rows[1]).parse().ok(),
                        bindings: rows[2]
                            .iter()
                            .filter_map(|line| binding(&String::from_utf8_lossy(line)))
                            .collect(),
                    }
                });
                finish(io, done, table);
            }),
        );
    }
    /// One allowlisted server command as this control client: no lists or blocks, so it
    /// keeps exactly one control reply (df8e2fe PrefixTable.tmuxAction).
    pub(crate) fn command(&mut self, io: &mut dyn Io, node: Id, command: &str, done: Done<()>) {
        let words: Vec<_> = command.split(' ').collect();
        if !FORWARDABLE.contains(&words[0])
            || words
                .iter()
                .any(|word| *word == "{" || *word == "}" || word.ends_with(';'))
        {
            return finish(
                io,
                done,
                Err(error("This tmux command cannot run from Dispatch")),
            );
        }
        match self.target(node).map(|(loc, _)| loc) {
            Ok(loc) => self.mutate(io, loc, vec![command.into()], 1, done),
            Err(e) => finish(io, done, Err(e)),
        }
    }
}
