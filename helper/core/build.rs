use std::{env, path::{Path, PathBuf}, process::Command};
#[path = "build/schema.rs"]
mod schema;

fn main() {
    let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    schema::generate(&manifest, &out);
    println!("cargo::rustc-check-cfg=cfg(dispatch_zstd)");
    // The replay corpus is zstd (Vendor/Zstd/PROVENANCE.md): only a macOS helper with the capture tool reads and
    // writes it. Linux helpers write live captures (bzip2) and need no C compiler.
    if env::var_os("CARGO_FEATURE_CAPTURE").is_some() && env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        zstd(&manifest.join("../../Vendor/Zstd/lib"), &out);
        println!("cargo::rustc-cfg=dispatch_zstd");
    }
}

/// Vendor/Zstd's common, compress and decompress sources as one static library, for the target's architecture.
fn zstd(lib: &Path, out: &Path) {
    println!("cargo::rerun-if-changed={}", lib.display());
    println!("cargo::rerun-if-env-changed=MACOSX_DEPLOYMENT_TARGET");
    let arch = match env::var("CARGO_CFG_TARGET_ARCH").unwrap().as_str() {
        "aarch64" => "arm64",
        other => other,
    }
    .to_owned();
    let deployment = env::var("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|_| "11.0".into());
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
                let (arch, deployment) = (&arch, &deployment);
                scope.spawn(move || {
                    let status = Command::new("xcrun")
                        .args(["--sdk", "macosx", "clang", "-c", "-O2", "-arch", arch])
                        .arg(format!("-mmacosx-version-min={deployment}"))
                        .args(["-DXXH_NAMESPACE=ZSTD_"])
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
    let status = Command::new("xcrun").args(["libtool", "-static", "-o"]).arg(&archive).args(&compiled).status().expect("xcrun libtool");
    assert!(status.success(), "archiving zstd");
    println!("cargo::rustc-link-search=native={}", out.display());
    println!("cargo::rustc-link-lib=static=dispatch_zstd");
}
