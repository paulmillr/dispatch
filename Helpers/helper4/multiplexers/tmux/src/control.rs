//! Native control records and the two tmux octal grammars.
use crate::mux::error;
pub use dispatch_helper4_core::api::Error;
use std::borrow::Cow;
pub const MAXIMUM: usize = 32 * 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub struct Pane<'a> {
    pub shell: u32,
    pub tty: &'a str,
    pub modes: [Option<bool>; 5],
}

impl<'a> Pane<'a> {
    pub fn parse(bytes: &'a [u8], pane: u32, server: u32) -> Result<Self, Error> {
        let invalid = || error("Invalid tmux pane state");
        if bytes.len() > 8192 {
            return Err(invalid());
        }
        let text = std::str::from_utf8(bytes).map_err(|_| invalid())?;
        let text = text.strip_suffix('\n').unwrap_or(text);
        let text = text.strip_suffix('\r').unwrap_or(text);
        let mut fields = text.split('|');
        let [
            Some(owner),
            Some(shell),
            Some(tty),
            Some(target),
            Some(a),
            Some(b),
            Some(c),
            Some(d),
            Some(e),
        ] = std::array::from_fn::<_, 9, _>(|_| fields.next())
        else {
            return Err(invalid());
        };
        let pid = |text: &str| {
            if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
                return Err(invalid());
            }
            text.parse::<i32>()
                .ok()
                .filter(|pid| *pid > 1)
                .map(|pid| pid as u32)
                .ok_or_else(invalid)
        };
        if fields.next().is_some()
            || pid(owner)? != server
            || target != format!("%{pane}")
            || !tty.starts_with("/dev/")
            || tty.len() > 1024
            || tty.chars().any(char::is_control)
        {
            return Err(invalid());
        }
        let mut modes = [None; 5];
        for (mode, value) in modes.iter_mut().zip([a, b, c, d, e]) {
            *mode = match value {
                "" => None,
                "0" => Some(false),
                "1" => Some(true),
                _ => return Err(invalid()),
            };
        }
        Ok(Self {
            shell: pid(shell)?,
            tty,
            modes,
        })
    }
}

/// A reply's lines in one buffer, each followed by '\n': its memory follows its bytes, not
/// its line count (a newline flood loaded into a tmux buffer is millions of empty lines).
#[derive(Clone, Default, PartialEq, Eq)]
pub struct Lines(Vec<u8>);
impl Lines {
    pub fn iter(&self) -> impl Iterator<Item = &[u8]> {
        self.0
            .split_inclusive(|b| *b == b'\n')
            .map(|line| &line[..line.len() - 1])
    }
    pub fn len(&self) -> usize {
        self.iter().count()
    }
    /// The lines joined by '\n', as tmux printed them.
    pub fn text(&self) -> &[u8] {
        self.0.strip_suffix(b"\n").unwrap_or(&self.0)
    }
}
impl<T: AsRef<[u8]>> FromIterator<T> for Lines {
    fn from_iter<I: IntoIterator<Item = T>>(lines: I) -> Self {
        let mut buffer = Vec::new();
        for line in lines {
            buffer.extend_from_slice(line.as_ref());
            buffer.push(b'\n');
        }
        Self(buffer)
    }
}
impl std::fmt::Debug for Lines {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_list()
            .entries(self.iter().map(String::from_utf8_lossy))
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    Reply {
        number: u64,
        flags: u64,
        lines: Lines,
        failed: bool,
    },
    Output {
        pane: u64,
        bytes: Vec<u8>,
    },
    Notification(String),
}
struct Reply {
    stamp: [u64; 3],
    lines: Lines,
    size: usize,
}
#[derive(Default)]
pub struct Decoder {
    reply: Option<Reply>,
    last: Option<Vec<u8>>,
    line: Vec<u8>,
    /// %exit is a control stream's last record; what follows (the DCS end, the terminal's
    /// own echo and shell) is not this stream.
    exited: bool,
}
/// c1654cc TmuxProtocol.Unexpected: the reason, the line and the line before it, each at most
/// 120 bytes with control characters escaped; pane output is never quoted.
pub fn unexpected(reason: &str, line: Option<&[u8]>, previous: Option<&[u8]>) -> Error {
    let excerpt = |data: &[u8]| {
        let text: String = String::from_utf8_lossy(&data[..data.len().min(120)])
            .chars()
            .map(|c| match c as u32 {
                value @ (0..0x20 | 0x7f..=0x9f) => format!("\\x{value:02X}"),
                _ => c.to_string(),
            })
            .collect();
        format!("`{text}{}`", if data.len() > 120 { "…" } else { "" })
    };
    let parts = [
        Some(reason.to_owned()),
        line.map(|line| format!("line: {}", excerpt(line))),
        previous.map(|previous| format!("after: {}", excerpt(previous))),
    ];
    error(parts.into_iter().flatten().collect::<Vec<_>>().join("; "))
}
fn frame(line: &[u8], prefix: &[u8]) -> Option<[u64; 3]> {
    let values = line
        .strip_prefix(prefix)?
        .split(|b| *b == b' ')
        .filter(|p| !p.is_empty())
        .map(|p| std::str::from_utf8(p).ok()?.parse().ok())
        .collect::<Option<Vec<_>>>()?;
    values.try_into().ok()
}
impl Decoder {
    /// Events of the complete lines in `input`; a partial line waits for the next chunk.
    pub fn feed(&mut self, input: &[u8]) -> Result<Vec<Event>, Error> {
        let mut events = Vec::new();
        for part in input.split_inclusive(|b| *b == b'\n') {
            if self.exited {
                break;
            }
            let complete = part.last() == Some(&b'\n');
            let part = &part[..part.len() - usize::from(complete)];
            if part.len() > MAXIMUM - self.line.len() {
                return Err(error("Tmux control record exceeds its byte limit"));
            }
            // Control mode escapes every control byte, so a line that begins with ESC outside a
            // reply is a new control session (`ESC P1000p`) on the same transport: refuse it at
            // its first byte, before any of it is consumed as this stream's data.
            if self.reply.is_none() && self.line.is_empty() && part.first() == Some(&0x1b) {
                return Err(unexpected(
                    "a new control stream started",
                    Some(part.strip_suffix(b"\r").unwrap_or(part)),
                    self.last.as_deref(),
                ));
            }
            self.line.extend_from_slice(part);
            if complete {
                let mut line = std::mem::take(&mut self.line);
                events.extend(self.consume(&line)?);
                line.clear();
                self.line = line;
            }
        }
        Ok(events)
    }
    pub fn consume(&mut self, line: &[u8]) -> Result<Option<Event>, Error> {
        if line.len() > MAXIMUM {
            return Err(error("Tmux control record exceeds its byte limit"));
        }
        let end = line.iter().rposition(|b| *b != b'\r').map_or(0, |i| i + 1);
        let line = &line[..end];
        let bad = |reason, current: &[u8]| unexpected(reason, Some(current), self.last.as_deref());
        if let Some(mut reply) = self.reply.take() {
            for (prefix, failed) in [(b"%end ".as_slice(), false), (b"%error ".as_slice(), true)] {
                if frame(line, prefix) == Some(reply.stamp) {
                    self.last = Some(line.iter().take(121).copied().collect());
                    return Ok(Some(Event::Reply {
                        number: reply.stamp[1],
                        flags: reply.stamp[2],
                        lines: reply.lines,
                        failed,
                    }));
                }
            }
            reply.size += line.len() + 1;
            if reply.size > MAXIMUM {
                return Err(error("Tmux control record exceeds its byte limit"));
            }
            reply.lines.0.extend_from_slice(line);
            reply.lines.0.push(b'\n');
            self.reply = Some(reply);
            return Ok(None);
        }
        if line.starts_with(b"%begin ") {
            let stamp = frame(line, b"%begin ").ok_or_else(|| bad("malformed %begin", line))?;
            self.reply = Some(Reply {
                stamp,
                lines: Lines::default(),
                size: 0,
            });
        } else if line.starts_with(b"%output ") || line.starts_with(b"%extended-output ") {
            let extended = line.starts_with(b"%extended-output ");
            let parts = line.splitn(3, |b| *b == b' ').collect::<Vec<_>>();
            let pane = parts
                .get(1)
                .and_then(|p| std::str::from_utf8(p).ok())
                .and_then(|p| crate::snapshot::id(p, '%').ok());
            let data = parts.get(2).and_then(|data| {
                if extended {
                    data.windows(3)
                        .position(|p| p == b" : ")
                        .map(|i| &data[i + 3..])
                } else {
                    Some(*data)
                }
            });
            let (Some(pane), Some(data)) = (pane, data) else {
                return Err(bad(
                    if extended {
                        "malformed %extended-output"
                    } else {
                        "malformed %output"
                    },
                    &line
                        .splitn(3, |b| *b == b' ')
                        .take(2)
                        .collect::<Vec<_>>()
                        .join(&b' ')
                        .into_iter()
                        .chain(" …".bytes())
                        .collect::<Vec<_>>(),
                ));
            };
            self.last = Some(format!("%output %{pane} …").into_bytes());
            return Ok(Some(Event::Output {
                pane,
                bytes: decode(data, false)?.into_owned(),
            }));
        } else {
            if line.is_empty() {
                return Ok(None);
            }
            for (prefix, reason) in [
                (b"%end ".as_slice(), "%end outside a reply"),
                (b"%error ".as_slice(), "%error outside a reply"),
            ] {
                if line.starts_with(prefix) {
                    return Err(bad(reason, line));
                }
            }
            self.last = Some(line.iter().take(121).copied().collect());
            self.exited = line.starts_with(b"%exit");
            return Ok(Some(Event::Notification(
                String::from_utf8_lossy(line).into_owned(),
            )));
        }
        self.last = Some(line.iter().take(121).copied().collect());
        Ok(None)
    }
}
pub fn decode(data: &[u8], capture: bool) -> Result<Cow<'_, [u8]>, Error> {
    let Some(first) = data.iter().position(|b| *b == b'\\') else {
        return Ok(Cow::Borrowed(data));
    };
    let mut output = data[..first].to_vec();
    let mut rest = &data[first..];
    for _ in 0..data.len() {
        if rest.is_empty() {
            break;
        }
        if rest[0] == b'\\' {
            if capture && rest.get(1) == Some(&b'\\') {
                output.push(b'\\');
                rest = &rest[2..];
            } else {
                let digits = rest
                    .get(1..4)
                    .filter(|p| p.iter().all(|b| (b'0'..=b'7').contains(b)))
                    .ok_or_else(|| error("Invalid tmux octal escape"))?;
                let value = digits
                    .iter()
                    .fold(0u16, |v, b| v * 8 + u16::from(*b - b'0'));
                output.push(u8::try_from(value).map_err(|_| error("Invalid tmux octal escape"))?);
                rest = &rest[4..];
            }
        }
        let end = rest.iter().position(|b| *b == b'\\').unwrap_or(rest.len());
        output.extend_from_slice(&rest[..end]);
        rest = &rest[end..];
    }
    Ok(Cow::Owned(output))
}
