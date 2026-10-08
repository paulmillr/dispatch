//! Restore native captured rows/modes and suppress terminal query feedback.
use crate::{control, mux::error};
pub use dispatch_helper4_core::api::Error;
use std::{borrow::Cow, collections::BTreeMap};
struct Buffer {
    bytes: Vec<u8>,
    limit: usize,
}
impl Buffer {
    fn put(&mut self, bytes: &[u8]) -> Result<(), Error> {
        if bytes.len() > self.limit.saturating_sub(self.bytes.len()) {
            return Err(error("Tmux terminal output exceeds its byte limit"));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }
    fn cursor(&mut self, x: i64, y: i64) -> Result<(), Error> {
        self.put(
            format!(
                "\x1b[{};{}H",
                y.max(0).saturating_add(1),
                x.max(0).saturating_add(1)
            )
            .as_bytes(),
        )
    }
    fn rows(&mut self, rows: &[Vec<u8>]) -> Result<(), Error> {
        for (index, row) in rows.iter().enumerate() {
            if index != 0 {
                self.put(b"\r\n")?;
            }
            self.put(row)?;
        }
        Ok(())
    }
}
pub struct Snapshot {
    pub screen: Vec<Vec<u8>>,
    pub saved: Vec<Vec<u8>>,
    pub cursor: Vec<u8>,
    pub state: BTreeMap<String, String>,
    pub preserve: bool,
}
impl Snapshot {
    pub fn bytes(&self, limit: usize) -> Result<Vec<u8>, Error> {
        let mut out = Buffer {
            bytes: Vec::new(),
            limit: limit.min(control::MAXIMUM),
        };
        let n = |key: &str, fallback| {
            self.state
                .get(key)
                .and_then(|s| s.parse::<i64>().ok())
                .unwrap_or(fallback)
        };
        let s = |key: &str| self.state.get(key).map_or("", String::as_str);
        // A preserving renderer keeps its history but can be on either screen (it missed the
        // pane's switch while detached): the primary screen first, then the pane's own screen.
        out.put(if self.preserve {
            b"\x1b[?1049l\x1b[H\x1b[2J"
        } else {
            b"\x1bc"
        })?;
        if n("alternate_on", 0) == 1 {
            out.rows(&self.saved)?;
            out.cursor(n("alternate_saved_x", 0), n("alternate_saved_y", 0))?;
            out.put(b"\x1b[?1049h")?;
        }
        out.rows(&self.screen)?;
        out.put(b"\x1b[0m\x1b[?6l")?;
        out.put(
            format!(
                "\x1b[{};{}r",
                n("scroll_region_upper", 0) + 1,
                n("scroll_region_lower", n("pane_height", 24) - 1) + 1
            )
            .as_bytes(),
        )?;
        out.put(b"\x1b[3g")?;
        for stop in s("pane_tabs").split(',').filter_map(|v| v.parse().ok()) {
            out.cursor(stop, 0)?;
            out.put(b"\x1bH")?;
        }
        for (key, mode) in [
            ("cursor_flag", 25),
            ("keypad_cursor_flag", 1),
            ("wrap_flag", 7),
            ("mouse_standard_flag", 1000),
            ("mouse_button_flag", 1002),
            ("mouse_any_flag", 1003),
            ("mouse_utf8_flag", 1005),
            ("mouse_sgr_flag", 1006),
            ("bracket_paste_flag", 2004),
        ] {
            out.put(format!("\x1b[?{mode}{}", if n(key, 0) == 1 { 'h' } else { 'l' }).as_bytes())?;
        }
        out.put(if n("insert_flag", 0) == 1 {
            b"\x1b[4h"
        } else {
            b"\x1b[4l"
        })?;
        out.put(if n("keypad_flag", 0) == 1 {
            b"\x1b="
        } else {
            b"\x1b>"
        })?;
        if n("origin_flag", 0) == 1 {
            out.put(b"\x1b[?6h")?;
        }
        for mode in [1004, 2026, 2031] {
            if s("pane_private_modes")
                .split(',')
                .filter_map(|v| v.parse::<i64>().ok())
                .any(|v| v == mode)
            {
                out.put(format!("\x1b[?{mode}h").as_bytes())?;
            }
        }
        let shape = match s("cursor_shape") {
            "block" => 2,
            "underline" => 4,
            "bar" => 6,
            _ => 0,
        };
        if shape > 0 {
            out.put(
                format!("\x1b[{} q", shape - i64::from(n("cursor_blinking", 0) == 1)).as_bytes(),
            )?;
        }
        let y = n("cursor_y", 0)
            - if n("origin_flag", 0) == 1 {
                n("scroll_region_upper", 0)
            } else {
                0
            };
        if n("cursor_x", 0) >= n("pane_width", 80) && !self.cursor.is_empty() {
            out.put(b"\x1b[4l")?;
            out.cursor(0, y)?;
            out.put(&self.cursor)?;
            if n("insert_flag", 0) == 1 {
                out.put(b"\x1b[4h")?;
            }
        } else {
            out.cursor(n("cursor_x", 0), y)?;
        }
        match s("pane_key_mode") {
            "Ext 1" => out.put(b"\x1b[>4;1m")?,
            "Ext 2" => out.put(b"\x1b[>4;2m")?,
            _ => {}
        }
        Ok(out.bytes)
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Ground,
    Escape,
    Csi,
    Osc,
    String,
}
pub struct Filter {
    state: State,
    sequence: Vec<u8>,
    escaped: bool,
    limit: usize,
}
impl Filter {
    pub fn new(limit: usize) -> Self {
        Self {
            state: State::Ground,
            sequence: Vec::new(),
            escaped: false,
            limit: limit.min(control::MAXIMUM),
        }
    }
    pub fn feed<'a>(&mut self, data: &'a [u8]) -> Result<Cow<'a, [u8]>, Error> {
        if self.state == State::Ground && !data.contains(&27) {
            return Ok(Cow::Borrowed(data));
        }
        let mut output = Vec::new();
        for &byte in data {
            if self.state == State::Ground {
                if byte == 27 {
                    self.state = State::Escape;
                    self.sequence.push(byte);
                } else {
                    output.push(byte);
                }
            } else {
                self.consume(byte, &mut output)?;
            }
        }
        Ok(Cow::Owned(output))
    }
    fn consume(&mut self, byte: u8, out: &mut Vec<u8>) -> Result<(), Error> {
        if self.sequence.len() >= self.limit {
            return Err(error("Tmux terminal output exceeds its byte limit"));
        }
        self.sequence.push(byte);
        let complete = if byte == 24 || byte == 26 {
            true
        } else {
            match self.state {
                State::Ground => false,
                State::Escape => {
                    if byte == 27 {
                        self.sequence.clear();
                        self.sequence.push(27);
                    } else if self.sequence.len() == 2 {
                        self.state = match byte {
                            b'[' => State::Csi,
                            b']' => State::Osc,
                            b'P' | b'X' | b'^' | b'_' => State::String,
                            _ => return self.end((48..=126).contains(&byte), out),
                        };
                        self.escaped = false;
                    } else {
                        return self.end((48..=126).contains(&byte), out);
                    }
                    false
                }
                State::Csi => {
                    if byte == 27 {
                        out.extend_from_slice(&self.sequence[..self.sequence.len() - 1]);
                        self.sequence.clear();
                        if self.sequence.capacity() > 4096 {
                            self.sequence = Vec::new();
                        }
                        self.sequence.push(27);
                        self.state = State::Escape;
                        false
                    } else {
                        (64..=126).contains(&byte)
                    }
                }
                State::Osc | State::String => {
                    if self.state == State::Osc && self.escaped && byte != 92 {
                        self.sequence.truncate(self.sequence.len() - 2);
                        self.sequence.extend_from_slice(b"\x1b\\");
                        if !query(&self.sequence) {
                            out.extend_from_slice(&self.sequence);
                        }
                        self.sequence.clear();
                        self.sequence.push(27);
                        self.state = State::Escape;
                        self.escaped = false;
                        return self.consume(byte, out);
                    }
                    let complete =
                        (self.state == State::Osc && byte == 7) || (self.escaped && byte == 92);
                    self.escaped = byte == 27;
                    complete
                }
            }
        };
        self.end(complete, out)
    }
    fn end(&mut self, complete: bool, out: &mut Vec<u8>) -> Result<(), Error> {
        if complete {
            if !query(&self.sequence) {
                out.extend_from_slice(&self.sequence);
            }
            if self.sequence.capacity() <= 4096 {
                self.sequence.clear();
            } else {
                self.sequence = Vec::new();
            }
            self.state = State::Ground;
            self.escaped = false;
        }
        Ok(())
    }
}
fn query(bytes: &[u8]) -> bool {
    let number = |b: &[u8]| {
        b.split(|b| *b == b';')
            .find(|s| !s.is_empty())
            .and_then(|s| std::str::from_utf8(s).ok())
            .and_then(|s| s.parse::<i64>().ok())
    };
    if bytes == b"\x1bZ" || bytes.starts_with(b"\x1bP$q") || bytes.starts_with(b"\x1bP+q") {
        return true;
    }
    if bytes.starts_with(b"\x1b[")
        && let Some(&end) = bytes.last()
    {
        let body = &bytes[2..bytes.len() - 1];
        if b"cnx".contains(&end)
            || (end == b'p' && body.ends_with(b"$"))
            || (end == b'q' && body.starts_with(b">"))
            || (end == b'u' && body == b"?")
            || (end == b'y' && body.ends_with(b"*"))
            || (end == b't' && number(body).is_some_and(|n| (11..=21).contains(&n)))
        {
            return true;
        }
    }
    bytes.starts_with(b"\x1b]")
        && number(&bytes[2..]).is_some_and(|n| [4, 10, 11, 12, 13, 14, 17, 19, 52].contains(&n))
        && bytes.windows(2).any(|b| b == b";?")
}

#[cfg(test)]
mod tests {
    use super::Snapshot;
    use std::collections::BTreeMap;

    fn snapshot(alternate: bool, preserve: bool) -> Vec<u8> {
        let state = BTreeMap::from([
            ("alternate_on".to_owned(), (alternate as u8).to_string()),
            ("pane_width".to_owned(), "20".to_owned()),
            ("pane_height".to_owned(), "2".to_owned()),
        ]);
        Snapshot {
            screen: vec![b"screen".to_vec()],
            saved: vec![b"saved".to_vec()],
            cursor: Vec::new(),
            state,
            preserve,
        }
        .bytes(1 << 20)
        .unwrap()
    }

    fn find(bytes: &[u8], needle: &[u8]) -> Option<usize> {
        bytes.windows(needle.len()).position(|w| w == needle)
    }

    /// A preserving renderer left on the alternate screen (it missed the pane's exit from a
    /// full-screen program) returns to the primary one; the pane's rows go there.
    #[test]
    fn preserved_primary_pane_leaves_a_stale_alternate_screen() {
        let bytes = snapshot(false, true);
        assert!(bytes.starts_with(b"\x1b[?1049l\x1b[H\x1b[2J"));
        assert_eq!(find(&bytes, b"\x1b[?1049h"), None);
        assert!(find(&bytes, b"screen").is_some());
    }

    /// A preserving renderer of a pane on its alternate screen gets the saved primary rows, then
    /// the alternate screen, like a full restore (which resets first instead).
    #[test]
    fn preserved_alternate_pane_restores_both_screens() {
        for preserve in [true, false] {
            let bytes = snapshot(true, preserve);
            let saved = find(&bytes, b"saved").unwrap();
            let enter = find(&bytes, b"\x1b[?1049h").unwrap();
            let screen = find(&bytes, b"screen").unwrap();
            assert!(saved < enter && enter < screen, "preserve={preserve}");
        }
    }
}
