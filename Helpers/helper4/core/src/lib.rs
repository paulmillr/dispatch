pub mod api;
pub mod date;
pub mod grapheme;
pub mod hash;
mod helper;
pub mod json;
mod menu;
mod probe;
mod prompt;
mod registered;
pub mod rpc;
pub mod system;
pub mod text;
pub mod tool;
pub mod wire;

pub use helper::DispatchHelper;
mod control;
mod dispatch;
mod encode;

/// Shared native metadata encoding; uses the same codec as wire byte fields.
pub mod base64 {
    pub use crate::dispatch::data as decode;
    pub use crate::encode::base64 as encode;
}
