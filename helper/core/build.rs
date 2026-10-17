use std::{env, path::{Path, PathBuf}, process::Command};
#[path = "build/schema.rs"]
mod schema;

fn main() {
    let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    schema::generate(&manifest, &out);
    // Captures are zstd (Vendor/Zstd/PROVENANCE.md): every helper with the capture tool reads and writes them.
    if env::var_os("CARGO_FEATURE_CAPTURE").is_some() {
        zstd(&manifest.join("../../Vendor/Zstd"), &out);
    }
}

/// Vendor/Zstd's common, compress and decompress sources as one static library, for the target: macOS with its SDK,
/// Linux (musl) with the same clang and the vendored freestanding headers, since macOS has no Linux libc headers.
fn zstd(vendor: &Path, out: &Path) {
    let lib = vendor.join("lib");
    println!("cargo::rerun-if-changed={}", vendor.display());
    println!("cargo::rerun-if-env-changed=MACOSX_DEPLOYMENT_TARGET");
    let (os, arch) = (env::var("CARGO_CFG_TARGET_OS").unwrap(), env::var("CARGO_CFG_TARGET_ARCH").unwrap());
    let flags: Vec<String> = match os.as_str() {
        "macos" => {
            let deployment = env::var("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|_| "11.0".into());
            let arch = if arch == "aarch64" { "arm64".into() } else { arch };
            vec!["--sdk".into(), "macosx".into(), "clang".into(), "-arch".into(), arch, format!("-mmacosx-version-min={deployment}")]
        }
        // clang's own stddef.h defers to the system's on musl (`__musl__`); freestanding, it defines size_t itself.
        "linux" => vec![
            "clang".into(),
            format!("--target={arch}-unknown-linux-musl"),
            "-U__musl__".into(),
            "-ffreestanding".into(),
            "-nostdlibinc".into(),
            "-isystem".into(),
            vendor.join("freestanding").display().to_string(),
        ],
        other => panic!("captures (zstd) are built for macOS and Linux helpers, not {other}"),
    };
    let objects = out.join("zstd");
    std::fs::create_dir_all(&objects).unwrap();
    let sources: Vec<PathBuf> = ["common", "compress", "decompress"]
        .iter()
        .flat_map(|part| std::fs::read_dir(lib.join(part)).unwrap().map(|entry| entry.unwrap().path()))
        .filter(|path| path.extension().is_some_and(|extension| extension == "c"))
        .collect();
    let compiled: Vec<PathBuf> = std::thread::scope(|scope| {
        let jobs: Vec<_> = sources
            .iter()
            .map(|source| {
                let object = objects.join(source.file_stem().unwrap()).with_extension("o");
                let (flags, lib) = (&flags, &lib);
                scope.spawn(move || {
                    let status = Command::new("xcrun")
                        .args(flags)
                        .args(["-c", "-O2", "-DXXH_NAMESPACE=ZSTD_"])
                        .arg("-I")
                        .arg(lib)
                        .arg(source)
                        .arg("-o")
                        .arg(&object)
                        .status()
                        .expect("xcrun clang");
                    assert!(status.success(), "compiling {}", source.display());
                    object
                })
            })
            .collect();
        jobs.into_iter().map(|job| job.join().unwrap()).collect()
    });
    let archive = out.join("libdispatch_zstd.a");
    let _ = std::fs::remove_file(&archive);
    // libtool archives only Mach-O. For ELF, ar's S skips the symbol index (macOS ranlib cannot read ELF); rust-lld
    // links the archive without one.
    let status = if os == "macos" {
        Command::new("xcrun").args(["libtool", "-static", "-o"]).arg(&archive).args(&compiled).status()
    } else {
        Command::new("xcrun").args(["ar", "rcS"]).arg(&archive).args(&compiled).status()
    }
    .expect("archiving zstd");
    assert!(status.success(), "archiving zstd");
    println!("cargo::rustc-link-search=native={}", out.display());
    println!("cargo::rustc-link-lib=static=dispatch_zstd");
}
