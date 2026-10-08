use super::{Error, Mode};

/// A revision is issued by the queue owner. The app retains it unchanged on edits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Queued {
    pub id: String,
    pub mode: Mode,
    pub revision: u64,
    pub preview: Vec<Preview>,
    pub editable: bool,
    /// Editing holds this item until commit/cancel; native uploads must skip it.
    pub editing: bool,
    pub paused: Option<Pause>,
    pub error: Option<Error>,
}

/// Original ordered content facts; the app supplies attachment labels and separators.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Preview {
    Text(String),
    Attachment(String),
}

/// c1654cc ChatModels.swift:693-710. Resume clears Stopped only.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pause {
    Stopped,
    Uncertain,
    DestinationChanged,
    NeedsEdit,
}
