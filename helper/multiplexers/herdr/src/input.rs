//! Native encoding of explicit input intent; ownership and submission stay with the caller.
use dispatch_helper_core::{
    api::{Error, Input, Key},
    json::{self, Data as D},
};

pub fn encode(pane: &str, input: &Input) -> Result<(&'static str, Vec<u8>), Error> {
    let (method, field, value) = match input {
        Input::Raw(_) => {
            return Err(Error {
                code: "raw_input",
                message: "Raw input uses the terminal stream.".into(),
            });
        }
        Input::Text(text) => ("pane.send_text", "text", D::String(text)),
        Input::Paste(text) => ("pane.send_input", "text", D::String(text)),
        Input::Key(key) => {
            let key = match key {
                Key::Enter => "Enter",
                Key::Escape => "Escape",
                Key::Up => "Up",
                Key::Down => "Down",
                Key::Left => "Left",
                Key::Right => "Right",
            };
            ("pane.send_keys", "keys", D::Array(vec![D::String(key)]))
        }
    };
    json::write(&D::Object(vec![
        ("pane_id", D::String(pane)),
        (field, value),
    ]))
    .map(|params| (method, params))
}
