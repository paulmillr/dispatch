//! Directly owned local terminal processes; harnesses never own a PTY.
mod mux;
mod process;
mod terminal;
pub use mux::Native;
