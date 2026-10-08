use std::{env, path::PathBuf};
#[path = "build/schema.rs"]
mod schema;

fn main() {
    schema::generate(
        &PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()),
        &PathBuf::from(env::var_os("OUT_DIR").unwrap()),
    );
}
