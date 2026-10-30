//! Who supplies each attached terminal's screens (feature screens.host, `Multiplexer::screen_clients`). A
//! screens.host client's attach turns host reads on for that terminal; a publication from any client (the iPhone)
//! wins while that client keeps the terminal attached, or, published without an attach, while it stays connected.
//! Multiplexers learn `attach`'s and `publish`'s part as they happen; this tells them when an attach ended or a
//! client left, so host reads resume once the publisher is gone.
use crate::api::Id;
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet},
    os::fd::RawFd,
    rc::Rc,
};

/// Publications by (client, terminal wire id), and whether that client was seen attaching the terminal since.
pub(crate) type Publishers = Rc<RefCell<BTreeMap<(RawFd, Id), bool>>>;

/// (hosting, published) of each terminal that has either, from the open attaches (client, terminal) and whether a
/// client names screens.host (`hosts`). A publication whose client no longer attaches the terminal it attached goes.
pub(crate) fn sources(
    attached: &BTreeSet<(RawFd, Id)>,
    hosts: impl Fn(RawFd) -> bool,
    publishers: &mut BTreeMap<(RawFd, Id), bool>,
) -> BTreeMap<Id, (bool, bool)> {
    publishers.retain(|key, seen| {
        let open = attached.contains(key);
        *seen |= open;
        open || !*seen
    });
    let mut sources: BTreeMap<Id, (bool, bool)> = BTreeMap::new();
    for (fd, terminal) in attached {
        if hosts(*fd) {
            sources.entry(*terminal).or_default().0 = true;
        }
    }
    for (_, terminal) in publishers.keys() {
        sources.entry(*terminal).or_default().1 = true;
    }
    sources
}

/// The terminals whose sources differ from `last`, with their new ones ((false, false) for one that has none left).
pub(crate) fn changes(
    last: &BTreeMap<Id, (bool, bool)>,
    now: &BTreeMap<Id, (bool, bool)>,
) -> Vec<(Id, (bool, bool))> {
    let gone = last.keys().filter(|terminal| !now.contains_key(terminal)).map(|terminal| (*terminal, (false, false)));
    now.iter()
        .filter(|(terminal, sources)| last.get(terminal) != Some(sources))
        .map(|(terminal, sources)| (*terminal, *sources))
        .chain(gone)
        .collect()
}

#[cfg(test)]
#[path = "screens.test.rs"]
mod tests;
