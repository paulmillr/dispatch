//! files.git `verify-commit` through the shipped helper with a real gpg: the user's GnuPG configuration asks for every
//! kind of key lookup (a key server, auto-key-retrieve, WKD, auto-key-import), yet a signature by an unknown signer
//! stays unknown and nothing that could reach the network starts. The configuration's `dirmngr-program` is a stand-in
//! that leaves a mark when started; a check run as plain git does shows the configuration would start it.
//!
//! Needs git and gpg (2.1 or later); skipped without them. Throwaway GnuPG homes, a fictional signer.
//! cargo test -p dispatch-helper --test gpg_verify
use dispatch_helper_core::{
    json::Data,
    wire::{self, Collector, Header, Kind, Received, body},
};
use std::{
    io::{Read, Write},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

const SIGNER: &str = "Sam Example <sam@example.com>";

fn found(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path)
        .chain(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map(PathBuf::from))
        .map(|directory| directory.join(name))
        .find(|candidate| candidate.is_file())
}

/// The test's folder, its GnuPG homes' daemons ended and the folder removed whatever happens.
struct Scene {
    root: PathBuf,
    gpgconf: Option<PathBuf>,
    homes: Vec<PathBuf>,
}

impl Drop for Scene {
    fn drop(&mut self) {
        for home in &self.homes {
            if let Some(gpgconf) = &self.gpgconf {
                let _ = Command::new(gpgconf).arg("--homedir").arg(home).args(["--kill", "all"]).status();
            }
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

impl Scene {
    /// A GnuPG home (0700) whose gpg.conf is `conf`.
    fn home(&mut self, name: &str, conf: &str) -> PathBuf {
        let home = self.root.join(name);
        std::fs::create_dir_all(&home).unwrap();
        std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(home.join("gpg.conf"), conf).unwrap();
        self.homes.push(home.clone());
        home
    }
}

fn run(command: &mut Command) -> String {
    let output = command.stdin(Stdio::null()).output().unwrap();
    assert!(output.status.success(), "{command:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).into_owned()
}

/// One `files.git` request to a stdio helper whose environment is `PATH`, `HOME` and `GNUPGHOME`; its result's status
/// and output.
fn verify(scene: &Scene, path: &str, gnupg: &Path, repository: &Path, hash: &str) -> (i64, String) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_dispatch-helper"))
        .args(["--stdio", "--capabilities", "git.read"])
        .env_clear()
        .env("PATH", path)
        .env("HOME", scene.root.join("home"))
        .env("DISPATCH_TEST_ROOT", scene.root.join("state"))
        .env("GNUPGHOME", gnupg)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let (mut input, mut output) = (child.stdin.take().unwrap(), child.stdout.take().unwrap());
    let mut call = |id: u64, method: &str, params: Data<'_>| {
        let body = body::encode(&Data::Object(vec![("method", Data::String(method)), ("params", params)])).unwrap();
        input.write_all(&wire::packet(Kind::Request, id, &body).unwrap()).unwrap();
        let mut collector = Collector::new(id, wire::LIMIT as usize);
        loop {
            let mut head = [0; 13];
            output.read_exact(&mut head).unwrap();
            let header = Header::decode(&head, wire::LIMIT).unwrap();
            let mut bytes = vec![0; header.len as usize];
            output.read_exact(&mut bytes).unwrap();
            if header.id != id || header.kind != Kind::Response {
                continue;
            }
            if let Some(Received::Value(value)) = collector.push(header, &bytes).unwrap() {
                return value;
            }
        }
    };
    call(1, "hello", Data::Object(Vec::new()));
    let args = Data::Array(vec![Data::String("verify-commit"), Data::String("--raw"), Data::String(hash)]);
    let repository = repository.to_str().unwrap();
    let answer = call(
        2,
        "files.git",
        Data::Object(vec![
            ("plugin", Data::String("files")),
            ("path", Data::String(repository)),
            ("args", args),
            ("limit", Data::Unsigned(0)),
        ]),
    );
    let root = answer.root();
    let error = root.get("error").and_then(|error| error.get("message")).and_then(Data::string).map(str::to_owned);
    let result = root.get("result").unwrap_or_else(|| panic!("files.git failed: {error:?}"));
    let status = result.get("status").and_then(Data::signed).unwrap();
    let text = result.get("output").and_then(Data::string).unwrap().to_owned();
    drop(input);
    assert!(child.wait().unwrap().success());
    (status, text)
}

#[test]
fn an_unknown_signer_stays_unknown_and_nothing_reaches_for_the_network() {
    let (Some(git), Some(gpg)) = (found("git"), found("gpg")) else {
        eprintln!("skipped: needs git and gpg");
        return;
    };
    let gpgconf = gpg.parent().map(|directory| directory.join("gpgconf")).filter(|path| path.is_file());
    // Short: gpg's socket names must fit in sockaddr_un.
    let root = PathBuf::from(format!("/tmp/dg-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("state")).unwrap();
    let mut scene = Scene { root: root.clone(), gpgconf, homes: Vec::new() };

    // The signer's own home makes a key and signs a commit with it.
    let signer = scene.home("signer", "");
    let gpg_in = |home: &Path| {
        let mut command = Command::new(&gpg);
        command.env("GNUPGHOME", home).arg("--batch");
        command
    };
    run(gpg_in(&signer).args(["--passphrase", "", "--quick-gen-key", SIGNER, "ed25519", "sign", "never"]));
    let listed = run(gpg_in(&signer).args(["--list-keys", "--with-colons"]));
    let fingerprint = listed.lines().find_map(|line| line.strip_prefix("fpr:")).unwrap().trim_matches(':').to_owned();
    let repository = root.join("repository");
    std::fs::create_dir_all(&repository).unwrap();
    let git_in = || {
        let mut command = Command::new(&git);
        command
            .current_dir(&repository)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .args(["-c", "user.name=Sam Example", "-c", "user.email=sam@example.com"]);
        command
    };
    run(git_in().args(["init", "-q"]));
    std::fs::write(repository.join("notes.txt"), "signed\n").unwrap();
    run(git_in().args(["add", "notes.txt"]));
    let signing = [format!("user.signingkey={fingerprint}"), format!("gpg.program={}", gpg.display())];
    run(git_in().env("GNUPGHOME", &signer).args(["-c", &signing[0], "-c", &signing[1], "commit", "-q", "-S", "-m", "Signed"]));
    let hash = run(git_in().args(["rev-parse", "HEAD"])).trim().to_owned();

    // The user's configuration asks for every lookup; its dirmngr is a stand-in that leaves a mark.
    let mark = root.join("dirmngr-started");
    let dirmngr = root.join("dirmngr");
    std::fs::write(&dirmngr, format!("#!/bin/sh\necho \"$@\" >> '{}'\nexit 1\n", mark.display())).unwrap();
    std::fs::set_permissions(&dirmngr, std::fs::Permissions::from_mode(0o755)).unwrap();
    let conf = format!(
        "keyserver hkps://keys.example.invalid\nkeyserver-options auto-key-retrieve honor-keyserver-url\n\
         auto-key-retrieve\nauto-key-locate wkd,keyserver\nauto-key-import\ndirmngr-program {}\n",
        dirmngr.display()
    );
    let user = scene.home("user", &conf);

    // The configuration is effective: plain git starts that dirmngr for the unknown signer.
    let plain = Command::new(&git)
        .current_dir(&repository)
        .env("GNUPGHOME", &user)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .args(["-c", &signing[1], "verify-commit", "--raw", &hash])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(mark.exists(), "this gpg would not start dirmngr for {conf}: {}", String::from_utf8_lossy(&plain.stderr));
    std::fs::remove_file(&mark).unwrap();

    let mut path = std::env::join_paths([git.parent().unwrap(), gpg.parent().unwrap()]).unwrap();
    path.push(":/usr/bin:/bin");
    let path = path.into_string().unwrap();
    let (status, output) = verify(&scene, &path, &user, &repository, &hash);
    assert_ne!(status, 0, "{output}");
    assert!(output.contains("[GNUPG:] NO_PUBKEY") || output.contains("[GNUPG:] ERRSIG"), "{output}");
    assert!(!output.contains("GOODSIG"), "{output}");
    assert!(!mark.exists(), "dirmngr started: {}", std::fs::read_to_string(&mark).unwrap_or_default());
    // Nothing was imported: the keyring is as empty as before.
    let keys = Command::new(&gpg).env("GNUPGHOME", &user).args(["--batch", "--list-keys", "--with-colons"]).output().unwrap();
    assert!(!String::from_utf8_lossy(&keys.stdout).contains("fpr:"), "a key was imported");

    // An installed key still checks: the signer's public key imported into another such home.
    let known = scene.home("known", &conf);
    let public = run(gpg_in(&signer).args(["--armor", "--export", &fingerprint]));
    let mut import = gpg_in(&known).arg("--import").stdin(Stdio::piped()).stderr(Stdio::null()).spawn().unwrap();
    import.stdin.take().unwrap().write_all(public.as_bytes()).unwrap();
    assert!(import.wait().unwrap().success());
    let (status, output) = verify(&scene, &path, &known, &repository, &hash);
    assert!(output.contains(&format!("[GNUPG:] GOODSIG {} {SIGNER}", &fingerprint[24..])), "{output}");
    assert_eq!(status, 0, "{output}");
    assert!(!mark.exists(), "dirmngr started");
}

#[test]
fn the_helper_named_as_gpg_only_ever_checks_a_signature() {
    // Set by the helper for git alone: with it, any other invocation (a helper start, a signing request) exits 2 and
    // runs nothing.
    for args in [&["--stdio"][..], &["--status-fd=1", "-bsau", "0123456789ABCDEF"], &[]] {
        let output = Command::new(env!("CARGO_BIN_EXE_dispatch-helper"))
            .args(args)
            .env("DISPATCH_HELPER_GPG", "/nonexistent/gpg")
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        assert!(output.stdout.is_empty(), "{args:?}");
        assert!(String::from_utf8_lossy(&output.stderr).contains("the signature was not checked"), "{args:?}");
    }
}
