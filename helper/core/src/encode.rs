//! One JSON encoder for common API values, independent of operation names.
use crate::{
    api::*,
    json::{self, Data},
};
use std::path::PathBuf;

pub(crate) trait Encode {
    fn encode(&self, out: &mut Vec<u8>);
}
impl Encode for Data<'_> {
    fn encode(&self, out: &mut Vec<u8>) {
        out.extend(json::write(self).expect("typed JSON value"));
    }
}
macro_rules! scalar {
    ($($t:ty => $v:ident),*) => {
        $(
            impl Encode for $t {
                fn encode(&self, out: &mut Vec<u8>) {
                    out.extend(json::write(&Data::$v((*self).into())).unwrap());
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
        out.extend(json::write(&Data::String(self)).unwrap());
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
        out.extend(b"null");
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
        out.push(b'[');
        for (i, v) in self.iter().enumerate() {
            if i > 0 {
                out.push(b',');
            }
            v.encode(out);
        }
        out.push(b']');
    }
}
impl<A: Encode, B: Encode> Encode for (A, B) {
    fn encode(&self, out: &mut Vec<u8>) {
        out.push(b'[');
        self.0.encode(out);
        out.push(b',');
        self.1.encode(out);
        out.push(b']');
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
    out.push(b'{');
    for (i, (key, value)) in fields.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        key.encode(out);
        out.push(b':');
        value.encode(out);
    }
    out.push(b'}');
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
        let before = self.before.as_ref().map(|v| base64(v));
        let after = self.after.as_ref().map(|v| base64(v));
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
pub fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let a = chunk[0] as usize;
        let b = *chunk.get(1).unwrap_or(&0) as usize;
        let c = *chunk.get(2).unwrap_or(&0) as usize;
        for index in [
            a >> 2,
            ((a & 3) << 4) | (b >> 4),
            ((b & 15) << 2) | (c >> 6),
            c & 63,
        ]
        .into_iter()
        .enumerate()
        {
            out.push(if index.0 > chunk.len() {
                '='
            } else {
                TABLE[index.1] as char
            });
        }
    }
    out
}
pub(crate) fn notify(method: &str, fields: &[(&str, &dyn Encode)]) -> Vec<u8> {
    let mut out = b"{\"method\":".to_vec();
    method.encode(&mut out);
    out.extend(b",\"params\":");
    object(&mut out, fields);
    out.push(b'}');
    out
}
