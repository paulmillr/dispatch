pub mod bridge;
pub mod events;
pub mod harness;
pub mod history;
pub mod install;
mod legacy;
pub mod presentation;
pub mod records;
pub mod registration;
pub mod screen;
pub mod side;
mod transcript;
pub use harness::Pi;

pub(crate) fn digest(bytes: &[u8]) -> String {
    let mut hash = dispatch_helper_core::hash::Sha256::new();
    hash.update(bytes);
    hash.finish()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
