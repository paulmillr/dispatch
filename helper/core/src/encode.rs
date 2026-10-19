//! One encoder for common API values, independent of operation names. It writes the wire's
//! binary value grammar (wire/body.rs) directly: no JSON text between an API value and its frame.
use crate::{
    api::*,
    json::Data,
    wire::body,
};
use std::path::PathBuf;

pub(crate) trait Encode {
    /// Append this value in the wire value grammar, without the schema prefix.
    fn encode(&self, out: &mut Vec<u8>);
}
impl Encode for crate::wire::body::Encoded {
    fn encode(&self, out: &mut Vec<u8>) {
        self.root().encode(out)
    }
}
impl Encode for Data<'_> {
    fn encode(&self, out: &mut Vec<u8>) {
        body::put(out, self).expect("typed wire value");
    }
}
/// Raw bytes: the wire carries them as bytes (tag 11), never as text.
pub(crate) struct Bytes<'a>(pub &'a [u8]);
impl Encode for Bytes<'_> {
    fn encode(&self, out: &mut Vec<u8>) {
        Data::Bytes(self.0).encode(out);
    }
}
/// A value already encoded by Encode (a result built ahead of its envelope).
pub(crate) struct Raw<'a>(pub &'a [u8]);
impl Encode for Raw<'_> {
    fn encode(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(self.0);
    }
}
macro_rules! scalar {
    ($($t:ty => $v:ident),*) => {
        $(
            impl Encode for $t {
                fn encode(&self, out: &mut Vec<u8>) {
                    Data::$v((*self).into()).encode(out);
                }
            }
        )*
    };
}
impl Encode for i128 {
    fn encode(&self, out: &mut Vec<u8>) {
        self.to_string().encode(out);
    }
}

scalar!(u64 => Unsigned, u32 => Unsigned, u16 => Unsigned, i64 => Signed, i32 => Signed, f64 => Real, bool => Bool);
impl Encode for str {
    fn encode(&self, out: &mut Vec<u8>) {
        Data::String(self).encode(out);
    }
}
impl Encode for String {
    fn encode(&self, out: &mut Vec<u8>) {
        self.as_str().encode(out);
    }
}
impl Encode for PathBuf {
    fn encode(&self, out: &mut Vec<u8>) {
        self.to_string_lossy().as_ref().encode(out);
    }
}
impl Encode for () {
    fn encode(&self, out: &mut Vec<u8>) {
        Data::Null.encode(out);
    }
}
impl<T: Encode> Encode for Option<T> {
    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            Some(v) => v.encode(out),
            None => ().encode(out),
        }
    }
}
impl<T: Encode> Encode for Vec<T> {
    fn encode(&self, out: &mut Vec<u8>) {
        body::array(out, self.len());
        for v in self {
            v.encode(out);
        }
    }
}
impl<A: Encode, B: Encode> Encode for (A, B) {
    fn encode(&self, out: &mut Vec<u8>) {
        body::array(out, 2);
        self.0.encode(out);
        self.1.encode(out);
    }
}
macro_rules! records {
    ($($t:ty {$($f:ident),*});*) => {
        $(
            impl Encode for $t {
                fn encode(&self, out: &mut Vec<u8>) {
                    object(out, &[$((stringify!($f), &self.$f as &dyn Encode)),*]);
                }
            }
        )*
    };
}
records! {
    Metadata {
        kind,
        size,
        device,
        inode,
        modified_ns,
        changed_ns
    };
    Grid {
        columns,
        rows
    };
    Screen {
        text,
        cursor,
        faint_tail
    };
    Summary {
        waiting,
        busy,
        activity,
        revision
    };
    InputWindow {
        terminal,
        credit
    };
    Record {
        id,
        turn,
        kind,
        text,
        title,
        output,
        blocks,
        completed,
        exit_code,
        patch,
        documents,
        tool,
        inline_reasoning,
        time_ms,
        position
    };
    Tool {
        kind,
        title,
        symbol,
        summary,
        input,
        language,
        directory,
        failed,
        read,
        search,
        shell,
        children,
        orchestration,
        patch,
        confirmed_result,
        additions,
        deletions
    };
    ToolRead {
        path,
        selection,
        source
    };
    ToolSearch {
        pattern,
        paths,
        filters,
        standard_input
    };
    ToolShell {
        command,
        kind,
        swift_tests
    };
    Document {
        path,
        kind,
        diff,
        workdir
    };
    Error {
        code,
        message
    };
    Page {
        records,
        earlier
    };
    Snapshot {
        generation,
        session,
        version,
        initial,
        caught_up,
        invalidated,
        awaiting_creation,
        file
    };
    FileIdentity {
        device,
        inode
    };
    FilePosition {
        file,
        offset
    };
    State {
        busy,
        activity,
        model,
        model_label,
        effort,
        usage,
        goal,
        draft,
        attention,
        leaf,
        dialog,
        title,
        version,
        pending,
        compacting,
        service_tier,
        mode,
        agents
    };
    Choice {
        id,
        label,
        detail
    };
    Prefix {
        key,
        repeat_ms,
        bindings
    };
    PrefixBinding {
        key,
        command,
        repeat
    };
    Question {
        id,
        header,
        text,
        secret,
        options,
        multiple,
        custom,
        blocks
    };
    Interaction {
        id,
        key,
        approval,
        blocking,
        questions,
        turn,
        record
    };
    Menu {
        choices,
        current,
        default
    };
    Queued {
        id,
        mode,
        revision,
        preview,
        editable,
        editing,
        paused,
        error
    };
    Sample {
        boot,
        cpu_present,
        cpu,
        cores,
        load,
        memory,
        swap,
        received_per_second,
        sent_per_second,
        uptime
    };
    Row {
        pid,
        start,
        name,
        cpu,
        rss
    };
    Disk {
        identity,
        paths,
        total,
        available
    };
    Entry {
        name,
        kind,
        size,
        modified_ns,
        device,
        inode,
        target,
        mark
    };
    Listing {
        path,
        entries,
        truncated,
        device,
        inode
    };
    FolderSummary {
        files,
        folders,
        bytes,
        truncated
    };
    Packed {
        archive,
        entries,
        files,
        folders,
        bytes,
        size,
        skipped
    };
    Transfer {
        transfer,
        staging
    };
    Progress {
        bytes
    };
    Unpacked {
        entries,
        bytes,
        replaced,
        kept,
        skipped
    };
    Git {
        status,
        output,
        truncated
    };
    Install {
        edits,
        restart,
        installed,
        optional,
        reload,
        trust
    };
    Layout {
        container,
        full,
        visible,
        focus
    }
}
impl Encode for Binding {
    fn encode(&self, out: &mut Vec<u8>) {
        object(
            out,
            &[
                ("session", &self.session),
                ("transcript", &self.transcript),
                ("pid", &u64::from(self.process.pid)),
                ("start", &self.process.start.to_vec()),
                ("executable", &self.process.executable),
            ],
        );
    }
}
impl Encode for Node {
    fn encode(&self, out: &mut Vec<u8>) {
        let agent = self.agent.as_ref().map(|(_, binding)| binding.clone());
        object(
            out,
            &[
                ("id", &self.id),
                ("parent", &self.parent),
                ("key", &self.key),
                ("kind", &self.kind),
                ("name", &self.name),
                ("renamed", &self.renamed),
                ("cwd", &self.cwd),
                ("size", &self.size),
                ("agent", &agent),
                ("tty", &self.tty),
                ("detached", &self.detached),
            ],
        );
    }
}
macro_rules! tags {
    ($t:ty {$($v:ident => $s:literal),*}) => {
        impl Encode for $t {
            fn encode(&self, out: &mut Vec<u8>) {
                match self {
                    $(Self::$v => $s),*
                }.encode(out);
            }
        }
    };
}
tags!(FileKind {File => "file", Directory => "directory", Symlink => "symlink", Other => "other"});
tags!(Kind {Workspace => "workspace", Tab => "tab", Terminal => "terminal"});
tags!(Mode {Prompt => "prompt", Steer => "steer", FollowUp => "follow_up"});
tags!(Pause {Stopped => "stopped", Uncertain => "uncertain", DestinationChanged => "destination_changed", NeedsEdit => "needs_edit"});
impl Encode for Preview {
    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            Self::Text(text) => object(out, &[("kind", &"text"), ("text", text)]),
            Self::Attachment(kind) => object(out, &[("kind", &"attachment"), ("type", kind)]),
        }
    }
}
tags!(RecordKind {TurnStarted => "turn_started", TurnEnded => "turn_ended", User => "user", Assistant => "assistant", Reasoning => "reasoning", Tool => "tool", Notice => "notice", Output => "output"});
tags!(DocumentKind {Add => "add", Delete => "delete", Update => "update"});
impl Encode for ReadSelection {
    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            Self::All => object(out, &[("kind", &"all")]),
            Self::Lines { start, end } => {
                object(out, &[("kind", &"lines"), ("start", start), ("end", end)])
            }
            Self::First(count) | Self::Last(count) => object(
                out,
                &[
                    (
                        "kind",
                        &if matches!(self, Self::First(_)) {
                            "first"
                        } else {
                            "last"
                        },
                    ),
                    ("count", count),
                ],
            ),
        }
    }
}
impl Encode for Block {
    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            Self::Code { language, text } => object(
                out,
                &[("kind", &"code"), ("language", language), ("text", text)],
            ),
            Self::Markdown(text) => object(out, &[("kind", &"markdown"), ("text", text)]),
            Self::Attachment(path) => object(out, &[("kind", &"attachment"), ("path", path)]),
        }
    }
}
impl Encode for &str {
    fn encode(&self, out: &mut Vec<u8>) {
        (*self).encode(out);
    }
}
pub(crate) fn object(out: &mut Vec<u8>, fields: &[(&str, &dyn Encode)]) {
    let named = body::object(out, fields.iter().map(|(key, _)| *key), fields.len());
    for (key, value) in fields {
        if named {
            body::name(out, key);
        }
        value.encode(out);
    }
}
impl Encode for Split {
    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            Self::Leaf(id) => object(out, &[("terminal", id)]),
            Self::Branch { id, axis, children } => {
                let axis = match axis {
                    Axis::Rows => "rows",
                    Axis::Columns => "columns",
                };
                let children: Vec<_> = children
                    .iter()
                    .map(|(weight, split)| Child {
                        weight: *weight,
                        split,
                    })
                    .collect();
                object(out, &[("id", id), ("axis", &axis), ("children", &children)]);
            }
        }
    }
}
struct Child<'a> {
    weight: u32,
    split: &'a Split,
}
impl Encode for Child<'_> {
    fn encode(&self, out: &mut Vec<u8>) {
        object(out, &[("weight", &self.weight), ("split", self.split)]);
    }
}
impl Encode for Sent {
    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            Self::Native {
                written,
                may_have_sent,
                reason,
            } => object(
                out,
                &[
                    ("written", written),
                    ("may_have_sent", may_have_sent),
                    ("reason", reason),
                ],
            ),
            Self::Keys(_) => unreachable!("terminal keys must be delivered by the multiplexer"),
        }
    }
}
impl Encode for Outcome {
    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            Self::Sent(sent) => object(out, &[("kind", &"sent"), ("sent", sent)]),
            Self::Shell {
                command,
                output,
                exit_code,
            } => object(
                out,
                &[
                    ("kind", &"shell"),
                    ("command", command),
                    ("output", output),
                    ("exit_code", exit_code),
                ],
            ),
            Self::Stopping => object(out, &[("kind", &"stopping")]),
            Self::Result { title, text } => object(
                out,
                &[("kind", &"result"), ("title", title), ("text", text)],
            ),
        }
    }
}
impl Encode for Edit {
    fn encode(&self, out: &mut Vec<u8>) {
        let before = self.before.as_deref().map(Bytes);
        let after = self.after.as_deref().map(Bytes);
        object(
            out,
            &[
                ("path", &self.path),
                ("before", &before),
                ("after", &after),
                ("backup", &self.backup),
            ],
        );
    }
}
/// A value encoded on its own (a message body without the schema prefix).
pub(crate) fn value(item: &dyn Encode) -> Vec<u8> {
    let mut out = Vec::new();
    item.encode(&mut out);
    out
}
pub(crate) struct Fields<'a>(pub &'a [(&'a str, &'a dyn Encode)]);
impl Encode for Fields<'_> {
    fn encode(&self, out: &mut Vec<u8>) {
        object(out, self.0);
    }
}
pub(crate) fn notify(method: &str, fields: &[(&str, &dyn Encode)]) -> Vec<u8> {
    value(&Fields(&[("method", &method), ("params", &Fields(fields))]))
}
