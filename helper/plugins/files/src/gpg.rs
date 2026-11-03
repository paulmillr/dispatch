//! The helper as `gpg.program` for `verify-commit` (git.rs `signing`). Git cannot pass gpg options of its own, and
//! the user's `gpg.conf` may ask a check of an unknown signature to fetch the key: `auto-key-retrieve`, a key server,
//! WKD, all through `dirmngr`. So git runs this helper, with the trusted gpg the helper found in PROGRAM, and it runs
//! that gpg with fixed options before git's own: no dirmngr at all, no automatic key retrieval, import or locate, no
//! photo viewer. Command-line options win over the configuration file; the user's installed keys and trust settings
//! still decide the verdict, and an unknown signer stays unknown.
use std::{
    collections::BTreeSet,
    ffi::OsString,
    path::Path,
    process::{Command, Stdio},
};

/// The trusted gpg, set only in the environment of the git that checks a signature.
pub const PROGRAM: &str = "DISPATCH_HELPER_GPG";

/// gpg's options before git's. One the installed gpg does not list (an older one lacks `--no-auto-key-import`) is
/// left out, except `--disable-dirmngr`: a gpg without it (gpg 1, 2.0) reaches key servers through helpers of its own,
/// and is not run.
const FIXED: [&str; 6] = [
    "--batch",
    "--disable-dirmngr",
    "--no-auto-key-retrieve",
    "--no-auto-key-import",
    "--no-auto-key-locate",
    "--verify-options=no-show-photos",
];
const NEEDED: &str = "--disable-dirmngr";

/// The helper run as gpg: Some(exit status) whenever PROGRAM is set (anything but a verification exits 2), None when
/// it is not. It never returns after starting gpg, and never goes on to start as a helper.
pub fn wrapper() -> Option<i32> {
    let program = std::env::var_os(PROGRAM)?;
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    Some(run(Path::new(&program), &args))
}

fn run(program: &Path, args: &[OsString]) -> i32 {
    use std::os::unix::process::CommandExt;
    let refuse = |message: String| {
        eprintln!("dispatch-helper: {message}; the signature was not checked");
        2
    };
    if !program.is_absolute() {
        return refuse(format!("{} is not an absolute path", program.display()));
    }
    if !verification(args) {
        return refuse("git asked gpg for more than checking a signature".into());
    }
    let listed = Command::new(program)
        .arg("--dump-options")
        .env_remove(PROGRAM)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output();
    let listed = match listed {
        Ok(listed) if listed.status.success() => listed,
        Ok(listed) => return refuse(format!("{} --dump-options failed ({})", program.display(), listed.status)),
        Err(error) => return refuse(format!("{} could not run: {error}", program.display())),
    };
    let Some(options) = arguments(&String::from_utf8_lossy(&listed.stdout)) else {
        return refuse(format!("{} cannot be kept off the network (it has no {NEEDED})", program.display()));
    };
    let error = Command::new(program).env_remove(PROGRAM).args(options).args(args).exec();
    refuse(format!("{} could not run: {error}", program.display()))
}

/// What git passes for an OpenPGP check: `--keyid-format=long` and `--status-fd=1` (either may be missing in another
/// git), then `--verify <signature file> -`. Nothing else is passed on: this is never a signing program.
pub(crate) fn verification(args: &[OsString]) -> bool {
    let Some(at) = args.iter().position(|arg| arg == "--verify") else { return false };
    let (options, check) = args.split_at(at);
    options.iter().all(|option| matches!(option.to_str(), Some("--keyid-format=long" | "--status-fd=1")))
        && check.len() == 3
        && !check[1].is_empty()
        && !check[1].as_encoded_bytes().starts_with(b"-")
        && check[2] == "-"
}

/// FIXED, less the options `dump` (`gpg --dump-options`, one per line) does not list; None without NEEDED.
pub(crate) fn arguments(dump: &str) -> Option<Vec<&'static str>> {
    let known: BTreeSet<&str> = dump.lines().map(str::trim).collect();
    if !known.contains(NEEDED) {
        return None;
    }
    let listed = |option: &&str| known.contains(option.split('=').next().unwrap_or(option));
    Some(FIXED.iter().copied().filter(listed).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    #[test]
    fn only_a_verification_is_passed_on() {
        for args in [
            &["--keyid-format=long", "--status-fd=1", "--verify", "/tmp/.git_vtag_tmp1", "-"][..],
            &["--status-fd=1", "--verify", "/tmp/.git_vtag_tmp1", "-"],
            &["--verify", "/tmp/.git_vtag_tmp1", "-"],
        ] {
            assert!(verification(&strings(args)), "{args:?}");
        }
        for args in [
            &["--status-fd=1", "-bsau", "key"][..],
            &["--status-fd=1", "--verify", "/tmp/sig"],
            &["--status-fd=1", "--verify", "/tmp/sig", "/tmp/data"],
            &["--status-fd=1", "--verify", "--import", "-"],
            &["--keyserver", "hkps://keys.example.invalid", "--verify", "/tmp/sig", "-"],
            &["--status-fd=1", "--verify", "/tmp/sig", "-", "--recv-keys"],
        ] {
            assert!(!verification(&strings(args)), "{args:?}");
        }
    }

    #[test]
    fn the_fixed_options_are_those_this_gpg_knows_and_dirmngr_is_always_off() {
        let all = "--batch\n--disable-dirmngr\n--no-auto-key-retrieve\n--no-auto-key-import\n--no-auto-key-locate\n--verify-options\n";
        assert_eq!(arguments(all).unwrap(), FIXED);
        // gpg 2.2 before --auto-key-import.
        let older = all.replace("--no-auto-key-import\n", "");
        let options = arguments(&older).unwrap();
        assert!(!options.contains(&"--no-auto-key-import") && options.contains(&"--no-auto-key-retrieve"), "{options:?}");
        // gpg 1.4 and 2.0 talk to key servers without dirmngr: not run at all.
        assert_eq!(arguments(&all.replace("--disable-dirmngr\n", "")), None);
        assert_eq!(arguments(""), None);
    }
}
