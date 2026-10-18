use super::*;

/// A bounded raw response chunk. Wait for done before reading the next chunk.
/// Completion means UI writer admission, not physical delivery. Cancel/disconnect fails it.
pub type Chunk = Box<dyn FnMut(&mut dyn Io, Vec<u8>, Done<()>)>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Read {
    pub path: PathBuf,
    pub offset: u64,
    pub length: Option<u64>,
    pub revision: Guard,
}

/// Expected file identity: every present field must match, absent fields are not checked.
/// Old callers sent inode, device and revision independently (c51466a files.rs:23-25,57-60;
/// c1654cc SSHRemoteFiles.swift:17-23).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Guard {
    pub kind: Option<FileKind>,
    pub size: Option<u64>,
    pub device: Option<u64>,
    pub inode: Option<u64>,
    pub modified_ns: Option<i128>,
    pub changed_ns: Option<i128>,
}

impl Guard {
    pub fn matches(&self, m: &Metadata) -> bool {
        self.kind.is_none_or(|v| v == m.kind)
            && self.size.is_none_or(|v| v == m.size)
            && self.device.is_none_or(|v| v == m.device)
            && self.inode.is_none_or(|v| v == m.inode)
            && self.modified_ns.is_none_or(|v| v == m.modified_ns)
            && self.changed_ns.is_none_or(|v| v == m.changed_ns)
    }
}

impl From<Metadata> for Guard {
    fn from(m: Metadata) -> Self {
        Guard {
            kind: Some(m.kind),
            size: Some(m.size),
            device: Some(m.device),
            inode: Some(m.inode),
            modified_ns: Some(m.modified_ns),
            changed_ns: Some(m.changed_ns),
        }
    }
}

pub trait Plugin {
    /// Advertised in hello; spec helper.md:117.
    fn name(&self) -> &str;
    /// Reset named collector baselines; no topics means all. Provider loss resets all;
    /// cadence changes reset processes only (c1654cc SSHStatisticsStore.swift:241-247).
    fn reset(&mut self, io: &mut dyn Io, _topics: &[String], done: Done<()>) {
        deferred(done)(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        );
    }
    /// Incremental bytes, independent of the text display bound. Each chunk is at most
    /// limit bytes. Finish with native metadata; the shared writer owns framing/totals.
    /// c1654cc SSHRemoteFiles.swift:17-39; the user also permits a whole file without length.
    fn read(
        &mut self,
        io: &mut dyn Io,
        _read: &Read,
        _limit: usize,
        _chunk: Chunk,
        done: Done<Metadata>,
    ) {
        deferred(done)(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        );
    }
    /// Whole UTF-8 file up to 2 MB; c1654cc Dispatch/Chat/ToolDocument.swift:155-161.
    fn text(&mut self, io: &mut dyn Io, _path: &Path, done: Done<String>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// Host counters; c1654cc Dispatch/Stats/HostMetrics.swift:55-69.
    fn sample(&mut self, io: &mut dyn Io, done: Done<Sample>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// Process table and whether it was truncated; c1654cc Dispatch/Stats/HostMetrics.swift:163, 176-177, Dispatch/Stats/SSHStatisticsStore.swift:449.
    fn processes(&mut self, io: &mut dyn Io, done: Done<(Vec<Row>, bool)>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// Disk capacity; c1654cc Dispatch/Stats/HostMetrics.swift:114.
    fn disks(&mut self, io: &mut dyn Io, done: Done<Vec<Disk>>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// Git branch for a terminal cwd; c1654cc Dispatch/SpaceBranch.swift:38.
    fn branch(&mut self, io: &mut dyn Io, _cwd: &Path, done: Done<Option<String>>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// One directory level, no symlink followed; `limit` 0 is the plugin's own bound. `git` asks
    /// for marks (reserved).
    fn list(
        &mut self,
        io: &mut dyn Io,
        _path: &Path,
        _hidden: bool,
        _limit: u64,
        _git: bool, done: Done<Listing>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// Totals of a bounded recursive walk under `path`, no symlink followed.
    fn summary(&mut self, io: &mut dyn Io, _path: &Path, _limit: u64, done: Done<FolderSummary>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// A whole new file at `path` (temp name beside it, then rename); `replace` allows an
    /// existing one. `mode` None is the default file mode under the umask. `bytes` is the
    /// request's own buffer, moved on to the job that writes it rather than copied again.
    fn write(
        &mut self,
        io: &mut dyn Io,
        _path: &Path,
        _bytes: Vec<u8>,
        _mode: Option<u32>,
        _replace: bool, done: Done<Metadata>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// `paths` (inside `base`) packed into a temporary archive named relative to `base`;
    /// `transfer` is the client's id for it.
    fn pack(
        &mut self,
        io: &mut dyn Io,
        _transfer: &str,
        _base: &Path,
        _paths: &[PathBuf],
        _limit: u64, done: Done<Packed>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// Removes a packed archive, or the one a running pack is still writing when it ends.
    fn pack_drop(&mut self, io: &mut dyn Io, _transfer: &str, done: Done<()>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// Stages an incoming archive beside `target`; `names` are the archive's only allowed
    /// top-level entries, and `policy` (replace, keep, skip) settles their conflicts at commit.
    fn unpack_open(
        &mut self,
        io: &mut dyn Io,
        _transfer: &str,
        _target: &Path,
        _policy: &str,
        _names: &[String], done: Done<Transfer>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// Appends archive bytes to an open transfer's staging archive.
    fn unpack_write(&mut self, io: &mut dyn Io, _transfer: &str, _bytes: Vec<u8>, done: Done<Progress>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// Ends a transfer whose client disconnected: drops a pack's archive (`unpack` false) or closes an unpack
    /// without commit, removing only what the helper made. The helper calls it with no capability check, so a
    /// client whose grants were reduced still leaves nothing behind.
    fn release(&mut self, io: &mut dyn Io, _transfer: &str, _unpack: bool, done: Done<()>) {
        deferred(done)(io, Ok(()))
    }
    /// Extracts and moves in (`commit`), or discards the staging directory.
    fn unpack_close(&mut self, io: &mut dyn Io, _transfer: &str, _commit: bool, done: Done<Unpacked>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// A read-only git command in `path`, output bounded by `limit` (reserved).
    fn git(
        &mut self,
        io: &mut dyn Io,
        _path: &Path,
        _args: &[String],
        _limit: u64, done: Done<Git>) {
        done(
            io,
            Err(Error {
                code: "unsupported",
                message: String::new(),
            }),
        )
    }
    /// Completion of IO this plugin submitted.
    fn event(&mut self, io: &mut dyn Io, ui: &mut dyn Ui, event: Event);
}
