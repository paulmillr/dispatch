//! Read-only history has no process or terminal authority.
use super::{Page, State};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Transcript {
    pub path: PathBuf,
    pub session: String,
    pub earlier: Option<String>,
    /// Snapshot.later of the previous read: only records appended since then (archive watch).
    pub later: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileIdentity {
    pub device: u64,
    pub inode: u64,
}

/// c1654cc ChatTests.swift:368-391: unread/replaced files cannot acknowledge a submitted prompt.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FilePosition {
    pub file: FileIdentity,
    pub offset: u64,
}

/// c1654cc TranscriptReader.Batch: loading, replacement and prompt-ack guards.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub generation: String,
    /// Native session id and harness version from the transcript header.
    pub session: Option<String>,
    pub version: Option<String>,
    pub initial: bool,
    pub caught_up: bool,
    pub invalidated: bool,
    pub awaiting_creation: bool,
    pub file: Option<FileIdentity>,
    /// Opaque resume point for the next read of this transcript (Transcript.later).
    pub later: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Archive {
    pub page: Page,
    pub snapshot: Snapshot,
    pub state: State,
}
