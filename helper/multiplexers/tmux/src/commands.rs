//! Literal native command encoding; submission authority remains in core.
use std::fmt::Write;

// c51466a tmux_submit.rs bounds each native literal argument to4096bytes.
const LITERAL: usize = 4096;

pub fn quote(value: &str) -> String {
    let mut result = String::with_capacity(value.len() + 2);
    result.push('"');
    for scalar in value.chars() {
        match scalar {
            '\\' | '"' | '$' => {
                result.push('\\');
                result.push(scalar);
            }
            scalar if (scalar as u32) < 32 || scalar == '\x7f' => {
                write!(result, "\\{:03o}", scalar as u32).unwrap();
            }
            scalar => result.push(scalar),
        }
    }
    result.push('"');
    result
}

pub fn input(bytes: &[u8], pane: u64) -> Vec<String> {
    bytes
        .chunks(256)
        .map(|chunk| {
            let mut command = format!("send-keys -H -t %{pane}");
            command.reserve(chunk.len() * 3);
            for byte in chunk {
                write!(command, " {byte:02x}").unwrap();
            }
            command
        })
        .collect()
}

pub fn keys(inputs: &[dispatch_helper_core::api::Input], pane: u64) -> Vec<String> {
    use dispatch_helper_core::api::{Input, Key};
    let mut commands = Vec::new();
    for value in inputs {
        match value {
            // Native literal arguments are C strings; hex preserves embedded NUL.
            Input::Raw(bytes) => commands.extend(input(bytes, pane)),
            Input::Text(text) | Input::Paste(text) if text.contains('\0') => {
                commands.extend(input(&Input::bytes(std::slice::from_ref(value)), pane))
            }
            // A paste is its bracketed bytes typed literally, chunked at UTF-8 boundaries like
            // c51466a tmux_submit.rs:42-48 over Input::terminal_bytes.
            Input::Text(_) | Input::Paste(_) => {
                let text = String::from_utf8(Input::bytes(std::slice::from_ref(value))).unwrap();
                let mut rest = text.as_str();
                for chunk in std::iter::from_fn(|| {
                    if rest.is_empty() {
                        return None;
                    }
                    let end = rest.floor_char_boundary(LITERAL.min(rest.len()));
                    let (chunk, next) = rest.split_at(end);
                    rest = next;
                    Some(chunk)
                }) {
                    commands.push(format!("send-keys -l -t %{pane} -- {}", quote(chunk)));
                }
            }
            Input::Key(key) => {
                let name = match key {
                    Key::Enter => "Enter",
                    Key::Escape => "Escape",
                    Key::Up => "Up",
                    Key::Down => "Down",
                    Key::Left => "Left",
                    Key::Right => "Right",
                };
                commands.push(format!("send-keys -t %{pane} {name}"));
            }
        }
    }
    commands
}
