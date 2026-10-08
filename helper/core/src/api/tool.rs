//! Display facts decoded by producers from their native tool formats.
use super::Record;
use std::path::PathBuf;

/// Existing ToolPresentation.swift:29-128. The app displays these facts without
/// parsing tool names, arguments, shell syntax, or orchestration source.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Tool {
    pub kind: String,
    pub title: String,
    pub symbol: String,
    pub summary: String,
    pub input: String,
    pub language: String,
    pub directory: Option<PathBuf>,
    pub failed: bool,
    pub read: Option<ToolRead>,
    pub search: Option<ToolSearch>,
    pub shell: Option<ToolShell>,
    pub children: Vec<Record>,
    pub orchestration: bool,
    pub patch: bool,
    pub confirmed_result: Option<String>,
    pub additions: u64,
    pub deletions: u64,
}

/// The original captured output is a reliable source excerpt only when source is true.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolRead {
    pub path: String,
    pub selection: ReadSelection,
    pub source: bool,
}

/// One-based inclusive native source lines; last(n) has no inferred first line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReadSelection {
    All,
    Lines { start: u64, end: u64 },
    First(u64),
    Last(u64),
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ToolSearch {
    pub pattern: String,
    pub paths: Vec<String>,
    pub filters: Vec<String>,
    pub standard_input: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ToolShell {
    pub command: String,
    /// Common display category, such as build, test, search, or wait.
    pub kind: String,
    pub swift_tests: bool,
}
